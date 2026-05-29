import 'dart:convert';
import 'dart:io';

import '../ast.dart';
import '../lexer.dart';
import '../parser.dart';
import '../source_provider.dart';
import 'environment.dart';
import 'value.dart';

// --- control-flow signals (not real exceptions) ---

class _ReturnSignal {
  final Value value;
  _ReturnSignal(this.value);
}

class _PropagateError {
  final Value error;
  _PropagateError(this.error);
}

// --- public error type ---

class InterpreterError implements Exception {
  final String message;
  InterpreterError(this.message);

  @override
  String toString() => message;
}

// --- interpreter ---

class Interpreter {
  // user-defined methods: typeName -> methodName -> (FnDecl, closureEnv)
  final _methods = <String, Map<String, (FnDecl, Environment)>>{};

  // native methods: typeName -> methodName -> NativeFnValue
  final _nativeMethods = <String, Map<String, NativeFnValue>>{};

  // base directory for resolving relative imports; set per-execution
  String? _baseDir;

  // resolves file paths to source text; supports overlays for LSP
  final SourceProvider sourceProvider;

  // SDK root for locating stdlib .aero source files (may be null in tests)
  final String? sdkRoot;

  // registry of native function implementations keyed by 'module.function'
  late final Map<String, Value Function(List<Value>, Map<String, Value>)>
      _nativeFnImpls;

  Interpreter({SourceProvider? sourceProvider, this.sdkRoot})
      : sourceProvider = sourceProvider ?? SourceProvider() {
    _nativeFnImpls = _buildNativeFnImpls();
    _registerNativeMethods();
  }

  // ---- public entry points ----

  /// Execute [program] with the given CLI [args].
  /// [baseDir] is used to resolve relative imports.
  /// Returns the process exit code.
  int execute(Program program, List<String> args, {String? baseDir}) {
    _baseDir = baseDir;
    final env = Environment();
    _setupGlobals(env);
    _loadDecls(program.decls, env);

    final mainFn = env.tryLookup('main');
    if (mainFn == null) {
      stderr.writeln('error: no main function');
      return 1;
    }

    final argsValue = _makeArgsValue(args);
    try {
      final result = _callFnWithValues(
        (mainFn as FnValue).decl,
        (mainFn).closure,
        null,
        {'args': argsValue},
      );
      return switch (result) {
        ResultValue(isOk: true, inner: IntValue(:final v)) => v,
        ResultValue(isOk: true) => 0,
        ResultValue(isOk: false, :final inner) => () {
            stderr.writeln('error: ${inner.display()}');
            return 1;
          }(),
        IntValue(:final v) => v,
        _ => 0,
      };
    } on InterpreterError catch (e) {
      stderr.writeln('error: $e');
      return 1;
    }
  }

  // ---- declarations ----

  void _registerImpl(ImplDecl decl, Environment env) {
    final typeName = decl.typeName;
    _methods.putIfAbsent(typeName, () => {});
    for (final method in decl.methods) {
      _methods[typeName]![method.name] = (method, env);
    }
  }

  void _handleImport(String path, String? alias, Environment env) {
    // stdlib modules start with 'std.'
    if (path.startsWith('std.')) {
      final moduleName = path.split('.').last;
      final prefix = alias ?? moduleName;
      // Prefer loading from the SDK source file; fall back to synthetic.
      final root = sdkRoot;
      if (root != null) {
        final stdlibFile = '$root/src/std/$moduleName.aero';
        if (File(stdlibFile).existsSync()) {
          final module = _loadStdlibModule(moduleName, stdlibFile);
          if (module != null) {
            env.define(prefix, module);
            return;
          }
        }
      }
      final module = _makeSyntheticModule(path);
      if (module != null) env.define(prefix, module);
      return;
    }
    // relative file import: load <baseDir>/<path>.aero
    _handleFileImport(path, alias, env);
  }

  /// Load a stdlib module from its .aero source file.
  ///
  /// For `native fn` declarations the Dart implementation is looked up in
  /// [_nativeFnImpls]. Regular `fn` declarations become [FnValue]s executed
  /// by the interpreter. Returns null on any parse or I/O error so the caller
  /// can fall back to the synthetic module.
  StructValue? _loadStdlibModule(String moduleName, String filePath) {
    try {
      final source = File(filePath).readAsStringSync();
      final lexResult = Lexer(source).tokenize();
      if (lexResult.hasErrors) return null;
      final parseResult = Parser(lexResult.tokens).parse();
      if (parseResult.hasErrors) return null;

      // The module environment inherits all globals so Aero-coded stdlib
      // functions can use Ok, Err, println, etc.
      final moduleEnv = Environment();
      _setupGlobals(moduleEnv);

      final fields = <String, Value>{};

      for (final decl in parseResult.program.decls) {
        if (decl is ConstDecl) {
          final val = _evalExpr(decl.value, moduleEnv);
          fields[decl.name] = val;
          moduleEnv.define(decl.name, val);
          continue;
        }
        if (decl is! FnDecl) continue;
        final Value? fn;
        if (decl.isNative) {
          final impl = _nativeFnImpls['$moduleName.${decl.name}'];
          fn = impl != null
              ? NativeFnValue('$moduleName.${decl.name}', impl)
              : null;
        } else if (decl.body != null) {
          fn = FnValue(decl, moduleEnv);
        } else {
          fn = null;
        }
        if (fn != null) {
          fields[decl.name] = fn;
          moduleEnv.define(decl.name, fn);
        }
      }

      return fields.isEmpty ? null : StructValue('_Module', fields);
    } catch (_) {
      return null; // fall through to synthetic module
    }
  }

  void _handleFileImport(String path, String? alias, Environment env) {
    final base = _baseDir;
    if (base == null)
      throw InterpreterError(
          'relative import "$path" but no base directory set');
    final filePath = '$base/$path.aero';
    final String source;
    try {
      source = sourceProvider.read(filePath);
    } on FileSystemException {
      throw InterpreterError(
          'cannot find module "$path" (looked for $filePath)');
    }
    final lexResult = Lexer(source).tokenize();
    if (lexResult.hasErrors) {
      throw InterpreterError(
          'lex errors in $filePath: ${lexResult.errors.first}');
    }
    final parseResult = Parser(lexResult.tokens).parse();
    if (parseResult.hasErrors) {
      throw InterpreterError(
          'parse errors in $filePath: ${parseResult.errors.first}');
    }
    // Execute the imported module's declarations into the current env so that
    // its functions and impls are directly visible (no prefix for file imports).
    _loadDecls(parseResult.program.decls, env);
  }

  void _loadDecls(List<Decl> decls, Environment env) {
    for (final decl in decls) {
      switch (decl) {
        case FnDecl():
          env.define(decl.name, FnValue(decl, env));
        case ImplDecl():
          _registerImpl(decl, env);
        case ImportDecl():
          _handleImport(decl.path, decl.alias, env);
        case TypeDecl():
          break;
        case InterfaceDecl():
          break;
        case ConstDecl():
          env.define(decl.name, _evalExpr(decl.value, env));
      }
    }
  }

  /// Build the registry used by [_loadStdlibModule] to resolve `native fn`
  /// declarations in .aero stdlib files to their Dart implementations.
  Map<String, Value Function(List<Value>, Map<String, Value>)>
      _buildNativeFnImpls() {
    // Extract each implementation from the corresponding synthetic module so
    // there is a single source of truth: the synthetic modules below.
    Value call(StructValue m, String name, List<Value> a, Map<String, Value> n) =>
        (m.fields[name] as NativeFnValue).fn(a, n);
    final fs = _makeFsModule();
    final path = _makePathModule();
    final process = _makeProcessModule();
    final fiber = _makeFiberModule();
    final string = _makeStringModule();
    return {
      for (final k in fs.fields.keys) 'fs.$k': (a, n) => call(fs, k, a, n),
      for (final k in path.fields.keys) 'path.$k': (a, n) => call(path, k, a, n),
      for (final k in process.fields.keys)
        'process.$k': (a, n) => call(process, k, a, n),
      for (final k in fiber.fields.keys)
        'fiber.$k': (a, n) => call(fiber, k, a, n),
      for (final k in string.fields.keys)
        'string.$k': (a, n) => call(string, k, a, n),
      // std.testing is not here: testing.aero uses regular Aero functions,
      // not native fn declarations, so no registry entries are needed.
    };
  }

  Value? _makeSyntheticModule(String path) => switch (path) {
        'std.fs' => _makeFsModule(),
        'std.path' => _makePathModule(),
        'std.process' => _makeProcessModule(),
        'std.testing' => _makeTestingModule(),
        'std.fiber' => _makeFiberModule(),
        'std.string' => _makeStringModule(),
        _ => null,
      };

  // ---- global setup ----

  void _setupGlobals(Environment env) {
    // Result constructors
    env.define(
      'Ok',
      NativeFnValue('Ok', (args, named) => ResultValue.ok(args.first)),
    );
    env.define(
      'Err',
      NativeFnValue('Err', (args, named) => ResultValue.err(args.first)),
    );

    // Option constructors
    env.define(
      'Some',
      NativeFnValue('Some', (args, named) => OptionValue.some(args.first)),
    );
    env.define('None', const OptionValue.none());

    // I/O
    env.define(
      'println',
      NativeFnValue('println', (args, named) {
        stdout.writeln(args.isEmpty ? '' : args.first.display());
        return VoidValue.instance;
      }),
    );
    env.define(
      'print',
      NativeFnValue('print', (args, named) {
        stdout.write(args.isEmpty ? '' : args.first.display());
        return VoidValue.instance;
      }),
    );
    env.define(
      'eprintln',
      NativeFnValue('eprintln', (args, named) {
        stderr.writeln(args.isEmpty ? '' : args.first.display());
        return VoidValue.instance;
      }),
    );
  }

  // ---- stdlib modules ----

  StructValue _makeStringModule() => StructValue('_Module', {
        'from_chars': NativeFnValue('string.from_chars', (args, named) {
          final cps = (args[0] as ListValue).items.map((v) => (v as IntValue).v);
          return StringValue(String.fromCharCodes(cps));
        }),
      });

  StructValue _makeFsModule() => StructValue('_Module', {
        'read_text': NativeFnValue('fs.read_text', (args, named) {
          final path = (args.first as StringValue).v;
          try {
            return ResultValue.ok(StringValue(File(path).readAsStringSync()));
          } catch (e) {
            return ResultValue.err(StringValue(e.toString()));
          }
        }),
        'write_text': NativeFnValue('fs.write_text', (args, named) {
          final path = (args[0] as StringValue).v;
          final text = (args[1] as StringValue).v;
          try {
            File(path).writeAsStringSync(text);
            return ResultValue.ok(VoidValue.instance);
          } catch (e) {
            return ResultValue.err(StringValue(e.toString()));
          }
        }),
        'exists': NativeFnValue('fs.exists', (args, named) {
          final path = (args.first as StringValue).v;
          return BoolValue.of(File(path).existsSync());
        }),
        'read_dir': NativeFnValue('fs.read_dir', (args, named) {
          final path = (args.first as StringValue).v;
          try {
            final names = Directory(path)
                .listSync()
                .map((e) {
                  final p = e.path;
                  return p.substring(p.lastIndexOf('/') + 1);
                })
                .toList()
              ..sort();
            return ResultValue.ok(
                ListValue(names.map<Value>((n) => StringValue(n)).toList()));
          } catch (e) {
            return ResultValue.err(StringValue(e.toString()));
          }
        }),
      });

  StructValue _makePathModule() => StructValue('_Module', {
        'join': NativeFnValue('path.join', (args, named) {
          final base = (args[0] as StringValue).v;
          final part = (args[1] as StringValue).v;
          if (part.isEmpty) return StringValue(base);
          if (base.isEmpty || part.startsWith('/')) return StringValue(part);
          return StringValue(base.endsWith('/') ? '$base$part' : '$base/$part');
        }),
        'dirname': NativeFnValue('path.dirname', (args, named) {
          final p = (args[0] as StringValue).v;
          final idx = p.lastIndexOf('/');
          if (idx < 0) return const StringValue('.');
          if (idx == 0) return const StringValue('/');
          return StringValue(p.substring(0, idx));
        }),
        'basename': NativeFnValue('path.basename', (args, named) {
          final p = (args[0] as StringValue).v;
          return StringValue(p.substring(p.lastIndexOf('/') + 1));
        }),
        'stem': NativeFnValue('path.stem', (args, named) {
          final p = (args[0] as StringValue).v;
          final name = p.substring(p.lastIndexOf('/') + 1);
          final dot = name.lastIndexOf('.');
          return StringValue(dot > 0 ? name.substring(0, dot) : name);
        }),
        'extension': NativeFnValue('path.extension', (args, named) {
          final p = (args[0] as StringValue).v;
          final name = p.substring(p.lastIndexOf('/') + 1);
          final dot = name.lastIndexOf('.');
          return StringValue(dot > 0 ? name.substring(dot) : '');
        }),
        'is_absolute': NativeFnValue('path.is_absolute', (args, named) {
          final p = (args[0] as StringValue).v;
          return BoolValue.of(
              p.startsWith('/') || (p.length > 1 && p[1] == ':'));
        }),
      });

  StructValue _makeProcessModule() => StructValue('_Module', {
        'run': NativeFnValue('process.run', (args, named) {
          final cmd = (args[0] as StringValue).v;
          final argList = (named['args'] as ListValue?)
                  ?.items
                  .map((v) => (v as StringValue).v)
                  .toList() ??
              [];
          try {
            final result = Process.runSync(cmd, argList, runInShell: false);
            if (result.exitCode != 0) {
              return ResultValue.err(StructValue('ProcessError', {
                'stdout': StringValue(result.stdout as String),
                'stderr': StringValue(result.stderr as String),
                'exit_code': IntValue(result.exitCode),
                'message':
                    StringValue('process exited with code ${result.exitCode}'),
              }));
            }
            return ResultValue.ok(StructValue('Output', {
              'stdout': StringValue(result.stdout as String),
              'stderr': StringValue(result.stderr as String),
              'exit_code': IntValue(result.exitCode),
            }));
          } catch (e) {
            return ResultValue.err(StringValue(e.toString()));
          }
        }),
      });

  StructValue _makeTestingModule() => StructValue('_Module', {
        'assert': NativeFnValue('testing.assert', (args, named) {
          final condition = (args.first as BoolValue).v;
          if (!condition) {
            final msg = named['message'] is StringValue
                ? (named['message'] as StringValue).v
                : 'assertion failed';
            throw _PropagateError(StringValue(msg));
          }
          return ResultValue.ok(VoidValue.instance);
        }),
        'assert_eq': NativeFnValue('testing.assert_eq', (args, named) {
          final actual = named['actual']!;
          final expected = named['expected']!;
          if (actual != expected) {
            throw _PropagateError(StringValue(
                'assert_eq failed\n  actual:   ${actual.debug()}\n  expected: ${expected.debug()}'));
          }
          return ResultValue.ok(VoidValue.instance);
        }),
        'assert_ne': NativeFnValue('testing.assert_ne', (args, named) {
          final actual = named['actual']!;
          final unexpected = named['unexpected']!;
          if (actual == unexpected) {
            throw _PropagateError(StringValue(
                'assert_ne failed: both values were ${actual.debug()}'));
          }
          return ResultValue.ok(VoidValue.instance);
        }),
        'assert_ok': NativeFnValue('testing.assert_ok', (args, named) {
          final result = args.first as ResultValue;
          if (!result.isOk) {
            throw _PropagateError(StringValue(
                'assert_ok failed: got Err(${result.inner.debug()})'));
          }
          return ResultValue.ok(result.inner);
        }),
        'assert_err': NativeFnValue('testing.assert_err', (args, named) {
          final result = args.first as ResultValue;
          if (result.isOk) {
            throw _PropagateError(StringValue('assert_err failed: got Ok'));
          }
          return ResultValue.ok(VoidValue.instance);
        }),
      });

  StructValue _makeFiberModule() => StructValue('_Module', {
        // stub — fibers not yet implemented in the interpreter
        'spawn': NativeFnValue('fiber.spawn', (args, named) {
          throw InterpreterError('fiber.spawn not implemented in interpreter');
        }),
      });

  // ---- native method registry ----

  void _registerNativeMethods() {
    _nativeMethods['String'] = {
      'len': NativeFnValue('String.len', (args, named) {
        return IntValue((args[0] as StringValue).v.runes.length);
      }),
      'byte_len': NativeFnValue('String.byte_len', (args, named) {
        return IntValue(utf8.encode((args[0] as StringValue).v).length);
      }),
      'is_empty': NativeFnValue('String.is_empty', (args, named) {
        return BoolValue.of((args[0] as StringValue).v.isEmpty);
      }),
      'chars': NativeFnValue('String.chars', (args, named) {
        final runes = (args[0] as StringValue).v.runes;
        return ListValue(runes.map<Value>((r) => IntValue(r)).toList());
      }),
      'slice': NativeFnValue('String.slice', (args, named) {
        final runes = (args[0] as StringValue).v.runes.toList();
        final start = (args[1] as IntValue).v;
        final end = (args[2] as IntValue).v;
        final clamped = runes.sublist(
            start.clamp(0, runes.length), end.clamp(0, runes.length));
        return StringValue(String.fromCharCodes(clamped));
      }),
      'trim': NativeFnValue('String.trim', (args, named) {
        return StringValue((args[0] as StringValue).v.trim());
      }),
      'lines': NativeFnValue('String.lines', (args, named) {
        final s = (args[0] as StringValue).v;
        if (s.isEmpty) return ListValue([]);
        // A trailing newline does not produce an extra empty entry.
        final trimmed = s.endsWith('\n') ? s.substring(0, s.length - 1) : s;
        return ListValue(
            trimmed.split('\n').map((l) => StringValue(l)).toList());
      }),
      'split_whitespace':
          NativeFnValue('String.split_whitespace', (args, named) {
        final s = (args[0] as StringValue).v;
        return ListValue(s
            .trim()
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .map((w) => StringValue(w))
            .toList());
      }),
      'split': NativeFnValue('String.split', (args, named) {
        final s = (args[0] as StringValue).v;
        final sep = (args[1] as StringValue).v;
        return ListValue(s.split(sep).map((p) => StringValue(p)).toList());
      }),
      'starts_with': NativeFnValue('String.starts_with', (args, named) {
        return BoolValue.of(
            (args[0] as StringValue).v.startsWith((args[1] as StringValue).v));
      }),
      'ends_with': NativeFnValue('String.ends_with', (args, named) {
        return BoolValue.of(
            (args[0] as StringValue).v.endsWith((args[1] as StringValue).v));
      }),
      'contains': NativeFnValue('String.contains', (args, named) {
        return BoolValue.of(
            (args[0] as StringValue).v.contains((args[1] as StringValue).v));
      }),
      'to_uppercase': NativeFnValue('String.to_uppercase', (args, named) {
        return StringValue((args[0] as StringValue).v.toUpperCase());
      }),
      'to_lowercase': NativeFnValue('String.to_lowercase', (args, named) {
        return StringValue((args[0] as StringValue).v.toLowerCase());
      }),
      'parse': NativeFnValue('String.parse', (args, named) {
        final s = (args[0] as StringValue).v;
        final n = int.tryParse(s) ?? double.tryParse(s);
        if (n == null) return ResultValue.err(StringValue('parse error: "$s"'));
        return ResultValue.ok(
            n is int ? IntValue(n) : FloatValue(n.toDouble()));
      }),
      'debug': NativeFnValue('String.debug', (args, named) {
        return StringValue((args[0] as StringValue).debug());
      }),
    };

    _nativeMethods['Int'] = {
      'debug': NativeFnValue('Int.debug', (args, named) {
        return StringValue(args[0].debug());
      }),
    };

    _nativeMethods['List'] = {
      'len': NativeFnValue('List.len', (args, named) {
        return IntValue((args[0] as ListValue).items.length);
      }),
      'map': NativeFnValue('List.map', (args, named) {
        final list = args[0] as ListValue;
        final fn = args[1];
        return ListValue(
            list.items.map((item) => _callValueDirect(fn, [item])).toList());
      }),
      'filter': NativeFnValue('List.filter', (args, named) {
        final list = args[0] as ListValue;
        final fn = args[1];
        return ListValue(list.items.where((item) {
          final result = _callValueDirect(fn, [item]);
          return result.isTruthy;
        }).toList());
      }),
      'to_list': NativeFnValue('List.to_list', (args, named) {
        return args[0]; // already a ListValue
      }),
      'sort': NativeFnValue('List.sort', (args, named) {
        final list = args[0] as ListValue;
        final sorted = List<Value>.from(list.items)
          ..sort((a, b) {
            if (a is StringValue && b is StringValue) return a.v.compareTo(b.v);
            if (a is IntValue && b is IntValue) return a.v.compareTo(b.v);
            return 0;
          });
        return ListValue(sorted);
      }),
      'push': NativeFnValue('List.push', (args, named) {
        (args[0] as ListValue).items.add(args[1]);
        return VoidValue.instance;
      }),
      'first': NativeFnValue('List.first', (args, named) {
        final list = args[0] as ListValue;
        return list.items.isEmpty
            ? const OptionValue.none()
            : OptionValue.some(list.items.first);
      }),
      'last': NativeFnValue('List.last', (args, named) {
        final list = args[0] as ListValue;
        return list.items.isEmpty
            ? const OptionValue.none()
            : OptionValue.some(list.items.last);
      }),
      'is_empty': NativeFnValue('List.is_empty', (args, named) {
        return BoolValue.of((args[0] as ListValue).items.isEmpty);
      }),
      'contains': NativeFnValue('List.contains', (args, named) {
        final list = args[0] as ListValue;
        final target = args[1];
        return BoolValue.of(list.items.any((item) => item == target));
      }),
      'join': NativeFnValue('List.join', (args, named) {
        final list = args[0] as ListValue;
        final sep = (args[1] as StringValue).v;
        return StringValue(
            list.items.map((v) => v.display()).join(sep));
      }),
    };

    _nativeMethods['Map'] = {
      'len': NativeFnValue('Map.len', (args, named) {
        return IntValue((args[0] as MapValue).entries.length);
      }),
      'is_empty': NativeFnValue('Map.is_empty', (args, named) {
        return BoolValue.of((args[0] as MapValue).entries.isEmpty);
      }),
      'has': NativeFnValue('Map.has', (args, named) {
        return BoolValue.of((args[0] as MapValue).entries.containsKey(args[1]));
      }),
      'get': NativeFnValue('Map.get', (args, named) {
        final v = (args[0] as MapValue).entries[args[1]];
        return v != null ? OptionValue.some(v) : const OptionValue.none();
      }),
      'keys': NativeFnValue('Map.keys', (args, named) {
        return ListValue((args[0] as MapValue).entries.keys.toList());
      }),
      'values': NativeFnValue('Map.values', (args, named) {
        return ListValue((args[0] as MapValue).entries.values.toList());
      }),
      'remove': NativeFnValue('Map.remove', (args, named) {
        final removed = (args[0] as MapValue).entries.remove(args[1]);
        return removed != null
            ? OptionValue.some(removed)
            : const OptionValue.none();
      }),
    };

    _nativeMethods['Option'] = {
      'ok_or': NativeFnValue('Option.ok_or', (args, named) {
        final opt = args[0] as OptionValue;
        if (opt.isSome) return ResultValue.ok(opt.inner!);
        // The error value is the first positional arg after self.
        final errVal = args.length > 1 ? args[1] : StringValue('None');
        return ResultValue.err(errVal);
      }),
      'is_some': NativeFnValue('Option.is_some', (args, named) {
        return BoolValue.of((args[0] as OptionValue).isSome);
      }),
      'is_none': NativeFnValue('Option.is_none', (args, named) {
        return BoolValue.of((args[0] as OptionValue).isNone);
      }),
      'unwrap': NativeFnValue('Option.unwrap', (args, named) {
        final opt = args[0] as OptionValue;
        if (opt.isSome) return opt.inner!;
        throw _PropagateError(StringValue('unwrap called on None'));
      }),
      'map': NativeFnValue('Option.map', (args, named) {
        final opt = args[0] as OptionValue;
        if (opt.isNone) return const OptionValue.none();
        return OptionValue.some(_callValueDirect(args[1], [opt.inner!]));
      }),
    };

    _nativeMethods['Result'] = {
      'is_ok': NativeFnValue('Result.is_ok', (args, named) {
        return BoolValue.of((args[0] as ResultValue).isOk);
      }),
      'is_err': NativeFnValue('Result.is_err', (args, named) {
        return BoolValue.of(!(args[0] as ResultValue).isOk);
      }),
      'unwrap': NativeFnValue('Result.unwrap', (args, named) {
        final r = args[0] as ResultValue;
        if (r.isOk) return r.inner;
        throw _PropagateError(
            StringValue('unwrap called on Err(${r.inner.debug()})'));
      }),
    };

    _nativeMethods['Args'] = {
      'flag': NativeFnValue('Args.flag', (args, named) {
        final self = args[0] as ArgsValue;
        final name = (args[1] as StringValue).v;
        final defaultVal = named['default']!;
        final flagStr = self.getFlag(name);
        if (flagStr == null) return defaultVal;
        return switch (defaultVal) {
          BoolValue() => BoolValue.of(flagStr == 'true'),
          IntValue() => IntValue(int.tryParse(flagStr) ?? 0),
          FloatValue() => FloatValue(double.tryParse(flagStr) ?? 0.0),
          _ => StringValue(flagStr),
        };
      }),
      'positional': NativeFnValue('Args.positional', (args, named) {
        final self = args[0] as ArgsValue;
        final index = (args[1] as IntValue).v;
        final val = self.getPositional(index);
        return val != null
            ? OptionValue.some(StringValue(val))
            : const OptionValue.none();
      }),
      'has': NativeFnValue('Args.has', (args, named) {
        final self = args[0] as ArgsValue;
        final name = (args[1] as StringValue).v;
        return BoolValue.of(self.getFlag(name) != null);
      }),
      'positionals': NativeFnValue('Args.positionals', (args, named) {
        final self = args[0] as ArgsValue;
        return ListValue(
            self.allPositionals().map((s) => StringValue(s)).toList());
      }),
    };
  }

  // ---- evaluation ----

  Value _evalExpr(Expr expr, Environment env) {
    return switch (expr) {
      IntLiteral(:final value) => IntValue(value),
      FloatLiteral(:final value) => FloatValue(value),
      BoolLiteral(:final value) => BoolValue.of(value),
      StringExpr(:final parts) => _evalString(parts, env),
      ListExpr(:final items) =>
        ListValue(items.map((e) => _evalExpr(e, env)).toList()),
      MapExpr(:final entries) => () {
          final map = MapValue.empty();
          for (final (k, v) in entries) {
            map.entries[_evalExpr(k, env)] = _evalExpr(v, env);
          }
          return map;
        }(),
      StructExpr(typeName: '()', fields: []) => VoidValue.instance,
      StructExpr(:final typeName, :final fields) => StructValue(
          typeName, {for (final f in fields) f.$1: _evalExpr(f.$2, env)}),
      IdentExpr(:final name) => _lookupIdent(name, env),
      CallExpr(:final callee, :final typeArgs, :final args) =>
        _evalCall(callee, typeArgs, args, env),
      FieldExpr(:final object, :final field) =>
        _evalFieldAccess(_evalExpr(object, env), field),
      IndexExpr(:final object, :final index) =>
        _evalIndex(_evalExpr(object, env), _evalExpr(index, env)),
      BinaryExpr(:final left, :final op, :final right) =>
        _evalBinary(left, op, right, env),
      UnaryExpr(:final op, :final operand) => _evalUnary(op, operand, env),
      PropagateExpr(:final inner) => _evalPropagate(_evalExpr(inner, env)),
      RangeExpr(:final start, :final end) => RangeValue(
          (_evalExpr(start, env) as IntValue).v,
          (_evalExpr(end, env) as IntValue).v),
      MatchExpr(:final subject, :final arms) =>
        _evalMatch(_evalExpr(subject, env), arms, env),
      LambdaExpr(:final params, :final body) => LambdaValue(params, body, env),
      BlockExpr(:final block) => () {
          final child = Environment.child(env);
          _evalBlock(block, child);
          return VoidValue.instance;
        }(),
      ReturnExpr(:final value) => throw _ReturnSignal(
          value != null ? _evalExpr(value, env) : VoidValue.instance),
      ThrowExpr(:final value) => throw _PropagateError(_evalExpr(value, env)),
    };
  }

  void _evalStmt(Stmt stmt, Environment env) {
    switch (stmt) {
      case LetStmt(:final name, :final value):
        env.define(name, _evalExpr(value, env));
      case ReturnStmt(:final value):
        throw _ReturnSignal(
            value != null ? _evalExpr(value, env) : VoidValue.instance);
      case ThrowStmt(:final value):
        throw _PropagateError(_evalExpr(value, env));
      case AssignStmt(:final target, :final value):
        final val = _evalExpr(value, env);
        switch (target) {
          case IdentExpr(:final name):
            if (!env.assign(name, val)) {
              throw InterpreterError('cannot assign to undefined variable: $name');
            }
          case FieldExpr(:final object, :final field):
            final obj = _evalExpr(object, env);
            if (obj is! StructValue) {
              throw InterpreterError(
                  'cannot assign field on non-struct ${_typeNameOf(obj)}');
            }
            obj.fields[field] = val;
          case IndexExpr(:final object, :final index):
            final obj = _evalExpr(object, env);
            final idx = _evalExpr(index, env);
            if (obj is ListValue && idx is IntValue) {
              obj.items[idx.v] = val;
            } else if (obj is MapValue) {
              obj.entries[idx] = val;
            } else {
              throw InterpreterError(
                  'cannot index-assign ${_typeNameOf(obj)} with ${_typeNameOf(idx)}');
            }
          default:
            throw InterpreterError('invalid assignment target');
        }
      case ExprStmt(:final expr):
        _evalExpr(expr, env);
      case IfStmt(:final condition, :final then, :final else_):
        final cond = _evalExpr(condition, env);
        if (cond.isTruthy) {
          _evalBlock(then, Environment.child(env));
        } else if (else_ != null) {
          _evalBlock(else_, Environment.child(env));
        }
      case ForStmt(:final pattern, :final iterable, :final body):
        _evalFor(pattern, iterable, body, env);
      case WhileStmt(:final condition, :final body):
        while (_evalExpr(condition, env).isTruthy) {
          _evalBlock(body, Environment.child(env));
        }
    }
  }

  void _evalBlock(Block block, Environment env) {
    for (final stmt in block.stmts) {
      _evalStmt(stmt, env);
    }
  }

  void _evalFor(
      Pattern pattern, Expr iterableExpr, Block body, Environment env) {
    final iterable = _evalExpr(iterableExpr, env);
    Iterable<Value> sequence;
    switch (iterable) {
      case RangeValue(:final start, :final end):
        sequence = List.generate(end - start, (i) => IntValue(start + i));
      case ListValue(:final items):
        sequence = items;
      default:
        throw InterpreterError('not iterable: ${iterable.display()}');
    }
    for (final item in sequence) {
      final loopEnv = Environment.child(env);
      final bindings = <String, Value>{};
      if (_matchPattern(pattern, item, bindings, env)) {
        for (final e in bindings.entries) {
          loopEnv.define(e.key, e.value);
        }
      }
      _evalBlock(body, loopEnv);
    }
  }

  // ---- expression helpers ----

  Value _lookupIdent(String name, Environment env) {
    final val = env.tryLookup(name);
    if (val != null) return val;
    throw InterpreterError('undefined: $name');
  }

  Value _evalString(List<StringPart> parts, Environment env) {
    final buf = StringBuffer();
    for (final part in parts) {
      switch (part) {
        case TextPart(:final text):
          buf.write(text);
        case InterpPart(:final expr):
          buf.write(_evalExpr(expr, env).display());
      }
    }
    return StringValue(buf.toString());
  }

  Value _evalCall(Expr calleeExpr, List<TypeRef> typeArgs,
      List<CallArg> callArgs, Environment env) {
    if (calleeExpr is FieldExpr) {
      final receiver = _evalExpr(calleeExpr.object, env);

      // Module-style: struct with a callable in its fields.
      if (receiver is StructValue) {
        final fieldVal = receiver.fields[calleeExpr.field];
        if (fieldVal != null) {
          return _callValue(fieldVal, callArgs, env);
        }
      }

      // Method dispatch.
      return _evalMethodCall(receiver, calleeExpr.field, callArgs, env);
    }

    final callee = _evalExpr(calleeExpr, env);
    return _callValue(callee, callArgs, env);
  }

  Value _evalFieldAccess(Value obj, String field) {
    if (obj is StructValue) {
      final val = obj.fields[field];
      if (val != null) return val;
    }
    throw InterpreterError('no field "$field" on ${_typeNameOf(obj)}');
  }

  Value _evalIndex(Value obj, Value index) {
    return switch (obj) {
      ListValue(:final items) when index is IntValue => items[index.v],
      MapValue(:final entries) => switch (entries[index]) {
          final v? => OptionValue.some(v),
          null => const OptionValue.none(),
        },
      _ => throw InterpreterError(
          'cannot index ${_typeNameOf(obj)} with ${_typeNameOf(index)}'),
    };
  }

  Value _evalBinary(Expr leftExpr, String op, Expr rightExpr, Environment env) {
    // Short-circuit operators
    if (op == '&&') {
      final l = _evalExpr(leftExpr, env);
      return l.isTruthy ? _evalExpr(rightExpr, env) : l;
    }
    if (op == '||') {
      final l = _evalExpr(leftExpr, env);
      return l.isTruthy ? l : _evalExpr(rightExpr, env);
    }

    final l = _evalExpr(leftExpr, env);
    final r = _evalExpr(rightExpr, env);

    return switch (op) {
      '+' => switch ((l, r)) {
          (IntValue(:final v), IntValue(v: final v2)) => IntValue(v + v2),
          (FloatValue(:final v), FloatValue(v: final v2)) => FloatValue(v + v2),
          (StringValue(:final v), StringValue(v: final v2)) =>
            StringValue(v + v2),
          _ => throw InterpreterError(
              'cannot add ${_typeNameOf(l)} and ${_typeNameOf(r)}'),
        },
      '-' => switch ((l, r)) {
          (IntValue(:final v), IntValue(v: final v2)) => IntValue(v - v2),
          (FloatValue(:final v), FloatValue(v: final v2)) => FloatValue(v - v2),
          _ => throw InterpreterError('cannot subtract'),
        },
      '*' => switch ((l, r)) {
          (IntValue(:final v), IntValue(v: final v2)) => IntValue(v * v2),
          (FloatValue(:final v), FloatValue(v: final v2)) => FloatValue(v * v2),
          _ => throw InterpreterError('cannot multiply'),
        },
      '/' => switch ((l, r)) {
          (IntValue(:final v), IntValue(v: final v2)) => IntValue(v ~/ v2),
          (FloatValue(:final v), FloatValue(v: final v2)) => FloatValue(v / v2),
          _ => throw InterpreterError('cannot divide'),
        },
      '%' => switch ((l, r)) {
          (IntValue(:final v), IntValue(v: final v2)) => IntValue(v % v2),
          _ => throw InterpreterError('cannot modulo'),
        },
      '==' => BoolValue.of(l == r),
      '!=' => BoolValue.of(l != r),
      '<' => switch ((l, r)) {
          (IntValue(:final v), IntValue(v: final v2)) => BoolValue.of(v < v2),
          (FloatValue(:final v), FloatValue(v: final v2)) =>
            BoolValue.of(v < v2),
          (StringValue(:final v), StringValue(v: final v2)) =>
            BoolValue.of(v.compareTo(v2) < 0),
          _ => throw InterpreterError('cannot compare'),
        },
      '>' => switch ((l, r)) {
          (IntValue(:final v), IntValue(v: final v2)) => BoolValue.of(v > v2),
          (FloatValue(:final v), FloatValue(v: final v2)) =>
            BoolValue.of(v > v2),
          (StringValue(:final v), StringValue(v: final v2)) =>
            BoolValue.of(v.compareTo(v2) > 0),
          _ => throw InterpreterError('cannot compare'),
        },
      '<=' => switch ((l, r)) {
          (IntValue(:final v), IntValue(v: final v2)) => BoolValue.of(v <= v2),
          _ => throw InterpreterError('cannot compare'),
        },
      '>=' => switch ((l, r)) {
          (IntValue(:final v), IntValue(v: final v2)) => BoolValue.of(v >= v2),
          _ => throw InterpreterError('cannot compare'),
        },
      _ => throw InterpreterError('unknown operator: $op'),
    };
  }

  Value _evalUnary(String op, Expr operandExpr, Environment env) {
    final v = _evalExpr(operandExpr, env);
    return switch (op) {
      '!' => BoolValue.of(!v.isTruthy),
      '-' => switch (v) {
          IntValue(:final v) => IntValue(-v),
          FloatValue(:final v) => FloatValue(-v),
          _ => throw InterpreterError('cannot negate ${_typeNameOf(v)}'),
        },
      _ => throw InterpreterError('unknown unary operator: $op'),
    };
  }

  Value _evalPropagate(Value v) {
    return switch (v) {
      ResultValue(isOk: true, :final inner) => inner,
      ResultValue(isOk: false, :final inner) => throw _PropagateError(inner),
      OptionValue(inner: final inner?) => inner,
      OptionValue() => throw _PropagateError(StringValue('None')),
      _ => throw InterpreterError(
          '? applied to non-Result/Option: ${v.display()}'),
    };
  }

  Value _evalMatch(Value subject, List<MatchArm> arms, Environment env) {
    for (final arm in arms) {
      final bindings = <String, Value>{};
      if (_matchPattern(arm.pattern, subject, bindings, env)) {
        final armEnv = Environment.child(env);
        for (final e in bindings.entries) {
          armEnv.define(e.key, e.value);
        }
        try {
          return _evalExpr(arm.body, armEnv);
        } on _ReturnSignal {
          rethrow; // return signals propagate out of match
        }
      }
    }
    throw InterpreterError('no matching arm for ${subject.display()}');
  }

  // ---- pattern matching ----

  bool _matchPattern(Pattern pat, Value subject, Map<String, Value> bindings,
      Environment env) {
    return switch (pat) {
      WildcardPattern() => true,
      IdentPattern(:final name) => () {
          bindings[name] = subject;
          return true;
        }(),
      ConstructorPattern(name: 'None', args: []) =>
        subject is OptionValue && subject.isNone,
      ConstructorPattern(name: 'Some', :final args) => subject is OptionValue &&
          subject.isSome &&
          (args.isEmpty ||
              _matchPattern(args[0], subject.inner!, bindings, env)),
      ConstructorPattern(name: 'Ok', :final args) => subject is ResultValue &&
          subject.isOk &&
          (args.isEmpty ||
              _matchPattern(args[0], subject.inner, bindings, env)),
      ConstructorPattern(name: 'Err', :final args) => subject is ResultValue &&
          !subject.isOk &&
          (args.isEmpty ||
              _matchPattern(args[0], subject.inner, bindings, env)),
      ConstructorPattern(:final name, :final args) => subject is StructValue &&
          subject.typeName == name &&
          args.isEmpty, // TODO: field patterns
      LiteralPattern(:final literal) => _evalExpr(literal, env) == subject,
    };
  }

  // ---- calling ----

  Value _evalMethodCall(Value receiver, String methodName,
      List<CallArg> callArgs, Environment env) {
    final typeName = _typeNameOf(receiver);

    // Native methods
    final nativeMethod = _nativeMethods[typeName]?[methodName];
    if (nativeMethod != null) {
      final positional = [receiver, ..._evalPositional(callArgs, env)];
      final named = _evalNamed(callArgs, env);
      return nativeMethod.fn(positional, named);
    }

    // User-defined methods
    final entry = _methods[typeName]?[methodName];
    if (entry != null) {
      final (decl, closureEnv) = entry;
      return _callFn(decl, closureEnv, receiver, callArgs, env);
    }

    throw InterpreterError('no method "$methodName" on $typeName');
  }

  Value _callValue(Value callee, List<CallArg> callArgs, Environment env) {
    return switch (callee) {
      FnValue(:final decl, :final closure) =>
        _callFn(decl, closure, null, callArgs, env),
      NativeFnValue(:final fn) =>
        fn(_evalPositional(callArgs, env), _evalNamed(callArgs, env)),
      LambdaValue(:final params, :final body, :final closure) =>
        _callLambda(params, body, closure, callArgs, env),
      _ => throw InterpreterError('not callable: ${callee.display()}'),
    };
  }

  /// Call a value with pre-evaluated positional args (used by native methods
  /// that call lambdas, e.g. List.map).
  Value _callValueDirect(Value callee, List<Value> positionalArgs) {
    return switch (callee) {
      NativeFnValue(:final fn) => fn(positionalArgs, {}),
      LambdaValue(:final params, :final body, :final closure) => () {
          final lambdaEnv = Environment(closure);
          for (var i = 0; i < params.length && i < positionalArgs.length; i++) {
            lambdaEnv.define(params[i], positionalArgs[i]);
          }
          try {
            return _evalExpr(body, lambdaEnv);
          } on _ReturnSignal catch (s) {
            return s.value;
          }
        }(),
      FnValue(:final decl, :final closure) => () {
          final fnEnv = Environment(closure);
          final nonSelf = decl.params.where((p) => !p.isSelf).toList();
          for (var i = 0;
              i < nonSelf.length && i < positionalArgs.length;
              i++) {
            fnEnv.define(nonSelf[i].name, positionalArgs[i]);
          }
          try {
            _evalBlock(decl.body!, fnEnv);
            return VoidValue.instance;
          } on _ReturnSignal catch (s) {
            return s.value;
          } on _PropagateError catch (e) {
            return ResultValue.err(e.error);
          }
        }(),
      _ => throw InterpreterError('not callable: $callee'),
    };
  }

  Value _callFn(FnDecl decl, Environment closure, Value? self,
      List<CallArg> callArgs, Environment callEnv) {
    if (decl.body == null) {
      throw InterpreterError('${decl.name} has no body (native or abstract)');
    }
    final fnEnv = Environment(closure);

    // positional args: those whose call-site label is null
    final positionalVals = callArgs
        .where((a) => a.label == null)
        .map((a) => _evalExpr(a.value, callEnv))
        .toList();
    // named args keyed by label
    final namedVals = {
      for (final a in callArgs.where((a) => a.label != null))
        a.label!: _evalExpr(a.value, callEnv)
    };

    int positionalIdx = 0;
    for (final param in decl.params) {
      if (param.isSelf) {
        fnEnv.define('self', self ?? (throw InterpreterError('missing self')));
        continue;
      }
      if (param.label == null) {
        // Suppressed label: match next positional arg.
        if (positionalIdx < positionalVals.length) {
          fnEnv.define(param.name, positionalVals[positionalIdx++]);
        } else if (param.defaultValue != null) {
          fnEnv.define(param.name, _evalExpr(param.defaultValue!, closure));
        } else {
          throw InterpreterError('missing positional arg for ${param.name}');
        }
      } else {
        // Named param: look up by label.
        final val = namedVals[param.label];
        if (val != null) {
          fnEnv.define(param.name, val);
        } else if (positionalIdx < positionalVals.length &&
            param.label == param.name) {
          // Allow passing a named param positionally if label == name.
          fnEnv.define(param.name, positionalVals[positionalIdx++]);
        } else if (param.defaultValue != null) {
          fnEnv.define(param.name, _evalExpr(param.defaultValue!, closure));
        } else {
          throw InterpreterError(
              'missing arg "${param.label}" for ${decl.name}');
        }
      }
    }

    try {
      _evalBlock(decl.body!, fnEnv);
      return VoidValue.instance;
    } on _ReturnSignal catch (s) {
      return s.value;
    } on _PropagateError catch (e) {
      return ResultValue.err(e.error);
    }
  }

  Value _callLambda(List<String> params, Expr body, Environment closure,
      List<CallArg> callArgs, Environment callEnv) {
    final lambdaEnv = Environment(closure);
    final vals = callArgs.map((a) => _evalExpr(a.value, callEnv)).toList();
    for (var i = 0; i < params.length && i < vals.length; i++) {
      lambdaEnv.define(params[i], vals[i]);
    }
    try {
      return _evalExpr(body, lambdaEnv);
    } on _ReturnSignal catch (s) {
      return s.value;
    }
  }

  /// Call a function directly from the runtime, passing pre-resolved values by
  /// param name.  Used to call main().
  Value _callFnWithValues(FnDecl decl, Environment closure, Value? self,
      Map<String, Value> values) {
    if (decl.body == null) {
      throw InterpreterError('${decl.name} has no body');
    }
    final fnEnv = Environment(closure);
    if (self != null) fnEnv.define('self', self);
    for (final param in decl.params) {
      if (param.isSelf) continue;
      final val = values[param.label ?? param.name] ?? values[param.name];
      if (val != null) {
        fnEnv.define(param.name, val);
      } else if (param.defaultValue != null) {
        fnEnv.define(param.name, _evalExpr(param.defaultValue!, closure));
      }
    }
    try {
      _evalBlock(decl.body!, fnEnv);
      return VoidValue.instance;
    } on _ReturnSignal catch (s) {
      return s.value;
    } on _PropagateError catch (e) {
      return ResultValue.err(e.error);
    }
  }

  // ---- argument helpers ----

  List<Value> _evalPositional(List<CallArg> callArgs, Environment env) =>
      callArgs
          .where((a) => a.label == null)
          .map((a) => _evalExpr(a.value, env))
          .toList();

  Map<String, Value> _evalNamed(List<CallArg> callArgs, Environment env) => {
        for (final a in callArgs.where((a) => a.label != null))
          a.label!: _evalExpr(a.value, env)
      };

  // ---- utilities ----

  String _typeNameOf(Value v) => switch (v) {
        IntValue() => 'Int',
        FloatValue() => 'Float',
        BoolValue() => 'Bool',
        StringValue() => 'String',
        ListValue() => 'List',
        MapValue() => 'Map',
        OptionValue() => 'Option',
        ResultValue() => 'Result',
        RangeValue() => 'Range',
        FnValue() => 'Fn',
        LambdaValue() => 'Lambda',
        NativeFnValue() => 'NativeFn',
        VoidValue() => 'Void',
        StructValue(:final typeName) => typeName,
      };

  // ---- test runner ----

  /// Run all @test functions in [program].
  /// [filePath] determines the base directory for relative imports.
  /// Returns the number of test failures.
  int runTests(Program program, String filePath, {bool verbose = false}) {
    _baseDir = File(filePath).parent.path;
    final env = Environment();
    _setupGlobals(env);

    // Collect @test functions while loading declarations.
    final testFns = <FnDecl>[];
    for (final decl in program.decls) {
      switch (decl) {
        case FnDecl():
          env.define(decl.name, FnValue(decl, env));
          if (decl.decorators.any((d) => d.name == 'test')) testFns.add(decl);
        case ImplDecl():
          _registerImpl(decl, env);
        case ImportDecl():
          _handleImport(decl.path, decl.alias, env);
        case TypeDecl():
          break;
        case InterfaceDecl():
          break;
        case ConstDecl():
          env.define(decl.name, _evalExpr(decl.value, env));
      }
    }

    if (testFns.isEmpty) {
      if (verbose) stderr.writeln('$filePath: no @test functions found');
      return 0;
    }

    var passed = 0;
    var failed = 0;
    for (final fn in testFns) {
      final label = '$filePath::${fn.name}';
      try {
        final result = _callFnWithValues(fn, env, null, {});
        switch (result) {
          case ResultValue(isOk: false, :final inner):
            failed++;
            stdout.writeln('FAIL $label');
            stdout.writeln('  ${inner.display()}');
          case _:
            passed++;
            if (verbose) stdout.writeln('ok   $label');
        }
      } on InterpreterError catch (e) {
        failed++;
        stdout.writeln('FAIL $label');
        stdout.writeln('  $e');
      }
    }

    if (verbose) {
      final total = passed + failed;
      stdout.writeln('$passed/$total passed');
    }

    return failed;
  }

  ArgsValue _makeArgsValue(List<String> cliArgs) {
    final positionals = <String>[];
    final flags = <String, String>{};
    var i = 0;
    while (i < cliArgs.length) {
      final arg = cliArgs[i];
      if (arg.startsWith('--')) {
        final name = arg.substring(2);
        if (i + 1 < cliArgs.length && !cliArgs[i + 1].startsWith('--')) {
          flags[name] = cliArgs[++i];
        } else {
          flags[name] = 'true';
        }
      } else {
        positionals.add(arg);
      }
      i++;
    }
    return ArgsValue(positionals, flags);
  }
}

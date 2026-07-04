# Hawk grammar

**What this is:** a semi-formal EBNF description of Hawk's concrete syntax — the
single reference for the keyword set, the operator/precedence table, and the
shape of every declaration, statement, and expression. It is **descriptive**:
the hand-written recursive-descent parser (`pkgs/cli/lexer/`,
`pkgs/cli/parser/`) is the source of truth, and this doc tracks it. A lexer test
(`pkgs/cli/lexer/lexer_test.hawk`) cross-checks the keyword list against the
lexer so the lexical half can't silently drift.

Its second job is to make **parser completeness** legible: the precedence table
and the [Not yet in the grammar](#not-yet-in-the-grammar) section spell out what
is deliberately or incidentally absent (e.g. increment/decrement, casts) — see
also [roadmap.md](roadmap.md). The semantics behind the forms live in
[language.md](language.md); the rationale in [overview.md](overview.md).

## Notation

EBNF, W3C-style:

| Form     | Meaning                                         |
| -------- | ----------------------------------------------- |
| `x y`    | sequence                                        |
| `x \| y` | alternation                                     |
| `x?`     | optional (zero or one)                          |
| `x*`     | zero or more                                    |
| `x+`     | one or more                                     |
| `( … )`  | grouping                                        |
| `'fn'`   | a literal terminal (keyword/punctuation)        |
| `IDENT`  | a token class (see [Lexical](#lexical-grammar)) |

`lowercase` names are nonterminals; `UPPERCASE` names are token classes.

## Lexical grammar

### Comments & whitespace

```
comment    = ordinary | item_doc | file_doc        // line comments only
ordinary   = '//'  (any char except newline)*       // not '///' or '//!'
item_doc   = '///' (any char except newline)*       // documents the next item
file_doc   = '//!' (any char except newline)*       // documents the file
whitespace = ' ' | '\t' | '\r' | '\n'
```

There are **no block comments** (`/* … */`). The `///` and `//!` forms are
**doc comments** — lexically still line comments, but carrying documentation
that tooling extracts; see [language.md](language.md#documentation) for the
conventions. `//` is an ordinary comment and is never extracted.

### Keywords

All reserved; none may be used as identifiers:

```
as  const  else  enum  false  fn  for  if  impl  import  in  interface
let  match  mut  native  pub  return  self  struct  throw  true  type  void  while
```

(`true`, `false`, `void`, `self` are keywords that appear in expression
position. `as` is used only in `import … as …`, not as a cast operator.)

### Identifiers

```
IDENT = (ALPHA | '_') (ALPHA | DIGIT | '_')*
```

…but a lone `_` lexes as the distinct `'_'` token (label suppressor / wildcard
pattern), not an identifier. By convention an initial uppercase letter marks a
type / enum-variant / zero-arg constructor; lowercase marks a value or binding
(the parser uses this to tell a binding pattern from a zero-arg constructor
pattern).

### Literals

```
INT    = DIGIT+ | ('0x' | '0X') HEXDIGIT+
FLOAT  = DIGIT+ '.' DIGIT+
BOOL   = 'true' | 'false'
UNIT   = 'void'                       // the single value of type Void
STRING = "'" strChar* "'" | '"' strChar* '"'
strChar = escape | interpolation | (any char except the delimiter)
escape  = '\' ('n' | 't' | 'r' | '\' | "'" | '"' | '$')
        | '\x' hex hex                    // a byte, U+0000..U+00FF
        | '\u{' hex (1..6 times) '}'       // a Unicode scalar value
interpolation = '${' expr '}'
```

Notes: integers are decimal or **hexadecimal** (`0x` / `0X` prefix); a hex
literal is read as an unsigned 64-bit pattern wrapped into the signed `Int`, so
`0x9E3779B97F4A7C15` is a (negative) constant. No binary/octal, digit separators
(`_`), exponents, or sign (a leading `-` is the unary operator). Floats require
digits on both sides of the `.` (`1.0`, not `1.` or `.5`), with no exponent.
Strings use `'` or `"` (single quotes by convention). Escapes are the seven
simple ones plus `\xNN` (a byte) and `\u{…}` (1–6 hex digits naming a Unicode
scalar value); an unrecognized escape is an **error** (no silent pass-through).
`${ … }` embeds an arbitrary expression.

### Operators & punctuation

```
{  }  (  )  [  ]  ,  ;  :  .  ..  ->  =>  ?  @  _
+  -  *  /  %  =  ==  !=  <  >  <=  >=  &&  ||  !
+=  -=  *=  /=  %=
&  |  ^  ~          // bitwise
```

The shift operators `<< >> >>>` are not lexed as tokens; the parser forms them
from adjacent `<`/`>` (see the precedence section). (`DIGIT` is `0`–`9`;
`HEXDIGIT` is `0`–`9` / `a`–`f` / `A`–`F`; `ALPHA` is a Latin letter.)

That is the complete operator set. See
[Not yet in the grammar](#not-yet-in-the-grammar) for the families that are
absent (increment/decrement, casts, …).

## Syntactic grammar

### Program & declarations

```
program     = declaration*

declaration = decorator* 'pub'? decl_body
decl_body   = importDecl | fnDecl | structDecl | nativeTypeDecl | enumDecl
            | interfaceDecl | implDecl | constDecl | letDecl

decorator   = '@' IDENT ( '(' ( expr (',' expr)* )? ')' )?
```

Constraints (enforced by the parser, not the grammar): decorators are allowed
only on `fn` / `native fn`; `pub` is not allowed on `impl` (mark methods `pub`
instead).

```
importDecl  = 'import' ( STRING | IDENT ('.' IDENT)* ) ( 'as' ( IDENT | '_' ) )? ';'?

fnDecl      = 'native'? 'fn' IDENT typeParams? '(' paramList? ')'
              ( '->' type )? ( block | ';'? )
              // a `native fn` has no block (just an optional ';')

typeParams  = '<' typeParam (',' typeParam)* '>'
typeParam   = IDENT ( ':' IDENT ('+' IDENT)* )?        // bounds: T: Eq + Debug

paramList   = param (',' param)*
param       = 'self'
            | '_' IDENT (':' type)? ('=' expr)?         // suppressed label
            | IDENT IDENT? (':' type)? ('=' expr)?      // [label] name, default
            // `label name` gives a distinct external label; a single IDENT
            // means label == name.

structDecl  = 'struct' IDENT typeParams? '{' field (',' field)* ','? '}'
field       = 'mut'? IDENT ':' type        // `mut` allows the field to be reassigned
              // A nominal record: `struct Point { x: Int, y: Int }`. Constructed
              // with a struct literal `Point { x: 1, y: 2 }`; methods come from
              // `impl` blocks. (There is no `=`: `struct Name { … }`, not
              // `type Name = { … }` — the latter form was removed.)

nativeTypeDecl = 'native' 'type' IDENT typeParams? ';'?
              // An opaque, runtime-represented type with no field layout
              // (`native type List<T>`) — a declaration site for a built-in whose
              // representation lives in the runtime. Methods come from `impl`
              // blocks; it cannot be built with a struct literal.

enumDecl    = 'enum' IDENT typeParams? '{' variant (',' variant)* ','? '}'
variant     = IDENT ( '(' type (',' type)* ')' )?       // positional payload

interfaceDecl = 'interface' IDENT typeParams? superInterfaces? '{' methodSig* '}'
superInterfaces = ':' IDENT ('+' IDENT)*    // extended interfaces, e.g. `: Display + Debug`
methodSig   = 'pub'? 'fn' IDENT typeParams? '(' paramList? ')' ('->' type)? ';'?

implDecl    = 'impl' qualName typeParams?       // typeParams = interface type args
              ( 'for' qualName typeParams? )?    //   in `impl Iface<Int> for T`
              '{' method* '}'
method      = decorator* 'pub'? 'native'? fnDecl_tail   // a fn, possibly native
qualName    = IDENT ('.' IDENT)?                          // e.g. Clock | time.Clock

constDecl   = 'const' IDENT (':' type)? '=' expr ';'?

letDecl     = 'let' IDENT (':' type)? '=' expr ';'?
              // A module-level binding (a global computed once at load; see
              // docs/module_init.md). Immutable: top-level `let mut` is rejected,
              // unlike the local `letStmt`. Parsed today; not yet executable.
```

A trailing `;` is optional almost everywhere it can appear.

### Types

```
type     = '(' ( type (',' type)* )? ')' '->' type       // function type
         | qualName typeArgs?
typeArgs = '<' type (',' type)* '>'
```

`qualName` is a possibly-namespaced name (`Clock`, `time.Clock`); the namespace
is resolved by the base name (one flat type table). The unit type is spelled
`Void`; there is no `()` type.

### Statements

```
// A statement-position block (function/if/while/for body): statements only.
block     = '{' statement* '}'

// An expression-position block (a `{…}` that is itself an expression, e.g. a
// `let` initializer or a `{…}` match arm): an optional trailing expression with
// no ';' is the block's *tail* — its value. See docs/language.md. (Function and
// loop bodies use `block` above, so they keep the require-';' rule and produce
// values with `return`.)
exprBlock = '{' statement* expr? '}'

statement = letStmt | constStmt | returnStmt | throwStmt
          | ifStmt | forStmt | whileStmt | assignOrExpr

letStmt   = 'let' 'mut'? IDENT (':' type)? '=' expr ';'
          | 'let' pattern '=' expr 'else' block ';'?      // `let … else` guard;
            // refutable (uppercase) pattern, `else` must diverge; desugars to
            // `match`. v1: binds ≤1 variable.
constStmt = 'const' IDENT (':' type)? '=' expr ';'       // a local immutable binding
returnStmt= 'return' expr? ';'
throwStmt = 'throw' expr ';'
ifStmt    = 'if' ( exprNB | 'let' pattern '=' exprNB )    // `if let` = cond. binding
            block ( 'else' ( ifStmt | block ) )?         //   (desugars to `match`)
forStmt   = 'for' pattern 'in' exprNB block
whileStmt = 'while' exprNB block

// The ';' is required, EXCEPT after a block-terminated expression statement
// (a bare `match`, ending in '}'), which — like if/for/while — needs none. A
// missing ';' is a parse error (so two adjacent literals do not silently merge).
assignOrExpr = expr ( assignOp expr )? ';'?
assignOp     = '=' | '+=' | '-=' | '*=' | '/=' | '%='
            // an assignment target must be an identifier, field access, or
            // index; `t op= e` desugars to `t = t op e`
```

`exprNB` is `expr` parsed with **struct literals suppressed**, so that
`if foo { … }` reads `foo` as the condition rather than `foo { … }` as a struct
literal. It is the same grammar as `expr` minus the bare `IDENT '{' … '}'`
production. There are no `break` / `continue` statements (exit a loop by
restructuring or `return`).

### Patterns

Used by `for`, `match`, and `if let`:

```
pattern = '_'                                            // wildcard
        | IDENT '(' ( pattern (',' pattern)* )? ')'       // constructor w/ args
        | IDENT                                           // Upper → zero-arg ctor;
        |                                                 //   lower → binding
        | INT | STRING | 'true' | 'false'                 // literal pattern
```

Constructor arguments are themselves patterns, so patterns **nest** to any depth
and bind at the leaves — `match e { Bin(Add, Num(a), Num(b)) => … }` tests the
`Bin` tag, the nested `Add`/`Num` tags, and binds `a`/`b`. A non-matching nested
pattern falls through to the next arm (matches are assumed exhaustive; end with
a catch-all `_` when the patterns are refutable). Literal patterns cover ints,
strings, and booleans (not floats) and may appear at any depth. There are no
or-patterns, guards, range, or struct/field patterns.

### Expressions

By precedence, **lowest to highest**. Each level is left-associative unless
noted.

```
expr       = or
or         = and        ( '||' and )*
and        = bitOr      ( '&&' bitOr )*
bitOr      = bitXor     ( '|' bitXor )*
bitXor     = bitAnd     ( '^' bitAnd )*
bitAnd     = equality   ( '&' equality )*
equality   = comparison ( ( '==' | '!=' ) comparison )*
comparison = shift      ( ( '<' | '>' | '<=' | '>=' ) shift )*
shift      = range      ( ( '<<' | '>>' | '>>>' ) range )*  // << >> formed from
           //   adjacent < / > tokens, so nested generics close with single >
range      = addition   ( '..' addition )?               // non-associative
addition   = mul        ( ( '+' | '-' ) mul )*
mul        = unary      ( ( '*' | '/' | '%' ) unary )*
unary      = ( '!' | '-' | '~' ) unary                   // prefix, right-assoc
           | postfix
postfix    = primary postfixOp*
postfixOp  = '.' IDENT                                    // field or method name
           | typeArgs? '(' callArgs? ')'                  // call (optionally generic)
           | '[' expr ']'                                 // index
           | '?'                                          // error propagation
callArgs   = callArg (',' callArg)*
callArg    = ( IDENT ':' )? expr                          // optional argument label
```

```
primary  = INT | FLOAT | STRING | 'true' | 'false' | 'self' | 'void'
         | '(' expr ')'                                   // grouping
         | '(' lambdaParams? ')' '=>' expr                // lambda
         | IDENT '=>' expr                                // single-param lambda
         | IDENT structBody                               // struct literal (when permitted)
         | IDENT                                          // name
         | listLit | mapLit
         | matchExpr
         | ifExpr                                         // if as a value (tail-valued)
         | exprBlock                                      // block expression (tail-valued)
         | 'return' expr? | 'throw' expr

lambdaParams = lambdaParam (',' lambdaParam)*
lambdaParam  = IDENT (':' type)?

listLit   = '[' ( expr (',' expr)* )? ']'
mapLit    = '{' ( mapEntry (',' mapEntry)* )? '}'         // '{}' or string/int-keyed
mapEntry  = expr ':' expr
structBody= '{' ( field (',' field)* ','? )? '}'   field = IDENT ':' expr

matchExpr = 'match' exprNB '{' arm* '}'
arm       = pattern '=>' ( exprBlock | expr ) ','?      // a block arm is tail-valued

// `if` in expression position (docs/language.md). Branches are tail-valued
// `exprBlock`s; `else` is required where the value is used (a primary `if`, or
// an `if` tail), optional for a discarded statement `if` inside an exprBlock. The
// statement form (`ifStmt`, above) is a separate node and keeps `else` optional.
ifExpr    = 'if' exprNB exprBlock ( 'else' ( ifExpr | exprBlock ) )?
```

A method call is `postfix` chaining: `recv '.' method` forms a field access, and
a following `'(' … ')'` makes it a call. A map literal and a block both start
with `{`; in **expression (`primary`) position** the parser commits to a **map**
when it sees `{}` or a string/int key followed by `:`, otherwise a **block
expression**. The exception is a position that grammatically expects a block
first — a **`match` arm** (`pattern '=>' ( exprBlock | expr )`, which tries
`exprBlock` before `expr`): there a bare `=> {}` is an **empty block** (value
`Void`), *not* an empty map. So an empty-map arm must be spelled `=> { {} }` (a
block whose tail is the map literal) or with a typed binding — a known sharp edge
tracked in [roadmap.md](roadmap.md).

## Operator precedence (summary)

| Level | Operators            | Assoc          | Notes                      |
| ----- | -------------------- | -------------- | -------------------------- |
| 1     | `\|\|`               | left           | logical or                 |
| 2     | `&&`                 | left           | logical and                |
| 3     | `\|`                 | left           | bitwise or                 |
| 4     | `^`                  | left           | bitwise xor                |
| 5     | `&`                  | left           | bitwise and                |
| 6     | `==` `!=`            | left           | equality                   |
| 7     | `<` `>` `<=` `>=`    | left           | comparison                 |
| 8     | `<<` `>>` `>>>`      | left           | shift (see below)          |
| 9     | `..`                 | non-assoc      | range (one only)           |
| 10    | `+` `-`              | left           | additive                   |
| 11    | `*` `/` `%`          | left           | multiplicative             |
| 12    | `!` `-` `~` (prefix) | right          | unary                      |
| 13    | `.` `()` `[]` `?`    | left (postfix) | field/call/index/propagate |

The bitwise (`& | ^ ~`) and shift (`<< >> >>>`) operators follow the C family.
`>>` is **arithmetic** (sign-preserving), `>>>` is **logical** (zero-fill); the
shift amount is masked to `0..=63`. They are `Int`-only. The shift operators are
not lexer tokens — the parser forms them by combining **adjacent** `<`/`>`
tokens, so nested generics (`List<List<Int>>`) still close with single `>`
tokens (a `>` separated from its neighbour by a space is never a shift).

## Not yet in the grammar

Deliberately or incidentally absent today. This is the parser-completeness
checklist; items that are planned link to [roadmap.md](roadmap.md).

**Operators**

- **Increment / decrement:** `++` `--`. (Compound assignment `+= -= *= /= %=`
  _is_ supported — desugared to `t = t op e`.)
- **Cast operator:** `expr as Type` — `as` is import-only.
- **Inclusive range** `..=`, and the ternary `cond ? a : b` (`?` is postfix
  error-propagation only).

**Literals**

- Integer bases & separators: `0b…`, `0o…` (binary/octal), digit separators
  (`1_000`); integer/float **exponents** (`1e9`); float shorthands `1.` and
  `.5`. (Hex `0x…` _is_ supported.)
- String: `\u{…}` / `\0` escapes, raw or triple-quoted strings.
- Tuple literals/types `(a, b)` — `(…)` is grouping or lambda params only.

**Statements & control flow**

- `break` / `continue` (and labeled loops); a `loop { }` form.
- `if` and `match` work in both statement position (`ifStmt`, a bare `match`)
  and expression position (`ifExpr`, `matchExpr`); the value forms are
  tail-valued (docs/language.md). There are no block-less `if` bodies (the body
  is always a block).

**Patterns**

- Float literal patterns; or-patterns (`A | B`), guards (`pat if cond`), range
  patterns, struct/field destructuring, and `name @ subpattern` bindings.

**Parser limitations (not language decisions)**

- Generic call type-arguments use a lookahead heuristic
  (`looks_like_type_arg_list`) that bails on **nested** generics in call
  position, e.g. `f<Result<T, E>>(…)` — and therefore also the receiver form
  `Map<String, List<Int>>.new()`, which is unwritable today. Annotated
  positions (`let`, params) handle nesting fine; only the `name<…>(…)` /
  `Type<…>.m(…)` call forms are limited.
- The `<` disambiguation: `name<Idents…>` followed by `(` or `.` commits to
  type arguments (so a comparison chain `a < b > c` parses as comparisons —
  ill-typed, but syntactically comparisons). The residual `a < b > (c)`
  ambiguity resolves the generic-call way (as in C#); the checker then rejects
  type arguments on a non-generic callee, so the comparison reading must be
  written parenthesized: `(a < b) > (c)`.

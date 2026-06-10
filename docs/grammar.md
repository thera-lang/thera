# Hawk grammar

**What this is:** a semi-formal EBNF description of Hawk's concrete syntax — the
single reference for the keyword set, the operator/precedence table, and the
shape of every declaration, statement, and expression. It is **descriptive**:
the hand-written recursive-descent parser (`tool/lib/src/lexer.dart`,
`tool/lib/src/parser.dart`) is the source of truth, and this doc tracks it. A
test (`tool/test/grammar_doc_test.dart`) cross-checks the keyword list against
the lexer so the lexical half can't silently drift.

Its second job is to make **parser completeness** legible: the precedence table
and the [Not yet in the grammar](#not-yet-in-the-grammar) section spell out what
is deliberately or incidentally absent (e.g. bitwise operators) — see also
[roadmap.md](roadmap.md). The semantics behind the forms live in
[language.md](language.md); the rationale in [guidelines.md](guidelines.md).

## Notation

EBNF, W3C-style:

| Form        | Meaning                                  |
| ----------- | ---------------------------------------- |
| `x y`       | sequence                                 |
| `x \| y`    | alternation                              |
| `x?`        | optional (zero or one)                   |
| `x*`        | zero or more                             |
| `x+`        | one or more                              |
| `( … )`     | grouping                                 |
| `'fn'`      | a literal terminal (keyword/punctuation) |
| `IDENT`     | a token class (see [Lexical](#lexical-grammar)) |

`lowercase` names are nonterminals; `UPPERCASE` names are token classes.

## Lexical grammar

### Comments & whitespace

```
comment    = '//' (any char except newline)*       // line comments only
whitespace = ' ' | '\t' | '\r' | '\n'
```

There are **no block comments** (`/* … */`) and no distinct doc-comment form.

### Keywords

All reserved; none may be used as identifiers:

```
as  const  else  enum  false  fn  for  if  impl  import  in  interface
let  match  mut  native  pub  return  self  throw  true  type  void  while
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
interpolation = '${' expr '}'
```

Notes: integers are decimal or **hexadecimal** (`0x` / `0X` prefix); a hex
literal is read as an unsigned 64-bit pattern wrapped into the signed `Int`, so
`0x9E3779B97F4A7C15` is a (negative) constant. No binary/octal, digit separators
(`_`), exponents, or sign (a leading `-` is the unary operator). Floats require
digits on both sides of the `.` (`1.0`, not `1.` or `.5`), with no exponent. Strings use `'` or `"` (single quotes by convention); the only
escapes are the seven above (no `\u…`); `${ … }` embeds an arbitrary expression.

### Operators & punctuation

```
{  }  (  )  [  ]  ,  ;  :  .  ..  ->  =>  ?  @  _
+  -  *  /  %  =  ==  !=  <  >  <=  >=  &&  ||  !
+=  -=  *=  /=  %=
```

(`DIGIT` is `0`–`9`; `HEXDIGIT` is `0`–`9` / `a`–`f` / `A`–`F`; `ALPHA` is a
Latin letter.)

That is the complete operator set. See [Not yet in the
grammar](#not-yet-in-the-grammar) for the families that are absent (bitwise,
shift, compound assignment, …).

## Syntactic grammar

### Program & declarations

```
program     = declaration*

declaration = decorator* 'pub'? decl_body
decl_body   = importDecl | fnDecl | typeDecl | enumDecl
            | interfaceDecl | implDecl | constDecl

decorator   = '@' IDENT ( '(' ( expr (',' expr)* )? ')' )?
```

Constraints (enforced by the parser, not the grammar): decorators are allowed
only on `fn` / `native fn`; `pub` is not allowed on `impl` (mark methods `pub`
instead).

```
importDecl  = 'import' ( STRING | IDENT ('.' IDENT)* ) ( 'as' IDENT )? ';'?

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

typeDecl    = 'type' IDENT typeParams? '=' '{' field (',' field)* ','? '}'
field       = IDENT ':' type

enumDecl    = 'enum' IDENT typeParams? '{' variant (',' variant)* ','? '}'
variant     = IDENT ( '(' type (',' type)* ')' )?       // positional payload

interfaceDecl = 'interface' IDENT '{' methodSig* '}'
methodSig   = 'pub'? 'fn' IDENT typeParams? '(' paramList? ')' ('->' type)? ';'?

implDecl    = 'impl' qualName typeParams?
              ( 'for' qualName typeParams? )?
              '{' method* '}'
method      = decorator* 'pub'? 'native'? fnDecl_tail   // a fn, possibly native
qualName    = IDENT ('.' IDENT)?                          // e.g. Clock | time.Clock

constDecl   = 'const' IDENT (':' type)? '=' expr ';'?
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
block     = '{' statement* '}'

statement = letStmt | constStmt | returnStmt | throwStmt
          | ifStmt | forStmt | whileStmt | assignOrExpr

letStmt   = 'let' 'mut'? IDENT (':' type)? '=' expr ';'?
constStmt = 'const' IDENT (':' type)? '=' expr ';'?       // a local immutable binding
returnStmt= 'return' expr? ';'?
throwStmt = 'throw' expr ';'?
ifStmt    = 'if' exprNB block ( 'else' ( ifStmt | block ) )?
forStmt   = 'for' pattern 'in' exprNB block
whileStmt = 'while' exprNB block

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

Used by `for` and `match`:

```
pattern = '_'                                            // wildcard
        | IDENT '(' ( pattern (',' pattern)* )? ')'       // constructor w/ args
        | IDENT                                           // Upper → zero-arg ctor;
        |                                                 //   lower → binding
        | INT | STRING | 'true' | 'false'                 // literal pattern
```

Literal patterns cover ints, strings, and booleans (not floats). There are no
or-patterns, guards, range, or struct/field patterns.

### Expressions

By precedence, **lowest to highest**. Each level is left-associative unless
noted.

```
expr       = or
or         = and        ( '||' and )*
and        = equality   ( '&&' equality )*
equality   = comparison ( ( '==' | '!=' ) comparison )*
comparison = range      ( ( '<' | '>' | '<=' | '>=' ) range )*
range      = addition   ( '..' addition )?               // non-associative
addition   = mul        ( ( '+' | '-' ) mul )*
mul        = unary      ( ( '*' | '/' | '%' ) unary )*
unary      = ( '!' | '-' ) unary                         // prefix, right-assoc
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
         | block                                          // block expression
         | 'return' expr? | 'throw' expr

lambdaParams = lambdaParam (',' lambdaParam)*
lambdaParam  = IDENT (':' type)?

listLit   = '[' ( expr (',' expr)* )? ']'
mapLit    = '{' ( mapEntry (',' mapEntry)* )? '}'         // '{}' or string/int-keyed
mapEntry  = expr ':' expr
structBody= '{' ( field (',' field)* ','? )? '}'   field = IDENT ':' expr

matchExpr = 'match' exprNB '{' arm* '}'
arm       = pattern '=>' ( block | expr ) ','?
```

A method call is `postfix` chaining: `recv '.' method` forms a field access,
and a following `'(' … ')'` makes it a call. A map literal and a block both
start with `{`; the parser commits to a **map** when it sees `{}` or a
string/int key followed by `:`, otherwise a **block expression**.

## Operator precedence (summary)

| Level | Operators              | Assoc          | Notes                       |
| ----- | ---------------------- | -------------- | --------------------------- |
| 1     | `\|\|`                 | left           | logical or                  |
| 2     | `&&`                   | left           | logical and                 |
| 3     | `==` `!=`              | left           | equality                    |
| 4     | `<` `>` `<=` `>=`      | left           | comparison                  |
| 5     | `..`                   | non-assoc      | range (one only)            |
| 6     | `+` `-`                | left           | additive                    |
| 7     | `*` `/` `%`            | left           | multiplicative              |
| 8     | `!` `-` (prefix)       | right          | unary                       |
| 9     | `.` `()` `[]` `?`      | left (postfix) | field/call/index/propagate  |

The gap between levels 4 and 6 — where bitwise-or, bitwise-xor, bitwise-and, and
the shift operators would sit in a C-family language — is **empty**. That
absence is the headline completeness item below.

## Not yet in the grammar

Deliberately or incidentally absent today. This is the parser-completeness
checklist; items that are planned link to [roadmap.md](roadmap.md).

**Operators**

- **Bitwise & shift:** `&` `|` `^` `~` `<<` `>>` — none exist (no tokens, no
  precedence tier). The reason `std.random`'s mixing and the future `std.hash` /
  `std.encoding` need Rust natives. Tracked on the roadmap as a self-contained
  arc (also wants an unsigned integer type or defined logical-shift semantics).
- **Increment / decrement:** `++` `--`. (Compound assignment `+= -= *= /= %=`
  *is* supported — desugared to `t = t op e`.)
- **Cast operator:** `expr as Type` — `as` is import-only.
- **Inclusive range** `..=`, and the ternary `cond ? a : b` (`?` is postfix
  error-propagation only).

**Literals**

- Integer bases & separators: `0b…`, `0o…` (binary/octal), digit separators
  (`1_000`); integer/float **exponents** (`1e9`); float shorthands `1.` and
  `.5`. (Hex `0x…` *is* supported.)
- String: `\u{…}` / `\0` escapes, raw or triple-quoted strings.
- Tuple literals/types `(a, b)` — `(…)` is grouping or lambda params only.

**Statements & control flow**

- `break` / `continue` (and labeled loops); a `loop { }` form.
- Standalone `if` / `match` as statements bind as expressions; there is no
  separate statement form, which is fine, but note there are no block-less
  `if` bodies (the body is always a `block`).

**Patterns**

- Float literal patterns; or-patterns (`A | B`), guards (`pat if cond`), range
  patterns, struct/field destructuring, and `name @ subpattern` bindings.

**Parser limitations (not language decisions)**

- Generic call type-arguments use a lookahead heuristic
  (`_looksLikeTypeArgList`) that bails on **nested** generics in call position,
  e.g. `f<Result<T, E>>(…)`. Annotated positions (`let`, params) handle nesting
  fine; only the `name<…>(…)` call form is limited.
```

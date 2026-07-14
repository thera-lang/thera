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

There are **no block comments** (`/* … */`). The `///` and `//!` forms are **doc
comments** — lexically still line comments, but carrying documentation that
tooling extracts; see [language.md](language.md#documentation) for the
conventions. `//` is an ordinary comment and is never extracted.

### Keywords

All reserved; none may be used as identifiers:

```
as  break  const  continue  else  enum  false  fn  for  if  impl  import  in
interface  let  match  mut  native  pub  return  self  struct  throw  true  type
void  while
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
`${ … }` embeds an arbitrary expression; a bare `$` not followed by `{` is
ordinary text (`\$` escapes a literal `${`).

### Operators & punctuation

```
{  }  (  )  [  ]  ,  ;  :  .  ..  ->  =>  ?  @  #  _
+  -  *  /  %  =  ==  !=  <  >  <=  >=  &&  ||  !
+=  -=  *=  /=  %=
&  |  ^  ~          // bitwise
```

`#` introduces a **compiler metaconstant** (`#loc` — see
[Expressions](#expressions)); `@` introduces a decorator.

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
              // A STRING path must be a plain literal — `${…}` interpolation in
              // an import path is a parse error.

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

structDecl  = 'struct' IDENT typeParams? '{' field* '}'
field       = 'let' 'mut'? IDENT ':' type ';'
              // Each field is a `let`-declaration terminated by `;` — `mut` opts
              // into reassignment. The `let`/`;` form reads as a declaration and
              // distinguishes a struct *declaration* from a struct *instantiation*
              // (the two bodies are otherwise identical). Both are required.
              // A nominal record: `struct Point { let x: Int; let y: Int; }`.
              // Constructed with a struct literal `Point { x: 1, y: 2 }`; methods
              // come from `impl` blocks. A fieldless `struct Marker {}` is legal (a
              // unit/marker type). (There is no `=`: `struct Name { … }`, not
              // `type Name = { … }` — the latter form was removed.)

nativeTypeDecl = 'native' 'type' IDENT typeParams? ';'?
              // An opaque, runtime-represented type with no field layout
              // (`native type List<T>`) — a declaration site for a built-in whose
              // representation lives in the runtime. Methods come from `impl`
              // blocks; it cannot be built with a struct literal.

enumDecl    = 'enum' IDENT typeParams? '{' variant (',' variant)* '}'
variant     = IDENT ( '(' type (',' type)* ')' )?       // positional payload
              // At least one variant is required — a zero-variant enum is a
              // parse error (uninhabited; there is no never type).

interfaceDecl = 'interface' IDENT typeParams? superInterfaces? '{' ifaceMethod* '}'
superInterfaces = ':' IDENT ('+' IDENT)*    // extended interfaces, e.g. `: Display + Debug`
ifaceMethod = 'pub'? 'fn' IDENT typeParams? '(' paramList? ')' ('->' type)? ( block | ';'? )
              // With a block: a **default method**, inherited by conformers
              // that don't define it (docs/language.md, Interfaces). Without,
              // a required signature.

implDecl    = 'impl' qualName implGenerics?
              ( 'for' qualName typeParams? )?
              '{' method* '}'
implGenerics = '<' implGeneric (',' implGeneric)* '>'
implGeneric  = type ( ':' IDENT ('+' IDENT)* )?
              // The `<…>` after the first name is read per the header's shape:
              // in `impl Iface<…> for T` it is the interface's *type arguments*
              // (full types, nesting OK — `impl Iterator<Indexed<T>> for E<T>`);
              // in an inherent `impl T<…>` each element must be a bare parameter
              // name with optional bounds (`impl Box<T: Display>`) — enforced by
              // the parser once it knows whether `for` follows.
method      = decorator* 'pub'? fnDecl                    // a fn, possibly native
qualName    = IDENT ('.' IDENT)?                          // e.g. Clock | time.Clock

constDecl   = 'const' IDENT (':' type)? '=' expr ';'?

letDecl     = 'let' IDENT (':' type)? '=' expr ';'?
              // A module-level binding (a global computed once at load; see
              // docs/language.md -> Module-level bindings). Immutable: top-level
              // `let mut` is rejected, unlike the local `letStmt`.
```

A trailing `;` is optional almost everywhere it can appear.

**Trailing commas.** Every comma-separated list — call arguments, parameter
lists, type parameters/arguments, list and map literal elements, enum variants
and their payloads, struct-literal fields, constructor-pattern arguments, lambda
parameters, decorator arguments — accepts an optional **trailing comma**. The
productions leave this implicit rather than writing `','?` into each one.
(Struct _declaration_ fields are `;`-terminated, not a comma list.)

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

statement = letStmt | constStmt | returnStmt | throwStmt | breakStmt | continueStmt
          | ifStmt | forStmt | whileStmt | assignOrExpr
          | ';'                                           // stray empty statement, tolerated

letStmt   = 'let' 'mut'? IDENT (':' type)? '=' expr ';'
          | 'let' '_' (':' type)? '=' expr ';'            // evaluate + discard (no binding)
          | 'let' pattern '=' expr 'else' block ';'?      // `let … else` guard;
            // refutable (uppercase) pattern, `else` must diverge; desugars to
            // `match`. v1: binds ≤1 variable.
constStmt = 'const' IDENT (':' type)? '=' expr ';'       // a local immutable binding
returnStmt= 'return' expr? ';'
throwStmt = 'throw' expr ';'
breakStmt = 'break' ';'                                   // exit the enclosing loop
continueStmt = 'continue' ';'                             // next iteration of the loop
            // Statement-only, unlabeled; a check error outside a loop body (and
            // never crosses a closure — a loop in an enclosing scope doesn't count).
ifStmt    = 'if' ( exprNB | 'let' pattern '=' exprNB )    // `if let` = cond. binding
            block ( 'else' ( ifStmt | block ) )?         //   (desugars to `match`)
forStmt   = 'for' pattern 'in' exprNB block
whileStmt = 'while' exprNB block

// The ';' is required, EXCEPT after a block-terminated expression statement
// (a bare `match`/`if`, ending in '}'), which — like if/for/while — needs none.
// An *assignment* always requires the ';'. A missing ';' is a parse error (so
// two adjacent literals do not silently merge).
assignOrExpr = expr ( assignOp expr )? ';'?
assignOp     = '=' | '+=' | '-=' | '*=' | '/=' | '%='
            // an assignment target must be an identifier, field access, or
            // index; `t op= e` desugars to `t = t op e`
```

`exprNB` is `expr` parsed with **struct literals suppressed**, so that
`if foo { … }` reads `foo` as the condition rather than `foo { … }` as a struct
literal. It is the same grammar as `expr` minus the `qualName structBody`
production (both the bare `Type { … }` and qualified `ns.Type { … }` forms);
parenthesizing restores it — `if x == (Point { x: 1 }) { … }` — as in Rust.

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
strings, and booleans (not floats) and may appear at any depth. A string pattern
must be a plain literal (`${…}` interpolation is a parse error), and there is no
negated form (a leading `-` is not part of a pattern, so `-1 => …` doesn't
parse). There are no or-patterns, guards, range, or struct/field patterns.

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
           | typeArgs '.' IDENT typeArgs? '(' callArgs? ')'
                // receiver type args on a static call — `Set<String>.new(…)`:
                // the first `<…>` binds the receiver type's parameters; the
                // method may carry its own `<…>`
           | '[' expr ']'                                 // index
           | '?'                                          // error propagation
callArgs   = callArg (',' callArg)*
callArg    = ( IDENT ':' )? expr                          // optional argument label
```

```
primary  = INT | FLOAT | STRING | 'true' | 'false' | 'self' | 'void'
         | '#' IDENT                                      // metaconstant (`#loc` only)
         | '(' expr ')'                                   // grouping
         | '(' lambdaParams? ')' '=>' expr                // lambda
         | IDENT '=>' expr                                // single-param lambda
         | qualName structBody                            // struct literal (when permitted)
         | IDENT                                          // name
         | listLit | mapLit
         | matchExpr
         | ifExpr                                         // if as a value (tail-valued)
         | exprBlock                                      // block expression (tail-valued)
         | 'return' expr? | 'throw' expr

lambdaParams = lambdaParam (',' lambdaParam)*
lambdaParam  = IDENT (':' type)?

listLit   = '[' ( expr (',' expr)* )? ']'
mapLit    = '[' ':' ']'                                   // the empty map
          | '[' mapEntry (',' mapEntry)* ']'
mapEntry  = expr ':' expr
            // After `[`, the parser reads one expression and the next token
            // decides — `:` commits to a map, anything else continues a list.
            // Keys are unrestricted expressions, and a map literal is valid
            // everywhere an expression is (including as a bare match-arm
            // body). (Maps briefly used braces — `{'a': 1}` — a form removed
            // by the map-literal migration; see below.)
structBody= '{' ( field (',' field)* )? '}'        field = IDENT ':' expr

matchExpr = 'match' exprNB '{' arm* '}'
arm       = pattern '=>' ( exprBlock ','? | expr ',' )
            // A block arm is tail-valued and needs no `,`; an expression arm
            // requires one. The last arm (before `}`) may omit it either way —
            // a trailing comma is optional, as everywhere.

// `if` in expression position (docs/language.md). Branches are tail-valued
// `exprBlock`s; `else` is required where the value is used (a primary `if`, or
// an `if` tail), optional for a discarded statement `if` inside an exprBlock. The
// statement form (`ifStmt`, above) is a separate node and keeps `else` optional.
ifExpr    = 'if' exprNB exprBlock ( 'else' ( ifExpr | exprBlock ) )?
```

A method call is `postfix` chaining: `recv '.' method` forms a field access, and
a following `'(' … ')'` makes it a call.

A `{` in expression position is always a **block**: `{}` is an empty block
(value `Void`), and `{ stmts… }` is a block expression. Maps never use braces —
the pre-migration brace-map form is a **targeted parse error** pointing at the
bracket syntax: a literal key (`{'a': 1}`, `{-1: 'x'}`) is caught at the `{`
(the old commit heuristic survives as the shape detector,
`at_legacy_brace_map`), and a non-literal key (`{k: 1}`) is caught at the `:`
after an expression statement. Both read "map literals are written `[k: v]`".

`#loc` is the one **compiler metaconstant** (`'#' IDENT`; any other name is a
parse error). It evaluates to a `SourceLoc` for the expression's own source
position — and as a parameter _default_ it captures the **caller's** location
(see [language.md](language.md)).

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
- String: `\0` escape, raw or triple-quoted strings. (`\u{…}` and `\xNN` _are_
  supported.)
- Tuple literals/types `(a, b)` — `(…)` is grouping or lambda params only.

**Statements & control flow**

- Labeled loops (`break`/`continue` target the innermost loop only); a
  `loop { }` form. (Unlabeled `break` / `continue` _are_ supported.)
- `if` and `match` work in both statement position (`ifStmt`, a bare `match`)
  and expression position (`ifExpr`, `matchExpr`); the value forms are
  tail-valued (docs/language.md). There are no block-less `if` bodies (the body
  is always a block).

**Patterns**

- Float and negative-int literal patterns; or-patterns (`A | B`), guards
  (`pat if cond`), range patterns, struct/field destructuring, and
  `name @ subpattern` bindings.

**Parser limitations (not language decisions)**

- Generic call type-arguments use a lookahead heuristic
  (`looks_like_type_arg_list`): after a `<`, a balanced run of identifiers / `.`
  / `,` / nested `<`/`>` whose closing `>` is followed by `(` or `.` commits to
  type arguments — so nested generics work in call position
  (`f<Result<T, E>>(…)`, `Map<String, List<Int>>.new()`). **Function types** are
  not recognized there (`f<(Int) -> Int>(…)` stays a comparison parse —
  admitting `(` would swallow parenthesized comparisons); annotated positions
  (`let`, params) handle them fine.
- The `<` disambiguation: a type-shaped `<…>` followed by `(` or `.` commits to
  type arguments (so a comparison chain `a < b > c` parses as comparisons —
  ill-typed, but syntactically comparisons). The residual `a < b > (c)`
  ambiguity (and its qualified/nested cousins, e.g. `a < b.c > (d)`) resolves
  the generic-call way (as in C#); the checker then rejects type arguments on a
  non-generic callee, so the comparison reading must be written parenthesized:
  `(a < b) > (c)`.

# Parser error recovery

**What this is:** the design and incremental rollout plan for Hawk's resilient
parsing strategy, ensuring the parser produces a structurally useful AST for
IDEs and LSP tooling even when code is incomplete or malformed mid-typing.

## Motivation

When a user is actively typing, the code is almost always in a syntax error
state. Code completion, hover, and other LSP features are the primary consumers
of the AST during these moments. If the parser aborts on the first error and
discards the rest of the file (or the rest of the function), these features fail
to provide useful context.

The Hawk parser must be resilient: it must recover locally at the node level,
insert synthetic tokens for missing delimiters, and preserve valid declarations
and statements both before and after the cursor.

## Recovery Strategies

**1. No global panicking flag** The parser currently uses a `panicking` flag
that aborts processing until the next top-level declaration keyword. We remove
this flag and its `sync_to_decl` logic. The parser will no longer globally abort
on the first error.

**2. Synthetic Tokens for Missing Delimiters & Identifiers** Instead of explicit
`Error` AST nodes, the parser synthesizes zero-length tokens. When
`expect(kind)` fails to find the correct token, it emits a `ParseError` but
returns a _synthetic token_ (a token of the expected `kind` with an empty string
span). Downstream consumers like code completion see a valid structural AST node
(e.g., an incomplete field access parses as a field access with an empty
identifier, which the completion engine can trigger on).

**3. Statement and Block Synchronization** Without `panicking`, the parser
avoids consuming arbitrary tokens endlessly when encountering garbage. When a
construct is entirely unrecognizable, the parser advances tokens one-by-one,
emitting an error, until it reaches a known statement or block boundary (like
`let`, `return`, `if`, or a closing `}`).

**4. Graceful Block/EOF Closing** When an unexpected `EOF` is hit inside a block
or nested expression, the parser synthesizes closing delimiters (`}`, `)`, etc.)
up to the root, rather than crashing or discarding the outer declarations.

## Testing Strategy & Completeness

Completeness is measured by verifying that the test suite comprehensively covers
the most likely mid-typing scenarios, producing structurally correct ASTs
before, at, and after the edit location.

We maintain a suite of `.hawk` files containing incomplete constructs in
`tests/recovery/` (or similar) and assert against the resulting structural AST.

### Likely Recovery Situations

1. **Typing Declarations**
   - **Incomplete functions**: `fn foo(a: Int` (missing `)` and body) or
     `fn foo() { ` (missing `}`).
   - **Incomplete types**: `type User = { name: ` (missing type and `}`).
   - **Mid-impl edits**: Adding `fn bar(` between two valid methods inside an
     `impl`.

2. **Typing Statements**
   - **Missing semicolons**: `let x = 5` followed immediately by another
     statement on the next line.
   - **Mid-function edits**: Adding `let y = ` between two valid statements.
   - **Incomplete control flow**: `if (foo) { ` or `match val { ` (missing
     branches/arms).

3. **Typing Expressions (Code Completion Triggers)**
   - **Dangling dots**: `user.` or `my_list.map(x => x.)` (waiting for
     field/method completion).
   - **Incomplete arguments**: `call_func(a, ` (waiting for next argument).
   - **Incomplete operators**: `let x = a + ` (waiting for RHS).
   - **Unclosed strings**: `let s = "hello ` (missing closing quote).

## Incremental Implementation Plan

To roll out parser recovery without breaking the existing compiler pipeline, we
can implement these changes in the following stages:

### Stage 1: Synthetic Tokens & Missing Delimiters

- Update the `expect(kind)` method in `parser.hawk` to return synthetic tokens
  instead of panicking.
- Fix any immediate downstream crashes caused by empty spans or synthetic tokens
  in the checker/compiler.
- Add initial tests for missing semicolons and unclosed parentheses.

### Stage 2: Graceful EOF Handling

- Modify the parsing loops (like `parse_program`, `parse_block`, etc.) to
  gracefully unwind and synthesize closing braces/parentheses when hitting
  `EOF`.
- Add tests for unclosed blocks and incomplete type declarations at the end of
  files.

### Stage 3: Removing Panic & Statement-Level Sync

- Remove the `panicking` flag entirely.
- Introduce `sync_to_stmt` for statement-level recovery inside blocks when
  garbage tokens are found.
- Add tests for mid-function and mid-impl edits, ensuring code after the syntax
  error is preserved in the AST.

### Stage 4: Expression-Level Recovery & Completion Scenarios

- Refine expression parsing to handle dangling dots and incomplete binary
  operators gracefully.
- Build out the full "Likely Recovery Situations" test suite.
- Verify that the resulting AST is well-suited for LSP code completion queries.

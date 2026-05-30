# Feature ideas and brainstorming

## General

- no exports?
- no getters / setters
- all imports are explicit; compilation and analysis is simple
- interfaces
- how to indicate private? case technique? underscore? explicit 'pub'?
- all method args are named?
- needs explicit return from methods (no implicit return)
- 2 space indent? 4?
- 100 char line limits?
- chars and strings set up well for unicode / utf / emojis
- don't have classes? just data structures and traits / interfaces? deep class
  heirarchies are one of the places where LLMs struggle
- how to handle asynchronous tasks and futures? Do we have a stream class?

## Strings

- Store strings as UTF-8 under the hood.
- Make the base `char` (`rune`?) type a 32-bit Unicode scalar.
- Prevent standard integer indexing on strings; instead force the user to
  iterate via explicit .chars() (code points) or .graphemes() (user-perceived
  characters) to guarantee they never accidentally slice an emoji or special
  character in half.

## Questions

- if you run a file, what determines the entrypoint?
  - for Dart, you have top level functions
  - for Java, you specify the entry-point class
  - for Python, you are running that modulo (and some wierd init method)
  - fn main(args: Args) -> int
- are we going for a simple language or a token efficient one?
  - we could require all params to be named, or we could support positional args

## Organizational units

The "Clearest" Taxonomy: the clearest, most defensible hierarchy to use is:

- A developer writes Source Files inside a Git Repository.
- Logically, those files are organized into reusable Modules.
- When ready to share, the code is bundled into a versioned Package (or
  Artifact).
- That Package is published to a Registry (like GitHub Packages, npm, or PyPI)
  so others can download it.

## TODO

- [x] create an 'sdk' subdir; use for artifacts that will make up the sdk
- rename to 'hawk'?
- create a cargo build for the 'hawk' cli tool (front-end image + interpreter +
  Cranelift + GC); in 'tool'?
- IR design
- interpreter

# The LLM-Native Programming Language: Architectural Guidelines

_(working name: ‘hawk’)_

As artificial intelligence transitions from localized code autocomplete to
autonomous agents capable of managing entire repositories, the criteria for an
"ideal" programming language have fundamentally shifted. Languages optimized for
human expressiveness or mathematical purity often introduce cognitive barriers
for Large Language Models (LLMs). This document outlines the architectural
choices, paradigms, and syntax features that maximize an AI agent's ability to
author, refactor, and maintain code productively and predictably.

## 1. The Core Pillars of LLM Productivity

- **Strong, Static Typing:** Acts as a deterministic boundary that immediately
  prunes an LLM's probabilistic hallucinations. Nominal types with
  straightforward generics are preferred over Turing-complete or structurally
  complex type systems (which consume excessive tokens and cause multi-line
  compilation cascades).
- **Fast, Precise Static Analysis:** Ecosystems with robust Language Server
  Protocols (LSPs) allow agents to query Abstract Syntax Trees (ASTs). This
  gives agents "sight"—enabling semantic renaming and scope-aware refactoring
  rather than relying on error-prone raw text regex modifications.
- **High-Level Memory Management:** Garbage-collected, memory-managed languages
  abstract away the need to manage pointer arithmetic and memory leaks,
  preserving the LLM's token budget for business logic rather than temporal
  memory tracking.
- **Comprehensive Standard Library:** "Batteries included" languages (like Go or
  Python) reduce hallucination rates. When standard libraries handle common
  tasks (HTTP, JSON, dates), the agent uses highly reinforced API patterns
  rather than guessing third-party package APIs.
- **Strict, Opinionated Formatting:** A single, culturally enforced way to
  format code and handle patterns reduces the number of decisions an agent must
  make, preventing architectural drift and minimizing token waste.

## 2. Language Features to Embrace

- **Immutability by Default:** Enforcing Single Static Assignment (where
  variables are bound once and transformed via pipelines) prevents the
  "multi-hop attention tax." It eliminates the need for an LLM to scan hundreds
  of lines backward to determine the current mutated state of a variable.
- **Explicit Errors as Values:** Returning errors as values (e.g., Rust's Result
  type) maintains a flat AST and keeps control flow linear and completely
  visible. Ergonomic implementations like Rust's ? or Zig's try prevent vertical
  boilerplate while maintaining predictability.
- **Explicit Scope Markers (Braces):** While semantic whitespace seems cleaner,
  explicit braces allow agents to inject or mutate code via diffs without
  breaking the AST due to off-by-one indentation errors.
- **Single-Threaded Futures / Async-Await:** Abstracts concurrency into
  sequential boundaries. Eliminates shared-memory multi-threading, which
  requires temporal/fourth-dimensional reasoning that pattern-matching LLMs
  fundamentally lack.
- **Inline Semantic Metadata:** Decorators and annotations (e.g., @Get("/api"))
  embed architectural intent directly adjacent to the function signature,
  keeping crucial context within the same local token window.

## 3. Language Features to Avoid

- **Exceptions (Checked and Unchecked):** Throwing exceptions creates invisible,
  non-linear jumps in control flow (stack unwinding) and is hostile to
  functional data pipelines, forcing agents to write nested try/catch
  boilerplate.
- **Heavy Metaprogramming and Macros:** Dynamic code generation and aggressive
  operator overloading break the WYSIWYG (What You See Is What You Get) nature
  of code, blinding both the LLM and its static analysis tools.
- **Deep Inheritance Hierarchies:** Forces the LLM to load multiple parent files
  into the context window to resolve state or method signatures. Composition
  over inheritance is strictly preferred.
- **Two-Way Data Binding & Implicit State:** Global singletons and automatic
  two-way UI bindings create unpredictable mutation paths. Unidirectional data
  flow makes state changes explicit and traceable.

## 4. The Ideal "Middle Ground" Paradigm

The most productive environment for an LLM combines the strict safety of
functional programming with the practical execution of imperative programming.
This is best achieved via the **Functional Core, Imperative Shell**
architecture:

| Layer                | Characteristics                                                             | LLM Advantage                                                                          |
| -------------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Functional Core**  | Pure functions, immutable data pipelines, domain logic. No side effects.    | Zero state hallucination; trivial to write unit tests for; perfectly linear reasoning. |
| **Imperative Shell** | Database adapters, UI framework bindings, network calls. Mutable and messy. | Keeps complex runtime state strictly quarantined to the application boundaries.        |

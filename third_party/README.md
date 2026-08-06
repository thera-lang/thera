# third_party

Content vendored from other projects. Each subdirectory holds one item drawn
from a single upstream source and carries:

- a `README.md` naming the upstream project, the exact version vendored, what
  subset was taken, and how to refresh it (usually an `update.sh` beside it);
- the upstream `LICENSE` file;
- the vendored files themselves, preserving the upstream layout where practical.

Vendoring here is for substantial imports — a test corpus, a data set. A minor
include (a constant, a table, a few lines with an attribution comment) does not
need a directory here.

The rest of the repo consumes these files in place; nothing copies them
elsewhere at build time.

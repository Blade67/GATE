# Roadmap

No dates, only order. This is what I intend to build, what I am still thinking about,
and what I am not going to do. Everything here is subject to change, and anything
already released is in [CHANGELOG.md](CHANGELOG.md).

## Next

Ordered by how self-contained the work is, not by how much I want it.

- **Carrying a comment written inside a call's brackets.** Array literals, dictionary
  literals and `enum` bodies carry theirs now; a call does not. Measured over 3,495 real
  files, that is 150 of the 764 comments written inside brackets. A call is rebuilt from
  the syntax tree onto one line, so it would need a wrapped form of its own - which would
  change the shape of far more output than a literal does, for a fifth of the remaining
  comments.
- **Calling another class's generic function.** `func first<T>(...)` works, and so does
  calling it from the class that declares it. `Helper.box<int>(3)` does not: it reads as
  a comparison, which is what GDScript means by it. A generic class is monomorphised in
  the file that declares it and reached by name from anywhere; a function has no global
  name, so the same trick needs the registry to carry the instantiation to the declaring
  file and the call to resolve to a method on it.
- **A converted project's second open.** The first open compiles each file once now.
  The second still recompiles most of them: a file GATE could not verify, because
  Godot had not registered the classes GATE had just written, is not saved as proved,
  so the next session builds it again only to check it. Measured on Pixelorama, 212
  files: 80 s for the first open and about 60 s for the second, where the third is 11 s.
  The output on disk is already right in every one of those cases, so what is missing
  is a way to remember "this is built, it just has not been checked" across a restart.
- **Per-member dependency tracking.** A file is rebuilt today when anything it reads
  changes, and a declaration counts as read by every file that reaches it. Adding a
  method to a file most of the project goes through costs about 35 s on a 211-file
  project, where a body edit in the same file costs about 2 s. Tracking which member
  each file actually reads should bring the first case close to the second.

## Considered

- **Type-first parameters.** `int func myFunc(int num)` instead of
  `func myFunc(num: int) -> int`. It reads better and it is the obvious completion of
  type-first declarations, but the parser already reads `int x` at the start of a line
  as a declaration, so telling the two apart needs more lookahead than the rest of the
  grammar does. It would also change how 44% of the functions in a real corpus are
  written, which is a large thing to be unsure about. Not ruled out, not started.
- **A `@compile_raw` block.** Proposed in issue #12 so that a region could be copied
  into the output untouched, and asked for because comments were being dropped.
  Comments are carried now, so the reason it was raised is gone. The issue stays open
  in case there is a second reason for it that I have not thought of.

## Not planned

- **Anything that makes valid GDScript stop being valid GATE.** This is the one rule
  the whole project is built on. A feature that needs it is not a feature.
- **Self-hosting.** GATE is a `@tool` plugin, so compiling itself would be a bootstrap
  problem, not a milestone.
- **A runtime.** Nothing GATE adds should have to ship with your game. The output is
  plain GDScript and there is nothing to link against.
- **Godot 3.** The output targets Godot 4's type system.

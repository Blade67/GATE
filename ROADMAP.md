# Roadmap

No dates, only order. This is what I intend to build, what I am still thinking about,
and what I am not going to do. Everything here is subject to change, and anything
already released is in [CHANGELOG.md](CHANGELOG.md).

## Next

Ordered by how self-contained the work is, not by how much I want it.

- **Comments inside a lambda body or grouping parentheses.** Array literals, dictionary
  literals, `enum` bodies and a call's argument list all carry their comments now:
  measured over 3,495 real files, 626 of the 764 written inside brackets. Of what is
  left, a comment inside a lambda body passed as an argument belongs to statements rather
  than to an argument list, and one inside grouping parentheses has nothing to attach to,
  since GATE drops the parentheses and re-emits the expression.
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

# Roadmap

No dates, only order. This is what I intend to build, what I am still thinking about,
and what I am not going to do. Everything here is subject to change, and anything
already released is in [CHANGELOG.md](CHANGELOG.md).

## Next

- **A class declared in a `.gate` can be attached to a node.** Today a top-level
  `class Foo extends Node2D:` lowers to an inner class of the generated `.gd`, so Godot
  will not let you attach it or place it from the Create Node dialog
  ([#6](https://github.com/Blade67/GATE/issues/6)). It should produce a script Godot
  recognises. The open question is the spelling: whether a top-level class becomes a
  `class_name` automatically, or whether you keep saying so yourself. Whichever it is,
  it changes what existing files compile to, so it comes with a rule written down in
  SYNTAX.md rather than quietly.
- **Arrow lambdas.** `array.map((int x) => x + 1)`, so a one-expression lambda stops
  costing a `func(x): return x`.
- **Per-member dependency tracking.** A file is rebuilt today when anything it reads
  changes, and a declaration counts as read by every file that reaches it. Adding a
  method to a file most of the project goes through costs about 35 s on a 211-file
  project, where a body edit in the same file costs about 2 s. Tracking which member
  each file actually reads should bring the first case close to the second.
- **Attach Script creates the `.gate`.** Choosing GATE in the Scene dock's Attach
  Script dialog refuses today, because a node has to run the compiled `.gd`. It should
  create the `.gate`, compile it, and attach the `.gd` that appears beside it.

## Considered

- **Type-first parameters.** `int func myFunc(int num)` instead of
  `func myFunc(num: int) -> int`. It reads better and it is the obvious completion of
  type-first declarations, but the parser already reads `int x` at the start of a line
  as a declaration, so telling the two apart needs more lookahead than the rest of the
  grammar does. Not ruled out, not started.
- **A pipe operator.** Something like `value |> f() |> g()`. Nothing is designed yet,
  and it has to earn its place against the confusion of a new operator.
- **Keeping `##` doc comments.** Comments are dropped today, which means renaming a
  documented `.gd` strips the documentation Godot builds its class reference from. Doc
  comments are the ones worth carrying through.
- **Faster first opens after converting a project.** Converting 211 files costs about
  130 s on the first open and about 50 s on the second, because Godot registers the
  classes GATE has just written. Once it settles, opening it unchanged is about 10 s.

## Not planned

- **Anything that makes valid GDScript stop being valid GATE.** This is the one rule
  the whole project is built on. A feature that needs it is not a feature.
- **Self-hosting.** GATE is a `@tool` plugin, so compiling itself would be a bootstrap
  problem, not a milestone.
- **A runtime.** Nothing GATE adds should have to ship with your game. The output is
  plain GDScript and there is nothing to link against.
- **Godot 3.** The output targets Godot 4's type system.

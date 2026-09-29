# Changelog

## Unreleased

### Added

- **Generic functions** (issue #8). `func first<T>(xs: T[]) -> T` is a template, and
  `first<int>(ns)` emits one monomorphised copy per set of type arguments, exactly as a
  generic class does. The template itself is never emitted, and one nothing calls emits
  nothing.

  Type arguments are written out rather than inferred, which is what generic classes
  already require. Another file's generic function is called through its class name or a
  preloaded const, `Helper.box<int>(3)`, and is monomorphised in the file that declares
  it. Only a *function* template may be followed by `(`, so `a.b<c>(d)` where `b` is not
  one stays the pair of comparisons GDScript reads it as.

  Almost all of it was already there: the parser mangles `Name<Args>` in expression
  position for `Pool<Bullet>.new()`, so teaching it that `func NAME<` declares a template
  and that a generic span before `(` is a call rewrote every call site; and the emitter's
  instantiation path reads only `generic_params` and `name`, so one table serves classes
  and functions both.

  Checked before building rather than after: `ident<Type>(` occurs 9 times in 3,495 real
  files and every one is inside a comment or a doc string, so no valid GDScript changes
  meaning.

- **Comments written inside an array literal, a dictionary literal or an `enum` body are
  carried into the output.** Measured over 3,495 real files: of the 764 comments written
  inside brackets, 614 now survive where none did. The rest are inside a call's argument
  list, which is rebuilt from the syntax tree onto one line and so has no line to put one
  back on.

  The lexer never makes these tokens - it cannot, because the parser only skips comments
  where an operand may appear and not where an operator may, which is why they were
  dropped in the first place - so they travel beside the token stream in a table keyed by
  line. The token stream is unchanged, which matters: the build cache is keyed on a hash
  that skips comments, and a comment edit must not look like a code edit.

  A construct that carries a comment takes its one-per-line form so that each comment has
  a line of its own. One that carries none is emitted exactly as before, including an
  `enum`, so no project is reformatted for a feature it is not using. `##` on an enum
  member is how Godot documents enum values, which is the same reason comments are
  carried at all.

  Three rules, each found by the corpus rather than designed:

  - A trailing comment goes on its element's **first** line. After the whole element, it
    migrates from the `[` it was written beside to the matching `]`, and the next compile
    finds it on a line no element claims and drops it.
  - Only a construct written across several lines claims anything. After one compile a
    nested literal and the element holding it share a line, and the inner one would take
    a comment written beside the outer.
  - A construct claims only what was written between its own brackets. Without that
    floor, an inner literal took a comment written above it and the comment descended one
    nesting level on every compile - six files in the corpus, none of them in corpus4.

### Changed

- **Converting a project compiles each file once, not three times, and opening it again
  compiles nothing.** Pixelorama, 212 files, measured before and after on the same tree,
  same harness and same machine: the first open went from 147 s and 424 compiles to 106 s
  and 212, which is one per file, and the second from 68 s and 200 compiles to 31 s and
  none. The two opens that matter go from 216 s to 137 s. Two causes on the first open,
  both of them GATE reacting to its own output.

  The first was deliberate and documented in the builder: a file whose output could not be
  verified yet - because Godot had not registered the classes GATE had just written - was
  recompiled so that it landed in the deferred set again, which is where verification
  happens. The output it produced the second time was identical to the first. It now
  re-enters that set directly, reusing the dependency list it recorded rather than
  recovering one from the finished text, which the dependency graph explicitly does not do
  because it misses every relatively-written preload.

  The second was a defect. `gd_class_names` is "the `class_name` a **plain** `.gd`
  declares", and the index walked every `.gd` in the project, GATE's own outputs included.
  The moment Godot registered one of them the table gained an entry, that changed the
  registry signature, and the signature is part of every file's cache key - so the build
  after the one that wrote the outputs recompiled the whole project for a name it already
  knew by another path. `_name_owners` had skipped outputs for this reason all along.

  The second open is fixed the same way, across a restart. A file that could not be
  checked is now saved as built-but-unchecked, with its dependency list, and the next
  session puts it straight into the verification queue instead of compiling it again. It
  is still marked unverified, so it really is validated - nothing is trusted that was not
  checked. On that project the second open went from 68 s and 200 compiles to 31 s and
  none. Both opens are measured, and pinned against regressing.

### Added

- **Multidimensional arrays, `int[,]`, off by default** (issue #3). Turn on
  `gate/features/multidim_arrays` to use it. `int[,]` is another spelling of `int[][]` and
  `a[i, j]` another spelling of `a[i][j]`; they are the same type and interchange freely,
  because both are the same `array_depth` and the parser builds the same nested index
  nodes. Nothing downstream learns that the spelling exists. More than two dimensions is
  refused for the reason `int[][][]` already was, since GDScript nests typed arrays only
  one level deep. Off by default because it is a second way to write something the
  language already has, and that should be asked for rather than met by surprise; with the
  flag off, both spellings are an error naming the setting.

- **A pipe operator, `x |> f()`, experimental and off by default.** Turn on
  `gate/experiments/pipe_operator` to use it. `x |> f()` is `f(x)` and `x |> f(a, b)` is
  `f(x, a, b)`: the piped value becomes the first argument and everything else keeps its
  order. Left-associative, so `a |> f() |> g()` is `g(f(a))`. It binds looser than every
  arithmetic and bitwise operator and tighter than a ternary, which is what makes
  `a + 1 |> f()` pipe the sum and `a |> f() if c else d` choose between two pipelines;
  ordinary bitwise or is untouched. The right side must be a call, brackets included, and
  anything else is an error saying so. Desugared in the parser into the call that was
  written the other way round, so no pass downstream knows pipes exist.

  It is experimental rather than shipped because it is the one thing on the roadmap that
  solves nothing specific to Godot, and a new operator has to earn its place against the
  confusion of one. Writing `|>` with the flag off is an error naming the setting rather
  than a syntax error, which is why the flag is checked at the operator and not at the
  lexer. `|>` cannot occur in valid GDScript (`a | > b` has a bare `>` where an operand
  goes), so recognising it takes nothing away from the superset rule either way.

- **A call hint carries the callee's documentation.** The caret inside an argument list
  already showed the full signature; it now also carries the `##` block written above that
  function, for a callee in the file being edited and for one in another `.gate`. Carrying
  comments into the output is what made this possible: before it, the text existed only in
  the `.gate` and reached nothing Godot or an LSP client could read. It is still not in the
  syntax tree, since no pass has a use for it, so it is read back out of the source by line
  number - and the line is checked to really hold that declaration before it is trusted,
  because a line number taken from one file and applied to another is exactly how the first
  version answered one call with another function's documentation. An engine method carries
  none: ClassDB has no documentation and Godot's class reference is not reachable from a
  script at editor run time, so nothing is the honest answer. Part of issue #11.

- **Arrow lambdas.** `nums.map((x: int) => x + 1)` instead of
  `nums.map(func(x: int): return x + 1)`. The parentheses are always required, because
  `(x)` on its own is a group and only the `=>` past the closing bracket tells the two
  apart; the parser decides by scanning to the matching bracket and looking at what
  follows, which is the one place in the grammar that needs to. `=>` cannot appear in
  valid GDScript (`a => b` would have to be `a = > b`, and a bare `>` is not an
  expression), so adding it takes nothing away from the superset rule. Parameters follow
  exactly the rules a `func` lambda's do, and the arrow is desugared to a single `return`
  in the parser, so the checker, the null analysis and the effect summaries never learn
  that arrow lambdas exist.

  The expression is the lambda's value, so it compiles to `return` - except over a call
  that returns nothing, which GDScript refuses outright ("Cannot get return value of call
  to 'f()' because it returns void") and which would have made
  `tween_callback(() => queue_free())` emit a script that does not load. GATE reads
  voidness from the method's own declared return type, and from ClassDB for an engine
  method, and treats anything it cannot establish as a value. The one case it knows it
  cannot answer is a method declared by a base written in GATE: the base chain records
  the name but not the return type, so ClassDB is deliberately not consulted there rather
  than risk matching an unrelated engine method of the same name.

- **A language server for `.gate` files, off by default.** GATE speaks LSP over a
  loopback socket from inside the Godot editor, the way Godot's own GDScript language
  server does, so a `.gate` can be edited in Neovim, Helix, Zed or VS Code. Turn it on
  with the project setting `gate/lsp/enabled`; `gate/lsp/port` is 6100, it binds
  `127.0.0.1` and nothing else, and a port already taken is reported rather than swapped
  for another one.

  **Diagnostics, in two tiers.** As you type, the errors and warnings Godot's script
  editor shows on the same file, because both come from one pass over one set of tokens,
  with GATE's hint carried as related information rather than glued onto the message.
  When you save, the errors a compile finds as well: unknown types, the null analysis and
  the superset checks, which used to reach you only through Godot's Output panel, where an
  external editor cannot see them. A type another `.gate` declares resolves, because the
  editor already holds the project's registry. The tiers are split because they cost
  different amounts: the lexer pass is 0.2 ms on a small file and 12.5 ms on a 238-line
  one, and a compile of the same two is 5.8 ms and 259 ms, on the editor's own main
  thread. A problem both tiers find is reported once.

  **Completion and signature help.** The same list Godot's script editor offers, in the
  same order, with GATE's kinds mapped to your editor's icons. Where GATE cannot work out
  the type of what is left of the dot it offers nothing, exactly as it does in Godot: a
  confidently wrong list costs more than an empty one. Signature help names the call you
  are inside and highlights the argument you are on, including after a comma inside a
  nested call. A method of a Variant built-in such as `String` or `Array` gets no
  signature, because Godot's own API dump records those methods without their parameters
  and a signature with an empty parameter list would say the method takes none.

  A callable is offered under its bare name, with the bracket Godot's own completion
  shows carried in what gets inserted instead. A client filters and sorts on the label,
  so `hurt(` sorted away from plain names and narrowed worse as you typed.

  **Go-to-definition, hover and an outline.** Definition asks the same code Ctrl-click
  asks, so it lands in the same place: a local, a parameter, a member, a function, a
  signal, an enum, a type declared in another `.gate`, a `class_name` in a hand-written
  `.gd`, an autoload, and anything inherited, including from a base written as a path. A
  word it cannot place answers nothing rather than the nearest name that looks similar,
  and the answer is always a location in a file you wrote, never in the `.gd` GATE
  generated from your `.gate`. Hover returns the declaration as you wrote it and the type
  GATE has declared for it, as markdown, and nothing at all rather than an empty tooltip
  where it has nothing to say. The outline is a tree rather than a list: a class holds its
  members, a namespace holds its classes, an enum holds its keys, and a file that is
  mid-edit still gets one.

  Requests GATE does not answer yet are answered "method not found" rather than with an
  empty result, so a client falls back to its own word list instead of believing GATE has
  nothing to offer. While your editor holds a file open, everything GATE says about that
  file is computed from your buffer; anything it has to read from another file comes from
  disk, so an unsaved change in a base class is not taken into account while it looks at
  the file that extends it.
- **Attach Script creates the `.gate`.** Choosing GATE in the Scene dock's *Attach
  Script* dialog used to be refused, with a sentence explaining that a node has to run
  the compiled `.gd`. It now writes the `.gate` from the chosen template, compiles it
  straight away rather than waiting for the next filesystem scan, and attaches the
  generated `.gd` to the selected node, as one undoable step. The reason behind the old
  refusal still holds: a `.gate` is never the script on a node, in the editor, in the
  saved scene, or at run time. The `.gate` is what stays open in the script editor,
  since that is the file you edit. If the build fails - most often because a
  hand-written `.gd` already sits where the output would go - GATE puts the build's own
  error on screen, leaves the written `.gate` on disk, and attaches nothing.
- **Conditional compilation: `@if` / `@elif` / `@else` / `@endif`** (issue #2). Resolved
  before the lexer sees the file, so a dropped block is never parsed - it can hold code
  that would not compile at all - and is blanked rather than deleted, so every line after
  it keeps its original number and the sourcemap needs no change. A condition is a symbol,
  `!`, `&&`, `||`, parentheses, and a comparison against `GODOT_VERSION` against a version
  literal like `4.7`. Symbols come from Godot itself at compile time: `DEBUG`, `RELEASE`,
  `EDITOR`, `EXPORT` (true only during an export recompile), a platform/architecture tag
  per `OS.has_feature()` (a fixed list of 18), and `GODOT_VERSION` (usable only in a
  comparison), plus any name declared in the project setting `gate/compiler/defines` - an
  entry is `NAME` (true) or `NAME=0`/`NAME=false` (false; `1`/`true` also accepted), wherever
  it is read, so a symbol can be turned off without deleting the `@if` that names it. An
  unknown symbol, or a malformed entry, is a compile error naming the setting - a typo does
  not silently delete code. The build cache picks
  up a change to `gate/compiler/defines` for a file that uses a directive, and leaves a
  file that does not alone. At export, `.gate` files never reach the pack; the addon's
  export plugin recompiles each file's shipped `.gd` with a table built entirely from the
  preset - `EXPORT` true, `DEBUG` from the preset's debug flag, `EDITOR` false, every
  platform and architecture tag decided by the preset alone, never by the machine doing the
  exporting - so a release build genuinely lacks a `@if DEBUG` block, not just skips running
  it, and exporting for one platform never inherits another's tags from the host. A failed
  recompile is left out of the pack and logged loudly, never shipped as a stale editor
  build. The editor colours a directive in the control-flow colour, not as an unrecognised
  annotation, and offers the four words after `@`.
- **`@global` classes (issue #6).** `@global class Foo extends Node2D:` writes its own
  Godot script beside the file that declares it, `<source>.Foo.gd`, carrying `class_name
  Foo` - a real, attachable script, listed in the Create Node dialog, rather than an inner
  class of the `.gate`'s own output. The name is project-wide: another file uses it with no
  preload, and two declarations of the same name are an error naming both. Refused on a
  class nested inside another class, a struct, an interface, a trait, or a class inside a
  `namespace` (a namespaced class still cannot be attached; see the README's known gaps). A
  generic global class writes one script per instantiation. Ctrl-click and F1 on a global
  class always land in the `.gate` that declares it, never the generated script.
- **A feature-flag table.** One place, `GateFeatures.ROWS`, declares every GATE flag; Project
  Settings registration, the value the compiler reads, and the incremental build cache all
  derive from it, so a new flag is one row plus the code that checks it. `gate/features/<id>`
  for a shipped feature, `gate/experiments/<id>` for one that is not. Flipping any flag
  rebuilds every file, the same way changing the project's classes does.
- **`Project Settings > Gate > Features > Type First`.** On by default. Off, a type-first
  declaration (`int hp = 100`, `str label = "x"`, `vec2[] tiles`, `const int MAX = 10`) is a
  compile error naming the setting and the `var name: Type` spelling to write instead. Only
  the declaration form goes away: GATE's own types still work in a GDScript annotation
  (`var scores: int[]`, `var target: Node2D?`, `var id: <int | str>`), and a struct,
  interface or trait body takes `var name: Type = value` too, so no other feature becomes
  unreachable. `int a, b` has no replacement, GDScript having no multi-name declaration.
  Independent of Shorthand Types: with type-first off, `var v: vec2` still means `Vector2`.
  Inside a destructuring pattern the flag covers the `Type name` slot spelling only:
  `var [a: int, b: String] = ...` always works, and destructuring itself is never refused,
  GDScript having none of its own to write instead.
- **`Project Settings > Gate > Features > Shorthand Types`.** On by default. Off, `str`,
  `vec2`, `f64` and the rest of GATE's shorthands are not type names anywhere - a type-first
  declaration, `is`/`as`, an array element or a generic argument spelled with one is a compile
  error ("'str' is not a type here") naming the setting and the Godot spelling to write
  instead. A file that declares its own class, struct, interface, trait, namespace, enum or
  const of that name keeps meaning that, flag on or off - only the shorthand meaning goes
  away, never a name the file gave itself (`str` excepted: it is also GDScript's own global
  `str()` function, so `struct str`/`interface str`/`trait str`/`namespace str` and a generic
  `class str<T>` are all refused outright on either setting, same as before this flag existed;
  a plain, non-generic `class str` is unaffected). Plain GDScript,
  which never spells a type this way, is
  unaffected either way. With `shorthand_types` off, `type_names_as_values` cannot map a
  bare shorthand used as a value either - there is no type name left to map it to - so that
  case's hint names `Shorthand Types` instead.
- **`Project Settings > Gate > Features > Type Names As Values`.** Off by default. Turns a
  shorthand type name used as a value (`vec2.ZERO`, `vec2(1, 2)`, `f64(3)`) back into the
  canonical Godot name instead of a compile error - see the entry under Changed. Never
  written to `project.godot` unless you change it yourself. Was briefly
  `gate/compiler/type_names_as_values`; renamed into the flag table above before shipping, so
  no project depends on the old path.
- **Typed destructuring.** `var [Move[] moves, Mark[] marks] = components` gives each name
  its own type. `var [moves: Move[], marks: Mark[]] = components` works too, and typed and
  untyped names mix. A name typed as an array or a dictionary is the slot's own object. An
  append through it reaches `components`, whether the arrays in it are typed or not.
  A loop over it is typed, and so is `var first := moves[0]`, as over a real typed array.
  A typed parameter, return, field or variable that GATE can see refuses it. That holds
  directly, through a ternary or `??`, or as a `duplicate()` of it: it is a compile error
  showing the copy to write. A `for` loop variable, an `as` cast (trusted by design), and a
  call through a `Callable` are not checked. Storing a value of the wrong element type in
  it is a compile error too, by `append`, `insert`, `assign`, `+=`, an index or a whole
  assignment. So is the same kind of store into an array or dictionary value nested inside
  it, such as `grid[0].append(x)` on an `int[][]` or `d["k"].append(x)` on a `{str, int[]}`.
  That holds as far as GATE's own nested-collection lowering keeps a real type there at
  all: `bool[][]`'s or `{str, bool[]}`'s inner level has no `Packed*` array to lower to. It
  is untyped the same as a real `bool[][]` variable's own element, and is left unchecked
  the same way. A nested level that does lower to a `Packed*` array has no `assign` method
  at all. That is now an error too, naming the packed array as the reason and pointing at
  `append_array`. `+=` on that same level is an error when the right side is a plain Array,
  but not when it is another packed array of the same exact kind, since Godot accepts that
  one. `i64`/`f64` share a canonical name with `int`/`float` but lower to a different
  `Packed*` array, so `int[][] += i64[][]` is still an error. A bare alias name on the
  right is never treated as packed either, whatever it actually holds.
  Storing through the alias is checked as if it reached a real typed array. One exception:
  `+=` and a whole reassignment on a bare (non-nested) alias name both reassign the untyped
  local instead of mutating the source in place. A converting element, a `float` into an
  `int` slot say, would then silently keep its unconverted value rather than the real
  array's own conversion. Both are now refused for that, with a hint to convert explicitly
  or use `append`/`assign` instead, since those do reach the real array.
  Nullcheck's own flow narrowing is what a store is checked against, not a value's bare
  declared type. A nullable value already guarded by a null check, `if f != null:
  xs.append(f)` say, is not refused either.
- **Completion offers the base's virtuals in a class body** (issue #11). Typing `_pro`
  where a declaration goes offers `_process(delta: float) -> void:` and the rest of what
  the base declares for overriding, signature filled in, the way GDScript does. The list
  comes from the resolved base, so it is right for `extends Node2D`, for a base that is
  another `.gate` - including its own `virtual func` declarations - and for
  `extends "res://x.gd"`. It is offered in a class body only, never inside a function and
  never on another object, where a virtual is not something to call. The text inserted
  carries the `func` the caret has not typed yet, and a case compiles it to prove it.
- **A call shows the signature of what is being called** (issue #11). The caret inside an
  argument list produces a parameter hint - return type, name, every parameter with its
  type and its default - for a function in the same file, in another `.gate`, in a `.gd`
  of the project, and for an engine method, with the argument the caret is on marked. It
  is not offered where the callee cannot be placed, and a parenthesis inside a string or a
  comment does not open a call.
- **Ctrl-click and F1 place an enum's members.** `Mood.CALM`, and `CALM` on its own where
  the enum is in scope, used to be the one member kind that was not underlined. They now
  go to the enum that declares them. The key itself has no line of its own - GATE's parser
  keeps an enum's keys as names on the declaration - so a one-line enum lands on the key
  and a multi-line one lands at the top of the body.

### Changed

- **A shorthand type name used as a value is now an error, not silently accepted.**
  `vec2(1, 2)` used to compile as the `Vector2` constructor; `vec2.ZERO`, `vec2i.ONE`,
  `f64(3)`, `str.chr(65)` and every other shorthand used as a member receiver or a
  conversion call compiled too, but Godot refused the output ("Identifier 'vec2' not
  declared in the current scope") - GATE reported success and handed back code that did
  not load. Every one of these is now a compile error, "'vec2' is a type name, not a
  value", with a hint giving the fix. `vec2(1, 2)`, `vec2.ZERO` and the rest map to the
  canonical name again if `Project Settings > Gate > Features > Type Names As Values` is
  turned on (see Added). `str(5)` is unaffected either way - it is GDScript's own builtin,
  not a shorthand - and so is a type position like `x is vec2` or `vec2 v`. A bare name
  used as a value is not an error when another file declares its own class, struct,
  namespace or enum of that same name (a `class color` or `enum plane`, say): the name
  means that declaration, project-wide, the same way a type position already reaches it.
- **A token left over on a line is an error.** `total = base bonus` compiled to
  `total = base` and then `bonus` on a line of its own, which Godot accepts. Only leftovers
  that looked like a second statement were caught before.
- **`int a, b = 3` is an error.** The value went to `a`, and `b` got 0. Put each name on
  its own line, or destructure.
- **A destructured tuple slot takes its type.** With `p: <float, int>`, `var [a, b] = p`
  now declares `a` a `float`, so an `int` arriving from GDScript is converted, as the tuple
  says, and `a / 2` divides as floats. Before, `a` was untyped and divided as integers. An
  `int` slot truncates a `float` the same way.

### Fixed

- **Loading a `.gate` with the cache ignored took the path off the open one.** The
  loader called `take_over_path()` whatever the caller asked for, so a load that wanted
  its own private copy left the script the editor was showing with an empty
  `resource_path`: it went on displaying the file, and anything answered from the path
  had nothing to work from. An ignore-mode load takes nothing over now.
- **Dragging a node from the Scene dock into a `.gate` was refused** (issue #11). The Scene
  dock asks the script for its instance base type and nothing else before it will accept the
  drop, and a `.gate` answered nothing, so `ClassDB.is_parent_class("", "Node")` was false
  and the drop was turned down with "script does not inherit Node". A `.gate` now answers
  the engine class at the root of its `extends` chain, resolved from the buffer being edited
  and the project's registry: `extends Node2D` answers `Node2D`, `extends Player` where
  `Player` is another `.gate` that extends `CharacterBody2D` answers `CharacterBody2D`, a
  `class_name` in a hand-written `.gd` and a path base (`extends "res://x.gd"`, absolute or
  relative) both resolve, and a file with no `extends` answers `RefCounted`, which is what
  GDScript answers. A chain that cannot be followed all the way to an engine class, text the
  lexer refuses included, still answers nothing rather than guessing. A `.gate` still cannot
  instantiate and still declares no global class name: the `.gd` beside it stays the
  runnable half and stays the holder of the `class_name`.
- **Private functions were missing from the script editor's method list** (issue #11). The
  list is built by scanning for declarations, and the scan trimmed a leading `static ` and
  then looked for `func`, so it saw `func` and `static func` and nothing else. Every other
  spelling GATE allows was absent: `priv func`, which is how a private function is written,
  along with `pub`, `virtual`, `override`, `final`, `abstract`, operator overloads and every
  combination of those with `static`. The scan reads the tokens the editor's validation pass
  has already produced, so it now sees every spelling in any order, an annotation in front
  of the declaration on the same line, and the line number in the `.gate`. It also stopped
  listing a `func` written inside a block string, which the line scan could not tell from a
  declaration.
- **Completion offered every function's parameters everywhere in the file** (issue #11).
  The walk that collects locals had no test of where the caret is: inside `run(d: Damage)`
  it offered `amount` and `label`, the parameters of another function, and typing `label.`
  answered with String's members for a name that is not in scope. A parameter is now
  offered only inside its own function, a local only below its own line and inside the
  block that declares it, a `for` variable only inside the loop, and a local in an inner
  `class` does not leak out of it. Members of the class the caret is in are offered
  everywhere in it, as before. Locals in an `if`, `else`, `match` or `while` block are now
  reached by the same walk, so a declaration in one is in scope inside it.
- **A `for` variable was never offered by name** (issue #11). `for i in 3:` and then
  typing `i` offered no `i`, although the type behind it was already worked out: the loop
  variable was the one declaration the walk did not collect. Loop variables over a range,
  an integer, a string, a typed array, a typed `Dictionary` and `enumerate` are now
  offered, each with the type the iterable gives it, and the innermost one wins where a
  loop shadows an outer name. An iterable whose type GATE cannot establish still offers
  nothing, and `i.` on an integer still offers nothing, because the engine gives `int` no
  members of its own.
- **A type-first constant named its own type as taken.** `const str NAME = "abc"` failed
  with "unknown type 'str'", and so did every other use of `str` in the same file: the scan
  that works out which shorthands a file has declared for itself read the token straight
  after `const`, which in a type-first constant is the type, not the name. Only
  `const str = "x"` and `const str: String = "x"` declare the name now. Nothing else was
  affected, since `class`, `enum`, `struct`, `interface`, `trait` and `namespace` always put
  their name straight after the keyword.
- **`var` with a type before the name reached the output verbatim.** `var int a = 1` at
  class level was passed through as an unrecognised line, with the compile reported as
  successful, and Godot then refused to load the `.gd` GATE had just written. It is a
  compile error now, in a function body as well, naming both spellings GATE does accept
  (`int a = 1`, or GDScript's own `var a: int = 1`). Inside a function it was already an
  error, but reported as a leftover token at the name rather than at the type.
- **A generic parameter's nullability was lost one level down.** `class Box<T>: var v: T`
  and `class Outer<T>: Box<T> inner = Box<T>.new()`, instantiated as `Outer<int?>`, emitted
  `inner` as `__Box_int` instead of `__Box_int_opt`, so `o.inner.v = null` crashed at
  runtime - `T`'s own `?` reached the class `Outer` bound it to, but not a further generic
  `Outer` built out of it. The same fix covers a class-lowered struct argument, `T[]` used
  as another generic's own argument, and any depth of nesting: every nested instantiation
  now sees the same nullability the outer one was given.
- **`o is int?` matched everything, and `o is Node?` matched nothing that was actually
  `null`.** An explicit `?` on an `is`/`as` target used to fall through the same rule that
  collapses a nullable scalar *field* to `Variant`, so `x is int?` compiled to `x is
  Variant` and matched a `String` just as happily as an `int`. An object type took the
  opposite wrong turn: `x is Node?` silently dropped the `?` and compiled to `x is Node`,
  which GDScript's own `is` never treats as "or null" (`null is Node` is `false`). Both
  now test `null` explicitly and the base type otherwise, reading the operand once: `x is
  int?` is true for an `int` or `null`, false for anything else, and `x as int?` casts to
  `int` unless the value is already `null`, in which case `null` comes back rather than an
  unchecked pass-through.
- **An explicit nullable enum field did not load.** `enum E { A, B }` then `var so: E? =
  null` compiled straight through, and Godot refused to load the result: an enum's
  generated type is still a name over an `int`, and Godot rejects a literal `null` stored
  in it the same way it rejects one for a plain `int`. `E?` now emits what an explicit
  nullable scalar already does (`Variant`), the same rule a generic's own nullable `T`
  follows.
- **`PackedInt32Array?` compiled but ignored the `?`.** Every `Packed*Array` type is a
  value type, not an object reference, and Godot refuses a literal `null` stored in one -
  but nothing marked them that way, so a nullable field kept the bare `PackedInt32Array`
  annotation and failed to load the first time it held `null`. They now collapse to
  `Variant` the same way a nullable `int` or `float` field already does.
- **Two different instantiations of one generic that generate two different classes were
  never compared.** `Box<int> b = Box<i32>.new()` and `Box<Node> b = Box<Node?>.new()`
  both compiled clean and only failed once Godot tried to load the result, quoting the
  generated class names (`__Box_i32`, `__Box_int`) rather than the source spelling. GATE
  now catches this itself in a variable or field's initial value, an assignment, a return,
  or a call argument, with a message naming both instantiations.
- **`Box<Box<int>?>` and `Box<Box<int?>>` mangled to the same class name.** A nested
  generic argument's own `?` and its inner argument's `?` both ended up as a trailing
  `_opt` with nothing to say which level it belonged to, so the two meant different things
  but generated the same class name, and GATE refused to compile either alongside the
  other ("two different instantiations of 'Box' both mangle to..."). A nested generic
  argument now marks its own nullability as a prefix instead, so the two stay distinct;
  every other generic argument's mangled name is unchanged.
- **A one-line class body was refused.** `class Inner extends RefCounted: var z = 1`
  is valid Godot GDScript - a class whose whole body is the one statement after the
  colon - but GATE reported "expected the end of the statement" because `var` also
  starts a second statement. `class`, `struct`, `interface`, `trait` and `namespace`
  all take the same header, so all of them compile a one-line body now, the same as
  Godot: `pass`, `func f(): return 1`, `const K = 1`, and so on. One member is the whole
  body: after the colon, a `;`, a `static` or an `@annotation` all end the body rather
  than adding to it, and the declaration then belongs to the nearest ENCLOSING
  multi-line scope - a real indented block, or the file itself - matching Godot's own
  surprising rule, not to `A`. This passes through any number of nested one-line
  headers: `class A: class B: @export var e = 1` puts `e` on whatever encloses `A`, not
  on `A` or `B`. An `@annotation` stays on the moved declaration (`@export` keeps
  exporting it), but a bare leading `static` does not - Godot drops it, so
  `class A: static var s = 3` puts a plain instance var `s` on the enclosing scope, not
  a static one.
- **A generic instantiated with two spellings of the same type produced two classes.**
  `Box<str>` and `Box<String>` mangled to `__Box_str` and `__Box_String`, two different
  generated classes for what is exactly the same type, and code that mixed the spellings
  compiled, but Godot treated the two as incompatible and refused to load the result. A
  type argument is canonicalised before it joins the mangled name now, recursively for a
  nested one (`Box<str[]>`, `Box<Box<str>>`), so every spelling - including through a
  `type` alias - lands on the same class. `f64`/`i32` and the other width-explicit names
  are the one exception, kept apart from `float`/`int` on purpose: a `@packed T[]` field
  picks its storage width from the written name, and canonicalising that away silently
  narrowed `Pool<f64>` to 32 bits.
- **A generic instantiated with a nullable type argument lost the nullability.** `Box<int?>`
  with `var first: T = items[0]` emitted `var first: int = items[0]`, the same as a
  non-nullable `Box<int>`, and reading a `null` through it crashed instead of doing what an
  explicit `int?` field already does (emit `Variant`). A struct or enum type argument had
  the same problem the other way: `Box<Struct?>` still auto-constructed the field's default
  and copied it unguarded on return, so a real `null` crashed there too. Every nullable
  argument now gets its own generated class, and that class's fields, defaults and returns
  match what writing the substituted type explicitly, with its own `?`, already produces.
  `T[]` is unaffected either way, matching what `int?[]` already emits, and `is`/`as`/a
  match type pattern test the substituted type on its own terms, not the nullable-collapsed
  declaration form - `x is T` with `T = int?` still tests `int`, not `Variant`.
- **A `;` after a type-first declaration with no value was refused.** `int x; int y` and
  `struct P: int x; int y` reported "expected the end of the statement" on the declaration
  itself, because GATE did not recognise `;` as ending `int x` the way it already ends
  `var x = 1`. `;` now terminates a type-first declaration everywhere `var` allows it:
  a function body, a class body, the file level, after `T a, b`, after a nullable type
  (`int? x`), after a tuple or union type list (`<int, str> t`), and after a type-first
  `const`. A one-line struct or class body follows the same leak rule as before: `struct
  P: int x; int y` puts `y` on the enclosing scope, not on `P`. `int x y` without a `;`
  is still refused, and so is a value after several names (`T a, b = v`).
- **A doubled `;;` was refused.** `var x = 1;; var y = 2` reported "unexpected token
  ';'", because GATE only ever expected a real statement right after a `;`, not another
  `;`. Godot itself treats a run of semicolons as empty statements and accepts it, in a
  function body, at the file level, inside a class body, in a one-line `if`/`for`/`func`
  body, and as a lone `;` on its own line once the block has already opened with a real
  statement - confirmed directly against a live `GDScript.reload()`. GATE now does the
  same and drops the empty statements from its output; the type-first flavour of a
  declaration (`int x;; int y`) is covered too. A `;` as the very first thing in a block,
  right after a block header's own colon (`func f():;`), or as the very first thing in
  the file, is still refused - Godot refuses all three the same way.
- **A bare reference to another file's enum compiled, and Godot refused to load it.**
  `enum E { A, B, C }` in one file, then plain `E.C` in another with no `const D =
  preload(...)` qualifier at all, compiled clean and failed with "Identifier 'E' not
  declared" - GATE already resolves a bare cross-file class or struct name this way
  (auto-preloading the file that declares it), but never did the same for an enum. A
  bare enum name now resolves the same way, wherever it appears: a type (both the
  plain annotation form and GATE's own type-first spelling, `E lv = E.C`, including
  a nullable local, an array, a dictionary value, a typed `const` and typed
  destructuring), `E.C`, a match pattern, a parameter default, `is`/`as`, and the
  nullable form `E?` (which still collapses to `Variant`, same as a same-file `E?`
  already does). An engine global, a `class_name` or a base-chain member of that
  bare name still wins over the enum, the same way one already wins over a bare
  cross-file class - a project-wide `enum Color` no longer hijacks `Color.RED`, and
  an `extends Node` script keeps reaching the real `ProcessMode`. When two files
  each declare their own top-level enum of the same bare name, there is no qualifier
  at a bare use site to tell them apart, so GATE now refuses it as a compile error
  naming both files, instead of silently picking one and risking a reference to a
  member the wrong one does not have. A cross-file enum with no initialiser - a plain
  field, a local, a one-line class member, or the qualified `D.E` form - now defaults
  to `0` the same way a same-file enum already does, instead of emitting `null` and
  failing to load.
- **An overloaded method called through a class name from another file produced a call
  that does not exist.** The declaring file emits `__compute_1` and `__compute_2` for two
  arities of `compute`, but `DamageMath.compute(3)` in another file kept the plain name,
  so Godot refused the caller with *Static function "compute()" not found in base
  "DamageMath"*. GATE only warned, and the warning said the type of the receiver was
  unknown when the receiver was the class itself. Both the flat case and a class nested
  inside another, `Outer.Inner.pick(3)`, now emit the name the declaring file wrote.
- **Issue #9's line compiled wrong without a word.** In
  `C_MoveIntent[] intents, C_MoveSpeed[] movespeeds = components`, GATE read `C_MoveSpeed`
  as a second variable and the rest of the line as separate statements. With a member named
  `movespeeds` in scope, Godot accepted the result, and it assigned the whole array to that
  member. It is now an error that points at the destructuring form.
- **Annotations and modifiers reached only the first name in `T a, b`.** `@export int a, b`
  exported `a` alone, and `static` and `priv` did the same. They now apply to every name.
- **`int a, b { get }` in an interface required only `a`.** Every name is required now.

## 1.1.1 - 2026-09-18

A compatibility fix. GATE's own type names claimed ordinary words, so a project that
used one of those words as a `class_name` could stop the plugin working, in one case
without saying so.

### Fixed

- **A global class named like one of GATE's internal types broke the plugin.** A project
  declaring `class_name Registry`, as the YARD addon does, made Godot refuse GATE's own
  `project.gd` with *Class "Registry" hides a global script class*, and every script
  depending on it failed after that, so GATE did not merely conflict with your code, it
  stopped running. 55 internal class names were exposed this way, among them `Token`,
  `Module`, `Result`, `Call`, `Member`, `Index`, `Param`, `Literal` and `Lambda`. Every
  one now carries an underscore, `GateLexer._Token` rather than `GateLexer.Token`.
- **The quieter half of the same bug.** `plugin.gd` held its preloads in constants named
  `Integration` and `SourceFollow` and used them as types, and `checker.gd` returned
  named enums `NodeKind` and `Inherits`. A project declaring one of those names made
  `plugin.gd` itself fail to parse, which is worse than it sounds: GATE never loaded, so
  it could report nothing, the one error pointed inside the addon rather than at your
  code, and editing a `.gate` silently left the previously generated `.gd` in place. The
  game kept running the old output. Those names are prefixed too, and the same holds for
  the other preload constants: `Icon`, `Export`, `Level`, `Tabs`, `Warnings`, `Lookup`,
  `Complete`, `Highlighter`, `Autoload`, `Breakpoints`, `Sourcemap` and the rest.
- The test suite now builds a project that declares a global class for every name GATE
  declares, reading them out of the addon rather than from a list, so a type added later
  is covered the day it lands.

Reported by @squidt, with a reproduction that made it a minute's work to confirm, and
fixed the way @penggrin12 proposed in #7. Nothing else changed: the compiler, the
generated output and the editor integration are the same as 1.1.0.

## 1.1.0 - 2026-09-18

The first feature release. Most of it is types: unions, tuples, typed callables,
aliases and typed scenes, plus flow typing that makes `is` narrow and `as` honest. The
rest is swizzling, object initialisers, two annotations and a way back from a
generated `.gd` to the `.gate` line it came from. The editor knows what a `.gate` is
now, too: colours, completion, go-to-definition, breakpoints and warnings.

Eighteen superset violations are gone - valid GDScript that GATE refused or, in one
case, quietly got wrong, since a parenthesised chained ternary lost its parentheses and
with them its value. Structs stopped pretending to be values in some places and
references in others. And a few numbers published with 1.0.0 did not survive a second
look; they are corrected below rather than left standing.

### Added

**Union types.** `<int | str> id = 7`. Emitted as a `Variant` variable; the checks
happen at compile time. A value going in must match one member; a value that widens to
exactly one member - `int` to `float`, `String` to `StringName` or `NodePath` - is
converted, so `<float | str> u = 1` holds a float. A union going out, into a narrower
union, a plain type, a parameter or a return, must fit with every member. An operator, a
member or a method is only allowed if it works the same way for every member; otherwise
narrow first. `<int | str>?` is the nullable form.

**Typed tuples.** `<int, str> entry = [7, "hp"]`. The value is a plain array, so it is
also valid GDScript, but GATE checks its length and each element, types a read or write at
a constant index per element, and rejects anything that would change its length or order.
`var [id, name] = entry` destructures with the element types.

**Typed callables.** `func(int) -> bool keep = func(x): return x > 0`. Assigned lambdas
and methods must match the signature, and `.call(...)` is checked for arity and types.

**Type aliases.** `type Hp = int`. Pure substitution, nothing is emitted. Visible in every
file, but a class, enum, constant, variable, parameter or `class_name` of the same name
always wins where it is visible. An alias that clashes with a global `class_name`, an
autoload or a name its own file declares is an error; one that another file's class hides
everywhere gets a warning.

**Typed scenes.** `PackedScene<Enemy> scene = preload("res://enemy.tscn")` makes
`scene.instantiate()` an `Enemy`. `T` must be a Node type. `x is PackedScene<T>` is an
error, since a scene's root type is only known once it is instantiated.

**Signal checks.** `signal hit(amount: int)` was already GDScript; GATE now warns when
`hit.emit("x")` or `emit_signal("hit", ...)` passes the wrong types or count, and when
`hit.connect(f)` gets a function of the wrong arity. Warnings, never errors: Godot accepts
those calls, so rejecting them would reject valid GDScript. On the test corpus they flag six
real mistakes in published projects and nothing else.

**`match` type patterns.** `Circle c:` binds `c` as a `Circle`, and composes with `when`:
`Rect r when r.w == r.h:`. A bare `Node2D:` pattern keeps its GDScript meaning.

**`is` narrows.** After `if x is Enemy:`, or an early exit that proves it, `x` is an `Enemy`
for everything GATE decides by type: checks, overloads, struct copies, swizzles. Locals,
parameters and typed instance fields narrow. An untyped field, a static var or an autoload
can be rebound by a call GATE cannot see into, so a check on one does not narrow it, and
no check carries past a setter, a getter or a lambda that may rebind what it tested. A
failed test narrows a union to its other members. `x is int[]` is true for an `Array[int]`
and for a `PackedInt32Array`.

**Swizzling.** `v.xy`, `v3.xz`, and writes such as `v.xy = w`, on statically typed vectors:
typed locals and fields, engine properties like `position`, constants, vector arithmetic.
An untyped `v.xy` is left alone, because it may be a property of your own.

**Object initialisers.** `scene.instantiate({ position: spawn, hp: 40 })`,
`Label.new({ text: "hi" })`, `Damage({ amount: 1, source: "fire" })`. The object is
constructed, then each property is assigned, in order, and each value is checked as that
assignment would be. A class whose `_init` takes a parameter keeps GDScript's meaning - the
dictionary is passed as the argument - and GATE warns there, because adding a parameter to
`_init` would otherwise silently flip every call site from "set properties" to "pass the
dictionary". A bare key is then a variable, so one that names nothing is an error.

**`@required`** on an exported Node property asserts it was set, at the top of `_ready`
(merged into your own `_ready` if you have one). Debug builds only, and not in the editor.

**`@export_if(condition)`** hides a property in the inspector until the condition holds,
through a generated `_validate_property`. It needs `@tool`, and GATE will not add `@tool`
for you: that changes when your script runs, so it is a compile error instead.

**From a generated `.gd` back to the `.gate`.** When the editor shows a generated file - a
runtime error, a stack frame - a toast names the `.gate` line it came from, read from the
`.gd.map` beside it. It only listens: nothing is added to your game, and nothing opens on
its own.

**A warning when an array is stored 32-bit.** `@packed int[]`, the inner arrays of
`int[][]` and `@soa` fields narrow to `PackedInt32Array` / `PackedFloat32Array`. GATE now
says so, once per file, as the docs always claimed it did.

**`.gate` is a language Godot knows about.** Until now the editor did not track the
extension at all, so a `.gate` file was invisible in the FileSystem dock and there was no
way to make one from the UI. GATE now registers a script language, a resource loader and
saver, and a syntax highlighter:

- `.gate` files show in the dock with their own icon, drawn from an SVG at the editor's
  own scale so it stays sharp at any display scale.
- They open in the real script editor, coloured for GATE's syntax - type-first
  declarations, `T?`, `T[]`, unions, tuples, f-strings, `struct`, `interface`,
  `namespace`, `pub`/`priv`, the annotations. Every type name in the table above
  colours, short or canonical, alone or as `T[]`; so does the name a `struct`,
  `interface`, `trait`, `namespace`, `type` or `class` declares, and a generic's
  parameter wherever it is used in the class that declares it. A name beginning with
  `_` is drawn dimmed, which Godot does not do for a `.gd`. Every colour is read from
  *Text Editor -> Theme -> Highlighting* and follows it when it changes.
- Errors decidable from one file - an unterminated string, inconsistent indentation -
  underline as you type, and a quote left open is reported on the line it opened on
  rather than where the file stops making sense, which can be a thousand lines lower.
  Anything needing the rest of the project is left to the build, which reports to the
  Output panel as before.
- Godot's own warnings, reported against the `.gate`: unused variable, unused local
  constant, unused parameter, unused signal, and a local, parameter or `for` variable
  shadowing a member of this class or of a base - another `.gate`, a hand-written
  `.gd`, or an engine class. They are worded the way `GDScriptWarning` words them and
  arrive in the same warnings panel, because otherwise the only way to see a warning
  about your own code was to open the generated `.gd`. `@warning_ignore`,
  `@warning_ignore_start`/`_restore` and the switches under
  *Project Settings -> Debug -> GDScript* are read first, so a warning the project
  turned off is not reported here either. This walks the file's tokens rather than
  parsing it: parsing a thousand real lines costs twice the budget `_validate` has,
  and a shape the walk cannot place with certainty is passed over rather than
  guessed at. Warnings that need the whole project, and the ones about types, are
  still the build's.
- Ctrl-click and F1 go to the declaration, across files: structs, classes,
  interfaces, traits, namespaces, generics and aliases wherever they are declared,
  `class_name`s in another `.gate` or in a hand-written `.gd`, members of any of
  those including inherited ones, and locals, parameters and fields in the current
  file. It goes through autoloads, a script autoload to its script and a scene
  autoload to its root node's script or engine class, so `Global.current_project.frames`
  reaches the field, and it follows a base written as a path, `extends "res://base.gd"`.
  An engine class opens its documentation. A word GATE cannot place is not
  underlined, rather than underlined and then leading somewhere wrong. It does not
  follow a member through a value whose type GATE cannot see, and it does not know
  the members of engine classes. A `class_name` declared in a `.gate` lands on the
  `.gate`: Godot opens the file a global class is registered against, which is the
  generated `.gd`, so GATE opens the source over it and closes the `.gd` tab its own
  click opened.
- Breakpoints set in a `.gate` stop the running game, and the stop is shown in the
  `.gate` with its line marked as executing. Godot's debugger only knows the
  generated `.gd`, so GATE translates each breakpoint through the `.gd.map` on its
  way to the game and translates the stop back on its way to the screen. Stepping
  follows. A breakpoint on a line that compiles to nothing is refused with a toast
  saying why, rather than left looking armed. Two things stay as they were: the
  Stack Frames and Debugger panels name the `.gd`, and a stop on a generated line
  with no `.gate` line behind it is left showing the `.gd` on purpose.
- Autocompletion, built from GATE's own registry, the parsed file and ClassDB.
  GDScript's cannot be borrowed: nothing on `ScriptLanguage` is exposed to scripts,
  so there is no way to hand it the compiled `.gd` and ask. After a dot it offers
  the members of the type on the left and everything that type inherits, through
  `.gate` bases, a hand-written `.gd` and into the engine; `?.` is the same.
  Unqualified, it offers locals, parameters, the file's own members and its
  inherited ones, every type in the project, the type shorthands, the keywords and
  the engine's classes. After `@`, the annotations. Autoloads are known, and so are
  bases written as a path. `String`, `Array`, `Vector2` and the other built-in types
  offer their members from a table generated from Godot 4.7.2's API. What a typed
  container holds carries through an index, the `Array` and `Dictionary` methods that
  return an element, and a `for` loop's variable, `enumerate` and two-variable loops
  included. A `:=` declaration or a constant takes its type from its initialiser; a
  plain `=` stays unknown. On another object, methods whose names start with an
  underscore are left out, since they exist to be overridden. Where the type on the
  left cannot be worked out it offers nothing rather than a list about something else.
  It follows names, calls and indexes, not arbitrary expressions, and it does not know
  the members of an untyped value.
- Open `.gate` tabs are kept out of Godot's own saved layout and reopened by GATE, so a
  session with GATE switched off has none to open as plain text and rewrite on exit.
  Switching GATE off from the Plugins tab closes them, saving any unsaved edit first.
- Saving a `.gate` that uses CRLF line endings writes it back with CRLF.
- *Script -> New Script* and the dock's *Create -> New GATE Script...* both offer GATE.
- *Project -> Tools -> Recompile all GATE files* forces a full rebuild.
- GATE stays out of the exported game: `.gate`, `.gate.uid`, `.gd.map`, the compiler
  and the editor integration are left out of the PCK. Four inert scripts from
  `addons/gate/editor/` ship so the game starts without errors: Godot's class list
  names the loader and saver, and a game that cannot find them prints six.

**A build does what an edit changed, and an unchanged project builds nothing.** What proves
a file up to date is kept in `.godot/gate/`, so opening a project with no changes compiles
nothing; deleting the folder costs one full build. A file is rebuilt when something it reads
from another file changes: declarations, struct field defaults, signal parameter types, or
what a function may set to null. A comment, or a body edit that changes none of those,
rebuilds only its own file. A hand-written `.gd` counts only for the `.gate` files that reach
it, and only through its declarations. Of `project.godot`, only the autoloads and the
`debug/gdscript` settings count, so switching a plugin on or off builds nothing. On
Pixelorama, measured, a comment or body edit saved in the editor builds in about 2 s.

**Attach Script offers GATE and then refuses**, with the reason on screen. A node's script
has to be the compiled `.gd`; a `.gate` cannot instantiate and has no methods, so attaching
one would have been a node that looks right and does nothing.

### Changed

**`as` is no longer trusted in GATE's own declarations.** `Foo f = x as Foo` inside a
function is an error unless an `if x is Foo:` guard or an early exit has proved it, or you
declare it `Foo?`. `as` yields null when the cast fails, and 1.0 took it at face value - the
one knowingly unsound spot in the null analysis. `x as SomeInterface` now yields null too
when `x` does not implement it. Plain GDScript uses of `as`, and field initialisers where
nothing can guard it, keep the old behaviour.

**Aliasing is no longer invisible to the null analysis.** A write to `d.next` invalidates
what GATE knew about `next` on every other reference that may be the same object: the same
or a related class, or an unknown type. Structs are copied at every binding and never alias.

**An untyped local's type follows what is assigned to it.** `var w = Sword.new()` then
`w = Bow.new()` no longer checks calls on `w` against `Sword`.

**Expressions GATE has to split up still run once and in order.** `??`, `?.`, `?[` and the
new forms sometimes need part of an expression hoisted into a temporary. Anything to its
left that could run code is hoisted first, so `[f(), a.b ?? 1]` still calls `f()` before it
reads `a.b`, and the right side of `??` still only runs when the left is null. A default
parameter that needs a statement becomes a small generated function its parameter calls,
so it still runs once, in order, and only when the argument is left out. A `when` guard and
a field initialiser read a value once through a lambda; only a `const` and an annotation
argument, where no lambda can go either, keep the expression whole.

**Struct defaults run once, and only for fields you leave out.** A default may read the
fields before it: `struct S: int a; int b = a * 2` makes `S(5).b` 10. An object-typed field
with no default must be given, or declared `T?`.

**Structs are copied where they are received.** A struct parameter copies on entry, so a
function reached through a signal, `map` or `bind` gets its own copy, and a lambda copies
the structs it captures when it is created. In a file that uses class-lowered structs, a
value whose type GATE cannot see is copied at run time if it turns out to be one.

**Struct `==` compares fields.** It compared identity for structs lowered to a class, so
two equal values were not equal. `!=` negates your own `operator ==` when you define no
`operator !=`. Because a dictionary finds object keys by identity, a class-lowered struct as
a dictionary key is now an error.

**New compile errors for things that could not work.** A getter or setter on a struct field.
Writing `p.x` or capturing `p` inside `for p in` an `@soa` array, where `p` is a value but
the write went into the array. `@export` of a struct lowered to a class. A declared type
given a value of a known type Godot would refuse, such as `int hp = "full"`, which compiled
and then did not load.

**Generics are checked for each instantiation.** A body was checked once, with `T`
unknown, so `x is T` with `T` a union or a Vector-lowered struct slipped through. The error
is reported where the instantiation is written.

**More compile errors, each in place of output that was silently wrong or would not load.**
Two statements on one line: `out += "x" "y"` kept the first and threw the rest away, and
because the file is a `.gate`, Godot's own complaint never reached anyone. A type nesting
arrays three or more levels deep, which cannot be written in GDScript at all. A struct,
interface, trait, generic or namespace declared at the top level of two files, once a third
file names it, since the project index is flat and GATE cannot tell which one is meant. A
`priv` name whose emitted `_name` is already taken by a member of the class, one it inherits,
or one of the engine class's own. An indented line in a class body that opens nothing. Text
after a `\` outside a string, in Godot's own wording. And an `@soa` array reached through an
instance, which is not one value.

**An expression nests at most 180 levels**, counting one for every operator, call and member,
so a flat chain of 180 terms or 90 steps of `a()[0]`. Parentheses keep their own cap of 48.
Every pass after the parser walks the tree once per level and GDScript stops at 1024 calls, so
past that the passes ran out of stack, printed a backtrace for each call and handed back
answers that were quietly cut short: 1,600 terms took 23 seconds to compile. The depth is now
measured with a stack of its own, straight after parsing, and a file that nests deeper is
refused with one error naming where the expression starts. Nothing walks the tree after that,
and the same 1,600 terms are refused in 58 ms. This is a place where valid GDScript is
refused.

**Generated files are indented the way the project is written.** GATE always wrote one tab a
level, so a project written with four spaces got output that did not match the rest of its
code. In the editor, the indent type and size from *Editor Settings -> Text Editor -> Behavior
-> Indent* decide, read and never written. With no editor - a headless build - the `.gate`
file's own first indented line decides, so a renamed `.gd` keeps the look it had. A tab is the
last resort. The unit is part of each file's build key, so changing the setting rewrites the
outputs rather than leaving stale ones. Lines are replaced one for one and never inside a
multi-line string, so no sourcemap entry moves and space-indented output is still its own
fixed point.

**`?.` and `?[` give a value that may be null.** The result was typed as the member's own
type, so `str n = a?.name` on a null `a` compiled and failed at run time. It is now nullable
whenever its base may be null, and keeps the member's own nullability when the base is known
not to be. `??` is null only when its right side may be, and each arm of a conditional is read
under the narrowing its condition gives, so `(a ?? b).name` is checked instead of waved
through. A `for` loop cannot iterate null, so an iterable that may be null is an error. In a
`match`, only an unguarded `null` arm makes the arms after it non-null. A base GATE cannot
type gives what it always gave, so untyped code picks up no nullability it did not ask for,
and both corpus sweeps are unchanged.

**Effect summaries reach static fields and overrides.** A summary now records the static
fields a function writes, and a call kills that field under every spelling the caller uses:
the class name, `self`, or bare inside a static function. `Class.f()` static calls resolve. A
summary also covers every override of the method in a class the build can see, so `b.touch()`
on a base type no longer misses what a subclass's `touch` does. A `virtual` or `abstract`
method with no body only ever runs as an override, possibly one outside the build, so calling
it is treated as a call nobody can see into: the receiver and the arguments lose their
narrowing.

### Removed

**The `Foo { a = 1 }` initialiser.** It was undocumented, and there is now one way to do
this: `Foo.new({ a: 1 })`. Using the old form is an error that points at the new one.

### Fixed

- **Six superset violations on real Godot 4 code**, each confirmed to load as plain
  GDScript and fail through GATE:
 - `enum Name` with its `{` on the next line
 - `% "name"`, a unique-node path with a space after the `%`
 - a class method named like a global function at a different arity, such as `is_same(x)`:
    Godot calls the built-in `is_same(a, b)`, GATE reported an arity error
 - `else: if (…):`, an inline `if` after `else:`
 - an annotation on the last line of a block, such as `@warning_ignore_restore(...)`
    closing a function or a class. In a function it was dropped; in a class the rest of the
    file became part of the class
 - a class, enum or constant named like a GATE shorthand - `class vec2`, `enum color` - was
    rewritten to the built-in type
- **Three expressions lost their parentheses**, one of them a wrong value in 1.0.x:
 - a parenthesised chained ternary: `("dead" if hp <= 0 else "hurt" if hp < 100 else "ok")
    + "!"` returned `"dead"`, and `10 * (3 if a else 1 if b else 2)` returned 2
 - `(x is not T)` and `(x not in xs)` used as an operand
 - an `as` chain before `.` or `[`, which did not load
- **Seven more superset violations**, most of them across files:
 - two files along an inheritance chain declared the same dependency constant, so the
    child did not load
 - another file's class leaked into lambda parameters, `match` bindings, locals inside a
    lambda and annotated statements, so a local named like it read the other file's class
 - a class named like an engine enum or global function, such as `class Error`, took that
    name over in every file
 - a function inherited from a base script and named like a shorthand, such as
    `color(1, 0, 0)`, was rewritten to the built-in constructor
 - two files declaring the same inner class gave a false error in a third that only had a
    local of that name
 - `when` and `abstract` were rejected as names
 - a struct or namespace named like an addon's `class_name` or an autoload took it over
- **Two more superset violations**, both valid GDScript refused outright:
 - `when`, `abstract` and `match` before a `%`. The lexer decides whether `%` is modulo or a
    unique-node path by what came before it, and it counted every contextual keyword as a
    keyword, so `arr[when % arr.size()]` was read as a node path. A soft keyword is now a name
    everywhere except where it heads its own construct: `match` only at the start of a line,
    `when` only after a pattern, `abstract` never before an operand. `match %Label:` and
    `1 when %Label.visible:` keep their node paths
 - a file holding U+FFFD, the replacement character, in a comment, a string or a StringName.
    A guard meant to refuse binary files matched it, because `String.chr(0)` is U+FFFD in
    Godot 4.7.2, and building the test string printed a Unicode parsing error on every
    compile. The guard could not have worked where it stood: Godot's text readers stop at a
    NUL and replace bytes that are not UTF-8 long before the compiler sees the text. The bytes
    are checked where they are read instead, on every path that reads another file's `.gate`
- **A cross-file `override` of an overloaded method never ran.** A `class_name` script that
  overrides a method its `class_name` base overloads, both at the top of their files, kept its
  plain name while the base and every call site used the mangled one, so the base ran. Both
  ends are linked now, and the base's mangled name is worked out when that file was not
  compiled in the same pass.
- **A declaration inside a block GATE does not model lost its indentation.** Under a header
  GATE does not read, such as a Godot 3 `remote func`, most lines passed through verbatim but
  a `var` line was taken for a class field and re-emitted at column 0, which did not load.
  Such a block is now kept whole, as the source text it was. `master`, `puppet`, `sync`,
  `setget` and `onready` are each pinned with a declaration inside.
- **An f-string placeholder is read as an expression.** `f"{ n }"`, with a space, failed.
  Braces inside a string the placeholder holds are text, a quote of the f-string's own kind is
  escaped there as anywhere else in a string, and a placeholder that is empty or never closed
  says so instead of "unexpected token ''".
- **`Combat.Pool<int>.new()`** said "unexpected token '.'". It now says a generic is
  instantiated by its own name, and what to write.
- **An escaped delimiter inside a `"""` block ended it.** The pass that records which
  lines sit inside a string honoured `\` only in single-quoted strings, so after
  `"""a\"""b"""` it took the lines below as string until the next delimiter run. The
  indenter reads that map, so on a project indented with spaces those lines kept their
  tabs and Godot refused the generated file outright: *Used tab character for
  indentation instead of space as used before in the file.* The lexer always read the
  escape, so this was the rest of the compiler disagreeing with it.
- **Null analysis flow.** A `break` in a nested loop landed in the enclosing loop's exit
  state, which turned a value always overwritten before that loop ended back into a maybe. An
  `elif` or `while` condition's call effects were applied and then thrown away, and so were
  those of the right side of `and`/`or` and of either arm of a conditional, so
  `x != null and drop()` still trusted `x`. A `for` loop variable, and a `match` binding, named
  like a field left that field untracked for the rest of the function; each now gives the name
  back when its scope ends. A write to a static field through one spelling left the others as
  they were.
- **A long operator chain compiles in linear time.** Three passes re-walked a chain's
  left side at every term, so a flat `1 + 1 + ...` or `a and a and ...` cost time quadratic in
  its length. A 1,000-term `and` chain went from 2.1 s to 81 ms, and the output of every corpus
  file is byte-identical.
- **Evaluation order.** Godot runs a call's arguments before its receiver, and an
  assignment's target before its value; where GATE splits an expression up, it now keeps
  both. An overloaded operator runs its left operand first. `??` in a field initialiser
  keeps its order and no longer emits an `if` at class level. GATE syntax inside `get:` and
  `set:` bodies is compiled. A multi-line lambda inside a rewritten expression keeps its
  indentation.
- **Struct value semantics.** A default ran twice per construction and again on every copy.
  Copying a struct shared the structs, arrays and dictionaries it held. Structs were not
  copied through loop variables, `enumerate`, destructuring, `??` or `as`. Copying a null
  struct crashed. A struct with a constant did not load. Vector structs ignored their
  defaults. Changing part of an
  `@observable` struct fired nothing. Another file's `struct Point` captured a call to your own
  function `Point(...)`.
- **`h.st?.bump()` on a struct field** called the method on a copy, so the change was lost, and
  crashed when the field was null. `h?.b = 5` and `h.inner?.n += 1` wrote into a temporary.
- **Nested generics.** `Pool<Box<int>> p` reported success and emitted a line that did not
  load. `x is Box<float>` named a class that was never generated.
- **`h.prop ?? 5` ran the getter twice** when the value was not null.
- **`x is int[]` never matched a packed array**, and did not load where `x` was statically one.
- **An `is` test against an interface inside an inner class** did not load, and on a value
  that is not an object it crashed instead of returning false.
- **`priv @export var x`** was passed through unchanged and did not load.
- **Building a project.** An output whose base class in another file changed its
  annotations was left stale. The `.gd.map` was not rewritten when only comments changed.
  Editing a trait did not rebuild the files using it. Two plain files each declaring an inner
  `class Helper` got a false error. Renaming a `.gate` left the old `.gd` behind; it now goes
  to the Recycle Bin, and only while it is byte for byte what GATE wrote, so a `.gd` you took
  over by deleting its header is never touched. A `class_name` used by type in the same build
  was an "unknown type" on the first build. On Windows, renaming `Foo.gate` to `foo.gate`
  locked its output forever, and a `.GATE` extension compiled once and was then refused.
  `.gate` files skipped under a nested `addons/` folder are now reported, and a subfolder
  with its own `project.godot` is left to that project. GodSVG, converted wholesale, now
  builds with no failed file on every editor session.
- **A `class_name` registered part-way through a session settles the files that read it.**
  With an inner `class Foo` in one file and `class_name Foo` in another, the first build wrote
  a third file's `Foo.new()` against the inner class, because `Foo` was not registered yet, and
  nothing in that editor session rebuilt it: the build key ignored Godot's class list and the
  checker kept its answer for the life of the process. Only a restart fixed it. The build key
  now includes the global class names a project declaration also has, the checker forgets which
  names are global whenever the class list or the autoloads change, and a failure is passed on
  only to the outputs that still load the file that failed.
- **A validation probe no longer reaches disk.** The probe GATE compiles a file against lives
  in memory, but it was given a `resource_path` beside the output so the output's relative
  `preload()`s resolve, and a script whose source has been set is an edited resource: saving a
  scene saved every one of those. One Ctrl+S on a two-file project wrote six
  `__gate_probe_*.gd` files and their `.uid` sidecars into the project, which the next scan
  listed in the FileSystem dock and registered as global classes. The path is needed only while
  the reload runs and is cleared straight after, so nothing is left in the cache to save. The
  sweep that cleans them up knows all three names GATE has ever used, takes their `.uid` files
  too, runs after every build as well as at start-up, and reads the generated header first, so
  a file of your own wearing the name is left alone.
- **Two inner classes in different files that name each other** were set aside as
  `.rejected` on every edit after the first build. Their outputs preload each other, and the
  check ran on a copy under another path, so Godot saw two scripts for one class and refused
  a correct output. An output whose preloads lead back to itself is checked in place.
- **A `class_name` declared in a plain `.gd` was an unknown type** in a headless build and
  before Godot's first scan, because only Godot's class list knew it. GATE now reads the
  project's `.gd` files for their `class_name` itself.
- **A file mixing tab and space indentation is refused in Godot's own words.** GATE reported
  "unexpected token" where the widths stopped lining up, or nothing at all where four spaces
  lined up with a tab. The first indented line of code now decides, as in Godot, and a later
  line using the other character, or both, is Godot's error.
- **Each build warning is printed once per editor session.** The editor builds several
  times while it comes up, and every build repeated "could not be verified yet" for every
  file still waiting on Godot's class list: 570 lines on Pixelorama's first open after
  converting. Each is now said once. Godot's own parse errors on that first open are unchanged, because it loads
  the scripts open scenes use before GATE has written them; the second session is quiet.

### Corrected

- 1.0.0 said 7,567 real `.gd` files were recompiled clean. That count included copies of
  GATE's own compiler sitting in the corpus projects; the real figure is **3,291**.
- 1.0.0 said all 23 compile errors in the corpus were Godot 3 syntax. Twelve were; the other
  eleven were GATE bugs, fixed above.
- The docs said `int[]` lowers to `PackedInt32Array`. It lowers to `Array[int]`. Packing is
  opt-in with `@packed`, and automatic only for the inner arrays of nested collections.

### Verification

A 24-stage suite, including one that builds real editor projects across restarts and one
that drives live editor sessions to check the editor integration from the outside. Beyond
GATE's own tests: **196 real project roots** swept from their own directories, every file
Godot loads there - **1,552 files, 176,219 lines** - with zero compile errors, zero outputs
that fail to load and zero fixed-point breaks; the **3,291** real `.gd` files compiled,
except seventeen in Godot 3 syntax or with mixed tab and space indentation, all of which
Godot 4 rejects too, and recompiled from their own
output with zero load failures and zero fixed-point breaks; and GodSVG's 191 files built
through the plugin with none failed.

The four feature areas were built in parallel and then attacked together by three
adversarial reviewers, one per seam where they meet: types against flow analysis, values
against hoisting, and the build pipeline across files. The release candidate was then
attacked twice more, once by five reviewers taking the superset guarantee, struct values,
types, evaluation order and the build pipeline, and once by three reading the whole
compiler. Every round found real defects while every stage was green, which is the reason
the suite keeps growing. Each finding is fixed and pinned by a test, or recorded as
deliberate behaviour.

### Known limitations

Comments are dropped, including `##` doc comments. `as` is trusted in plain GDScript and in
field initialisers. Three aliasing gaps remain in the null analysis: calls GATE cannot see
into, what they return, and writes through a container that holds a parameter. A struct
that reaches a plain file through an untyped value is not copied there.

The null analysis tracks only the static fields the file itself declares. One declared in
another file is not tracked at all, a path below one reached through the class name falls back
to the coarse aliasing rule, and a static function of a subclass does not track a static field
it inherits.

An expression nests at most 180 levels and parentheses at most 48. Both refuse valid GDScript
that Godot's own parser takes. Reaching the parenthesis cap is itself expensive, about twenty
calls a level, so `not (not (...))` past 46 levels exhausts GDScript's stack before
the cap can report it, and what GATE writes for such a file does not recompile to itself. Deep
member chains cost time quadratic in their depth, well past any depth real code reaches.

Godot's debugger panels still name the generated `.gd`, since that is what the game runs.
Completion offers nothing where GATE cannot see a type, and editing a declaration in a very
long file reparses it. Its first request in a session can take several seconds if GATE has
not finished reading the project in the background. Saving a `.gate` re-indents it to your
editor's setting, as Godot does for a `.gd`.

Changing a declaration in a file most of the project reaches rebuilds every file that
reaches it: about 35 s on Pixelorama, measured, where almost everything goes through one
autoload.

The first two opens of a large project after converting it are slow while GATE builds and
Godot registers the new classes: about 130 s and then 50 s for Pixelorama's 211 files,
measured, and about 10 s for an unchanged open after that.

The full list, with reasoning, is in `README.md`.

The honest gap is still there: nobody has yet shipped a game written in GATE.

## 1.0.1 - 2026-09-10

Fixes one parser bug. No syntax changes, no behaviour changes anywhere else.

### Fixed

A type-first declaration with **no initialiser and a trailing comment** was not
recognised as a declaration and was copied into the output verbatim, comment and
all - and `Node2D? target  # who we chase` is not GDScript, so the generated file
would not load.

```gdscript
vec2i[] tiles           # Array[Vector2i]      <- was emitted as-is
Node2D? target          # nullable, and tracked
priv float speed        # no initialiser
```

Comments are tokens, and the check that decides whether a line is a type-first
declaration required the token after the name to be a newline, `=`, `:` or `,`. A
trailing comment sits exactly where the newline would be. Declarations *with* an
initialiser were unaffected, because the check matched on `=` before it ever
reached the comment, and the `{K, V} name` form was unaffected because it returns
before looking that far.

Every form is pinned in the regression suite, including the two that already
worked, so a future fix cannot trade one for the other.

## 1.0.0 - 2026-09-09

First release. GATE is a GDScript superset that compiles to plain GDScript: valid
GDScript renamed to `.gate` must compile with zero errors, load, behave identically,
and be a byte-identical fixed point on recompile. Everything below is in service of
that promise.

Requires **Godot 4.7**. MIT licensed.

### What is in it

Types and nullability (`T?`, `?.`, `?[`, `??`) with a flow-sensitive null analysis
carrying interprocedural effect summaries; typed collections with Packed lowering;
`struct` with value semantics, lowered to a Vector where it fits and a class
otherwise; `interface`, `trait`, `namespace`; generics, monomorphised once in their
declaring file so `is Box<int>` holds across files; operator overloading; arity-based
overloads; `@observable`; `@soa`; f-strings, destructuring, `enumerate`; cross-file
declarations linked through injected `preload` consts; a sourcemap next to every
generated file; and an editor plugin that builds the project on save.

### Verification

A 20-stage suite, every stage able to fail (kept in development, not shipped here).
Beyond GATE's own tests it
is checked against **186 real Godot project roots** swept from their own directories -
the official demo, tutorial and benchmark repos plus ten shipped applications and games
- **1,093 files, 100,574 lines, zero compile errors, zero outputs that fail to load,
zero fixed-point breaks** - and, separately, every `.gd` in both corpora (**7,567 files**,
`addons/` included) compiled and recompiled from its own output with **zero fixed-point
breaks**. Two real projects, beehave and GodSVG, were also converted wholesale to GATE
and built through the plugin, with **zero files where only GATE's output fails to
load**.

The suite exists because six rounds of adversarial review each found defects while
every stage was green: roughly 60, 40, 26, 50, 65 and 8. The last two rounds are why the
final three stages exist at all - nothing recompiled a `.gate` source from its *own*
output (the superset stage skips anything carrying the generated banner), nothing
compared output byte for byte, and nothing noticed when the parser gave up on a member
and passed it through as raw text, which silently dropped a whole file out of every
analysis pass while leaving it loadable.

Two lessons are recorded at the top of `README.md` and neither is about an individual
bug: *a green stage is evidence the corpus does not contain the bug, not that the
compiler does not - and a test that pins the right input with the wrong assertion will
keep passing forever.* And: *harden a walker and you must harden its twin* - three of
the last round's defects were one walker fixed and its counterpart left alone, which no
test can see, because both are exercised by the same inputs and only one is wrong.

### Performance

Measured through `godot-benchmarks`' own harness on Godot 4.7.2, against a run-to-run
noise floor of 1.6% median:

* **GATE's output is performance-neutral against hand-written GDScript.** Across 110
  benchmarks the median ratio is 0.98; every difference outside the ported cases is
  inside the noise floor.
* **Escape analysis and scalar replacement** (new in this release):
  a struct local that provably never escapes becomes one plain local per field, with
  no allocation and no `_gate_copy()`. Measured **13.5×** against the class form GATE
  used to emit (27.5 ms vs 372.5 ms, 300k iterations, identical results).
* **Struct lowering** is 9.9× faster than the idiomatic `Array[SomeClass]` end to end.
* **`@soa` was re-measured twice, and both earlier claims were wrong** - first "1.9×
  faster", then "1.27× slower". Both measurements were real; both descriptions folded
  construction and iteration together, and those point in opposite directions. Timed
  apart: `@soa` is **~2.4× slower to build and 1.9× faster to iterate**, so it pays for
  itself after about 1.3 passes per rebuild. Build once and iterate every frame - a
  particle system, a simulation - and it is worth 1.9× per frame; rebuild every frame
  and walk it once and it is not. `godot-benchmarks`' `nbody` ported to `@soa Body[]`
  measured **1.93×**, which is the same number on a real workload. The README carries
  the table and the command that reproduces it.

### Not in this release

**Local type inference.** Emitting `var x := expr` for a bare `var x = expr` was built,
measured (1.24×–1.66× per converted local) and withdrawn. Typing a local changes how
GDScript checks every *use* of it, not just its assignments, and `0 < hp < 100` is one
member of an unbounded family that stops compiling once `hp` is concrete. Coverage on
real code was 2.2% of untyped locals, because 94% of untyped initialisers call engine
APIs whose return types GATE cannot see. Not worth the risk to the superset promise.
`README.md` carries the full reasoning.

### Known limitations

Comments are dropped, including `##` doc comments. `as` is trusted by the null
analysis and aliasing is invisible to it - both documented and deliberate. Expression
nesting is capped at 48 levels. The full list, with reasoning, is in `README.md`.

The honest gap: nobody has yet shipped a game written in GATE.

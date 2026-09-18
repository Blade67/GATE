# Changelog

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

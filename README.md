# GATE

GATE is a [GDScript](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html)
superset for the [Godot Engine](https://godotengine.org/) that adds [extra features](#features)
while compiling down to plain GDScript.

###### Requires Godot 4.7. MIT licensed.

Valid GDScript is valid GATE. Rename a `.gd` to `.gate` and it compiles with no errors,
loads, and behaves identically. Recompiling GATE's own output gives back the same bytes.

## Table of Contents
- [Install](#install)
- [Usage](#usage)
- [Features](#features)
   * [Type-first declarations](#type-first-declarations)
   * [Null safety](#null-safety)
   * [Structs](#structs)
   * [Interfaces, traits and namespaces](#interfaces-traits-and-namespaces)
   * [Generics](#generics)
   * [Unions, tuples and typed callables](#unions-tuples-and-typed-callables)
   * [Type aliases and typed scenes](#type-aliases-and-typed-scenes)
   * [Narrowing and match patterns](#narrowing-and-match-patterns)
   * [Swizzling and object initialisers](#swizzling-and-object-initialisers)
   * [Editor annotations](#editor-annotations)
   * [Expressions](#expressions)
- [In the editor](#in-the-editor)
- [Performance](#performance)
- [Known limitations](#known-limitations)
- [Verification](#verification)
- [Documentation](#documentation)
- [Roadmap](ROADMAP.md)

The full syntax is in [SYNTAX.md](SYNTAX.md).

## Install

Copy `addons/gate/` into your project, then enable **GATE** under
*Project Settings -> Plugins*. The plugin watches the filesystem and compiles every `.gate`
file to a `.gd` beside it whenever anything changes.

### Converting an existing script

Rename `foo.gd` to `foo.gate` and leave `foo.gd.uid` where it is. Godot references scripts
by uid, so deleting it makes every `ext_resource` fall back to a text path with a warning.
GATE regenerates `foo.gd` and never touches the uid.

The first time you open a project after renaming its scripts, expect a burst of errors
in the Output panel. Godot loads the scripts your open scenes use before GATE has written
their `.gd` files, so each of those fails to parse once, and GATE says once for every file
it could not check yet: about 1,600 lines for Pixelorama, 200 for GodSVG. Nothing is
wrong. Close the editor and open it again; the second session is quiet.

On a large project the first two opens are also slow, while GATE builds every file and
Godot registers the classes it wrote. Pixelorama, 211 files, took about 130 s the first
time and about 50 s the second, measured; after that, opening it unchanged takes about 10 s.

Leave `script_templates/` alone. Godot keeps a `.gdignore` in that folder, and GATE does
not compile anything under a `.gdignore`, so a template renamed to `.gate` is never turned
back into a `.gd` and simply disappears from the Script Create dialog.

## Usage

Write `.gate`, get `.gd`. The output is ordinary GDScript with a header naming its source,
plus a `.gd.map` recording which source line each output line came from.

```gdscript
# player.gate
extends CharacterBody2D

pub int health = 100
Node2D? target

func hurt(amount: int) -> void:
	health -= amount
	target?.notify_damage(amount)
```

```gdscript
# player.gd, generated
extends CharacterBody2D

var health: int = 100
var target: Node2D = null

func hurt(amount: int) -> void:
	health -= amount
	if target != null:
		target.notify_damage(amount)
```

The output is indented the way the rest of your project is. In the editor, the indent type
and size come from *Editor Settings -> Text Editor -> Behavior -> Indent*. With no editor
running, a headless build takes the first indented line of the `.gate` file itself, so a
renamed `.gd` keeps the look it had. A tab is the last resort. Changing the setting rewrites
the outputs on the next build.

Delete the header, then the `.gate` file, and what remains is a normal script you can
maintain by hand: the leftover `.gd.map` can go with them, and the `.gd.uid` stays. There
is no runtime, no dependency, and nothing to ship.

### What gets rebuilt

What proves a file up to date is kept in `.godot/gate/`, so opening a project nothing has
changed in compiles nothing. Deleting that folder costs one full build and nothing else.

A file is rebuilt when something it reads changes. From another `.gate` it reads the
declarations, struct field defaults, signal parameter types, and what each function may set
to null. A comment, or an edit inside a function body that changes none of those, rebuilds
only the file it was made in. A hand-written `.gd` counts only for the `.gate` files that
reach it, by `class_name`, as a base, as an autoload or by path, and only through its
declarations. Of `project.godot`, only the autoloads and the `debug/gdscript` warning
settings count, so switching a plugin on or off builds nothing.

*Project -> Tools -> Recompile all GATE files* ignores all of this and looks at every
`.gate` again.

## Features

### Type-first declarations

The type goes before the name, so the typed form is shorter than the untyped one. `var`
still works exactly as it does in GDScript.

##### Example
```gdscript
int hp = 100            # var hp: int = 100
str label = "player"    # var label: String = "player"
vec2i[] tiles           # Array[Vector2i]
int[] scores            # Array[int]
{str, int} counts       # Dictionary[String, int]
int[][] grid            # Array[PackedInt32Array] - GDScript rejects nested typed collections
```

The short names are spellings, not new types. `str` **is** `String`, `vec2` is `Vector2`,
`f64` is `float`: same value, same methods, same thing every Godot API takes and returns,
with no wrapper and no conversion. Write `String` instead if you prefer - both compile to
the same line.

**This form replaces nothing.** `var hp: int = 100` means what it always did, and GATE's
own types work in that position too, so nothing here is behind the type-first spelling:

```gdscript
var target: Node2D? = null      # tracked nullable
var scores: int[] = [1, 2]      # Array[int]
var id: <int | str> = 7         # union, emitted as Variant
```

Use the null tracking, structs, generics and the rest without writing a single type-first
declaration if that suits you better. Type-first is there because the type is the thing
worth reading first in a block of fields, and because it is shorter. That is the whole
reason; there is no technical one. Parameters keep GDScript's own `name: Type` form, which
is an inconsistency on purpose: making them type-first is a spelling change that costs the
parser more lookahead than the rest of the grammar, so it sits in [ROADMAP.md](ROADMAP.md)
rather than half-built here.

### Null safety

`T?` is a tracked nullable type. A flow-sensitive pass follows guards, early exits and
assignments, and rejects a dereference it cannot prove is safe. It only ever complains
about types you declared nullable, so plain GDScript cannot trip it.

##### Example
```gdscript
Node2D? target

func update() -> void:
	target.queue_free()             # error: 'target' may be null
	target?.queue_free()            # fine
	if target != null:
		target.queue_free()         # fine
```

`?.` gives null when its left side is null, so its result is itself a value that may be
null. Where `a` may be null, `str n = a?.label` is an error and `str n = a?.label ?? ""` is
not.

### Structs

`struct` has value semantics, `class` has reference semantics. A struct of two to four
same-typed `int` or `float` fields becomes a `Vector2/3/4` and costs nothing; anything else
becomes a class and GATE inserts the copies that keep it a value.

##### Example
```gdscript
struct Damage:
	int amount
	str source

	func doubled() -> int:
		return amount * 2

var a = Damage(7, "hit")
var b = a            # a copy, not an alias
```

### Interfaces, traits and namespaces

Interfaces are checked at compile time and testable at runtime. Traits inline their members
into the implementor. Namespaces lower to inner classes.

##### Example
```gdscript
interface Damageable:
	func take_damage(amount: int) -> void

trait Poolable:
	int _pool_id = -1

	func reset() -> void:
		_pool_id = -1

class Enemy extends CharacterBody2D implements Damageable with Poolable:
	func take_damage(amount: int) -> void:
		pass
```

### Generics

Monomorphised, so `Pool<Bullet>` holds a real `Array[Bullet]` rather than an untyped one.
A generic is monomorphised once, in the file that declares it, so `is Pool<Bullet>` holds
across files.

##### Example
```gdscript
class Pool<T> extends Node:
	T[] _items

	func acquire() -> T?:
		return _items.pop_back() if _items.size() > 0 else null

var bullets = Pool<Bullet>.new()
```

### Unions, tuples and typed callables

All three compile to plain GDScript types and are checked at compile time. A union holds
one of its members, a tuple is an array of fixed length with a type per slot, and a typed
callable says what it takes and returns.

##### Example
```gdscript
<int | str> id = 7                          # var id: Variant = 7
<int, str> entry = [7, "hp"]                # var entry: Array = [7, "hp"]
func(int) -> bool keep = func(x): return x > 0

func update() -> void:
	id = 1.5                                # error: float is not int or String
	entry[1] = 3                            # error: slot 1 is a String
	keep.call("7")                          # error: expects int
```

### Type aliases and typed scenes

`type` names a type once; nothing is emitted for it. `PackedScene<T>` makes
`instantiate()` return a `T`.

##### Example
```gdscript
type Hp = int
type Loot = <Item | Gold>

Hp health = 100                             # var health: int = 100
PackedScene<Enemy> scene = preload("res://enemy.tscn")
Enemy e = scene.instantiate()               # typed, no cast
```

Signals you declared with types are checked too: `hit.emit("x")` on `signal hit(amount: int)`
is a warning. Only a warning, because Godot accepts it.

### Narrowing and match patterns

After `if x is T:`, or an early exit that proves it, `x` is a `T`. A `match` arm can test a
type and bind it in one go, and it composes with `when`.

##### Example
```gdscript
func area(s: Shape) -> float:
	match s:
		Circle c:
			return PI * c.r * c.r
		Rect r when r.w == r.h:
			return r.w * r.w
		Rect r:
			return r.w * r.h
	return 0.0

func hit(n: Node) -> void:
	if n is not Enemy:
		return
	n.take_damage(1)                        # n is an Enemy here
```

`Foo f = x as Foo` is an error unless `x is Foo` was proved first, since a failed `as` is
null. Plain GDScript's `(x as Foo).bar()` is left alone.

### Swizzling and object initialisers

`.xy`, `.xz`, `.zyx` and the rest work on any statically typed vector, reading and
writing. An object can be built and filled in one expression.

##### Example
```gdscript
vec3 p = Vector3(1, 2, 3)
vec2 flat = p.xz                            # Vector2(p.x, p.z)
p.xy = Vector2(5, 6)

var e = scene.instantiate({ position: spawn, hp: 40 + wave * 10, target: player })
var l = Label.new({ text: "Ready", modulate: Color.RED })
var d = Damage({ amount: 3, source: "fire" })
```

### Editor annotations

`@required` asserts in `_ready` that an exported node was assigned, in debug builds.
`@export_if` shows a property in the inspector only while a condition holds; it needs
`@tool`, and GATE will not add that for you.

##### Example
```gdscript
@tool
extends Node

@export @required Node2D target
@export bool use_timer = false
@export_if(use_timer) float delay = 1.0
```

### Expressions

##### Example
```gdscript
var name = player?.profile?.name        # safe navigation
var hp = saved ?? 100                   # null coalescing
var [x, y] = get_pos()                  # destructuring
var msg = f"{player} scored {pts}"      # f-string
a, b = b, a                             # swap
for i, item in enumerate(items):        # index and value
for k, v in scores:                     # dictionary key and value
```

## In the editor

With the plugin enabled, Godot treats `.gate` as a language of its own.

- **`.gate` files appear in the FileSystem dock**, with their own icon. Before this they
  were invisible: Godot did not track the extension at all.
- **Double-clicking one opens the real script editor**, with GATE's syntax colours -
  type-first declarations, `T?`, `T[]`, unions, f-strings, `struct`, `interface`,
  `namespace` and the rest. Every type name colours, short or canonical, and so does
  the name a `struct`, `interface`, `trait`, `namespace`, `type` or `class` declares
  and a generic's parameter. A name starting with `_` is dimmed. The colours come from
  your own editor theme, and follow it when you change it.
- **Some errors are underlined as you type** - an unterminated string, inconsistent
  indentation - the ones decidable from the file in front of you. A quote you left open
  is reported where you opened it, not where the file stops making sense. Anything that
  needs the rest of the project is left to the build, which reports to the Output panel
  as before.
- **Godot's own warnings show in the `.gate`**, in the same warnings panel and in the
  same words: unused variable, unused local constant, unused parameter, unused signal,
  and a local, parameter or `for` variable that shadows a member of this class or of a
  base - another `.gate`, a hand-written `.gd`, or an engine class. Before this they
  existed only against the generated `.gd`, which you are told never to open.
  `@warning_ignore`, `@warning_ignore_start`/`_restore` and the switches under
  *Project Settings -> Debug -> GDScript* are honoured, so a warning you turned off
  stays off. The warnings that need the whole project, and the ones about types, are
  still the build's.
- **Ctrl-click, or F1, goes to the declaration** - across files. A struct, class,
  interface, trait, namespace, generic or alias declared anywhere in the project, a
  `class_name` in another `.gate` or in a hand-written `.gd`, a member of any of
  those including one it inherits, and locals, parameters and fields in the file you
  are in. It goes through autoloads, so `Global.current_project.frames` reaches the
  field's declaration: a script autoload stands for its script, and a scene autoload for
  its root node's script, or the root's engine class when it has none. A base written as
  a path, `extends "res://base.gd"`, is followed like a named one. An engine class opens
  its documentation instead. Where GATE cannot place a word it says so by not
  underlining it.
- **Breakpoints work.** Set one in a `.gate` and the running game stops there, and
  the stop is shown in the `.gate` with the line marked, not in the generated `.gd`.
  Stepping follows. A breakpoint on a line that compiles to nothing - a comment, a
  blank, a declaration that lowers away - is taken back with a toast saying why,
  rather than left sitting there never firing. Godot's own debugger panels still name
  the `.gd`.
- **Autocompletion knows GATE's own forms.** After a dot it offers the members of
  whatever is on the left - a struct from another `.gate`, a `T?` field, a
  `class_name`, a hand-written `.gd` class, an autoload, an engine class - including
  everything inherited, all the way up, through a base written as a path too. `?.` is
  the same. `String`, `Array`, `Vector2` and the engine's other built-in types offer
  their methods, properties and constants, from a table generated from Godot 4.7.2's API.
  What a typed container holds carries through an index, the `Array` and `Dictionary`
  methods that return an element, and a `for` loop's variable, so with `Frame[] frames`
  both `frames[0].` and `f.` inside `for f in frames:` offer what a `Frame` has. A
  variable declared with `:=`, or a constant, takes its type from its initialiser; one
  declared with a plain `=` is still untyped. Unqualified, it offers locals, parameters, the file's own members and
  everything it inherits, the autoloads, every type in the project, GATE's type
  shorthands and keywords, and the engine's classes. After `@` it offers the
  annotations, GATE's and Godot's. On another object a dot leaves out the methods that
  start with an underscore, such as `_ready`, since those are there to be overridden;
  on `self` they are offered.
- **Open `.gate` tabs come back next session.** Godot's own layout never holds them;
  GATE keeps them and reopens them itself. That is so a session with GATE switched off
  finds nothing to reopen: without GATE, Godot would open a `.gate` as plain text and
  rewrite its indentation on exit, badly enough that it no longer compiles. Switching
  GATE off from the Plugins tab closes its tabs, saving any unsaved edit first, and a
  session with GATE off never rewrites a `.gate`.
- **Saving keeps the file's line endings.** A `.gate` that used CRLF is written back with
  CRLF; a new file, or one that used LF, stays LF.
- **New scripts.** *Script -> New Script* and the FileSystem dock's right-click
  *Create -> New GATE Script...* both offer GATE as a language.
- **Project -> Tools -> Recompile all GATE files** forgets what the build already knows
  and looks at every `.gate` again.
- **GATE stays out of the exported game.** `.gate` sources, their `.uid` files, the
  `.gd.map` sourcemaps, the compiler and the editor integration are all left out of
  the PCK; the compiled `.gd` is what ships. Four small scripts from
  `addons/gate/editor/` do ship - `loader.gd`, `saver.gd`, `registry.gd` and
  `script.gd` - because Godot's class list names the first two and a game that cannot
  find them prints six errors at start-up. They do nothing in a game. If you exclude
  `addons/gate/` in your export preset yourself, keep those four.

Three things deliberately do not work.

- **A `.gate` cannot be attached to a node.** *Attach Script* offers GATE and then
  refuses, because the script a node runs has to be the compiled `.gd`. Create the
  `.gate` first and attach the `.gd` that appears beside it.
- **Autocompletion offers nothing rather than guess.** Where the type of what is
  left of the dot cannot be worked out - a variable declared with a plain `=` and no
  type, an untyped container after an index, the return of an engine method GATE
  cannot follow - the list is empty rather than filled from somewhere else. It follows
  a chain of names, calls and indexes, not arbitrary expressions.
- **Ctrl-click only follows what GATE can type.** A member reached through a value
  whose type GATE cannot see is not underlined, and neither is a member of an engine
  class.

## Performance

The generated code is not slower than the GDScript you would have written: across 110
benchmarks the median ratio is 0.98, inside a 1.6% noise floor.

Where GATE is faster, it is because of a lowering you would not write by hand. A struct
local that provably never escapes its function becomes one plain local per field, with no
allocation and no copy - **13.5x** on a 300k-iteration loop. An array of structs that packs
into a Vector is **9.9x** faster than the idiomatic `Array[SomeClass]`.

`@soa` is the one to be careful with: it is about 2.4x slower to build and 1.9x faster to
iterate, so it pays off only if you make more than about 1.3 passes per rebuild.

## Known limitations

- **Comments are dropped**, including `##` doc comments. Renaming a documented `.gd` to
  `.gate` strips the documentation Godot's class reference is built from.
- **Godot's debugger panels name the generated `.gd`.** The game runs the `.gd`, so the
  Stack Frames list and a runtime error point at it; a toast names the `.gate` line each
  came from. Breakpoints and stepping are shown in the `.gate`. A stop on a generated line
  with no `.gate` line behind it - a helper GATE wrote - is left showing the `.gd`,
  deliberately, rather than pointing at a `.gate` line that is not the one running.
- **`as` is only checked in GATE's own declarations.** `x as T` is null when the cast
  fails. Inside a function, `Foo f = x as Foo` is an error unless an `if x is Foo:` or an
  early exit proved it, or you declare it `Foo?`. Everywhere else, `(x as Foo).field`,
  `var y = x as Foo`, arguments and field initialisers, the cast is trusted, so plain
  GDScript keeps its meaning. That is a known unsound spot in the null analysis.
- **Aliasing is judged by type.** A write to `d.next` clears what GATE knew about `next`
  on every reference that may be the same object: the same or a related class, or an
  unknown type. Three gaps remain. A call GATE cannot see into, like an engine method,
  clears what is under the references it is given but not their aliases. What it returns
  is taken to be a new object. And a function that writes through an array or dictionary
  holding a parameter (`var arr = [c]` then `arr[0].next = null`) is not seen by its
  callers to write to `c`.
- **Static fields are tracked only where GATE indexed them.** The null analysis follows a
  static field the file itself declares, under every spelling a function reaches it by, and a
  call that writes one clears it for the caller. A static field declared in another file is
  not tracked at all. A path below one reached through the class name, `Reg.cached.next`,
  falls back to the aliasing rule above rather than to the field itself. And a static function
  of a subclass does not track a static field it inherits from its base.
- **`is` narrows locals, parameters and typed instance fields.** An untyped field, a static
  var or an autoload can be rebound by a call GATE cannot trace, so a check on one does not
  narrow it at all. Copy it to a local and test that.
- **A struct field read through an untyped container is left as written.** `arr[0].c` maps
  to the Vector component when GATE knows what the container holds - a declared `S[]`, a
  parameter, a loop variable or a literal of one struct. From an untyped local grown with
  `append`, or an untyped parameter, there is no element type, and the read fails at run
  time.
- **Structs are only guarded where structs are used.** In a file that uses class-lowered
  structs, a value of unknown type is copied at run time if it turns out to be a struct. A
  plain file is left as it is, so a struct it reads out of an untyped array or dictionary is
  the stored one, not a copy.
- **An expression may nest at most 180 levels**, counting one level for every operator, call
  and member: a flat chain of 180 terms, or 90 steps of `a()[0]`. Every pass after the parser
  walks the tree once per level and GDScript stops at 1024 calls, so deeper than that the
  passes ran out of stack and handed back answers that were quietly cut short. A file that
  nests deeper is refused with one error naming where the expression starts. This is a place
  where valid GDScript is refused: Godot's own parser takes it. Deep member chains also cost
  time quadratic in their depth, which only shows well past a depth real code reaches.
- **Parentheses nest at most 48 levels.** A separate cap, in the parser, which is recursive
  descent written in GDScript. Reaching it is itself expensive, about twenty calls a level,
  so `not (not (...))` past 46 levels exhausts the stack before the cap can report it, and
  what GATE writes for such a file does not recompile to itself.
- **A file that references a `class_name` declared by another file in the same build** is
  written with a warning and validated once that class is registered, usually by the next
  build. Godot resolves global class names from the editor's class list, which only updates
  after the file is on disk.
- **Interfaces do not fall back to structural checks.** `x is SomeInterface` is false for a
  class GATE did not compile.
- **Namespaced classes cannot be attached to nodes** as their script.
- **Saving a `.gate` in the editor rewrites its indentation** to whatever
  *Text Editor -> Behavior -> Indent* says, as Godot does for a `.gd`. GATE reads tabs
  and spaces alike, so the output is unchanged either way.
- **Changing a declaration in a file most of the project reaches rebuilds all of it.**
  Adding a method, or changing a signature, a struct field default, a signal's parameter
  types or what a function may set to null, rebuilds every file that reaches the edited
  one. On Pixelorama, where almost everything goes through one autoload, adding a method
  to a file that autoload reaches measured about 35 s; a comment or a body edit in the
  same file measured about 2 s.
- **Completion re-reads the file when a declaration changes.** That costs about
  16 ms in a 130-line file, 100 ms at 900 lines and half a second at 4,200. Typing
  an expression - which is what a completion request usually follows - reuses the
  last reading and stays around 3 ms at any size.
- **Completion's first request in a session can take several seconds.** After the editor
  opens, GATE reads the project in the background, a few files per frame. A request made
  before that has finished reads the rest at once: about 7 s on Pixelorama, measured, where
  one made afterwards takes a fraction of a second.
- **A `.gate` opened before GATE 1.1.0 keeps "Plain Text" highlighting.** The choice is
  remembered per file in `.godot/editor/script_editor_cache.cfg`; pick GATE once from the
  highlighter menu and it sticks.
- **No game has shipped with it.**

## Verification

GATE is developed against a 24-stage test suite: differential execution against Godot
itself, a real-world superset corpus, build-pipeline scenarios across editor restarts,
live editor sessions, sourcemap fidelity, byte-exact output comparison and randomised
input. That suite is not
part of this repository; what ships here is the addon.

What it established at `v1.1.0`:

- **196 real Godot project roots** swept from their own directories - the official demo,
  tutorial and benchmark repositories plus ten shipped applications and games. Every file
  Godot itself loads there, 1,552 files and 176,219 lines: zero compile errors, zero outputs
  that fail to load, zero fixed-point breaks. Eight more roots, the OpenXR demos, never finish
  a headless run and are not counted.
- **3,291 real `.gd` files**, every one in both corpora that is not a copy of GATE itself,
  compiled and then recompiled from their own output, with zero outputs that fail to load and
  zero fixed-point breaks. The 17 that do not compile are Godot 3 syntax or mix tabs and
  spaces for indentation, and Godot 4 rejects every one of them too.
- **GodSVG** converted wholesale - all 191 non-addon files renamed to `.gate` and built
  through the plugin, then again after each of three editor restarts - with zero failed files,
  and every output loads.

The differential harness is the one that matters. It does not ask whether GATE accepted the
file, it asks whether Godot's answer equals GATE's answer. Every silent-wrong-value defect
in this project was found that way and none were found any other way.

## Documentation

The documentation in this repository, meaning this README, `SYNTAX.md` and
`CHANGELOG.md`, was written by AI and then checked by me before it shipped. Every
claim about behaviour is one I verified against the test suite or the compiler
itself, and every number quoted is one that came out of a run rather than an
estimate. Where it is still wrong, that is a mistake I missed, so please open an
issue and I will fix it.

## License

MIT. See [LICENSE](LICENSE).

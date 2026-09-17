# GATE

GATE is a [GDScript](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html)
superset for the [Godot Engine](https://godotengine.org/) that adds [extra features](#features)
while compiling down to plain GDScript.

###### Requires Godot 4.7. MIT licensed.

Valid GDScript is valid GATE. Rename a `.gd` to `.gate` and it compiles with no errors,
loads, and behaves identically. Recompiling GATE's own output gives back the same bytes.

## Table of Content
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
iterate, so it pays off only if you make more than about one pass per rebuild.

## Known limitations

- **Comments are dropped**, including `##` doc comments. Renaming a documented `.gd` to
  `.gate` strips the documentation Godot's class reference is built from.
- **The debugger points at the generated `.gd`.** A `.gd.map` is written beside every file,
  but nothing consumes it yet.
- **`as` is trusted.** `x as T` yields null when the cast fails, so it is really `T?`, but
  the common shape is `if x is T: (x as T).field` where it cannot. GATE has no type
  narrowing to tell them apart, so the declared type is taken at face value. This is the
  one knowingly unsound spot in the null analysis.
- **Aliasing is invisible** to the null analysis. `var d = c` then `d.next = null` does not
  invalidate a narrowing on `c.next`.
- **Expression nesting stops at 48 levels.** The parser is recursive descent written in
  GDScript, so it runs out of stack long before Godot's own parser does. Past the cap it
  reports one clear error.
- **A file that references a `class_name` declared by another file in the same build** is
  written with a warning and validated once that class is registered, usually by the next
  build. Godot resolves global class names from the editor's class list, which only updates
  after the file is on disk.
- **Interfaces do not fall back to structural checks.** `x is SomeInterface` is false for a
  class GATE did not compile.
- **Namespaced classes cannot be attached to nodes** as their script.
- **No game has shipped with it.**

## Verification

GATE is developed against a 22-stage test suite: differential execution against Godot
itself, a real-world superset corpus, build-pipeline scenarios, sourcemap fidelity,
byte-exact output comparison and randomised input. That suite is not part of this
repository; what ships here is the addon.

What it established at `v1.0.0`:

- **186 real Godot project roots** swept from their own directories - the official demo,
  tutorial and benchmark repositories plus ten shipped applications and games. 1,093 files,
  100,574 lines: zero compile errors, zero outputs that fail to load, zero fixed-point
  breaks.
- **7,567 real `.gd` files** compiled and then recompiled from their own output, with zero
  fixed-point breaks. The 23 compile errors are all Godot 3 syntax that Godot 4 rejects too.
- Two shipped projects, **beehave** and **GodSVG**, converted wholesale - every non-addon
  `.gd` renamed to `.gate` and built through the plugin - with zero files where only GATE's
  output fails to load.

The differential harness is the one that matters. It does not ask whether GATE accepted the
file, it asks whether Godot's answer equals GATE's answer. Every silent-wrong-value defect
in this project was found that way and none were found any other way.

## License

MIT. See [LICENSE](LICENSE).

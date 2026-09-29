# GATE

GATE is a [GDScript](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html)
superset for the [Godot Engine](https://godotengine.org/) that adds [extra features](#features)
while compiling down to plain GDScript.

###### Requires Godot 4.7. MIT licensed.

Valid GDScript is valid GATE. Rename a `.gd` to `.gate` and it compiles with no errors,
loads, and behaves identically. Recompiling GATE's own output gives back the same bytes.

Questions, or want to show what you built? [Discord](https://discord.gg/mzW5kY8Zj7).
Bugs and feature requests go in [issues](https://github.com/Blade67/GATE/issues).

## Table of Contents
- [Install](#install)
- [Usage](#usage)
- [Features](#features)
   * [Type-first declarations](#type-first-declarations)
   * [Null safety](#null-safety)
   * [Structs](#structs)
   * [Interfaces, traits and namespaces](#interfaces-traits-and-namespaces)
   * [Global classes](#global-classes)
   * [Generics](#generics)
   * [Unions, tuples and typed callables](#unions-tuples-and-typed-callables)
   * [Type aliases and typed scenes](#type-aliases-and-typed-scenes)
   * [Narrowing and match patterns](#narrowing-and-match-patterns)
   * [Swizzling and object initialisers](#swizzling-and-object-initialisers)
   * [Editor annotations](#editor-annotations)
   * [Conditional compilation](#conditional-compilation)
   * [Expressions](#expressions)
- [In the editor](#in-the-editor)
- [Editing a `.gate` in another editor](#editing-a-gate-in-another-editor)
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
Godot registers the classes it wrote. Pixelorama, 212 files, measured: about 80 s the first
time and about 60 s the second; after that, opening it unchanged takes about 11 s. The
first open compiles each file once. The second still recompiles most of them, because a
file GATE could not verify before Godot registered the classes is not remembered as proved
and has to be built again to be checked.

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

### Global classes

`@global` on a top-level class gives it its own Godot script beside the file that
declares it, carrying `class_name` - a real, attachable script that shows up in the
Create Node dialog, rather than an inner class of the `.gate`'s own output. The name is
project-wide, the same as a file's own `class_name`.

##### Example
```gdscript
# res://src/bullet.gate
@global class Bullet extends Node2D:
	var speed: float = 400.0
# writes res://src/bullet.Bullet.gd, carrying `class_name Bullet`
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

A function takes type parameters the same way, and one copy is emitted per set of type
arguments used. They are written out rather than inferred, and the call has to be a plain
call to a function of the same class.

```gdscript
func first<T>(xs: T[]) -> T:
	return xs[0]

print(first<int>(ns))    # __first_int(ns)
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

### Conditional compilation

`@if` / `@elif` / `@else` / `@endif` resolve when the file compiles. A dropped block is
blanked, not deleted, so every line after it keeps its original number, and it is never
parsed, so it can hold code that would not compile at all. Symbols come from Godot itself:
`DEBUG`, `RELEASE`, `EDITOR`, `EXPORT`, platform and architecture tags, and `GODOT_VERSION`
in a comparison. An unknown symbol is a compile error, not a silent false. At export, each
`.gd` is recompiled with the preset's own values, so a release build genuinely lacks a
`@if DEBUG` block.

##### Example
```gdscript
@if DEBUG
print("debug build")
@elif GODOT_VERSION >= 4.7 && WINDOWS
print("windows, recent Godot")
@else
print("release")
@endif
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
nums.map((x: int) => x + 1)             # arrow lambda
```

An arrow lambda is a one-expression `func` lambda with the noise removed: the parentheses
are always required, and the parameters follow the same rules a `func` lambda's do.

Two spellings are behind a project setting, both off by default, because each is a second
way to write something GATE already has:

```gdscript
int[,] grid = [[1, 2]]                  # gate/features/multidim_arrays, = int[][]
var shown = raw |> roundi() |> mini(99) # gate/experiments/pipe_operator, = mini(roundi(raw), 99)
```

Writing either with its flag off is an error naming the setting.

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
  Stepping follows. A breakpoint on a line the game can never stop on - a blank, a
  declaration that lowers away, or a comment, which is carried through but is still
  not something Godot breaks on - is taken back with a toast saying why, rather than
  left sitting there never firing. Godot's own debugger panels still name the `.gd`.
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
  on `self` they are offered. A name is offered only where the caret can actually see
  it: a parameter inside its own function, a local below its own line, a `for`
  variable inside its loop. Typing the start of a virtual in a class body offers the
  base's overridable methods with their signature filled in, and typing a call's
  opening bracket shows that function's parameters.
- **A node dragged in from the Scene dock lands as a reference**, the same line a `.gd`
  would get. A `.gate` answers the editor with the engine class at the root of its
  `extends` chain, which is the one question the Scene dock asks before it allows the
  drop.
- **The script editor's method list holds every function**, whatever it is written with:
  `priv func`, `pub func`, `virtual func`, an operator overload, and any of those with
  `static`, each jumping to its line in the `.gate`.
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
- **Attach Script creates the `.gate` and attaches the `.gd`.** Choose GATE in the
  Scene dock's *Attach Script* dialog and it writes the `.gate` from the template you
  picked, compiles it, and puts the generated `.gd` on the node. The node runs the
  `.gd`, as it has to; the `.gate` is what stays open in the script editor. If the
  build fails, GATE says so on screen, leaves the `.gate` alone so you can fix it, and
  attaches nothing.
- **Project -> Tools -> Recompile all GATE files** forgets what the build already knows
  and looks at every `.gate` again.
- **GATE stays out of the exported game.** `.gate` sources, their `.uid` files, the
  `.gd.map` sourcemaps, the compiler and the editor integration are all left out of
  the PCK; the compiled `.gd` is what ships. Four small scripts from
  `addons/gate/editor/` do ship - `loader.gd`, `saver.gd`, `registry.gd` and
  `script.gd` - because Godot's class list names the first two and a game that cannot
  find them prints six errors at start-up. They do nothing in a game. If you exclude
  `addons/gate/` in your export preset yourself, keep those four.

Two things deliberately do not work.

- **Autocompletion offers nothing rather than guess.** Where the type of what is
  left of the dot cannot be worked out - a variable declared with a plain `=` and no
  type, an untyped container after an index, the return of an engine method GATE
  cannot follow - the list is empty rather than filled from somewhere else. It follows
  a chain of names, calls and indexes, not arbitrary expressions.
- **Ctrl-click only follows what GATE can type.** A member reached through a value
  whose type GATE cannot see is not underlined, and neither is a member of an engine
  class.

## Editing a `.gate` in another editor

GATE speaks LSP, so a `.gate` can be edited in Neovim, Helix, Zed or VS Code. The server
runs inside the Godot editor, the way Godot's own GDScript language server does, which is
what makes what it tells your editor and what the script editor shows you come from the
same code rather than from two implementations that drift apart.

It is off unless you ask for it. In *Project -> Project Settings -> GATE*:

- `gate/lsp/enabled` - off by default. Nobody gets a listening socket they did not want.
- `gate/lsp/port` - 6100 by default. It binds `127.0.0.1` and nothing else. If that port
  is already taken, GATE says so and stops instead of moving to another one: a client is
  configured with a fixed port, and a server that quietly moves is a server the client
  never finds.

Godot has to be running with the project open for anything to answer.

While a client is attached, GATE keeps the editor's main loop at about 60 Hz. Godot
sleeps 100 ms between frames when its window is not focused, and not focused is what it
is the whole time you are typing somewhere else, which is exactly when this is answering:
the server polls the socket once a frame, so that period is how long a reply can sit
waiting. It is handed back the moment the client disconnects, and a focused editor, which
is already quicker than 60 Hz, is left alone.

### Pointing an editor at it

The server is a socket rather than a program, so a client has to connect to it rather
than start it. That is the same shape as Godot's own GDScript server, and it is why an
editor that can only launch a language server needs something in between.

**Neovim** connects to a socket on its own:

```lua
vim.lsp.start({
  name = "gate",
  cmd = vim.lsp.rpc.connect("127.0.0.1", 6100),
  root_dir = vim.fs.dirname(vim.fs.find({ "project.godot" }, { upward = true })[1]),
})
```

**VS Code** has no built-in way to attach to a language server at all; every language
there arrives through an extension. There is one for GATE in the `GateVsCode` repository
beside this one, unpublished and installed by copying a folder.

**Helix and Zed** launch a language server as a child process and talk to it over its
standard input and output, so they need a bridge that forwards stdio to the socket. Any
of `nc`, `socat` or a three-line script will do it; none of them is installed on Windows
by default.

**What it answers today.** Diagnostics, completion, signature help, go-to-definition,
hover and a document outline. Anything else is answered "method not there", which is what
makes a client fall back to its own word list rather than conclude GATE has nothing to
say.

**Go-to-definition refuses rather than guesses.** It answers exactly where Ctrl-click in
the script editor answers, because it asks the same code: a local, a parameter, a member,
a function, a signal, an enum, a type declared in another `.gate`, a `class_name` in a
hand-written `.gd`, an autoload, and anything inherited from a base, including a base
written as a path. A word it cannot place answers nothing at all rather than the nearest
name that looks similar. An engine class answers nothing too, since there is no file to
open; hover still describes it. The answer is always a location in something you wrote -
the `.gate`, or a `.gd` you wrote yourself - never in the `.gd` GATE generated.

**An enum member takes you to its enum.** GATE's parser keeps an enum's keys as names on
the declaration and gives them no line of their own, so `Mood.CALM` opens the line `enum
Mood` is on. On a one-line enum that puts the caret on the key itself; on an enum whose
body runs over several lines it puts you at the top of it.

**Hover shows the declaration and its declared type.** The line as you wrote it, and the
type GATE has for it. A `var` with no type on it gets no type line, because the type of
one of those comes out of the build, against the whole project, and a hover is answered
from one file. It says nothing at all rather than showing an empty tooltip.

**The outline is the file's own declarations.** Classes, structs, interfaces, traits,
namespaces, enums and their members, functions, signals, constants and fields, nested the
way you wrote them. A file that is mid-edit still gets an outline: a half-typed
declaration costs its own entry and nothing else.

**Diagnostics come in two tiers, and the difference matters.** As you type, you get what
Godot's script editor underlines on the same file: the lexer's errors and Godot's own
unused and shadowed-variable warnings. When you save, you also get what a compile finds -
unknown types, the null analysis, the superset checks - which is everything GATE knows
about that file. A type declared in another `.gate` resolves, because the editor already
holds the project's registry. Where GATE has a hint it arrives as related information, so
your editor can show the message on the line and the hint on demand, and a problem both
tiers find is reported once.

The split is not arbitrary. The lexer pass takes 0.2 ms on a small file and 12.5 ms on a
238-line one; compiling the same two takes 5.8 ms and 259 ms, and it runs on the editor's
main thread, which means Godot is not doing anything else while it does. Paying that on
every pause in your typing would be paying it dozens of times a minute for an answer that
has usually not changed. So a keystroke buys the fast tier and a save buys both. If you
want GATE's full opinion on a file, save it.

**What it still does not carry.** The rest of the project. You get every diagnostic for
the file you saved, not for the files that depend on it, and a build still reports those
to Godot's Output panel.

**Completion offers nothing rather than guess, here too.** The list is the one the script
editor gives, in the same order, with GATE's kinds mapped to your editor's icons. Where
GATE cannot establish the type of what is left of the dot, the answer is an empty list.
Signature help names the call you are inside and highlights the argument you are on,
including after a comma inside a nested call. A method of a Variant built-in such as
`String` or `Array` gets no signature at all: Godot's own API dump records those methods
with a name and a return type and no parameters, so there is no argument list to show, and
an empty one would say the method takes none.

**Unsaved changes count for the file you are in, and only that one.** While your editor
holds a file open, everything GATE says about that file is computed from your buffer.
Anything it has to read from another file - a base class, when it is working out whether a
local shadows a member of it - is read from disk. So a member you added to a base class
and have not saved is not taken into account while GATE looks at the file that extends it.
Saving fixes it once Godot has noticed the file changed, which happens the next time the
editor scans the filesystem.

**One file, one editor.** A `.gate` open in Godot's script editor and in an external
editor at the same time is two buffers over one file, and GATE does not arbitrate between
them. Pick one.

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

- **A comment written inside a call's brackets is dropped.** Comments are carried into
  the output, `##` docs included, and that now covers one written inside an array
  literal, a dictionary literal or an `enum` body - such a construct takes its
  one-per-line form so each comment has a line of its own, and one carrying no comment is
  emitted exactly as before. A call is the exception: it is rebuilt from the syntax tree
  onto one line, so there is no line to put a comment back on. Measured over 3,495 real
  files, 614 of the 764 comments written inside brackets are carried and these 150 are
  not. A comment written on the end of a line of code is also dropped in the one case
  where that line became more than one line of output, or none: `@rpc func f()` written
  on a single line comes out on two, and there is then no single right place for it.
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
- **Namespaced classes cannot be attached to nodes** as their script. A top-level class
  marked `@global` can; `@global` does not reach inside a `namespace`.
- **A `@global` class's own body can only name itself, a project-wide name, or something it
  declares itself** - not a plain sibling declared at the same file's own top level: a
  class, struct, interface, trait, namespace, enum, const, var, signal or func that is not
  itself `@global`, since that sibling is not there any more once the class is extracted
  into its own script. Refused at compile time, naming the sibling; mark it `@global` too,
  or move it inside the class.
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
- **Conditional compilation has no file-local `@define`.** A custom symbol comes from the
  project setting `gate/compiler/defines` only. A comparison operator is defined only for
  `GODOT_VERSION`. Directives are line-based: half an expression cannot be dropped. The
  editor shows a dropped block as ordinary code; it is not greyed out.
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

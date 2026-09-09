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
   * [Expressions](#expressions)
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

Delete the `.gate` file and the header, and what remains is a normal script you can
maintain by hand. There is no runtime, no dependency, and nothing to ship.

## Features

### Type-first declarations

The type goes before the name, so the typed form is shorter than the untyped one. `var`
still works exactly as it does in GDScript.

##### Example
```gdscript
int hp = 100            # var hp: int = 100
str label = "player"    # var label: String = "player"
vec2i[] tiles           # Array[Vector2i]
int[] scores            # PackedInt32Array
{str, int} counts       # Dictionary[String, int]
int[][] grid            # Array[PackedInt32Array] - GDScript rejects nested typed collections
```

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

### Structs

`struct` has value semantics, `class` has reference semantics. A struct of two to four
same-typed numbers becomes a `Vector2/3/4` and costs nothing; anything else becomes a class
and GATE inserts the copies that keep it a value.

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
  written but not validated until the next build. Godot resolves global class names from
  the editor's class list, which only updates after the file is on disk.
- **Interfaces do not fall back to structural checks.** `x is SomeInterface` is false for a
  class GATE did not compile.
- **Namespaced classes cannot be attached to nodes** as their script.
- **No game has shipped with it.**

## Verification

GATE is developed against a 20-stage test suite: differential execution against Godot
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

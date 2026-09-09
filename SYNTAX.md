# GATE syntax reference

GATE 1.0.0, targeting Godot 4.7.

Valid GDScript is valid GATE. Everything below is additional syntax, and a `.gate` file may
use as much or as little of it as you want. Each section shows what the construct compiles
down to.

## Table of Content
- [Type names](#type-names)
- [Declarations](#declarations)
- [Nullable types](#nullable-types)
- [Structs](#structs)
- [Interfaces, traits and namespaces](#interfaces-traits-and-namespaces)
- [Generics](#generics)
- [Operators and expressions](#operators-and-expressions)
- [Members and methods](#members-and-methods)
- [Annotations](#annotations)
- [Complete example](#complete-example)

## Type names

Lowercase shorthands. Canonical names still work, and engine classes keep theirs.

| GATE | GDScript |
|---|---|
| `int` `float` `bool` `str` | `int` `float` `bool` `String` |
| `i32` `i64` `f32` `f64` | `int` `int` `float` `float` |
| `vec2` `vec3` `vec4` | `Vector2` `Vector3` `Vector4` |
| `vec2i` `vec3i` `vec4i` | `Vector2i` `Vector3i` `Vector4i` |
| `rect2` `rect2i` | `Rect2` `Rect2i` |
| `quat` `xform2d` `xform3d` | `Quaternion` `Transform2D` `Transform3D` |
| `color` `aabb` `plane` `basis` `proj` | `Color` `AABB` `Plane` `Basis` `Projection` |
| `nodepath` `rid` `sname` `any` | `NodePath` `RID` `StringName` `Variant` |

## Declarations

A type-first declaration puts the type before the name. `var` works exactly as it does in
GDScript.

```gdscript
int hp = 100            # var hp: int = 100
float speed             # var speed: float = 0.0
str label = "player"    # var label: String = "player"
```

Without an initialiser the declaration takes the type's default value. Fields of the same
type can share a line.

### Collections

```gdscript
vec2i[] tiles           # Array[Vector2i]
int[] scores            # PackedInt32Array
{str, int} counts       # Dictionary[String, int]
{str, vec2} spawns      # Dictionary[String, Vector2]
```

The bracket you declare with is the bracket you initialise with: `T[]` takes `[]`,
`{K, V}` takes `{}`. `{T}` with a single parameter is reserved and not accepted.

### Nested collections

GDScript rejects nested typed collections. GATE accepts them by lowering the inner type to
its `Packed*` equivalent.

```gdscript
int[][] grid            # Array[PackedInt32Array]
vec2[][] paths          # Array[PackedVector2Array]
{str, int[]} buckets    # Dictionary[String, PackedInt32Array]
```

Where the inner type has no `Packed*` equivalent, the inner container is untyped and GATE
warns that the inner type is unenforced.

### Numeric width

`int[]` and `float[]` lower to `PackedInt32Array` and `PackedFloat32Array`, which store
32-bit values. GDScript's own `int` and `float` are 64-bit, so this is a narrowing, and GATE
warns once per file when it applies.

Use `i64` or `f64` to keep the full width. The array then lowers to `PackedInt64Array` or
`PackedFloat64Array`, and a struct using them lowers to a class rather than a Vector.

```gdscript
float[] samples         # PackedFloat32Array
f64[] precise           # PackedFloat64Array
```

## Nullable types

`T?` declares a value that may be null. GATE tracks nullness through guards, early exits and
assignments, and rejects an unguarded dereference.

```gdscript
Node2D? target

var name = player?.profile?.name    # null if any link is null
var first = items?[0]               # null if items is null
var hp = saved ?? 100               # 100 if saved is null

if target != null:
	target.queue_free()             # accepted: guarded
```

`?.` and `?[` yield null when the left side is null, and protect exactly one step. `??`
returns its right side when the left side is null.

## Structs

`struct` has value semantics. `class` has reference semantics.

```gdscript
struct Damage:
	int amount
	str source
	float crit = 1.0

var a = Damage(7, "hit")
var b = a                # a copy, not an alias
```

A struct of two to four same-typed `int` or `float` fields lowers to `Vector2/3/4` and
copies for free. Anything else - more fields, mixed types, a method - lowers to a generated
class, and GATE inserts a copy wherever the value is bound to a new location: assignment,
argument passing, `return`, and stores into an array or dictionary.

A struct is constructed by calling its name. Fields with an initialiser may be omitted.
Structs take methods and operator overloads.

```gdscript
struct Vec3f:
	float x, y, z

	func length_squared() -> float:
		return x * x + y * y + z * z

	operator +(o: Vec3f) -> Vec3f:
		return Vec3f(x + o.x, y + o.y, z + o.z)
```

### Struct-of-arrays

`@soa` stores one array per field instead of one array of values.

```gdscript
@soa Particle[] swarm       # swarm_x, swarm_y, swarm_vx, swarm_vy
```

`append`, `size`, `is_empty`, `clear`, `swarm[i].field` and `for p in swarm` are rewritten
to operate on the parallel arrays. Inside the loop `p` is a value, not a reference, and
storing it beyond the iteration is a compile error.

## Interfaces, traits and namespaces

```gdscript
interface Damageable:
	func take_damage(amount: int) -> void
	int health { get }

trait Poolable:
	int _pool_id = -1

	func reset() -> void:
		_pool_id = -1

namespace Combat:
	const MAX_DAMAGE := 999

	class Weapon extends Node2D:
		pass

class Enemy extends CharacterBody2D implements Damageable with Poolable:
	pass
```

- **Interfaces** declare methods and property requirements. Conformance is checked at
  compile time, and `x is Damageable` works at runtime for classes GATE compiled.
- **Traits** inline their members into the implementor. A conflict between two traits is a
  compile error.
- **`requires`** in a class header names members the class must provide.
- **Namespaces** lower to inner classes. A namespaced class cannot be attached to a node as
  its script.

## Generics

```gdscript
class Pool<T> extends Node:
	T[] _items

	func acquire() -> T?:
		return _items.pop_back() if _items.size() > 0 else null

	func release(item: T) -> void:
		_items.push_back(item)

var bullets = Pool<Bullet>.new()
```

Each instantiation is monomorphised into a concrete class, so `Pool<Bullet>` holds a real
`Array[Bullet]`. A generic is monomorphised once, in the file that declares it, so
`is Pool<Bullet>` holds across files. Type arguments cannot cross a dynamic `load()`.

## Operators and expressions

```gdscript
var name = player?.profile?.name        # safe navigation
var hp = saved ?? 100                   # null coalescing
var [x, y] = get_pos()                  # destructuring
var msg = f"{player} scored {pts}"      # f-string
a, b = b, a                             # swap
for i, item in enumerate(items):        # index and value
for k, v in scores:                     # dictionary key and value
```

Comparison is left-associative, as in GDScript: `a == b == c` means `(a == b) == c`. There
is no comparison chaining, so write `0 < hp and hp < max_hp`.

## Members and methods

```gdscript
class Enemy extends CharacterBody2D implements Damageable:
	pub int health = 100
	priv vec2[] _patrol
	const MAX_HP := 100

	@observable int score = 0

	override func _ready() -> void:
		reset()

	virtual func on_hit() -> void

	final func commit() -> void:
		pass
```

| keyword | effect |
|---|---|
| `pub` | public, and the default for a type-first declaration |
| `priv` | private; the emitted name is prefixed with `_` |
| `override` | checked against the parent, and an error if no such member exists |
| `virtual` | declared without a body; an implementor must provide one |
| `final` | cannot be overridden |
| `operator` | operator overload, rewritten where the operand type is known |

Methods may be overloaded by argument count. Two overloads taking the same number of
arguments are a compile error.

## Annotations

| annotation | effect |
|---|---|
| `@observable` | emits `on_<name>_changed(value)` and a getter/setter pair that fires it |
| `@soa` | stores an array of structs as one array per field |
| `@packed` | asks for the `Packed*` lowering where it is not automatic |

GDScript's own annotations pass through unchanged.

## Complete example

```gdscript
namespace Combat:

	interface Damageable:
		func take_damage(amount: int) -> void

	trait Poolable:
		int _pool_id = -1

		func reset() -> void:
			_pool_id = -1

	struct Damage:
		int amount
		float crit = 1.0

	class Enemy extends CharacterBody2D implements Damageable with Poolable:
		pub int health = 100
		priv vec2[] _patrol
		priv {str, float} _resistances

		@observable int hp_display = 100

		override func _ready() -> void:
			reset()

		func take_damage(amount: int) -> void:
			var mult = _resistances.get("phys") ?? 1.0
			health -= int(amount * mult)
			hp_display = health

		func nearest_point(from: vec2) -> vec2?:
			if _patrol.is_empty():
				return null
			var best = _patrol[0]
			for p in _patrol:
				if from.distance_to(p) < from.distance_to(best):
					best = p
			return best
```

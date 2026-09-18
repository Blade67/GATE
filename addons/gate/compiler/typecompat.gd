@tool
class_name GateTypeCompat
extends RefCounted

## Whether a value of one type can be stored where another is declared. Only GATE's own
## types are judged. UNKNOWN is never reported, so an unknown type is never an error.

enum { NO, YES, UNKNOWN }

const IMPLICIT := {
	"int": ["float"],
	"String": ["StringName", "NodePath"],
	"StringName": ["String"],
}

const GODOT_CONVERTS := {
	"bool": ["int", "float"],
	"int": ["float", "bool"],
	"float": ["int", "bool"],
	"String": ["StringName", "NodePath"],
	"StringName": ["String", "NodePath"],
	"NodePath": ["String", "StringName"],
	"Vector2i": ["Vector2"], "Vector2": ["Vector2i"],
	"Vector3i": ["Vector3"], "Vector3": ["Vector3i"],
	"Vector4i": ["Vector4"], "Vector4": ["Vector4i"],
}


static func godot_converts(from_t: GateAST._TypeRef, to_t: GateAST._TypeRef) -> bool:
	if from_t == null or to_t == null or from_t.array_depth > 0 or to_t.array_depth > 0:
		return false
	var f: String = GateTypes.canonical(from_t.name)
	return (GODOT_CONVERTS.get(f, []) as Array).has(GateTypes.canonical(to_t.name))


const SCALARS := {
	"int": true, "float": true, "bool": true, "String": true, "StringName": true,
	"NodePath": true, "Vector2": true, "Vector2i": true, "Vector3": true, "Vector3i": true,
	"Vector4": true, "Vector4i": true, "Rect2": true, "Rect2i": true, "Transform2D": true,
	"Transform3D": true, "Quaternion": true, "Basis": true, "Color": true, "AABB": true,
	"Plane": true, "Projection": true, "RID": true, "Callable": true, "Signal": true,
}

const PACKED_ARRAYS := {
	"PackedByteArray": true, "PackedInt32Array": true, "PackedInt64Array": true,
	"PackedFloat32Array": true, "PackedFloat64Array": true, "PackedStringArray": true,
	"PackedVector2Array": true, "PackedVector3Array": true, "PackedVector4Array": true,
	"PackedColorArray": true,
}


static func null_type() -> GateAST._TypeRef:
	var t: GateAST._TypeRef = GateAST._TypeRef.new()
	t.name = "null"
	return t


static func tuple_of(elem_types: Array) -> GateAST._TypeRef:
	var t: GateAST._TypeRef = GateAST._TypeRef.new()
	t.name = "Array"
	for e in elem_types:
		t.shaped().tuple_elems.append(e)
	return t


static func holds_null(t: GateAST._TypeRef, infer = null) -> bool:
	if t == null or t.nullable:
		return true
	var cat: String = _category(t, infer)
	return cat == "object" or cat == ""


static func describe(t: GateAST._TypeRef) -> String:
	if t == null:
		return "Variant"
	return t.describe()


static func assignable(value_t: GateAST._TypeRef, target_t: GateAST._TypeRef, infer = null,
		convert: bool = true) -> int:
	if value_t == null or target_t == null:
		return UNKNOWN
	if _is_variant(target_t):
		return YES
	if value_t.name == "null" and value_t.array_depth == 0 and not value_t.is_tuple():
		return YES if target_t.nullable else NO
	if value_t.is_union() and value_t.array_depth == 0:
		var result: int = YES
		for m in flat_members(value_t):
			var r: int = assignable(m, target_t, infer, convert)
			if r == NO:
				return NO
			if r == UNKNOWN:
				result = UNKNOWN
		return result
	if target_t.array_depth > 0:
		return _into_array(value_t, target_t, infer, convert)
	if target_t.is_union():
		return _into_union(value_t, target_t, infer, convert)
	if target_t.is_tuple():
		return _into_tuple(value_t, target_t, infer, convert)
	if _is_variant(value_t):
		return UNKNOWN
	if target_t.is_func_type:
		return _into_func(value_t, target_t, infer)
	return _plain(value_t, target_t, infer, convert)


static func _into_array(value_t: GateAST._TypeRef, target_t: GateAST._TypeRef, infer, convert: bool) -> int:
	var te: GateAST._TypeRef = _element(target_t)
	if value_t.is_tuple() and value_t.array_depth == 0:
		var result: int = YES
		for e in value_t.tuple_elems:
			var r: int = assignable(e, te, infer, convert)
			if r == NO:
				return NO
			if r == UNKNOWN:
				result = UNKNOWN
		return result
	if value_t.array_depth > 0:
		return NO if assignable(_element(value_t), te, infer, convert) == NO else UNKNOWN
	var cat: String = _category(value_t, infer)
	return NO if cat == "scalar" or cat == "object" or cat == "dict" else UNKNOWN


## The conversion to write in, if the value widens into exactly one member.
static func widening(value_t: GateAST._TypeRef, target_t: GateAST._TypeRef, infer = null) -> String:
	if value_t == null or target_t == null or value_t.array_depth > 0 or target_t.array_depth > 0:
		return ""
	if value_t.is_union() or value_t.is_tuple() or value_t.name == "null":
		return ""
	if not target_t.is_union():
		return canonical_name(target_t) if _widens(value_t, target_t) else ""
	if assignable(value_t, target_t, infer, false) != NO:
		return ""
	var hits: Dictionary = {}
	for m in flat_members(target_t):
		if _widens(value_t, m):
			hits[canonical_name(m)] = true
	if hits.size() == 1:
		return String(hits.keys()[0])
	return "?" if hits.size() > 1 else ""


static func member_widenings(value_t: GateAST._TypeRef, target_t: GateAST._TypeRef, infer = null) -> Array:
	var out: Array = []
	for m in flat_members(value_t):
		var to: String = widening(m, target_t, infer)
		if to != "":
			out.append([canonical_name(m), to])
	return out


static func _widens(value_t: GateAST._TypeRef, target_t: GateAST._TypeRef) -> bool:
	if target_t.array_depth > 0 or target_t.is_union() or target_t.is_tuple() or target_t.is_dict():
		return false
	var vn: String = GateTypes.canonical(value_t.name)
	return (IMPLICIT.get(vn, []) as Array).has(GateTypes.canonical(target_t.name))


static func canonical_name(t: GateAST._TypeRef) -> String:
	return GateTypes.canonical(t.name)


static func flat_members(t: GateAST._TypeRef) -> Array:
	var out: Array = []
	for m in t.union_members:
		var mt: GateAST._TypeRef = m
		if mt.is_union() and mt.array_depth == 0:
			out.append_array(flat_members(mt))
		else:
			out.append(mt)
	return out


static func _into_func(value_t: GateAST._TypeRef, target_t: GateAST._TypeRef, infer) -> int:
	if not (value_t.is_func_type or value_t.sig_known) \
			or GateTypes.canonical(value_t.name) != "Callable":
		if value_t.array_depth == 0 and GateTypes.canonical(value_t.name) == "Callable":
			return UNKNOWN   # a Callable whose signature was never seen
		var cat: String = _category(value_t, infer)
		return NO if cat != "" else UNKNOWN
	var n: int = target_t.callable_params.size()
	var total: int = value_t.callable_params.size()
	var required: int = total - value_t.callable_optional
	if n < required or (n > total and not value_t.callable_rest):
		return NO
	var result: int = YES
	for i in mini(n, total):
		var vp: GateAST._TypeRef = value_t.callable_params[i]
		if vp == null:
			continue   # an untyped parameter takes anything
		var r: int = assignable(target_t.callable_params[i], vp, infer)
		if r == NO:
			return NO
		if r == UNKNOWN:
			result = UNKNOWN
	var tr: GateAST._TypeRef = target_t.callable_return
	var vr: GateAST._TypeRef = value_t.callable_return
	if tr == null or GateTypes.canonical(tr.name) == "void":
		return result
	if vr == null:
		return UNKNOWN
	if GateTypes.canonical(vr.name) == "void":
		return NO
	var rr: int = assignable(vr, tr, infer)
	if rr == NO:
		return NO
	return UNKNOWN if rr == UNKNOWN else result


static func _into_union(value_t: GateAST._TypeRef, target_t: GateAST._TypeRef, infer, convert: bool) -> int:
	var any_unknown: bool = false
	for m in target_t.union_members:
		var r: int = assignable(value_t, m, infer, convert)
		if r == YES:
			return YES
		if r == UNKNOWN:
			any_unknown = true
	return UNKNOWN if any_unknown else NO


static func _into_tuple(value_t: GateAST._TypeRef, target_t: GateAST._TypeRef, infer, convert: bool) -> int:
	var cat: String = _category(value_t, infer)
	if value_t.array_depth != target_t.array_depth:
		return NO if cat != "" and cat != "array" else UNKNOWN
	if not value_t.is_tuple():
		return NO if cat == "scalar" or cat == "object" or cat == "dict" else UNKNOWN
	if value_t.tuple_elems.size() != target_t.tuple_elems.size():
		return NO
	var result: int = YES
	for i in target_t.tuple_elems.size():
		var r: int = assignable(value_t.tuple_elems[i], target_t.tuple_elems[i], infer, convert)
		if r == NO:
			return NO
		if r == UNKNOWN:
			result = UNKNOWN
	return result


static func _plain(value_t: GateAST._TypeRef, target_t: GateAST._TypeRef, infer, convert: bool = true) -> int:
	var vc: String = _category(value_t, infer)
	var tc: String = _category(target_t, infer)
	if vc == "" or tc == "":
		return UNKNOWN
	if vc != tc:
		return NO
	var vn: String = GateTypes.canonical(value_t.name)
	var tn: String = GateTypes.canonical(target_t.name)
	match vc:
		"scalar":
			if vn == tn:
				return YES
			if convert and (IMPLICIT.get(vn, []) as Array).has(tn):
				return YES
			return NO
		"array":
			if value_t.array_depth > 0 and target_t.array_depth > 0:
				var ve: GateAST._TypeRef = _element(value_t)
				var te: GateAST._TypeRef = _element(target_t)
				var r: int = assignable(ve, te, infer)
				return YES if r == YES and vn == tn else UNKNOWN
			return YES if vn == tn and value_t.array_depth == target_t.array_depth \
				and value_t.generic_args.is_empty() and target_t.generic_args.is_empty() else UNKNOWN
		"object":
			return _object(vn, tn, infer)
	return UNKNOWN


static func _element(t: GateAST._TypeRef) -> GateAST._TypeRef:
	var e: GateAST._TypeRef = GateChecker.copy_type(t)
	e.array_depth = t.array_depth - 1
	e.nullable = t.elem_nullable and t.array_depth == 1
	return e


static func _object(vn: String, tn: String, infer) -> int:
	if vn == tn:
		return YES
	if infer != null and infer.open_types.has(tn):
		return YES if infer.implements_interface(vn, tn) else UNKNOWN
	if infer != null and infer.open_types.has(vn):
		return UNKNOWN
	var vchain: Array = _chain(vn, infer)
	var tchain: Array = _chain(tn, infer)
	if vchain.is_empty() or tchain.is_empty():
		return UNKNOWN
	if vchain.has(tn):
		return YES
	if tchain.has(vn):
		return UNKNOWN   # a downcast: GDScript checks it when it runs
	if ClassDB.class_exists(String(vchain[vchain.size() - 1])) \
			and ClassDB.class_exists(String(tchain[tchain.size() - 1])):
		return NO
	return UNKNOWN


static func _chain(cls: String, infer) -> Array:
	var out: Array = []
	var c: String = cls
	var seen: Dictionary = {}
	while c != "" and not seen.has(c):
		seen[c] = true
		out.append(c)
		if ClassDB.class_exists(c):
			var p: String = c
			while true:
				p = ClassDB.get_parent_class(p)
				if p == "":
					break
				out.append(p)
			return out
		if infer == null:
			return []
		if infer.bases.has(c):
			c = String(infer.bases[c])
		elif infer.has_class(c):
			c = "RefCounted"
		else:
			return []
	return []


static func _category(t: GateAST._TypeRef, infer = null) -> String:
	if t.is_tuple() or t.array_depth > 0:
		return "array"
	if t.is_dict():
		return "dict"
	if t.is_union() or t.name == "" or t.name.contains(".") or t.is_path_literal:
		return ""
	var n: String = GateTypes.canonical(t.name)
	if SCALARS.has(n):
		return "scalar"
	if n == "Array" or PACKED_ARRAYS.has(n):
		return "array"
	if n == "Dictionary":
		return "dict"
	if n == "Object" or ClassDB.class_exists(n):
		return "object"
	if infer != null and (infer.bases.has(n) or infer.has_class(n)):
		return "object"
	return ""


const OPERATORS := {"+": true, "-": true, "*": true, "/": true, "%": true, "**": true,
	"<<": true, ">>": true, "&": true, "|": true, "^": true,
	"<": true, ">": true, "<=": true, ">=": true}

static var _op_cache: Dictionary = {}
static var _op_exprs: Dictionary = {}
static var _object_sample: RefCounted = null


static func release_statics() -> void:
	_object_sample = null


static func operator_problem(op: String, left_t: GateAST._TypeRef, right_t: GateAST._TypeRef,
		unary: bool, infer = null) -> String:
	var ls: Array = _alternatives(left_t)
	var rs: Array = [null] if unary else _alternatives(right_t)
	for l in ls:
		for r in rs:
			if _defined(op, l, r, unary, infer) == NO:
				if unary:
					return "%s%s" % [op, describe(l)]
				return "%s %s %s" % [describe(l), op, describe(r) if r != null else "its operand"]
	return ""


static func _alternatives(t: GateAST._TypeRef) -> Array:
	if t != null and t.is_union() and t.array_depth == 0:
		return flat_members(t)
	return [t]


static func _defined(op: String, l: GateAST._TypeRef, r: GateAST._TypeRef, unary: bool, infer) -> int:
	var ls: Array = _sample(l, infer)
	if ls.is_empty():
		return UNKNOWN
	if unary:
		return YES if _evaluates("%sa" % op, [ls[0]]) else NO
	var rs: Array = _sample(r, infer)
	if rs.is_empty():
		for probe in _universe():
			if _evaluates("a %s b" % op, [ls[0], probe]):
				return YES
		return NO
	return YES if _evaluates("a %s b" % op, [ls[0], rs[0]]) else NO


## Godot decides which operators a type supports: run it on a sample value.
static func _evaluates(src: String, values: Array) -> bool:
	var key: String = "%s|%s" % [src, ",".join(values.map(func(v): return str(typeof(v))))]
	if _op_cache.has(key):
		return _op_cache[key]
	if not _op_exprs.has(src):
		var ex: Expression = Expression.new()
		ex.parse(src, PackedStringArray(["a", "b"]) if values.size() == 2 else PackedStringArray(["a"]))
		_op_exprs[src] = ex
	var e: Expression = _op_exprs[src]
	e.execute(values, null, false)
	var ok: bool = not e.has_execute_failed()
	_op_cache[key] = ok
	return ok


static func _sample(t: GateAST._TypeRef, infer) -> Array:
	if t == null:
		return []
	if t.array_depth > 0 or t.is_tuple():
		return [[1]]
	if t.is_dict():
		return [{1: 1}]
	var n: String = GateTypes.canonical(t.name)
	match n:
		"int": return [3]
		"float": return [2.5]
		"bool": return [true]
		"String": return ["%s"]   # a placeholder, so `%` formats rather than fails
		"StringName": return [&"%s"]
		"NodePath": return [^"a"]
		"Vector2": return [Vector2(1, 2)]
		"Vector2i": return [Vector2i(1, 2)]
		"Vector3": return [Vector3(1, 2, 3)]
		"Vector3i": return [Vector3i(1, 2, 3)]
		"Vector4": return [Vector4(1, 2, 3, 4)]
		"Vector4i": return [Vector4i(1, 2, 3, 4)]
		"Color": return [Color(0.5, 0.5, 0.5)]
		"Rect2": return [Rect2(1, 1, 2, 2)]
		"Rect2i": return [Rect2i(1, 1, 2, 2)]
		"Transform2D": return [Transform2D()]
		"Transform3D": return [Transform3D()]
		"Basis": return [Basis()]
		"Quaternion": return [Quaternion()]
		"AABB": return [AABB()]
		"Plane": return [Plane()]
		"Projection": return [Projection()]
		"Callable": return [Callable()]
		"Array": return [[1]]
		"Dictionary": return [{1: 1}]
	if PACKED_ARRAYS.has(n):
		return [_packed_sample(n)]
	if _category(t, infer) == "object":
		if _object_sample == null:
			_object_sample = RefCounted.new()
		return [_object_sample]
	return []


static func _universe() -> Array:
	return [3, 2.5, true, "s", &"s", ^"a", Vector2(1, 2), Vector2i(1, 2), Vector3(1, 2, 3),
		Vector3i(1, 2, 3), Vector4(1, 2, 3, 4), Vector4i(1, 2, 3, 4), Quaternion(), Basis(),
		Transform2D(), Transform3D(), Rect2(1, 1, 2, 2), Rect2i(1, 1, 2, 2), Plane(), Projection(),
		Color(0.5, 0.5, 0.5), AABB(), [1], {1: 1}, PackedInt32Array([1]), PackedFloat32Array([1.0]),
		PackedStringArray(["s"]), PackedVector2Array([Vector2(1, 2)]),
		PackedVector3Array([Vector3(1, 2, 3)]), PackedColorArray([Color(1, 1, 1)]),
		PackedByteArray([1])]


static func _packed_sample(n: String) -> Variant:
	match n:
		"PackedByteArray": return PackedByteArray([1])
		"PackedInt32Array": return PackedInt32Array([1])
		"PackedInt64Array": return PackedInt64Array([1])
		"PackedFloat32Array": return PackedFloat32Array([1.0])
		"PackedFloat64Array": return PackedFloat64Array([1.0])
		"PackedStringArray": return PackedStringArray(["s"])
		"PackedVector2Array": return PackedVector2Array([Vector2(1, 2)])
		"PackedVector3Array": return PackedVector3Array([Vector3(1, 2, 3)])
		"PackedVector4Array": return PackedVector4Array([Vector4(1, 2, 3, 4)])
		"PackedColorArray": return PackedColorArray([Color(1, 1, 1)])
	return PackedInt32Array([1])


static func _is_variant(t: GateAST._TypeRef) -> bool:
	return t.array_depth == 0 and not t.is_dict() and not t.is_union() and not t.is_tuple() \
		and (t.name == "" or GateTypes.canonical(t.name) == "Variant")

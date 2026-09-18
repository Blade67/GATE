@tool
class_name GateTypes
extends RefCounted

## Type shorthands, Packed promotion, and struct lowering rules.

const SHORTHAND := {
	"str": "String",
	"vec2": "Vector2", "vec2i": "Vector2i",
	"vec3": "Vector3", "vec3i": "Vector3i",
	"vec4": "Vector4", "vec4i": "Vector4i",
	"rect2": "Rect2", "rect2i": "Rect2i",
	"quat": "Quaternion",
	"xform2d": "Transform2D", "xform3d": "Transform3D",
	"color": "Color", "aabb": "AABB", "plane": "Plane",
	"basis": "Basis", "proj": "Projection",
	"nodepath": "NodePath", "rid": "RID",
	"sname": "StringName",
	"any": "Variant",
	# GDScript has no 32-bit scalar. These names pick a storage lowering, which is
	# the only place the width is observable. `f64`/`i64` opt out of it.
	"f32": "float", "i32": "int",
	"f64": "float", "i64": "int",
}

const BUILTIN := {
	"int": true, "float": true, "bool": true, "String": true, "Variant": true,
	"Vector2": true, "Vector2i": true, "Vector3": true, "Vector3i": true,
	"Vector4": true, "Vector4i": true, "Rect2": true, "Rect2i": true,
	"Transform2D": true, "Transform3D": true, "Quaternion": true, "Basis": true,
	"Color": true, "AABB": true, "Plane": true, "Projection": true,
	"NodePath": true, "StringName": true, "RID": true, "Callable": true,
	"Signal": true, "Array": true, "Dictionary": true,
}

const PACKED := {
	"int": "PackedInt32Array",
	"float": "PackedFloat32Array",
	"i32": "PackedInt32Array",
	"f32": "PackedFloat32Array",
	"i64": "PackedInt64Array",
	"f64": "PackedFloat64Array",
	"String": "PackedStringArray",
	"Vector2": "PackedVector2Array",
	"Vector3": "PackedVector3Array",
	"Vector4": "PackedVector4Array",
	"Color": "PackedColorArray",
	"byte": "PackedByteArray",
}

const VECTOR_FLOAT := {2: "Vector2", 3: "Vector3", 4: "Vector4"}
const VECTOR_INT := {2: "Vector2i", 3: "Vector3i", 4: "Vector4i"}


## Shorthand names the file or the project declares itself: a `class vec2` means that
## class, as it does in GDScript. Set for each file before it is parsed.
static var shadowed: Dictionary = {}


static func shadow_declared(tokens: Array, class_names: Dictionary = {}) -> void:
	shadowed = {}
	for i in tokens.size() - 1:
		var t: GateLexer._Token = tokens[i]
		if t.type != GateLexer._T.KEYWORD:
			continue
		if t.value in ["class", "class_name", "enum", "const", "struct", "interface", "trait", "namespace"]:
			var nx: GateLexer._Token = tokens[i + 1]
			if nx.type == GateLexer._T.IDENT and SHORTHAND.has(nx.value):
				shadowed[nx.value] = true
	for cn in class_names:
		if SHORTHAND.has(cn):
			shadowed[cn] = true
	for entry in ProjectSettings.get_global_class_list():
		if SHORTHAND.has(String(entry["class"])):
			shadowed[String(entry["class"])] = true


static func is_shorthand(name: String) -> bool:
	return SHORTHAND.has(name) and not shadowed.has(name)


static func canonical(name: String) -> String:
	if shadowed.has(name):
		return name
	return SHORTHAND.get(name, name)


static func packed_for(elem: String) -> String:
	if PACKED.has(elem):
		return PACKED[elem]
	return PACKED.get(canonical(elem), "")


static func has_packed(elem: String) -> bool:
	return PACKED.has(elem) or PACKED.has(canonical(elem))


static func is_gd_nullable(mapped: String) -> bool:
	if mapped == "" or mapped == "Variant":
		return true
	if mapped.begins_with("Array[") or mapped.begins_with("Dictionary["):
		return false
	return not BUILTIN.has(mapped)


static func resolve(t: GateAST._TypeRef, diags: GateDiagnostics = null, packed_hint := false) -> String:
	var mapped: String = _resolve_core(t, diags, packed_hint)
	if t != null and t.nullable and not is_gd_nullable(mapped):
		return "Variant"
	return mapped


static func _resolve_core(t: GateAST._TypeRef, diags: GateDiagnostics, packed_hint: bool) -> String:
	if t == null:
		return ""

	if t.is_path_literal:
		return t.name

	if t.is_set():
		if diags:
			diags.warn("set types are reserved but not supported by GDScript; using Dictionary",
				t.line, t.col, "proposal #867 would add a real Set primitive")
		return "Dictionary"

	if t.is_dict():
		var k: String = resolve(t.dict_key, diags)
		var v: String = _resolve_nested(t.dict_value, diags)
		if v == "":
			if diags:
				diags.warn("nested collection value has no Packed equivalent; inner type left unenforced",
					t.line, t.col, "GDScript cannot express nested typed collections (proposal #12224)")
			v = _outer_only(t.dict_value)
		return "Dictionary[%s, %s]" % [k, v]

	var base: String = canonical(t.name)

	if not t.generic_args.is_empty() and base == "Array" and t.generic_args.size() == 1:
		return _resolve_core(_arrayed_arg(t), diags, packed_hint)
	if not t.generic_args.is_empty() and base == "Dictionary" and t.generic_args.size() == 2:
		var dv: String = _resolve_nested(t.generic_args[1], diags)
		if dv == "":
			if diags:
				diags.warn("nested collection value has no Packed equivalent; inner type left unenforced",
					t.line, t.col, "GDScript cannot express nested typed collections (proposal #12224)")
			dv = _outer_only(t.generic_args[1])
		return "Dictionary[%s, %s]" % [resolve(t.generic_args[0], diags), dv]
	if not t.generic_args.is_empty() and (base == "Array" or base == "Dictionary"):
		var parts: PackedStringArray = PackedStringArray()
		for g in t.generic_args:
			parts.append(resolve(g, diags))
		return "%s[%s]" % [base, ", ".join(parts)]

	if t.array_depth > 0:
		var elem: String = base
		var raw_elem: String = t.name
		var out: String = elem
		for level in range(t.array_depth):
			if level == 0:
				if packed_hint and has_packed(raw_elem):
					out = packed_for(raw_elem)
				else:
					out = "Array[%s]" % elem
			elif level == 1:
				var inner: String = _packed_of_annotation(out, raw_elem if has_packed(raw_elem)
					else elem, diags, t)
				out = "Array[%s]" % inner
			else:
				out = "Array[Array]"
		return out

	return base


static func _arrayed_arg(t: GateAST._TypeRef) -> GateAST._TypeRef:
	var arg: GateAST._TypeRef = GateChecker.copy_type(t.generic_args[0])
	arg.at(t.line, t.col)
	arg.array_depth += 1 + t.array_depth
	arg.nullable = t.nullable
	return arg


static func _resolve_nested(t: GateAST._TypeRef, diags: GateDiagnostics) -> String:
	if t == null:
		return "Variant"
	if t.is_dict() or t.is_set():
		return ""
	if t.array_depth > 0:
		var elem: String = t.name if has_packed(t.name) else canonical(t.name)
		if t.array_depth == 1 and has_packed(elem):
			return packed_for(elem)
		return ""
	return canonical(t.name)


static func _outer_only(t: GateAST._TypeRef) -> String:
	if t == null:
		return "Variant"
	if t.is_dict():
		return "Dictionary"
	if t.array_depth > 0:
		return "Array"
	return canonical(t.name)


static func _packed_of_annotation(current: String, elem: String, diags: GateDiagnostics, t: GateAST._TypeRef) -> String:
	if has_packed(elem):
		return packed_for(elem)
	if diags:
		diags.warn("nested array of '%s' has no Packed equivalent; inner type left unenforced" % elem,
			t.line, t.col,
			"GDScript cannot express Array[Array[T]] (proposal #12224). Emitting Array[Array].")
	return "Array"


static func default_value(t: GateAST._TypeRef) -> String:
	if t == null:
		return ""
	if t.nullable:
		return "null"
	if t.is_union() and t.array_depth == 0:
		return default_value(t.union_members[0])
	if t.is_tuple() and t.array_depth == 0:
		var elems: PackedStringArray = PackedStringArray()
		for te in t.tuple_elems:
			elems.append(default_value(te))
		return "[%s]" % ", ".join(elems)
	if t.is_dict() or t.is_set():
		return "{}"
	if t.array_depth > 0:
		return "[]"
	var base: String = canonical(t.name)
	if not t.generic_args.is_empty():
		if base == "Array":
			return "[]"
		if base == "Dictionary":
			return "{}"
	match base:
		"int": return "0"
		"float": return "0.0"
		"bool": return "false"
		"String": return "\"\""
		"StringName": return "&\"\""
		"Vector2": return "Vector2.ZERO"
		"Vector2i": return "Vector2i.ZERO"
		"Vector3": return "Vector3.ZERO"
		"Vector3i": return "Vector3i.ZERO"
		"Vector4": return "Vector4.ZERO"
		"Vector4i": return "Vector4i.ZERO"
		"Color": return "Color()"
		"Array": return "[]"
		"Dictionary": return "{}"
		"Variant": return "null"
	if PACKED.values().has(base):
		return base + "()"
	if BUILTIN.has(base):
		return base + "()"
	return "null"

const NARROWABLE_FLOAT := {"float": true, "f32": true}
const NARROWABLE_INT := {"int": true, "i32": true}


static func struct_field_kind(tr) -> String:
	if tr == null:
		return "Variant"
	var t: GateAST._TypeRef = tr
	if t.array_depth != 0 or t.is_dict() or t.is_set() or t.is_union() or t.is_tuple() \
			or t.is_func_type or not t.generic_args.is_empty():
		return ""
	return t.name


static func struct_lowering(field_types: Array) -> Dictionary:
	var n: int = field_types.size()
	if n < 2 or n > 4:
		return {"kind": "class", "vector": ""}
	var all_float: bool = true
	var all_int: bool = true
	for ft in field_types:
		if not NARROWABLE_FLOAT.has(String(ft)):
			all_float = false
		if not NARROWABLE_INT.has(String(ft)):
			all_int = false
	if all_float:
		return {"kind": "vector", "vector": VECTOR_FLOAT[n]}
	if all_int:
		return {"kind": "vector", "vector": VECTOR_INT[n]}
	return {"kind": "class", "vector": ""}


static func narrows_width(elem: String) -> bool:
	return elem == "float" or elem == "int"

const VECTOR_COMPONENTS := ["x", "y", "z", "w"]

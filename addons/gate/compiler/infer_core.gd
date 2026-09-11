@tool
extends RefCounted

## Static type inference: tables, lookup, and `type_of`. Returns null whenever it
## cannot be sure, and every caller treats null as unknown.

var fields: Dictionary = {}
var static_fields: Dictionary = {}
var methods: Dictionary = {}
var bases: Dictionary = {}
var module_functions: Dictionary = {}
var struct_names: Dictionary = {}
var untyped_fields: Dictionary = {}
var open_types: Dictionary = {}
var implements: Dictionary = {}
var accessor_fields: Dictionary = {}

var _accessor_re: RegEx = RegEx.create_from_string("(^|[\\s,:])(set|get)\\s*[(=:]")


func accessor_kinds(vd: GateAST.VarDecl) -> Dictionary:
	var out: Dictionary = {}
	for a in vd.annotations:
		if (a as GateAST.Annotation).name == "observable":
			out["set"] = true
	var text: String = vd.setter + "\n" + vd.inline_accessors
	if text.strip_edges() != "":
		for line in text.split("\n"):
			for rm in _accessor_re.search_all(String(line).strip_edges()):
				out[rm.get_string(2)] = true
	if out.is_empty():
		return out
	return {"get": out.has("get"), "set": out.has("set")}


func _note_implements(cd: GateAST.ClassDecl) -> void:
	var names: Array = []
	for n in cd.interface_names + cd.implements + cd.traits:
		if not names.has(n):
			names.append(n)
	if not names.is_empty():
		implements[cd.name] = names


func implements_type(cls: String, iface: String) -> bool:
	return cls != iface and implements_interface(cls, iface)
var member_names: Dictionary = {}
var signals: Dictionary = {}          ## "Class.name" -> SignalDecl
var generic_params: Dictionary = {}   ## generic template name -> its parameter names

const MODULE_CLASS := "@module"


func _index_member_names(members: Array, owner: String) -> void:
	for m in members:
		if m is GateAST.FuncDecl:
			member_names["%s.%s" % [owner, (m as GateAST.FuncDecl).name]] = true
		elif m is GateAST.VarDecl:
			member_names["%s.%s" % [owner, (m as GateAST.VarDecl).name]] = true
		elif m is GateAST.SignalDecl:
			member_names["%s.%s" % [owner, (m as GateAST.SignalDecl).name]] = true
			signals["%s.%s" % [owner, (m as GateAST.SignalDecl).name]] = m
		elif m is GateAST.EnumDecl:
			var ed: GateAST.EnumDecl = m
			if ed.name != "":
				member_names["%s.%s" % [owner, ed.name]] = true
			else:
				for k in ed.keys:
					member_names["%s.%s" % [owner, k]] = true
		elif m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
			member_names["%s.%s" % [owner, cd.name]] = true
			_index_member_names(cd.members, cd.name)


func has_member(cls: String, name: String) -> int:
	_ensure_member_names()
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c):
		seen[c] = true
		if c != MODULE_CLASS and ClassDB.class_exists(c):
			if ClassDB.class_has_method(c, name) or ClassDB.class_has_signal(c, name) \
					or ClassDB.class_has_integer_constant(c, name):
				return 1
			if name == "free":
				return 0 if (c == "RefCounted" or ClassDB.is_parent_class(c, "RefCounted")) else 1
			for p in ClassDB.class_get_property_list(c):
				if String(p["name"]) == name:
					return 1
			return 0
		if member_names.has("%s.%s" % [c, name]):
			return 1
		if not has_class(c):
			return -1
		c = String(bases.get(c, "RefCounted"))
	return -1


func emitted_member(cls: String, name: String) -> String:
	_ensure_member_names()
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c):
		seen[c] = true
		if c != MODULE_CLASS and ClassDB.class_exists(c):
			return name
		if struct_names.has(c) and (struct_names[c] as GateAST.ClassDecl).lowering == "vector":
			var fields: Array = []
			for f in GateChecker.struct_fields(struct_names[c]):
				fields.append((f as GateAST.VarDecl).name)
			var at: int = fields.find(name)
			return name if at < 0 else String(GateTypes.VECTOR_COMPONENTS[at])
		var fns: Array = methods.get("%s.%s" % [c, name], [])
		if fns.size() > 1:
			var mangled: Array = []
			for fd in fns:
				var m: String = (fd as GateAST.FuncDecl).mangled_name
				mangled.append(m if m != "" else name)
			mangled.sort()
			return ",".join(PackedStringArray(mangled))
		if fns.size() == 1:
			var one: String = (fns[0] as GateAST.FuncDecl).mangled_name
			if one != "":
				return one
		if priv_members.has("%s.%s" % [c, name]):
			return "_" + name
		if member_names.has("%s.%s" % [c, name]):
			return name
		if not _class_index.has(c):
			return ""
		c = String(bases.get(c, "RefCounted"))
	return ""


var priv_members: Dictionary = {}     ## "Class.name" -> true for a `priv` member


func _index(members: Array, owner: String) -> void:
	_class_index[owner] = true
	for m in members:
		if (m is GateAST.FuncDecl or m is GateAST.VarDecl) and m.visibility == "priv" \
				and not String(m.name).begins_with("_"):
			priv_members["%s.%s" % [owner, m.name]] = true
		if m is GateAST.FuncDecl:
			var key: String = "%s.%s" % [owner, (m as GateAST.FuncDecl).name]
			if not methods.has(key):
				methods[key] = []
			methods[key].append(m)
		elif m is GateAST.VarDecl:
			var vd: GateAST.VarDecl = m
			if vd.type != null:
				fields["%s.%s" % [owner, vd.name]] = vd.type
				if vd.is_static:
					static_fields["%s.%s" % [owner, vd.name]] = vd.type
		elif m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
			if cd.extends_type != null:
				bases[cd.name] = cd.extends_type.name
			_index(cd.members, cd.name)


func _lookup(table: Dictionary, cls: String, key_suffix: String):
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c):
		seen[c] = true
		var k: String = "%s.%s" % [c, key_suffix]
		if table.has(k):
			return table[k]
		c = bases.get(c, "")
	return null


func field_type(cls: String, field: String) -> GateAST.TypeRef:
	var t = _lookup(fields, cls, field)
	return t if t is GateAST.TypeRef else null

const CALLABLE_INVOKERS := ["call", "callv", "rpc", "rpc_id", "emit"]

const SYNC_HIGHER_ORDER := {
	"map": true, "filter": true, "reduce": true, "any": true, "all": true,
	"sort_custom": true, "bsearch_custom": true, "apply": true,
}

const OPAQUE_ENGINE_METHODS := {
	"set": true, "set_deferred": true, "set_indexed": true, "set_script": true,
	"call": true, "callv": true, "call_deferred": true, "call_thread_safe": true,
	"emit_signal": true, "notification": true, "rpc": true, "rpc_id": true,
}


func engine_root(cls: String) -> String:
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c):
		seen[c] = true
		if c != MODULE_CLASS and ClassDB.class_exists(c):
			return c
		c = String(bases.get(c, ""))
	return "RefCounted"


func is_engine_method(engine_base: String, name: String) -> bool:
	if engine_base == "" or OPAQUE_ENGINE_METHODS.has(name):
		return false
	if not ClassDB.class_exists(engine_base):
		return false
	return ClassDB.class_has_method(engine_base, name)


func method_candidates(cls: String, name: String) -> Array:
	var out: Array = []
	var arities: Dictionary = {}
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c):
		seen[c] = true
		var here = methods.get("%s.%s" % [c, name], null)
		if here is Array:
			for f in here:
				var fd: GateAST.FuncDecl = f
				var n: int = fd.params.size()
				if arities.has(n):
					continue
				arities[n] = true
				out.append(fd)
		c = bases.get(c, "")
	return out

const PACKED_ELEM := {
	"PackedInt32Array": "int", "PackedInt64Array": "int",
	"PackedFloat32Array": "float", "PackedFloat64Array": "float",
	"PackedStringArray": "String", "PackedVector2Array": "Vector2",
	"PackedVector3Array": "Vector3", "PackedVector4Array": "Vector4",
	"PackedColorArray": "Color", "PackedByteArray": "int",
}


static func maybe_null(t: GateAST.TypeRef, base_may_be_null: bool) -> GateAST.TypeRef:
	if not base_may_be_null or (t != null and t.nullable):
		return t
	if t == null:
		var any: GateAST.TypeRef = GateAST.TypeRef.new()
		any.name = "Variant"
		any.nullable = true
		return any
	var c: GateAST.TypeRef = GateChecker.copy_type(t)
	c.nullable = true
	return c


func element_type(t: GateAST.TypeRef) -> GateAST.TypeRef:
	if t == null:
		return null
	if t.is_dict():
		return t.dict_value
	if t.array_depth > 0:
		var inner: GateAST.TypeRef = GateAST.TypeRef.new()
		inner.name = t.name
		inner.array_depth = t.array_depth - 1
		inner.generic_args = t.generic_args
		inner.elem_nullable = t.elem_nullable
		inner.nullable = t.elem_nullable and t.array_depth == 1
		return inner
	var base: String = GateTypes.canonical(t.name)
	if PACKED_ELEM.has(base):
		return _named(PACKED_ELEM[base])
	if (base == "Array" or base == "Dictionary") and not t.generic_args.is_empty():
		return t.generic_args[t.generic_args.size() - 1]
	return null


func has_class(cls: String) -> bool:
	if bases.has(cls):
		return true
	for k in fields:
		if String(k).begins_with(cls + "."):
			return true
	for k in methods:
		if String(k).begins_with(cls + "."):
			return true
	return false


func _method_ref(n: String, locals: Dictionary) -> GateAST.FuncDecl:
	var self_t: Variant = locals.get("self", null)
	var cands: Array = []
	if self_t is GateAST.TypeRef:
		var cls: String = (self_t as GateAST.TypeRef).name
		cands = method_candidates(cls, n)
		if cands.is_empty() and (cls != MODULE_CLASS or _declares(cls, n)):
			return null
	if cands.is_empty():
		cands = module_functions.get(n, [])
	return cands[0] if cands.size() == 1 else null


func _declares(cls: String, n: String) -> bool:
	_ensure_member_names()
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c):
		seen[c] = true
		if member_names.has("%s.%s" % [c, n]):
			return true
		c = String(bases.get(c, ""))
	return false


func tuple_element(t: GateAST.TypeRef, index) -> GateAST.TypeRef:
	var i: int = -1
	if index is GateAST.Literal and (index as GateAST.Literal).kind == "number" \
			and (index as GateAST.Literal).raw.is_valid_int():
		i = int((index as GateAST.Literal).raw)
	elif index is GateAST.Unary and (index as GateAST.Unary).op == "-" \
			and (index as GateAST.Unary).operand is GateAST.Literal \
			and ((index as GateAST.Unary).operand as GateAST.Literal).raw.is_valid_int():
		i = t.tuple_elems.size() - int(((index as GateAST.Unary).operand as GateAST.Literal).raw)
	if i < 0 or i >= t.tuple_elems.size():
		return null
	return t.tuple_elems[i]


func implements_interface(cls: String, iface: String) -> bool:
	var seen: Dictionary = {}
	var queue: Array = [cls]
	while not queue.is_empty():
		var c: String = queue.pop_front()
		if c == "" or seen.has(c):
			continue
		seen[c] = true
		if c == iface:
			return true
		queue.append_array(implements.get(c, []))
		queue.append(String(bases.get(c, "")))
	return false


func has_class(cls: String) -> bool:
	return bases.has(cls) or _class_index.has(cls)


var _class_index: Dictionary = {}
var _ref_names: Dictionary = {}

var _names_built: bool = false
var _names_mod: GateAST.Module = null
var _names_registry: Variant = null


func _ensure_member_names() -> void:
	if _names_built:
		return
	_names_built = true
	if _names_registry != null:
		var scripts: Dictionary = _names_registry.script_class_decls \
			if "script_class_decls" in _names_registry else {}
		for table in [_names_registry.classes, _names_registry.structs,
				_names_registry.namespaces, _names_registry.generics, scripts]:
			for cname in table:
				_index_member_names((table[cname] as GateAST.ClassDecl).members, String(cname))
	if _names_mod != null:
		_index_member_names(_names_mod.members, MODULE_CLASS)


func type_of(e, locals: Dictionary) -> GateAST.TypeRef:
	if e == null:
		return null

	if e is GateAST.Ident:
		var n: String = (e as GateAST.Ident).name
		if locals.has(n):
			return locals[n]
		return null

	if e is GateAST.SelfExpr:
		return locals.get("self", null)

	if e is GateAST.Literal:
		var lit: GateAST.Literal = e
		return _prim(lit.kind)

	if e is GateAST.ObjectInit:
		return (e as GateAST.ObjectInit).type

	if e is GateAST.CastExpr:
		return (e as GateAST.CastExpr).type

	if e is GateAST.FString:
		return _named("String")

	if e is GateAST.ArrayLit:
		return _named("Array")

	if e is GateAST.DictLit:
		return _named("Dictionary")

	if e is GateAST.NullCoalesce:
		return type_of((e as GateAST.NullCoalesce).right, locals)

	if e is GateAST.AwaitExpr:
		return null

	if e is GateAST.Index:
		var ix: GateAST.Index = e
		var target_t: GateAST.TypeRef = type_of(ix.target, locals)
		var ix_null: bool = ix.safe and target_t != null and target_t.nullable
		if target_t != null and target_t.is_tuple() and target_t.array_depth == 0:
			return maybe_null(tuple_element(target_t, ix.index), ix_null)
		return maybe_null(element_type(target_t), ix_null)

	if e is GateAST.Lambda:
		var lam: GateAST.Lambda = e
		var ct: GateAST.TypeRef = _named("Callable")
		ct.callable_return = lam.return_type
		return ct

	if e is GateAST.Member:
		var m: GateAST.Member = e
		var base: GateAST.TypeRef = type_of(m.target, locals)
		if base == null or base.array_depth > 0 or base.is_dict():
			return null
		return field_type(base.name, m.name)

	if e is GateAST.Call:
		var c: GateAST.Call = e
		if c.callee is GateAST.Member:
			var cm: GateAST.Member = c.callee
			if cm.name == "new" and cm.target is GateAST.Ident:
				return _named((cm.target as GateAST.Ident).name)
			var recv: GateAST.TypeRef = type_of(cm.target, locals)
			if recv != null and cm.name in ["call", "callv", "bind"] and GateTypes.canonical(recv.name) == "Callable":
				return recv.callable_return
			if recv != null and recv.array_depth == 0 and not recv.is_dict():
				var cands: Array = method_candidates(recv.name, cm.name)
				var fd: GateAST.FuncDecl = _pick(cands, c.args.size())
				if fd != null:
					return fd.return_type
			return null
		if c.callee is GateAST.Ident:
			var fname: String = (c.callee as GateAST.Ident).name
			var fd2: GateAST.FuncDecl = _pick(module_functions.get(fname, []), c.args.size())
			if fd2 != null:
				return fd2.return_type
			return null
		return null

	return null


func _pick(cands: Array, arity: int) -> GateAST.FuncDecl:
	for f in cands:
		var fd: GateAST.FuncDecl = f
		var required: int = 0
		var has_rest: bool = false
		for p in fd.params:
			var pp: GateAST.Param = p
			if pp.is_rest: has_rest = true
			elif pp.default == null: required += 1
		if arity >= required and (has_rest or arity <= fd.params.size()):
			return fd
	return null


func _prim(kind: String) -> GateAST.TypeRef:
	match kind:
		"number": return _named("int")
		"string": return _named("String")
		"bool": return _named("bool")
	return null


func _named(n: String) -> GateAST.TypeRef:
	var t: GateAST.TypeRef = GateAST.TypeRef.new()
	t.name = GateTypes.canonical(n)
	return t

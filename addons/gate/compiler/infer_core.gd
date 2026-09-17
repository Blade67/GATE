@tool
extends RefCounted

## Static type inference: tables, lookup, and `type_of`. Returns null whenever it
## cannot be sure, and every caller treats null as unknown.

var fields: Dictionary = {}
var static_fields: Dictionary = {}
var methods: Dictionary = {}
var bases: Dictionary = {}
var module_functions: Dictionary = {}

const MODULE_CLASS := "@module"


func _index(members: Array, owner: String) -> void:
	for m in members:
		if m is GateAST.GateFuncDecl:
			var key: String = "%s.%s" % [owner, (m as GateAST.GateFuncDecl).name]
			if not methods.has(key):
				methods[key] = []
			methods[key].append(m)
		elif m is GateAST.GateVarDecl:
			var vd: GateAST.GateVarDecl = m
			if vd.type != null:
				fields["%s.%s" % [owner, vd.name]] = vd.type
				if vd.is_static:
					static_fields["%s.%s" % [owner, vd.name]] = vd.type
		elif m is GateAST.GateClassDecl:
			var cd: GateAST.GateClassDecl = m
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


func field_type(cls: String, field: String) -> GateAST.GateTypeRef:
	var t = _lookup(fields, cls, field)
	return t if t is GateAST.GateTypeRef else null

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
				var fd: GateAST.GateFuncDecl = f
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


func element_type(t: GateAST.GateTypeRef) -> GateAST.GateTypeRef:
	if t == null:
		return null
	if t.is_dict():
		return t.dict_value
	if t.array_depth > 0:
		var inner: GateAST.GateTypeRef = GateAST.GateTypeRef.new()
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


func type_of(e, locals: Dictionary) -> GateAST.GateTypeRef:
	if e == null:
		return null

	if e is GateAST.GateIdent:
		var n: String = (e as GateAST.GateIdent).name
		if locals.has(n):
			return locals[n]
		return null

	if e is GateAST.GateSelfExpr:
		return locals.get("self", null)

	if e is GateAST.GateLiteral:
		var lit: GateAST.GateLiteral = e
		return _prim(lit.kind)

	if e is GateAST.GateObjectInit:
		return (e as GateAST.GateObjectInit).type

	if e is GateAST.GateCastExpr:
		return (e as GateAST.GateCastExpr).type

	if e is GateAST.GateFString:
		return _named("String")

	if e is GateAST.GateArrayLit:
		return _named("Array")

	if e is GateAST.GateDictLit:
		return _named("Dictionary")

	if e is GateAST.GateNullCoalesce:
		return type_of((e as GateAST.GateNullCoalesce).right, locals)

	if e is GateAST.GateAwaitExpr:
		return null

	if e is GateAST.GateIndex:
		var ix: GateAST.GateIndex = e
		return element_type(type_of(ix.target, locals))

	if e is GateAST.GateLambda:
		var lam: GateAST.GateLambda = e
		var ct: GateAST.GateTypeRef = _named("Callable")
		ct.callable_return = lam.return_type
		return ct

	if e is GateAST.GateMember:
		var m: GateAST.GateMember = e
		var base: GateAST.GateTypeRef = type_of(m.target, locals)
		if base == null or base.array_depth > 0 or base.is_dict():
			return null
		return field_type(base.name, m.name)

	if e is GateAST.GateCall:
		var c: GateAST.GateCall = e
		if c.callee is GateAST.GateMember:
			var cm: GateAST.GateMember = c.callee
			if cm.name == "new" and cm.target is GateAST.GateIdent:
				return _named((cm.target as GateAST.GateIdent).name)
			var recv: GateAST.GateTypeRef = type_of(cm.target, locals)
			if recv != null and cm.name in ["call", "callv", "bind"] and GateTypes.canonical(recv.name) == "Callable":
				return recv.callable_return
			if recv != null and recv.array_depth == 0 and not recv.is_dict():
				var cands: Array = method_candidates(recv.name, cm.name)
				var fd: GateAST.GateFuncDecl = _pick(cands, c.args.size())
				if fd != null:
					return fd.return_type
			return null
		if c.callee is GateAST.GateIdent:
			var fname: String = (c.callee as GateAST.GateIdent).name
			var fd2: GateAST.GateFuncDecl = _pick(module_functions.get(fname, []), c.args.size())
			if fd2 != null:
				return fd2.return_type
			return null
		return null

	return null


func _pick(cands: Array, arity: int) -> GateAST.GateFuncDecl:
	for f in cands:
		var fd: GateAST.GateFuncDecl = f
		var required: int = 0
		var has_rest: bool = false
		for p in fd.params:
			var pp: GateAST.GateParam = p
			if pp.is_rest: has_rest = true
			elif pp.default == null: required += 1
		if arity >= required and (has_rest or arity <= fd.params.size()):
			return fd
	return null


func _prim(kind: String) -> GateAST.GateTypeRef:
	match kind:
		"number": return _named("int")
		"string": return _named("String")
		"bool": return _named("bool")
	return null


func _named(n: String) -> GateAST.GateTypeRef:
	var t: GateAST.GateTypeRef = GateAST.GateTypeRef.new()
	t.name = GateTypes.canonical(n)
	return t

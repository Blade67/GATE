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


func accessor_kinds(vd: GateAST._VarDecl) -> Dictionary:
	var out: Dictionary = {}
	for a in vd.annotations:
		if (a as GateAST._Annotation).name == "observable":
			out["set"] = true
	var text: String = vd.setter + "\n" + vd.inline_accessors
	if text.strip_edges() != "":
		for line in text.split("\n"):
			for rm in _accessor_re.search_all(String(line).strip_edges()):
				out[rm.get_string(2)] = true
	if out.is_empty():
		return out
	return {"get": out.has("get"), "set": out.has("set")}


func _note_implements(cd: GateAST._ClassDecl) -> void:
	var names: Array = []
	for n in cd.interface_names + cd.implements + cd.traits:
		if not names.has(n):
			names.append(n)
	if not names.is_empty():
		implements[cd.name] = names


func implements_type(cls: String, iface: String) -> bool:
	return cls != iface and implements_interface(cls, iface)
var member_names: Dictionary = {}
var signals: Dictionary = {}          ## "Class.name" -> _SignalDecl
var generic_params: Dictionary = {}   ## generic template name -> its parameter names

const MODULE_CLASS := "@module"


func _index_member_names(members: Array, owner: String) -> void:
	for m in members:
		if m is GateAST._FuncDecl:
			member_names["%s.%s" % [owner, (m as GateAST._FuncDecl).name]] = true
		elif m is GateAST._VarDecl:
			member_names["%s.%s" % [owner, (m as GateAST._VarDecl).name]] = true
		elif m is GateAST._SignalDecl:
			member_names["%s.%s" % [owner, (m as GateAST._SignalDecl).name]] = true
			signals["%s.%s" % [owner, (m as GateAST._SignalDecl).name]] = m
		elif m is GateAST._EnumDecl:
			var ed: GateAST._EnumDecl = m
			if ed.name != "":
				member_names["%s.%s" % [owner, ed.name]] = true
			else:
				for k in ed.keys:
					member_names["%s.%s" % [owner, k]] = true
		elif m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			member_names["%s.%s" % [owner, cd.name]] = true
			_index_member_names(cd.members, cd.name)


func signal_type(cls: String, name: String) -> GateAST._TypeRef:
	var sd: Variant = _lookup(signals, cls, name)
	if not (sd is GateAST._SignalDecl):
		return null
	var st: GateAST._TypeRef = _named("Signal")
	st.sig_known = true
	for p in (sd as GateAST._SignalDecl).params:
		st.shaped().callable_params.append((p as GateAST._Param).type)
	return st


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
		if struct_names.has(c) and (struct_names[c] as GateAST._ClassDecl).lowering == "vector":
			var fields: Array = []
			for f in GateChecker.struct_fields(struct_names[c]):
				fields.append((f as GateAST._VarDecl).name)
			var at: int = fields.find(name)
			return name if at < 0 else String(GateTypes.VECTOR_COMPONENTS[at])
		var fns: Array = methods.get("%s.%s" % [c, name], [])
		if fns.size() > 1:
			var mangled: Array = []
			for fd in fns:
				var m: String = (fd as GateAST._FuncDecl).mangled_name
				mangled.append(m if m != "" else name)
			mangled.sort()
			return ",".join(PackedStringArray(mangled))
		if fns.size() == 1:
			var one: String = (fns[0] as GateAST._FuncDecl).mangled_name
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
		if (m is GateAST._FuncDecl or m is GateAST._VarDecl) and m.visibility == "priv" \
				and not String(m.name).begins_with("_"):
			priv_members["%s.%s" % [owner, m.name]] = true
		if m is GateAST._FuncDecl:
			var key: String = "%s.%s" % [owner, (m as GateAST._FuncDecl).name]
			if not methods.has(key):
				methods[key] = []
			methods[key].append(m)
			_ref_names[(m as GateAST._FuncDecl).name] = true
		elif m is GateAST._SignalDecl:
			signals["%s.%s" % [owner, (m as GateAST._SignalDecl).name]] = m
			_ref_names[(m as GateAST._SignalDecl).name] = true
		elif m is GateAST._VarDecl:
			var vd: GateAST._VarDecl = m
			if vd.type != null:
				fields["%s.%s" % [owner, vd.name]] = vd.type
				if vd.is_static:
					static_fields["%s.%s" % [owner, vd.name]] = vd.type
			else:
				untyped_fields["%s.%s" % [owner, vd.name]] = true
			var acc: Dictionary = accessor_kinds(vd)
			if not acc.is_empty():
				accessor_fields["%s.%s" % [owner, vd.name]] = acc
		elif m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			_note_implements(cd)
			if cd.form == "struct":
				struct_names[cd.name] = cd
			elif cd.form == "interface" or cd.form == "trait":
				open_types[cd.name] = true
			if cd.extends_type != null:
				bases[cd.name] = cd.extends_type.name
			if not cd.generic_params.is_empty():
				generic_params[cd.name] = cd.generic_params
			_index(cd.members, cd.name)


func subst_generic(t: GateAST._TypeRef, recv: GateAST._TypeRef) -> GateAST._TypeRef:
	if t == null or recv == null or recv.generic_args.is_empty() or not generic_params.has(recv.name):
		return t
	var params: Array = generic_params[recv.name]
	var at: int = params.find(t.name)
	if at < 0 or at >= recv.generic_args.size():
		return t
	var c: GateAST._TypeRef = GateChecker.copy_type(recv.generic_args[at])
	c.at(t.line, t.col)
	if t.array_depth > 0:
		c.elem_nullable = c.elem_nullable or (c.array_depth == 0 and c.nullable) or t.elem_nullable
		c.nullable = t.nullable
		c.array_depth += t.array_depth
	else:
		c.nullable = c.nullable or t.nullable
	return c


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


func static_owner(cls: String, field: String) -> String:
	if static_fields.is_empty():
		return ""
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c):
		seen[c] = true
		if static_fields.has("%s.%s" % [c, field]):
			return c
		if fields.has("%s.%s" % [c, field]):
			return ""
		c = bases.get(c, "")
	return ""


func field_type(cls: String, field: String) -> GateAST._TypeRef:
	var t = _lookup(fields, cls, field)
	return t if t is GateAST._TypeRef else null

const CALLABLE_INVOKERS := ["call", "callv", "rpc", "rpc_id", "emit"]

const FLOAT_CONSTANTS := {"INF": true, "NAN": true}

const SIGNED := {"int": true, "float": true, "Vector2": true, "Vector2i": true,
	"Vector3": true, "Vector3i": true, "Vector4": true, "Vector4i": true}

const CONSTRUCTED := {"int": true, "float": true, "bool": true, "String": true,
	"StringName": true, "NodePath": true, "Vector2": true, "Vector2i": true, "Vector3": true,
	"Vector3i": true, "Vector4": true, "Vector4i": true, "Color": true, "Rect2": true,
	"Rect2i": true, "Transform2D": true, "Transform3D": true, "Basis": true, "Quaternion": true,
	"AABB": true, "Plane": true, "Projection": true, "RID": true, "Callable": true}

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
				var fd: GateAST._FuncDecl = f
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


static func maybe_null(t: GateAST._TypeRef, base_may_be_null: bool) -> GateAST._TypeRef:
	if not base_may_be_null or (t != null and t.nullable):
		return t
	if t == null:
		var any: GateAST._TypeRef = GateAST._TypeRef.new()
		any.name = "Variant"
		any.nullable = true
		return any
	var c: GateAST._TypeRef = GateChecker.copy_type(t)
	c.nullable = true
	return c


func element_type(t: GateAST._TypeRef) -> GateAST._TypeRef:
	if t == null:
		return null
	if t.is_dict():
		return t.dict_value
	if t.array_depth > 0:
		var inner: GateAST._TypeRef = GateChecker.copy_type(t)
		inner.array_depth = t.array_depth - 1
		inner.elem_nullable = t.elem_nullable
		inner.nullable = t.elem_nullable and t.array_depth == 1
		return inner
	var base: String = GateTypes.canonical(t.name)
	if PACKED_ELEM.has(base):
		return _named(PACKED_ELEM[base])
	if (base == "Array" or base == "Dictionary") and not t.generic_args.is_empty():
		return t.generic_args[t.generic_args.size() - 1]
	return null


func signature_of(params: Array, return_type: GateAST._TypeRef) -> GateAST._TypeRef:
	var ct: GateAST._TypeRef = _named("Callable")
	ct.callable_return = return_type
	ct.sig_known = true
	for p in params:
		var pp: GateAST._Param = p
		if pp.is_rest:
			ct.callable_rest = true
			continue
		ct.shaped().callable_params.append(pp.type)
		if pp.default != null:
			ct.callable_optional += 1
	return ct


func _lambda_return(lam: GateAST._Lambda, locals: Dictionary) -> GateAST._TypeRef:
	if lam.return_type != null:
		return lam.return_type
	if lam.body.size() == 1 and lam.body[0] is GateAST._ReturnStmt \
			and (lam.body[0] as GateAST._ReturnStmt).value != null:
		var inner: Dictionary = locals.duplicate()
		for p in lam.params:
			var pp: GateAST._Param = p
			if pp.type != null:
				inner[pp.name] = pp.type
			else:
				inner.erase(pp.name)
		return type_of((lam.body[0] as GateAST._ReturnStmt).value, inner)
	if not _returns_value(lam.body):
		return _shared("void")
	return null


static func _returns_value(body: Array) -> bool:
	for s in body:
		if s is GateAST._ReturnStmt and (s as GateAST._ReturnStmt).value != null:
			return true
		if s is GateAST._IfStmt:
			var ifs: GateAST._IfStmt = s
			if _returns_value(ifs.then_body) or _returns_value(ifs.else_body):
				return true
			for pair in ifs.elifs:
				if _returns_value(pair[1]):
					return true
		elif s is GateAST._ForStmt and _returns_value((s as GateAST._ForStmt).body):
			return true
		elif s is GateAST._WhileStmt and _returns_value((s as GateAST._WhileStmt).body):
			return true
		elif s is GateAST._MatchStmt:
			for br in (s as GateAST._MatchStmt).branches:
				if _returns_value(br[2]):
					return true
		elif s is GateAST._AnnotatedStmt and _returns_value([(s as GateAST._AnnotatedStmt).stmt]):
			return true
	return false


func _method_ref(n: String, locals: Dictionary) -> GateAST._FuncDecl:
	var self_t: Variant = locals.get("self", null)
	var cands: Array = []
	if self_t is GateAST._TypeRef:
		var cls: String = (self_t as GateAST._TypeRef).name
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


func tuple_element(t: GateAST._TypeRef, index) -> GateAST._TypeRef:
	var i: int = -1
	if index is GateAST._Literal and (index as GateAST._Literal).kind == "number" \
			and (index as GateAST._Literal).raw.is_valid_int():
		i = int((index as GateAST._Literal).raw)
	elif index is GateAST._Unary and (index as GateAST._Unary).op == "-" \
			and (index as GateAST._Unary).operand is GateAST._Literal \
			and ((index as GateAST._Unary).operand as GateAST._Literal).raw.is_valid_int():
		i = t.tuple_elems.size() - int(((index as GateAST._Unary).operand as GateAST._Literal).raw)
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
var _names_mod: GateAST._Module = null
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
				_index_member_names((table[cname] as GateAST._ClassDecl).members, String(cname))
	if _names_mod != null:
		_index_member_names(_names_mod.members, MODULE_CLASS)


func _index_signals(members: Array, owner: String) -> void:
	for m in members:
		if m is GateAST._SignalDecl:
			signals["%s.%s" % [owner, (m as GateAST._SignalDecl).name]] = m
			_ref_names[(m as GateAST._SignalDecl).name] = true
		elif m is GateAST._ClassDecl:
			_index_signals((m as GateAST._ClassDecl).members, (m as GateAST._ClassDecl).name)


func type_of(e, locals: Dictionary) -> GateAST._TypeRef:
	if e == null:
		return null

	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		if locals.has(n):
			return locals[n]
		if not _ref_names.has(n):
			return _shared("float") if FLOAT_CONSTANTS.has(n) else null
		var self_t: Variant = locals.get("self", null)
		if self_t is GateAST._TypeRef:
			var sig: GateAST._TypeRef = signal_type((self_t as GateAST._TypeRef).name, n)
			if sig != null:
				return sig
		var ref: GateAST._FuncDecl = _method_ref(n, locals)
		if ref != null:
			return signature_of(ref.params, ref.return_type)
		return null

	if e is GateAST._SelfExpr:
		return locals.get("self", null)

	if e is GateAST._Literal:
		var lit: GateAST._Literal = e
		return _prim(lit.kind, lit.raw)

	if e is GateAST._ObjectInit:
		return (e as GateAST._ObjectInit).type

	if e is GateAST._CastExpr:
		return (e as GateAST._CastExpr).type

	if e is GateAST._FString:
		return _shared("String")

	if e is GateAST._ArrayLit:
		return _shared("Array")

	if e is GateAST._DictLit:
		return _shared("Dictionary")

	if e is GateAST._NullCoalesce:
		var nc: GateAST._NullCoalesce = e
		var nlt: GateAST._TypeRef = type_of(nc.left, locals)
		if nlt == null:
			return null   # an untyped left may hold anything
		return coalesce_type(nlt, type_of(nc.right, locals))

	if e is GateAST._Binary:
		if COMPARISONS.has((e as GateAST._Binary).op):
			return _shared("bool")   # binary_type answers these without the operands
		var spine: Array = []
		var cur = e
		while cur is GateAST._Binary:
			spine.append(cur)   # top down: read back to front for left to right
			cur = (cur as GateAST._Binary).left
		var acc: GateAST._TypeRef = type_of(cur, locals)
		for i in range(spine.size() - 1, -1, -1):
			var b: GateAST._Binary = spine[i]
			acc = binary_type(b.op, acc, null if COMPARISONS.has(b.op) else type_of(b.right, locals))
		return acc

	if e is GateAST._AwaitExpr:
		return null

	if e is GateAST._Index:
		var ix: GateAST._Index = e
		var target_t: GateAST._TypeRef = type_of(ix.target, locals)
		var ix_null: bool = ix.safe and target_t != null and target_t.nullable
		if target_t != null and target_t.is_tuple() and target_t.array_depth == 0:
			return maybe_null(tuple_element(target_t, ix.index), ix_null)
		return maybe_null(element_type(target_t), ix_null)

	if e is GateAST._Lambda:
		var lam: GateAST._Lambda = e
		return signature_of(lam.params, _lambda_return(lam, locals))

	if e is GateAST._Unary:
		var un: GateAST._Unary = e
		if un.op == "not" or un.op == "!":
			return _shared("bool")
		if un.op == "~":
			var nt: GateAST._TypeRef = type_of(un.operand, locals)
			return _shared("int") if nt != null and nt.array_depth == 0 \
				and GateTypes.canonical(nt.name) == "int" else null
		if un.op == "-" or un.op == "+":
			var ot: GateAST._TypeRef = type_of(un.operand, locals)
			if ot != null and ot.array_depth == 0 and SIGNED.has(GateTypes.canonical(ot.name)):
				return ot
		return null

	if e is GateAST._Member:
		var sm: GateAST._Member = e
		var sm_null: bool = false
		if sm.safe:
			var sb: GateAST._TypeRef = type_of(sm.target, locals)
			sm_null = sb != null and sb.nullable
		return maybe_null(_member_type(sm, locals), sm_null)

	if e is GateAST._Call:
		var c: GateAST._Call = e
		if c.callee is GateAST._Member:
			var cm: GateAST._Member = c.callee
			if cm.name == "new" and cm.target is GateAST._Ident:
				var gt: GateAST._TypeRef = (cm.target as GateAST._Ident).generic_type
				if gt != null and generic_params.has(gt.name):
					var inst_t: GateAST._TypeRef = _named(gt.name)
					inst_t.generic_args = gt.generic_args
					return inst_t
				return _named((cm.target as GateAST._Ident).name)
			var recv: GateAST._TypeRef = type_of(cm.target, locals)
			if recv != null and GateTypes.canonical(recv.name) == "Callable":
				if cm.name == "call" or cm.name == "callv":
					return recv.callable_return
				if cm.name == "bind" or cm.name == "unbind":
					return _named("Callable")   # a Callable still, not its result
			if recv != null and cm.name == "instantiate" and recv.array_depth == 0 \
					and GateTypes.canonical(recv.name) == "PackedScene" and recv.generic_args.size() == 1:
				var inst: GateAST._TypeRef = recv.generic_args[0]
				var it: GateAST._TypeRef = _named(inst.name)
				it.generic_args = inst.generic_args
				return it
			if recv != null and recv.array_depth == 0 and not recv.is_dict():
				var cands: Array = method_candidates(recv.name, cm.name)
				var fd: GateAST._FuncDecl = _pick(cands, c.args.size())
				if fd != null:
					return subst_generic(fd.return_type, recv)
			return null
		if c.callee is GateAST._Ident:
			var fname: String = (c.callee as GateAST._Ident).name
			var fd2: GateAST._FuncDecl = _pick(module_functions.get(fname, []), c.args.size())
			if fd2 != null:
				return fd2.return_type
			if struct_names.has(fname) and not locals.has(fname) and not module_functions.has(fname):
				return _named(fname)
			if not locals.has(fname) and not module_functions.has(fname):
				var gr: GateAST._TypeRef = _global_return(fname, c.args, locals)
				if gr != null:
					return gr
			if (CONSTRUCTED.has(fname) or GateTypes.is_shorthand(fname)) \
					and CONSTRUCTED.has(GateTypes.canonical(fname)) \
					and not locals.has(fname) and not module_functions.has(fname):
				return _shared(fname)
			return null
		return null

	return null


const CONSTANT_TYPES := {
	"Vector2": "AXIS_", "Vector2i": "AXIS_", "Vector3": "AXIS_", "Vector3i": "AXIS_",
	"Vector4": "AXIS_", "Vector4i": "AXIS_", "Color": "", "Transform2D": "", "Transform3D": "",
	"Basis": "", "Quaternion": "", "Plane": "", "Projection": "PLANE_",
}


static func builtin_constant_type(type_name: String, cname: String) -> String:
	if GateTypes.shadowed.has(type_name) or cname == "" or cname != cname.to_upper():
		return ""
	var n: String = GateTypes.canonical(type_name)
	if not CONSTANT_TYPES.has(n):
		return ""
	var enum_prefix: String = CONSTANT_TYPES[n]
	if enum_prefix != "" and cname.begins_with(enum_prefix):
		return "int"
	return n


const COMPARISONS := {"==": true, "!=": true, "<": true, ">": true, "<=": true, ">=": true,
	"and": true, "or": true, "&&": true, "||": true, "in": true, "not in": true}
const GLOBAL_RETURNS := {"len": "int", "floori": "int", "ceili": "int", "roundi": "int",
	"absi": "int", "signi": "int", "clampi": "int", "maxi": "int", "mini": "int", "snappedi": "int",
	"floorf": "float", "ceilf": "float", "roundf": "float", "absf": "float", "signf": "float",
	"clampf": "float", "maxf": "float", "minf": "float", "snappedf": "float", "sqrt": "float",
	"pow": "float", "fmod": "float", "sin": "float", "cos": "float", "tan": "float",
	"lerpf": "float", "deg_to_rad": "float", "rad_to_deg": "float", "randf": "float",
	"randi": "int", "hash": "int", "is_equal_approx": "bool", "is_zero_approx": "bool"}
const NUMERIC_JOIN := {"max": true, "min": true, "abs": true, "sign": true, "clamp": true,
	"snapped": true, "wrap": true}


func binary_type(op: String, lt: GateAST._TypeRef, rt: GateAST._TypeRef) -> GateAST._TypeRef:
	if COMPARISONS.has(op):
		return _shared("bool")
	var ln: String = _plain_name(lt)
	var rn: String = _plain_name(rt)
	if op == "%" and ln == "String":
		return _shared("String")
	if ln == "" or rn == "":
		return null
	if op == "+" and (ln == "String" or ln == "StringName") and (rn == "String" or rn == "StringName"):
		return _shared("String")
	var numeric: bool = (ln == "int" or ln == "float") and (rn == "int" or rn == "float")
	if not numeric:
		return null
	if ln == "int" and rn == "int":
		return _shared("int")
	if op in ["+", "-", "*", "/", "**"]:
		return _shared("float")
	return null


func _plain_name(t: GateAST._TypeRef) -> String:
	if t == null or t.array_depth > 0 or t.nullable or t.is_union() or t.is_tuple() or t.is_dict():
		return ""
	return GateTypes.canonical(t.name)


func coalesce_type(lt: GateAST._TypeRef, rt: GateAST._TypeRef) -> GateAST._TypeRef:
	if lt == null or not lt.is_union() or lt.array_depth > 0:
		return rt
	var u: GateAST._TypeRef = GateChecker.copy_type(lt)
	u.nullable = false
	if rt == null or rt.name == "null":
		return u
	for m in GateTypeCompat.flat_members(lt):
		if GateTypeCompat.assignable(rt, m, self, false) == GateTypeCompat.YES:
			return u
	var r: GateAST._TypeRef = GateChecker.copy_type(rt)
	r.nullable = false
	u.shaped().union_members.append(r)
	return u


func _global_return(fname: String, args: Array, locals: Dictionary) -> GateAST._TypeRef:
	if GLOBAL_RETURNS.has(fname):
		return _shared(GLOBAL_RETURNS[fname])
	if not NUMERIC_JOIN.has(fname) or args.is_empty():
		return null
	var all_int: bool = true
	for a in args:
		var n: String = _plain_name(type_of(a, locals))
		if n == "float":
			all_int = false
		elif n != "int":
			return null
	return _shared("int" if all_int else "float")


func _pick(cands: Array, arity: int) -> GateAST._FuncDecl:
	for f in cands:
		var fd: GateAST._FuncDecl = f
		var required: int = 0
		var has_rest: bool = false
		for p in fd.params:
			var pp: GateAST._Param = p
			if pp.is_rest: has_rest = true
			elif pp.default == null: required += 1
		if arity >= required and (has_rest or arity <= fd.params.size()):
			return fd
	return null


func _prim(kind: String, raw: String = "") -> GateAST._TypeRef:
	match kind:
		"number": return _shared("float" if _is_float_literal(raw) else "int")
		"string":
			if raw.begins_with("&"): return _shared("StringName")
			if raw.begins_with("^"): return _shared("NodePath")
			return _shared("String")
		"bool": return _shared("bool")
	return null


static func _is_float_literal(raw: String) -> bool:
	var r: String = raw.lstrip("+-").to_lower()
	if r.begins_with("0x") or r.begins_with("0b"):
		return false
	return r.contains(".") or r.contains("e")


func _named(n: String) -> GateAST._TypeRef:
	var t: GateAST._TypeRef = GateAST._TypeRef.new()
	t.name = GateTypes.canonical(n)
	return t


static var _shared_types: Dictionary = {}


func _shared(n: String) -> GateAST._TypeRef:
	var t: GateAST._TypeRef = _shared_types.get(n, null)
	if t == null:
		t = _named(n)
		_shared_types[n] = t
	return t


func _member_type(e: GateAST._Member, locals: Dictionary) -> GateAST._TypeRef:
	var m: GateAST._Member = e
	if m.target is GateAST._Ident and not locals.has((m.target as GateAST._Ident).name):
		var ct: String = builtin_constant_type((m.target as GateAST._Ident).name, m.name)
		if ct != "":
			return _shared(ct)
	var base: GateAST._TypeRef = type_of(m.target, locals)
	if base == null or base.array_depth > 0 or base.is_dict():
		return null
	var ft: GateAST._TypeRef = field_type(base.name, m.name)
	if ft != null:
		return subst_generic(ft, base)
	if not _ref_names.has(m.name):
		return null
	var st: GateAST._TypeRef = signal_type(base.name, m.name)
	if st != null:
		return st
	var mc: Array = method_candidates(base.name, m.name)
	if mc.size() == 1:
		var mfd: GateAST._FuncDecl = mc[0]
		return signature_of(mfd.params, subst_generic(mfd.return_type, base))
	return null

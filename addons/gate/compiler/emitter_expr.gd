@tool
extends "res://addons/gate/compiler/emitter_types.gd"

## Emitter layer 3: expressions.


func _emit_statement(s) -> void:
	push_error("[GATE] internal: _emit_statement not overridden")


func _is_assigned(n: String) -> bool:
	return true


func _never_holds_struct(n: String, seen: Dictionary) -> bool:
	return false


func _expr(e) -> String:
	if e == null:
		return "null"

	if e is GateAST._Literal:
		return (e as GateAST._Literal).raw
	if e is GateAST._Ident:
		var iname: String = (e as GateAST._Ident).name
		if _ident_renames.has(iname):
			return _ident_renames[iname]
		if _soa_cursors.has(iname):
			diagnostics.error(
				"'%s' is a value view into the @soa array '%s' and cannot be stored"
					% [iname, _soa_cursors[iname]["soa"]], e.line, e.col,
				"@soa keeps each field in its own array, so there is no element object "
				+ "to hand out. Read or write its fields (`%s.field`) inside the loop, "
				% iname + "or remove @soa to get real struct elements.")
			return "null"
		if _soa.has(iname):
			diagnostics.error(
				"'%s' is an @soa array and cannot be used as a value" % iname, e.line, e.col,
				"it is emitted as %d parallel arrays, so it cannot be passed, returned "
				% _soa[iname]["arrays"].size()
				+ "or assigned. Iterating it with `for x in %s` is fine, as is "
				% iname
				+ "`for i in range(%s.size())` with `%s[i].field`." % [iname, iname])
			return "null"
		var gb: String = (e as GateAST._Ident).generic_base
		if gb != "":
			var gt: GateAST._TypeRef = (e as GateAST._Ident).generic_type
			if gt != null:
				var st: GateAST._TypeRef = _substituted(gt)
				if _generics.has(gb):
					iname = _generic_name(st)
				else:
					iname = GateParser.mangle_generic(st)
			if _generic_renames.has(iname):
				iname = _generic_renames[iname]
			var galias: String = _extern_generic_alias(gb)
			if galias != "":
				return "%s.%s" % [galias, iname]
		var ialias: String = _extern_alias(iname)
		if ialias != "":
			return "%s.%s" % [ialias, iname]
		var nsq: String = _namespace_qualifier(iname) if gb == "" else ""
		if nsq != "":
			return "%s.%s" % [nsq, _member_name(nsq, iname)]
		if gb == "" and not _fn_locals.has(iname):
			return _member_name(_scope_class, iname)   # a `priv` member is `_name`
		return iname
	if e is GateAST._SelfExpr:
		return "self"
	if e is GateAST._NodePathExpr:
		return (e as GateAST._NodePathExpr).raw
	if e is GateAST._RawExpr:
		return (e as GateAST._RawExpr).text

	if e is GateAST._Unary:
		var u: GateAST._Unary = e
		var op: String = u.op
		if op == "not":
			return "not %s" % _paren_below(u.operand, PREC_ATOM)
		if u.operand is GateAST._Binary and (u.operand as GateAST._Binary).op == "**":
			return "%s(%s)" % [op, _expr(u.operand)]
		if op == "+" and not u.tight and u.operand is GateAST._Literal:
			var raw: String = (u.operand as GateAST._Literal).raw
			if raw.begins_with("0x") or raw.begins_with("0b") or raw.begins_with("0X") or raw.begins_with("0B"):
				return "+(%s)" % raw
		return "%s%s" % [op, _paren_below(u.operand, PREC_UNARY)]

	if e is GateAST._Binary:
		return _emit_binary(e)

	if e is GateAST._NullCoalesce:
		return _emit_coalesce(e, false)

	if e is GateAST._Ternary:
		var t3: GateAST._Ternary = e
		var copy_arms: bool = _copy_arms_node == e
		_copy_arms_node = null
		var cond: String = _paren_below(t3.cond, PREC_TERNARY + 1)
		var saved_p: PackedStringArray = _pending
		_pending = PackedStringArray()
		var av: String
		if copy_arms:
			av = _lazy_part(t3.if_true, true) if _lazy_ctx() else _copy_value(t3.if_true)
		else:
			av = _lazy_part(t3.if_true, false, PREC_TERNARY + 1) if _lazy_ctx() \
				else _paren_below(t3.if_true, PREC_TERNARY + 1)
		var ap: PackedStringArray = _pending
		_pending = PackedStringArray()
		var bv: String
		if copy_arms:
			bv = _lazy_part(t3.if_false, true) if _lazy_ctx() else _copy_value(t3.if_false)
		else:
			bv = _lazy_part(t3.if_false) if _lazy_ctx() else _expr(t3.if_false)
		var bp: PackedStringArray = _pending
		_pending = saved_p
		if t3.if_false is GateAST._Lambda:
			bv = "(%s)" % bv
		if ap.is_empty() and bp.is_empty():
			return _ternary_text(av, cond, bv)
		var tmp: String = _new_tmp()
		_hoist("var %s = null" % tmp)
		_hoist("if %s:" % cond)
		_hoist_nested(ap)
		_hoist_in_block("%s = %s" % [tmp, av])
		_hoist("else:")
		_hoist_nested(bp)
		_hoist_in_block("%s = %s" % [tmp, bv])
		return tmp

	if e is GateAST._Member and (e as GateAST._Member).target is GateAST._Ident:
		var sm: GateAST._Member = e
		var skey: String = "%s.%s" % [(sm.target as GateAST._Ident).name, sm.name]
		if _scalar_names.has(skey):
			return _scalar_names[skey]

	if e is GateAST._Member and (e as GateAST._Member).target is GateAST._SelfExpr \
			and _soa.has((e as GateAST._Member).name):
		return _expr(_as_ident(e))

	if e is GateAST._Member:
		var sw: Dictionary = _swizzle_of(e)
		if not sw.is_empty():
			return _emit_swizzle_read(e, sw)

	if e is GateAST._Member or e is GateAST._Index:
		var flat: String = _emit_postfix_spine(e)
		if flat != "":
			return flat

	if e is GateAST._Member:
		var m: GateAST._Member = e
		if m.target is GateAST._Ident and _soa_cursors.has((m.target as GateAST._Ident).name):
			var cur: Dictionary = _soa_cursors[(m.target as GateAST._Ident).name]
			var cinfo: Dictionary = _soa[cur["soa"]]
			var carr: String = _soa_field_array(cinfo, m.name)
			if carr == "":
				diagnostics.error("'%s' has no field '%s'" % [cinfo["struct"], m.name],
					m.line, m.col,
					"@soa exposes exactly the struct's fields: %s"
						% ", ".join(PackedStringArray(cinfo["fields"])))
				return "null"
			return "%s[%s]" % [carr, cur["idx"]]
		if m.target is GateAST._Index:
			var mix: GateAST._Index = m.target
			var sname: String = _soa_name(mix.target)
			if sname != "":
				var info: Dictionary = _soa[sname]
				var arr: String = _soa_field_array(info, m.name)
				if arr == "":
					diagnostics.error(
						"'%s' has no field '%s'" % [info["struct"], m.name], m.line, m.col)
					return "null"
				return "%s[%s]" % [arr, _expr(mix.index)]
		var owner_key: String = _declared_type_of(m.target)
		if owner_key == "":
			owner_key = _name_key(_scope_class, _static_type_of(m.target))
		if owner_key != "" and _soa_fields.has("%s#%s" % [owner_key, m.name]):
			diagnostics.error("'%s' is an @soa array and cannot be reached through an instance"
					% m.name, m.line, m.col,
				"@soa keeps each field in its own array, so '%s.%s' is not one value. " % [
					_expr(m.target), m.name]
				+ "Give the class a method that answers what you need, or remove @soa.")
			return "null"
		if m.safe:
			return _emit_safe_member(m)
		var vst: Dictionary = _vector_struct_of(m.target)
		if not vst.is_empty():
			var vfields: Array = vst["fields"]
			var fi: int = vfields.find(m.name)
			if fi >= 0:
				return "%s.%s" % [_postfix_base(m.target), _vec_component(vst, fi)]
			diagnostics.error("'%s' has no field '%s'" % [vst["name"], m.name],
				m.line, m.col,
				"it lowered to %s, whose components are the struct's fields in order: %s"
					% [vst["vector"], ", ".join(PackedStringArray(vfields))])
			return "null"

		var base: String = _postfix_base(m.target)
		var mname: String = _member_name(m.member_class if m.member_class != "" else _owner_key(m.target), m.name)
		return "%s.%s" % [base, mname]

	if e is GateAST._Index:
		var ix: GateAST._Index = e
		if ix.safe and _no_hoist_ctx() != "":
			return _safe_inplace(ix.target, _postfix_base(ix.target), "[%s]" % _lazy_part(ix.index))
		if ix.safe:
			var base2: String = _render_once(ix.target, _postfix_base(ix.target))
			var saved_p: PackedStringArray = _pending
			_pending = PackedStringArray()
			var sidx: String = _expr(ix.index)
			var idx_pending: PackedStringArray = _pending
			_pending = saved_p
			if _no_hoist == "guard" and idx_pending.is_empty() and _repeatable(ix.target, base2):
				return "(%s[%s] if %s != null else null)" % [base2, sidx, base2]
			var res2: String = _new_tmp()
			if idx_pending.is_empty() or _no_hoist_ctx() != "":
				_rehoist(idx_pending)
				_hoist("var %s = (%s[%s] if %s != null else null)" % [res2, base2, sidx, base2])
				return res2
			_hoist("var %s = null" % res2)
			_hoist("if %s != null:" % base2)
			_hoist_nested(idx_pending)
			_hoist_in_block("%s = %s[%s]" % [res2, base2, sidx])
			return res2
		if _is_value_class(_static_type_of(ix.index)):
			_struct_key_error(ix.index)
		var pair: PackedStringArray = _ordered([ix.target, ix.index], func(i: int) -> String:
			if i == 0:
				return _postfix_base(ix.target)
			return _expr(ix.index))
		return "%s[%s]" % [pair[0], pair[1]]

	if e is GateAST._Widen and not (e as GateAST._Widen).guards.is_empty():
		return _emit_widen(e)

	if e is GateAST._Call:
		return _emit_call(e)

	if e is GateAST._ArrayLit:
		var al: GateAST._ArrayLit = e
		var lines: PackedInt32Array = PackedInt32Array()
		_coll_depth += 1
		var parts: PackedStringArray = _ordered(al.elements,
			func(i: int) -> String: return _copy_value(al.elements[i]))
		for el in al.elements:
			lines.append((el as GateAST._Expr).line)
		_coll_depth -= 1
		return _collection("[", parts, "]", lines)

	if e is GateAST._DictLit:
		var dl: GateAST._DictLit = e
		var parts2: PackedStringArray = PackedStringArray()
		var lines2: PackedInt32Array = PackedInt32Array()
		_coll_depth += 1
		var ops: Array = []
		var op_value: Array = []
		for i in dl.keys.size():
			var v = dl.values[i] if i < dl.values.size() else null
			var lua: bool = i < dl.lua_keys.size() and dl.lua_keys[i]
			if not lua:
				ops.append(dl.keys[i])
				op_value.append(false)
			if v != null:
				ops.append(v)
				op_value.append(true)
		var texts: PackedStringArray = _ordered(ops, func(i: int) -> String:
			if not op_value[i] and _is_value_class(_static_type_of(ops[i])):
				_struct_key_error(ops[i])
			return _copy_value(ops[i]) if op_value[i] else _expr(ops[i]))
		var at: int = 0
		for i in dl.keys.size():
			lines2.append((dl.keys[i] as GateAST._Expr).line)
			var v = dl.values[i] if i < dl.values.size() else null
			var lua: bool = i < dl.lua_keys.size() and dl.lua_keys[i]
			var ktext: String = ((dl.keys[i] as GateAST._Ident).name if dl.keys[i] is GateAST._Ident
				else _expr(dl.keys[i])) if lua else texts[at]
			if not lua:
				at += 1
			if v == null:
				parts2.append(ktext)
				continue
			parts2.append(("%s = %s" if lua else "%s: %s") % [ktext, texts[at]])
			at += 1
		_coll_depth -= 1
		return _collection("{", parts2, "}", lines2)

	if e is GateAST._AwaitExpr:
		return "await " + _expr((e as GateAST._AwaitExpr).operand)

	if e is GateAST._CastExpr:
		var ce: GateAST._CastExpr = e
		if ce.type != null and ce.type.array_depth == 0 and not _is_known_native(ce.type.name) \
				and _looks_like_interface(ce.type.name):
			_want_iface_helper()
			return ("(func(__gate_v): return (__gate_v if __gate_is(__gate_v, \"%s\") else null))"
				% ce.type.name) + ".call(%s)" % _expr(ce.operand)
		var inner: String = _expr(ce.operand)
		# A lambda body extends as far right as it can, so it needs parentheses before
		# the cast or the cast lands inside the body.
		if ce.operand is GateAST._Lambda:
			inner = "(%s)" % inner
		if ce.operand is GateAST._CastExpr:
			return "%s as %s" % [inner, _map_type(ce.type)]
		return "(%s as %s)" % [inner, _map_type(ce.type)]

	if e is GateAST._IsExpr:
		return _emit_is(e)

	if e is GateAST._FString:
		return _emit_fstring(e)

	if e is GateAST._ObjectInit:
		var oi: GateAST._ObjectInit = e
		var oalias: String = _extern_alias(oi.type.name)
		var octor: String = "%s.%s" % [oalias, oi.type.name] if oalias != "" else oi.type.name
		return _lower_init(oi.type.name, octor, oi.keys, oi.values, oi)

	if e is GateAST._Lambda:
		return _emit_lambda(e)

	diagnostics.warn("unhandled expression kind", e.line, e.col)
	return "null"


func _emit_coalesce(nc: GateAST._NullCoalesce, copy: bool, guard: bool = false) -> String:
	var ltext: String = _expr(nc.left)
	if _lazy_ctx() and not _repeatable(nc.left, ltext) and not _keeps_inplace(nc.left):
		var took_v: String = "__v._gate_copy()" if copy else (_guarded_copy("__v") if guard else "__v")
		return "(func(__v): return %s).call(%s)" \
			% [_ternary_text(took_v, "__v != null", _lazy_part(nc.right, copy)), ltext]
	var lhs: String = _render_once(nc.left, ltext)
	var took: String = "%s._gate_copy()" % lhs if copy else lhs
	if guard:
		took = _guarded_copy(lhs)
	if _lazy_ctx():
		return _ternary_text(took, "%s != null" % lhs, _lazy_part(nc.right, copy))
	var saved_p: PackedStringArray = _pending
	_pending = PackedStringArray()
	var rhs: String = _copy_value(nc.right) if copy else _expr(nc.right)
	var rhs_pending: PackedStringArray = _pending
	_pending = saved_p
	if rhs_pending.is_empty() or _no_hoist_ctx() != "":
		_rehoist(rhs_pending)
		return _ternary_text(took, "%s != null" % lhs, rhs)
	var t: String = _new_tmp()
	_hoist("var %s = %s" % [t, lhs])
	_hoist("if %s == null:" % t)
	_hoist_nested(rhs_pending)
	_hoist_in_block("%s = %s" % [t, rhs])
	if copy or guard:
		_hoist("else:")
		_hoist("\t%s = %s" % [t, _guarded_copy(t) if guard else "%s._gate_copy()" % t])
	return t


func _guarded_copy(text: String) -> String:
	var owner: String = _guard_owner()
	if owner == "":
		return GUARD_LAMBDA % text
	return "%s(%s)" % [owner, text]


const GUARD_LAMBDA := "(func(__v): return (__v._gate_copy() if is_instance_valid(__v) and __v.has_method(\"_gate_copy\") else __v)).call(%s)"


func _guard_owner(want: String = "_gate_value") -> String:
	var fallback: String = ""
	for sn in _structs:
		var st: Dictionary = _structs[sn]
		if st.get("lowering", "") == "vector" or not st.has("decl"):
			continue
		var helper: String = _eq_helper(st, want)
		var scope: String = String(st.get("scope", ""))
		if scope != "":
			var own: String = _struct_class_text(String(sn))
			if not _name_rebound(own.get_slice(".", 0)):
				return "%s.%s" % [own, helper]
			continue
		if fallback != "":
			continue
		var origin: String = String(_extern_origin.get(sn, _extern_origin.get(String(sn).get_slice(".", 0), "")))
		if origin != "":
			fallback = "%s.%s.%s" % [_dep_const_for(origin), sn, helper]
	return fallback


func _eqv_text(b: GateAST._Binary) -> String:
	var es: String = _eq_struct(b)
	if es != "":
		return "%s.%s" % [_struct_class_text(es), _eq_helper(_struct_of(es), "_gate_eqv")]
	if _against_null(b) or not _structs_visible():
		return ""
	if _static_type_of(b.left) != "" or _static_type_of(b.right) != "":
		return ""
	if not (_may_hold_struct(b.left) or _may_hold_struct(b.right)):
		return ""
	return _guard_owner("_gate_eqv")


func _in_struct_text(b: GateAST._Binary) -> String:
	var ct: GateAST._TypeRef = _container_tref(b.right)
	if not _is_array_tref(ct):
		return ""
	var et: GateAST._TypeRef = _array_elem(ct)
	if et == null or et.array_depth != 0 or not _is_value_class(et.name):
		return ""
	return "%s.%s" % [_struct_class_text(et.name), _eq_helper(_struct_of(et.name), "_gate_index")]


func _name_rebound(n: String) -> bool:
	return _bound_names.has(n) or _fn_locals.has(n) or _declares_value(_scope_class, n)


func _dep_const_for(origin: String) -> String:
	if _used_origins.has(origin):
		return _used_origins[origin]
	var target: String = "\"%s.gd\"" % String(origin).get_basename()
	for m in _module_members:
		if m is GateAST._VarDecl and (m as GateAST._VarDecl).is_const \
				and (m as GateAST._VarDecl).value is GateAST._Call:
			var c: GateAST._Call = (m as GateAST._VarDecl).value
			if c.callee is GateAST._Ident and (c.callee as GateAST._Ident).name == "preload" \
					and c.args.size() == 1 and c.args[0] is GateAST._Literal \
					and (c.args[0] as GateAST._Literal).raw == target:
				return (m as GateAST._VarDecl).name
	return _origin_alias(origin)


func _lazy_ctx() -> bool:
	var ctx: String = _no_hoist_ctx()
	return ctx != "" and ctx != "const"


func _lazy_part(e, copy: bool = false, floor_prec: int = -1) -> String:
	var before: int = _pending.size()
	var text: String
	if floor_prec >= 0:
		text = _paren_below(e, floor_prec)
	else:
		text = _copy_value(e) if copy else _expr(e)
	if _pending.size() > before and _no_hoist_ctx() == "field":
		_pending.resize(before)
		diagnostics.error("this part runs only when it is reached, and computing it needs a "
				+ "statement a field initialiser has nowhere to put", e.line, e.col,
			"initialise the field in _init() instead.")
	return text


func _emit_swizzle_read(m: GateAST._Member, sw: Dictionary) -> String:
	if not _swizzle_in_range(m, sw):
		return "null"
	var result: String = _swizzle_result(sw, m.name.length())
	var names: String = m.name
	var target = m.target
	while target is GateAST._Member and not _swizzle_of(target).is_empty():
		var inner: GateAST._Member = target
		if not _swizzle_in_range(inner, _swizzle_of(inner)):
			return "null"
		var composed: String = ""
		for i in names.length():
			composed += inner.name[GateTypes.VECTOR_COMPONENTS.find(names[i])]
		names = composed
		target = inner.target
	var text: String = _postfix_base(target)
	var base: String = text
	if not _repeatable(target, text):
		var ctx: String = _no_hoist_ctx()
		if ctx == "":
			base = _render_once(target, text)
		elif ctx != "const":
			var lcomps: PackedStringArray = PackedStringArray()
			for i in names.length():
				lcomps.append("__v.%s" % names[i])
			return "(func(__v): return %s(%s)).call(%s)" % [result, ", ".join(lcomps), text]
	var comps: PackedStringArray = PackedStringArray()
	for i in names.length():
		comps.append("%s.%s" % [base, names[i]])
	return "%s(%s)" % [result, ", ".join(comps)]


static func _ternary_text(if_true: String, cond: String, if_false: String) -> String:
	if _reads_as_ternary(if_false) or _bare_ternary(if_false):
		return "%s if %s else %s" % [if_true, cond, if_false]
	return "(%s if %s else %s)" % [if_true, cond, if_false]


static func _reads_as_ternary(text: String) -> bool:
	if not text.begins_with("(") or not text.ends_with(")"):
		return false
	var depth: int = 0
	var quote: String = ""
	var saw_if: bool = false
	for i in text.length():
		var ch: String = text[i]
		if quote != "":
			if ch == quote:
				quote = ""
			continue
		if ch == "\"" or ch == "'":
			quote = ch
		elif ch == "(" or ch == "[" or ch == "{":
			depth += 1
		elif ch == ")" or ch == "]" or ch == "}":
			depth -= 1
			if depth == 0 and i != text.length() - 1:
				return false   # the first group closes before the end
		elif depth == 1 and text.substr(i, 4) == " if ":
			saw_if = true
	return saw_if


func _tmp_like(name: String, like) -> GateAST._Ident:
	var id: GateAST._Ident = _tmp_ident(name, like)
	id.flow_type = (like as GateAST._Expr).flow_type if like is GateAST._Expr else null
	var info: Dictionary = {"t": _declared_type_of(like), "e": ""}
	var tr: GateAST._TypeRef = _value_tref(like)
	if tr != null:
		info = _decl_info(_scope_class, tr)
	_fn_locals[name] = info
	var st: String = _static_type_of(like)
	if st != "":
		_var_types[name] = st
		_var_depths[name] = 0
	return id


func _raw_like(text: String, like) -> GateAST._RawExpr:
	var r: GateAST._RawExpr = GateAST._RawExpr.new()
	r.at(like.line, like.col)
	r.text = text
	return r


func _tmp_ident(name: String, at_node) -> GateAST._Ident:
	var id: GateAST._Ident = GateAST._Ident.new()
	id.at(at_node.line, at_node.col)
	id.name = name
	return id


func _emit_safe_member(m: GateAST._Member) -> String:
	var base: String = _postfix_base(m.target)
	if _no_hoist_ctx() != "":
		if _repeatable(m.target, base) or _keeps_inplace(m.target):
			return "(%s if %s != null else null)" % [_safe_step(m, base), base]
		return "(func(__v): return (%s if __v != null else null)).call(%s)" \
			% [_safe_step(m, "__v"), base]
	var once: String = _render_once(m.target, base)
	var inner: String = _safe_step(m, once)
	if _no_hoist == "guard" and _repeatable(m.target, once):
		return "(%s if %s != null else null)" % [inner, once]
	var res: String = _new_tmp()
	_hoist("var %s = (%s if %s != null else null)" % [res, inner, once])
	return res


func _safe_step(m: GateAST._Member, base: String) -> String:
	var had_local: bool = _fn_locals.has(base)
	var was_local = _fn_locals.get(base)
	var had_type: bool = _var_types.has(base)
	var was_type = _var_types.get(base)
	var had_depth: bool = _var_depths.has(base)
	var was_depth = _var_depths.get(base)
	var had_tmp: bool = _tmp_names.has(base)
	var stand: GateAST._Ident = _tmp_like(base, m.target)
	_tmp_names[base] = true
	var step: GateAST._Member = GateAST._Member.new()
	step.at(m.line, m.col)
	step.name = m.name
	step.member_class = m.member_class
	step.flow_type = m.flow_type
	step.target = stand
	var text: String = _expr(step)
	if not had_tmp:
		_tmp_names.erase(base)
	if had_local:
		_fn_locals[base] = was_local
	else:
		_fn_locals.erase(base)
	if had_type:
		_var_types[base] = was_type
	else:
		_var_types.erase(base)
	if had_depth:
		_var_depths[base] = was_depth
	else:
		_var_depths.erase(base)
	return text


func _safe_inplace(target, base: String, suffix: String) -> String:
	if _repeatable(target, base) or _keeps_inplace(target):
		return "(%s%s if %s != null else null)" % [base, suffix, base]
	return "(func(__v): return (__v%s if __v != null else null)).call(%s)" % [suffix, base]


func _needs_copy(e) -> bool:
	if e is GateAST._Call or e is GateAST._ObjectInit or e is GateAST._Binary:
		return false   # a fresh value (an overloaded operator is a call)
	var tn: String = _static_type_of(e)
	if tn == "":
		return false
	var st: Dictionary = _struct_of(tn)
	return not st.is_empty() and st["lowering"] != "vector"


func _engine_result(e) -> Dictionary:
	if e is GateAST._Binary and (e as GateAST._Binary).op == "+":
		var bt: GateAST._TypeRef = _container_tref(e)
		var bs: String = _innermost_struct(bt)
		return {"deep": bs} if bs != "" else {}
	if not (e is GateAST._Call) or not ((e as GateAST._Call).callee is GateAST._Member):
		return {}
	var cm: GateAST._Member = (e as GateAST._Call).callee
	if cm.safe:
		return {}
	var rt: GateAST._TypeRef = _container_tref(cm.target)
	if rt == null:
		return {}
	var elem: GateAST._TypeRef = null
	var parts: Array = _dict_parts(rt)
	if not parts.is_empty():
		if cm.name == "get":
			elem = parts[1]
		elif cm.name == "find_key":
			elem = parts[0]
		elif cm.name in ["values", "keys", "duplicate"]:
			var ds: String = _innermost_struct(_container_tref(e))
			return {"deep": ds} if ds != "" else {}
	elif _is_array_tref(rt):
		if cm.name in ["back", "front", "get", "pick_random", "max", "min"]:
			elem = _array_elem(rt)
		elif cm.name in ["duplicate", "slice", "filter"]:
			var arr_st: String = _innermost_struct(rt)
			return {"deep": arr_st} if arr_st != "" else {}
	if elem == null:
		return {}
	if elem.array_depth == 0 and not elem.is_dict() and _is_value_class(elem.name):
		return {"elem": elem}
	var inner: String = _innermost_struct(elem)
	return {"deep": inner} if inner != "" else {}


func _innermost_struct(t: GateAST._TypeRef) -> String:
	var node: GateAST._TypeRef = t
	for _guard in 16:
		if node == null:
			return ""
		if _is_array_tref(node):
			node = _array_elem(node)
		elif not _dict_parts(node).is_empty():
			node = _dict_parts(node)[1]
		else:
			return node.name if _is_value_class(node.name) else ""
	return ""


func _struct_key_error(at) -> void:
	var key: String = "%d:%d" % [at.line, at.col]
	if _key_errors.has(key):
		return
	_key_errors[key] = true
	diagnostics.error("a struct lowered to a class cannot be a dictionary key", at.line, at.col,
		"a dictionary finds an object key by identity, so an equal copy would not find it. "
		+ "Key by a field, or use a struct of 2-4 same-typed numbers, which lowers to a Vector.")


func _struct_class_text(sname: String) -> String:
	var scope: String = String(_struct_of(sname).get("scope", ""))
	if scope != "" and scope != ".":
		return "%s.%s" % [scope, sname.get_slice(".", sname.get_slice_count(".") - 1)]
	var t: GateAST._TypeRef = GateAST._TypeRef.new()
	t.name = sname
	return _map_type(t)


func _eq_helper(st: Dictionary, want: String) -> String:
	var n: String = want
	while (st["fields"] as Array).has(n) or (st.get("methods", {}) as Dictionary).has(n) \
			or (st.get("consts", {}) as Dictionary).has(n):
		n = "_" + n
	return n


func _struct_search(c: GateAST._Call) -> String:
	if not (c.callee is GateAST._Member) or (c.callee as GateAST._Member).safe:
		return ""
	var cm: GateAST._Member = c.callee
	if not (cm.name in ["has", "find", "rfind", "count", "erase"]) or c.args.is_empty():
		return ""
	var ct: GateAST._TypeRef = _container_tref(cm.target)
	if not _is_array_tref(ct):
		return ""
	var et: GateAST._TypeRef = _array_elem(ct)
	if et == null or et.array_depth != 0 or not _is_value_class(et.name):
		return ""
	var st: Dictionary = _struct_of(et.name)
	var cls: String = _struct_class_text(et.name)
	var parts: PackedStringArray = _ordered([cm.target] + c.args, func(i: int) -> String:
		return _expr(cm.target) if i == 0 else _expr(c.args[i - 1]))
	match cm.name:
		"has":
			return "%s.%s(%s, %s, 0, 1) >= 0" % [cls, _eq_helper(st, "_gate_index"), parts[0], parts[1]]
		"find":
			return "%s.%s(%s, %s, %s, 1)" % [cls, _eq_helper(st, "_gate_index"), parts[0], parts[1],
				parts[2] if parts.size() > 2 else "0"]
		"rfind":
			return "%s.%s(%s, %s, %s, -1)" % [cls, _eq_helper(st, "_gate_index"), parts[0], parts[1],
				parts[2] if parts.size() > 2 else "-1"]
		"count":
			return "%s.%s(%s, %s)" % [cls, _eq_helper(st, "_gate_count"), parts[0], parts[1]]
	return "%s.%s(%s, %s)" % [cls, _eq_helper(st, "_gate_erase"), parts[0], parts[1]]


func _struct_store(c: GateAST._Call) -> String:
	if not (c.callee is GateAST._Member) or (c.callee as GateAST._Member).safe:
		return ""
	var cm: GateAST._Member = c.callee
	if not (cm.name in ["append_array", "assign", "merge"]) or c.args.is_empty():
		return ""
	var sname: String = _innermost_struct(_container_tref(cm.target))
	if sname == "":
		sname = _innermost_struct(_container_tref(c.args[0]))
	if sname == "" or not _is_value_class(sname):
		return ""
	var parts: PackedStringArray = _ordered([cm.target] + c.args, func(i: int) -> String:
		return _postfix_base(cm.target) if i == 0 else _expr(c.args[i - 1]))
	var args: PackedStringArray = PackedStringArray()
	for i in c.args.size():
		args.append("%s.%s(%s)" % [_struct_class_text(sname), _deep_helper(_struct_of(sname)),
			parts[i + 1]] if i == 0 else parts[i + 1])
	return "%s.%s(%s)" % [parts[0], cm.name, ", ".join(args)]


func _deep_helper(st: Dictionary) -> String:
	var n: String = "_gate_deep"
	while (st["fields"] as Array).has(n) or (st.get("methods", {}) as Dictionary).has(n) \
			or (st.get("consts", {}) as Dictionary).has(n):
		n = "_" + n
	return n


func _copy_value(e) -> String:
	if _in_gate_helper:
		return _expr(e)
	var sft: GateAST._TypeRef = _soa_field_tref(e)
	if sft != null:
		return _copied(_expr(e), sft)
	var er: Dictionary = _engine_result(e)
	if er.has("elem"):
		var etr: GateAST._TypeRef = GateChecker.copy_type(er["elem"])
		etr.nullable = true   # an empty container hands out null
		if _no_hoist_ctx() in ["param", "annotation", "guard", "const"]:
			return "(func(__v): return (__v._gate_copy() if __v != null else null)).call(%s)" % _expr(e)
		return _copied(_render_once(e, _expr(e)), etr)
	if er.has("deep"):
		var dst: GateAST._TypeRef = GateAST._TypeRef.new()
		dst.name = er["deep"]
		return "%s.%s(%s)" % [_map_type(dst), _deep_helper(_struct_of(er["deep"])), _expr(e)]
	if e is GateAST._NullCoalesce:
		var nlt: String = _static_type_of((e as GateAST._NullCoalesce).left)
		if _is_value_class(nlt):
			return _emit_coalesce(e, true)
		if nlt == "" and (_is_value_class(_static_type_of((e as GateAST._NullCoalesce).right))
				or (_structs_visible() and _may_hold_struct((e as GateAST._NullCoalesce).left))):
			return _emit_coalesce(e, true, true)
	if e is GateAST._Ternary and (_is_value_class(_static_type_of((e as GateAST._Ternary).if_true))
			or _is_value_class(_static_type_of((e as GateAST._Ternary).if_false))
			or (_structs_visible() and (_may_hold_struct((e as GateAST._Ternary).if_true)
				or _may_hold_struct((e as GateAST._Ternary).if_false)))):
		_copy_arms_node = e
		return _expr(e)
	if e is GateAST._CastExpr and _is_value_class(_static_type_of(e)):
		return _with_once(e, _expr(e), func(n: String) -> String:
			return "(%s._gate_copy() if %s != null else null)" % [n, n])
	if e is GateAST._Index and _structs_visible() and _from_tuple((e as GateAST._Index).target):
		return _guard_value(e)
	var tr: GateAST._TypeRef = _declared_tref(e)
	if tr == null and e is GateAST._Member:
		tr = _value_tref(e)   # another object's field, `h.st`, declared `Ctr?`
	if tr == null and e is GateAST._Ident and _null_locals.has((e as GateAST._Ident).name) and _needs_copy(e):
		var nt: String = _expr(e)
		return "(%s._gate_copy() if %s != null else null)" % [nt, nt]
	if tr != null and tr.array_depth == 0 and (tr.is_union() or tr.nullable):
		var text: String = _expr(e)
		if _copied(text, tr) == text:
			return text
		return _with_once(e, text, func(n: String) -> String: return _copied(n, tr))
	if not _needs_copy(e):
		var members: Array = _union_struct_members(e)
		if members.is_empty():
			if (_structs_visible() and _static_type_of(e) == "" and _declared_type_of(e) == ""
					and _may_hold_struct(e)):
				return _guard_value(e)
			return _expr(e)
		return _with_once(e, _postfix_base(e), func(n: String) -> String:
			var tests: PackedStringArray = PackedStringArray()
			for mn in members:
				tests.append("%s is %s" % [n, mn])
			return "(%s._gate_copy() if %s else %s)" % [n, " or ".join(tests), n])
	if _has_safe_step(e):
		return _with_once(e, _postfix_base(e), func(n: String) -> String:
			return "(%s._gate_copy() if %s != null else null)" % [n, n])
	return "%s._gate_copy()" % _postfix_base(e)


func _value_may_be_null(e) -> bool:
	if e is GateAST._Ident and _fn_locals.has((e as GateAST._Ident).name) \
			and (_fn_locals[(e as GateAST._Ident).name] as Dictionary).get("tr", null) == null:
		return _null_locals.has((e as GateAST._Ident).name)
	return _may_be_null(e)


func _from_tuple(e) -> bool:
	if _tuple_tref(_container_tref(e)) != null:
		return true
	return e is GateAST._Index and _from_tuple((e as GateAST._Index).target)


func _with_once(e, text: String, build: Callable) -> String:
	if _repeatable(e, text):
		return build.call(text)
	var ctx: String = _no_hoist_ctx()
	if ctx == "":
		return build.call(_render_once(e, text))
	if _keeps_inplace(e):
		return build.call(text)
	return "(func(__v): return %s).call(%s)" % [build.call("__v"), text]


func _guard_value(e) -> String:
	return _guarded_copy(_expr(e))


func _union_struct_members(e) -> Array:
	if not (e is GateAST._Expr) or e is GateAST._Call or e is GateAST._ObjectInit:
		return []
	var ft: GateAST._TypeRef = (e as GateAST._Expr).flow_type
	if ft == null or not ft.is_union() or ft.array_depth != 0:
		return []
	var out: Array = []
	for um in ft.union_members:
		if _is_class_struct(um):
			out.append(_map_type(um))
	return out


func _observable_prop(e) -> String:
	var owner: String = _scope_class
	var n: String = ""
	if e is GateAST._Ident:
		n = (e as GateAST._Ident).name
		if _fn_locals.has(n):
			return ""
	elif e is GateAST._Member and not (e as GateAST._Member).safe:
		n = (e as GateAST._Member).name
		if not ((e as GateAST._Member).target is GateAST._SelfExpr):
			owner = _declared_type_of((e as GateAST._Member).target)
			if owner == "" and _static_type_of((e as GateAST._Member).target) != "":
				owner = _name_key(_scope_class, _static_type_of((e as GateAST._Member).target))
	if n == "" or owner == "":
		return ""
	var q: String = owner
	for _guard in 64:
		var key: String = "%s#%s" % [q, n]
		if _observable_fields.has(key):
			return _observable_fields[key] if _is_value_class(_observable_fields[key]) else ""
		var b: Dictionary = _base_of(q) if (q == "." or _class_decls.has(q)) else {"kind": "none"}
		if String(b["kind"]) != "local":
			return ""
		q = String(b["key"])
	return ""


func _observable_root_of(e) -> Dictionary:
	var node = e
	while node is GateAST._Member or node is GateAST._Index:
		var inner = node.target
		var sn: String = _observable_prop(inner)
		if sn != "":
			return {"node": inner, "struct": sn}
		node = inner
	return {}


func _observable_lvalue(node) -> String:
	if node is GateAST._Ident:
		return _expr(node)
	var m: GateAST._Member = node
	if m.target is GateAST._SelfExpr:
		return "self." + m.name
	return "%s.%s" % [_render_once(m.target, _postfix_base(m.target)), m.name]


func _observable_open(obs: Dictionary, e) -> Array:
	var lv: String = _observable_lvalue(obs["node"])
	var t: String = _new_tmp()
	_hoist("var %s = %s._gate_copy()" % [t, lv])
	_fn_locals[t] = {"t": obs["struct"], "e": ""}
	_var_types[t] = obs["struct"]
	_var_depths[t] = 0
	var id: GateAST._Ident = GateAST._Ident.new()
	id.at(obs["node"].line, obs["node"].col)
	id.name = t
	return [lv, t, _with_root(e, obs["node"], id)]


static func _with_root(e, root, repl):
	if e == root:
		return repl
	if e is GateAST._Member:
		var m: GateAST._Member = GateAST._Member.new()
		m.at(e.line, e.col)
		m.name = (e as GateAST._Member).name
		m.target = _with_root((e as GateAST._Member).target, root, repl)
		return m
	if e is GateAST._Index:
		var ix: GateAST._Index = GateAST._Index.new()
		ix.at(e.line, e.col)
		ix.index = (e as GateAST._Index).index
		ix.target = _with_root((e as GateAST._Index).target, root, repl)
		return ix
	return e


func _struct_mutators(sname: String) -> Dictionary:
	if _mutators.has(sname):
		return _mutators[sname]
	_mutators[sname] = {}
	var st: Dictionary = _struct_of(sname)
	if st.is_empty() or not st.has("decl"):
		return {}
	var funcs: Dictionary = {}
	for m in (st["decl"] as GateAST._ClassDecl).members:
		if m is GateAST._FuncDecl and not (m as GateAST._FuncDecl).is_static:
			funcs[(m as GateAST._FuncDecl).name] = m
	var out: Dictionary = {}
	var changed: bool = true
	while changed:
		changed = false
		for fname in funcs:
			var fd: GateAST._FuncDecl = funcs[fname]
			if not out.has(fname) and _mutates(fd.body, st,
					GateChecker.local_names(fd.params, fd.body), out):
				out[fname] = true
				changed = true
	_mutators[sname] = out
	return out


func _mutates(node, st: Dictionary, locals: Dictionary, mut: Dictionary) -> bool:
	if node is Array:
		for x in node:
			if _mutates(x, st, locals, mut):
				return true
		return false
	if node == null or not (node is Object) or (node as Object).get_script() == null:
		return false
	var targets: Array = []
	if node is GateAST._AssignStmt:
		targets.append((node as GateAST._AssignStmt).target)
	elif node is GateAST._MultiAssign and not (node as GateAST._MultiAssign).destructure:
		targets.append_array((node as GateAST._MultiAssign).targets)
	for t in targets:
		var root = t
		while root is GateAST._Member or root is GateAST._Index:
			root = root.target
		if root is GateAST._SelfExpr or (root is GateAST._Ident
				and (st["fields"] as Array).has((root as GateAST._Ident).name)
				and not locals.has((root as GateAST._Ident).name)):
			return true
	if node is GateAST._Call:
		var callee = (node as GateAST._Call).callee
		if callee is GateAST._Ident and mut.has((callee as GateAST._Ident).name) \
				and not locals.has((callee as GateAST._Ident).name):
			return true
		if callee is GateAST._Member:
			var cm: GateAST._Member = callee
			if cm.target is GateAST._SelfExpr and mut.has(cm.name):
				return true
			if cm.target is GateAST._Ident and not locals.has((cm.target as GateAST._Ident).name):
				var at: int = (st["fields"] as Array).find((cm.target as GateAST._Ident).name)
				if at >= 0 and _struct_mutators(String(st["types"][at])).has(cm.name):
					return true
	for prop in (node as Object).get_property_list():
		var pn: String = prop["name"]
		if pn in ["script", "Built-in script", "RefCounted", "Object"]:
			continue
		var v = (node as Object).get(pn)
		if (v is Array or (v is Object and v != null)) and _mutates(v, st, locals, mut):
			return true
	return false


func _observable_call_root(c: GateAST._Call) -> Dictionary:
	if not (c.callee is GateAST._Member) or (c.callee as GateAST._Member).safe:
		return {}
	var cm: GateAST._Member = c.callee
	var obs: Dictionary = _observable_root_of(cm)
	if obs.is_empty():
		return {}
	var recv_t: String = _static_type_of(cm.target)
	if recv_t == "" or not _struct_mutators(recv_t).has(cm.name):
		return {}
	return obs


func _namespace_qualifier(n: String) -> String:
	if _scope_class == "." or _fn_locals.has(n) or _class_declares(_scope_class, n):
		return ""
	var q: String = String(_class_parent.get(_scope_class, "."))
	while q != ".":
		var names: Dictionary = _names_of_scope(q)
		if names.has(n):
			var cd = _class_decls.get(q)
			if cd == null or (cd as GateAST._ClassDecl).form != "namespace":
				return ""
			for m in (cd as GateAST._ClassDecl).members:
				if (m is GateAST._FuncDecl and (m as GateAST._FuncDecl).name == n) \
						or (m is GateAST._VarDecl and (m as GateAST._VarDecl).name == n
							and not (m as GateAST._VarDecl).is_const):
					return q
			return ""
		if _class_declares(q, n):
			return ""
		q = String(_class_parent.get(q, "."))
	return ""


static func _as_ident(m: GateAST._Member) -> GateAST._Ident:
	var id: GateAST._Ident = GateAST._Ident.new()
	id.at(m.line, m.col)
	id.name = m.name
	return id


func _soa_field_tref(e) -> GateAST._TypeRef:
	if not (e is GateAST._Member) or (e as GateAST._Member).safe:
		return null
	var m: GateAST._Member = e
	var sname: String = ""
	if m.target is GateAST._Ident and _soa_cursors.has((m.target as GateAST._Ident).name):
		sname = String(_soa_cursors[(m.target as GateAST._Ident).name]["soa"])
	elif m.target is GateAST._Index:
		sname = _soa_name((m.target as GateAST._Index).target)
	if sname == "":
		return null
	var st: Dictionary = _struct_of(String(_soa[sname]["struct"]))
	var fi: int = (st.get("fields", []) as Array).find(m.name)
	return (st["typerefs"] as Array)[fi] if fi >= 0 else null


func _structs_visible() -> bool:
	return _struct_user and not _in_gate_helper


func _may_hold_struct(e) -> bool:
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		if _scalar_repl.has(n) or _soa.has(n) or _soa_cursors.has(n):
			return false
		if _fn_locals.has(n):
			var tr = (_fn_locals[n] as Dictionary).get("tr", null)
			if tr != null:
				return _unknown_tref(tr)
			return not _never_holds_struct(n, {})
		var ft: GateAST._TypeRef = _member_tref(_scope_class, n, false)
		if ft != null:
			return _unknown_tref(ft)
		return _declares_value(_scope_class, n)
	if e is GateAST._Member:
		var m: GateAST._Member = e
		var root = m.target
		while root is GateAST._Member:
			root = (root as GateAST._Member).target
		if root is GateAST._Ident and not _may_be_value(root as GateAST._Ident) \
				and not (root is GateAST._Ident and _fn_locals.has((root as GateAST._Ident).name)):
			if m.target is GateAST._Ident or _class_path(m.target):
				return false
		var ot: String = _static_type_of(m.target)
		var cot: String = GateTypes.canonical(ot)
		if cot != "" and cot != "Variant" and GateTypes.BUILTIN.has(cot):
			return false   # a builtin's own property, `Vector2i.y`, is a number
		if ot != "":
			var ft = _field_types.get("%s.%s" % [ot.get_slice(".", ot.get_slice_count(".") - 1), m.name])
			if ft == null:
				ft = _struct_field_tref(ot, m.name)
			if ft != null:
				return _unknown_tref(ft)
		return true
	if e is GateAST._Index:
		var it: String = GateTypes.canonical(_static_type_of((e as GateAST._Index).target))
		if it == "":
			it = GateTypes.canonical(_declared_type_of((e as GateAST._Index).target))
		return not (it.begins_with("Packed") and it.ends_with("Array")) and it != "String"
	if e is GateAST._AwaitExpr:
		return true
	if e is GateAST._Call:
		return _call_may_hold_struct(e)
	return false


func _class_path(e) -> bool:
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		return (not _may_be_value(e) and (_local_types.has(n) or _extern_origin.has(n)
			or n.begins_with("__gate_dep_") or n.begins_with("___gate_dep_") or ClassDB.class_exists(n)))
	if e is GateAST._Member:
		var n2: String = (e as GateAST._Member).name
		return _class_path((e as GateAST._Member).target) and n2.length() > 0 and n2[0] == n2[0].to_upper()
	return false


static func _unknown_tref(t: GateAST._TypeRef) -> bool:
	return (t.array_depth == 0 and not t.is_dict() and not t.is_tuple()
		and (t.is_union() or GateTypes.canonical(t.name) == "Variant"))


func _may_be_value(id: GateAST._Ident) -> bool:
	return _fn_locals.has(id.name) or _declares_value(_scope_class, id.name)


func _declares_value(key: String, n: String) -> bool:
	var q: String = key
	var seen: Dictionary = {}
	while q != "" and not seen.has(q):
		seen[q] = true
		if (_class_fields.get(q, {}) as Dictionary).has(n):
			return true
		if not (q == "." or _class_decls.has(q)):
			return false
		var b: Dictionary = _base_of(q)
		q = String(b["key"]) if String(b["kind"]) == "local" else ""
	return false


func _call_may_hold_struct(c: GateAST._Call) -> bool:
	if _gate_callee(c) != null:
		return false
	if c.callee is GateAST._Ident:
		var n: String = (c.callee as GateAST._Ident).name
		if not _struct_of(n).is_empty() or CTOR_SHORTHAND.has(n) or GateTypes.BUILTIN.has(n) \
				or _local_types.has(n) or ClassDB.class_exists(n):
			return false
		var base: String = _engine_base_of(_scope_class)
		return base != "" and ClassDB.class_has_method(base, n) and _engine_may_return_struct(base, n)
	if c.callee is GateAST._Member:
		var cm: GateAST._Member = c.callee
		if cm.name == "new" or cm.name.begins_with("_gate_") or _gate_lambda_call(c) \
				or (not _struct_of(cm.name).is_empty() and _is_namespace_ref(cm.target)):
			return false
		if cm.target is GateAST._Ident and not _may_be_value(cm.target as GateAST._Ident) \
				and ClassDB.class_exists((cm.target as GateAST._Ident).name):
			var eng: String = (cm.target as GateAST._Ident).name
			return not ClassDB.class_has_method(eng, cm.name) or _engine_may_return_struct(eng, cm.name)
		if _builtin_scalar_method(cm):
			return false
		var owner: String = GateTypes.canonical(_static_type_of(cm.target))
		if owner != "" and ClassDB.class_exists(owner) and ClassDB.class_has_method(owner, cm.name):
			return _engine_may_return_struct(owner, cm.name)
	return true


func _iter_unknown(it) -> bool:
	if it is GateAST._Literal or it is GateAST._Binary or it is GateAST._Unary:
		return false
	if it is GateAST._Call:
		var c: GateAST._Call = it
		if c.callee is GateAST._Ident and (c.callee as GateAST._Ident).name == "range":
			return false
		if c.callee is GateAST._Member and _builtin_scalar_method(c.callee):
			return false
	var st: String = GateTypes.canonical(_static_type_of(it))
	if st in ["int", "float", "String", "StringName", "bool"]:
		return false
	var tr: GateAST._TypeRef = _value_tref(it)
	return tr == null or _unknown_tref(tr) or (GateTypes.canonical(tr.name) in ["Array", "Dictionary"]
		and tr.array_depth == 0 and tr.generic_args.is_empty() and not tr.is_dict())


func _builtin_scalar_method(cm: GateAST._Member) -> bool:
	return cm.name in ["size", "is_empty", "find", "rfind", "count", "has", "hash", "bsearch",
		"length", "to_int", "to_float", "is_valid_int", "begins_with", "ends_with", "contains",
		"substr", "replace", "to_lower", "to_upper", "strip_edges", "split", "join", "has_all",
		"is_typed", "is_read_only", "is_same_typed"]


func _engine_may_return_struct(cls: String, method: String) -> bool:
	for mi in ClassDB.class_get_method_list(cls):
		if String(mi["name"]) != method:
			continue
		var ret: Dictionary = mi.get("return", {})
		var rt: int = int(ret.get("type", TYPE_NIL))
		if rt == TYPE_NIL:
			return int(ret.get("usage", 0)) & PROPERTY_USAGE_NIL_IS_VARIANT != 0
		if rt != TYPE_OBJECT:
			return false
		var rc: String = String(ret.get("class_name", ""))
		return rc == "" or rc == "Object" or rc == "RefCounted"
	return true


func _engine_base_of(key: String) -> String:
	var q: String = key
	var seen: Dictionary = {}
	while q != "" and not seen.has(q):
		seen[q] = true
		var b: Dictionary = _base_of(q) if (q == "." or _class_decls.has(q)) else {"kind": "none"}
		match String(b["kind"]):
			"local":
				q = String(b["key"])
			"ext":
				return String(b["name"]) if ClassDB.class_exists(String(b["name"])) else ""
			"none":
				return "RefCounted"
			_:
				return ""
	return ""


func _gate_callee(c: GateAST._Call) -> GateAST._FuncDecl:
	var owner: String = ""
	var name: String = ""
	if c.callee is GateAST._Ident:
		name = (c.callee as GateAST._Ident).name
		if _fn_locals.has(name):
			return null
		owner = _scope_class
	elif c.callee is GateAST._Member:
		var cm: GateAST._Member = c.callee
		name = cm.name
		if cm.target is GateAST._SelfExpr:
			owner = _scope_class
		elif cm.target is GateAST._Ident and (cm.target as GateAST._Ident).name == "super":
			var b: Dictionary = _base_of(_scope_class) if (_scope_class == "." or _class_decls.has(_scope_class)) else {"kind": "none"}
			owner = String(b["key"]) if String(b["kind"]) == "local" else ""
		elif cm.target is GateAST._Ident and not _may_be_value(cm.target as GateAST._Ident) \
				and _resolve_class(_scope_class, (cm.target as GateAST._Ident).name) != "":
			owner = _resolve_class(_scope_class, (cm.target as GateAST._Ident).name)
		else:
			owner = _declared_type_of(cm.target)
			if owner == "" and _static_type_of(cm.target) != "":
				owner = _name_key(_scope_class, _static_type_of(cm.target))
			var sst: Dictionary = _struct_of(owner)
			if not sst.is_empty() and sst.has("decl"):
				return _pick_overload((sst["decl"] as GateAST._ClassDecl).members, name, c.args.size())
	if owner == "" or name == "":
		return null
	var q: String = owner
	var seen: Dictionary = {}
	while q != "" and not seen.has(q):
		seen[q] = true
		var fns: Array = (_class_funcs.get(q, {}) as Dictionary).get(name, [])
		if not fns.is_empty():
			return _pick_overload(fns, name, c.args.size())
		if not (q == "." or _class_decls.has(q)):
			if _reg_classes.has(q):
				return _pick_overload((_reg_classes[q] as GateAST._ClassDecl).members, name, c.args.size())
			return null
		var b2: Dictionary = _base_of(q)
		if String(b2["kind"]) == "local":
			q = String(b2["key"])
		elif String(b2["kind"]) == "ext" and _reg_classes.has(String(b2["name"])):
			q = String(b2["name"])
		else:
			return null
	return null


static func _pick_overload(members: Array, name: String, argc: int) -> GateAST._FuncDecl:
	for m in members:
		if not (m is GateAST._FuncDecl) or (m as GateAST._FuncDecl).name != name:
			continue
		var fd: GateAST._FuncDecl = m
		var required: int = 0
		for p in fd.params:
			if (p as GateAST._Param).default == null and not (p as GateAST._Param).is_rest:
				required += 1
		if argc >= required and (argc <= fd.params.size() or (not fd.params.is_empty()
				and (fd.params[fd.params.size() - 1] as GateAST._Param).is_rest)):
			return fd
	return null


static func _copies_first(stmts: Array, n: String) -> bool:
	for k in mini(stmts.size(), 8):
		var s = stmts[k]
		var v = null
		if s is GateAST._AssignStmt and (s as GateAST._AssignStmt).target is GateAST._Ident \
				and ((s as GateAST._AssignStmt).target as GateAST._Ident).name == n:
			v = (s as GateAST._AssignStmt).value
		elif s is GateAST._VarDecl:
			v = (s as GateAST._VarDecl).value
		if v != null and _gate_helper_on(v, n):
			return true
	return false


static func _gate_helper_on(v, n: String) -> bool:
	var read: Dictionary = {}
	GateChecker.idents_in(v, read)
	if not read.has(n):
		return false
	var found: Array = [false]
	_find_gate_call(v, found)
	return found[0]


static func _find_gate_call(e, found: Array) -> void:
	if e == null or found[0] or not (e is Object) or (e as Object).get_script() == null:
		return
	if e is GateAST._Member and (e as GateAST._Member).name.begins_with("_gate_"):
		found[0] = true
		return
	for prop in (e as Object).get_property_list():
		var pn: String = prop["name"]
		if pn in ["script", "Built-in script", "RefCounted", "Object"]:
			continue
		var x = (e as Object).get(pn)
		if x is Array:
			for y in x:
				_find_gate_call(y, found)
		elif x is Object:
			_find_gate_call(x, found)


func _would_copy(pp: GateAST._Param) -> bool:
	if pp.is_rest or _in_gate_helper:
		return false
	var t: GateAST._TypeRef = pp.type
	if t == null or (t.array_depth == 0 and not t.is_union() and not t.is_tuple() and not t.is_dict()
			and GateTypes.canonical(t.name) == "Variant"):
		return _structs_visible()
	if t.array_depth != 0 or t.is_dict() or t.is_tuple():
		return false
	if t.is_union():
		for m in t.union_members:
			if (m as GateAST._TypeRef).array_depth == 0 and _is_value_class((m as GateAST._TypeRef).name):
				return true
		return false
	return _is_value_class(t.name)


func _entry_copy(pp: GateAST._Param) -> String:
	if pp.is_rest:
		return ""
	var c: String = _copied(pp.name, pp.type)
	return "" if c == pp.name else "%s = %s" % [pp.name, c]


func _arg_text(c: GateAST._Call, fd: GateAST._FuncDecl, i: int) -> String:
	return _copy_value(c.args[i]) if _arg_copies(c, fd, i) else _expr(c.args[i])


func _arg_copies(c: GateAST._Call, fd: GateAST._FuncDecl, i: int) -> bool:
	if fd == null and i > 0 and c.callee is GateAST._Member \
			and ASKS_KEY_ONLY.has((c.callee as GateAST._Member).name):
		return true   # the value it adds is stored
	if fd == null and _keeps_no_arg(c):
		return false
	if fd == null or i >= fd.params.size() or not _would_copy(fd.params[i]):
		return true
	for j in range(i + 1, c.args.size()):
		if not _runs_no_code(c.args[j]):
			return true
	return c.callee is GateAST._Member and not _runs_no_code((c.callee as GateAST._Member).target)


const ASKS_ONLY := {"get": true, "has": true, "erase": true, "find_key": true,
	"get_or_add": true, "has_all": true, "count": true, "find": true, "rfind": true}
const ASKS_KEY_ONLY := {"get_or_add": true}


func _keeps_no_arg(c: GateAST._Call) -> bool:
	if c.callee is GateAST._Member:
		if ASKS_ONLY.has((c.callee as GateAST._Member).name):
			return true   # a key or a value looked for, never a value stored
		return (c.callee as GateAST._Member).name.begins_with("_gate_") or _gate_lambda_call(c)
	if c.callee is GateAST._Ident:
		var n: String = (c.callee as GateAST._Ident).name
		return ((GateInfer.PURE_GLOBALS.has(n) or INSPECT_ONLY.has(n)) and not _declared_funcs.has(n)
			and not _may_be_value(c.callee as GateAST._Ident) and _structs_visible())
	return false


const INSPECT_ONLY := {"is_same": true, "var_to_bytes": true, "var_to_bytes_with_objects": true,
	"inst_to_dict": true, "print_verbose": true}


static func _gate_lambda_call(c: GateAST._Call) -> bool:
	return (c.callee is GateAST._Member and (c.callee as GateAST._Member).name == "call"
		and _gate_lambda((c.callee as GateAST._Member).target))


static func _gate_lambda(e) -> bool:
	if not (e is GateAST._Lambda) or (e as GateAST._Lambda).params.size() != 1 \
			or ((e as GateAST._Lambda).params[0] as GateAST._Param).name != "__v":
		return false
	var found: Array = [false]
	_find_gate_call(e, found)
	return found[0]


func _runs_no_code(e) -> bool:
	if e == null or e is GateAST._Literal or e is GateAST._Ident or e is GateAST._SelfExpr \
			or e is GateAST._Lambda:
		return true
	if e is GateAST._Member:
		return _runs_no_code((e as GateAST._Member).target)
	if e is GateAST._Index:
		return _runs_no_code((e as GateAST._Index).target) and _runs_no_code((e as GateAST._Index).index)
	if e is GateAST._Unary:
		return _runs_no_code((e as GateAST._Unary).operand)
	if e is GateAST._Binary:
		return (_binary_lowering(e) == "" and _runs_no_code((e as GateAST._Binary).left)
			and _runs_no_code((e as GateAST._Binary).right))
	if e is GateAST._ArrayLit:
		for el in (e as GateAST._ArrayLit).elements:
			if not _runs_no_code(el):
				return false
		return true
	return false


func _is_value_class(n: String) -> bool:
	var st: Dictionary = _struct_of(n)
	return not st.is_empty() and st["lowering"] != "vector"


func _copied(text: String, tr: GateAST._TypeRef) -> String:
	if tr == null or (tr.array_depth == 0 and not tr.is_union() and not tr.is_tuple()
			and not tr.is_dict() and GateTypes.canonical(tr.name) == "Variant"):
		return _guarded_copy(text) if _structs_visible() else text
	if tr.array_depth != 0 or tr.is_dict() or tr.is_tuple():
		return text
	if tr.is_union():
		var tests: PackedStringArray = PackedStringArray()
		for m in tr.union_members:
			var mt: GateAST._TypeRef = m
			if mt.array_depth == 0 and _is_value_class(mt.name):
				var bare: GateAST._TypeRef = GateAST._TypeRef.new()
				bare.name = mt.name
				tests.append("%s is %s" % [text, _map_type(bare)])
		if tests.is_empty():
			return text
		return "(%s._gate_copy() if %s else %s)" % [text, " or ".join(tests), text]
	if not _is_value_class(tr.name):
		return text
	if tr.nullable:
		return "(%s._gate_copy() if %s != null else null)" % [text, text]
	return "%s._gate_copy()" % text


func _emit_postfix_spine(e) -> String:
	var steps: Array = []
	var node = e
	while true:
		if node is GateAST._Member:
			var m: GateAST._Member = node
			if m.safe or _soa_name(m.target) != "" or not _vector_struct_of(m.target).is_empty():
				return ""
			if not _swizzle_of(m).is_empty():
				return ""   # a swizzle is not a member access; let _expr rewrite it
			if m.target is GateAST._Ident and _soa_cursors.has((m.target as GateAST._Ident).name):
				return ""
			steps.push_front(node)
			node = m.target
		elif node is GateAST._Index:
			var ix: GateAST._Index = node
			if ix.safe or _soa_name(ix.target) != "":
				return ""
			steps.push_front(node)
			node = ix.target
		else:
			break
	if steps.size() < 32:
		return ""   # short enough for the readable path
	var out: String = _postfix_base(node)
	var plain: bool = _stable(node, out)   # nothing read yet that could change
	for st in steps:
		if st is GateAST._Member:
			out += ".%s" % (st as GateAST._Member).name
			plain = false
			continue
		var before: int = _pending.size()
		var itext: String = _expr((st as GateAST._Index).index)
		if _pending.size() > before and not plain and _no_hoist_ctx() == "" and _in_lvalue == 0:
			var t: String = _new_tmp()
			_hoist_at(before, "var %s = %s" % [t, out])
			out = t
		out += "[%s]" % itext
		plain = false
	return out


func _postfix_base(e) -> String:
	return _paren_below(e, PREC_ATOM)


func _paren_below(e, floor_prec: int) -> String:
	var s: String = _expr(e)
	if _text_prec(e, s) < floor_prec and not _is_bare_ident(s):
		return "(%s)" % s
	return s


func _emit_binary(b: GateAST._Binary) -> String:
	var sops: Dictionary = _ops_of(_static_type_of(b.left))
	var low: String = _binary_lowering(b)
	if low != "" and (sops.has(b.op) or b.op == "!=" and sops.has("==")):
		var derived_ne: bool = not sops.has(b.op)
		var mname: String = String(sops["=="] if derived_ne else sops[b.op])
		var sp: PackedStringArray = _ordered([b.left, b.right],
			func(i: int) -> String: return _postfix_base(b.left) if i == 0 else _expr(b.right))
		var left: String = sp[0]
		if not _stable(b.left, left) and not _stable(b.right, sp[1]):
			var ctx: String = _no_hoist_ctx()
			if ctx == "":
				var t: String = _new_tmp()
				_hoist("var %s = %s" % [t, left])
				left = t
			elif ctx != "const":
				var lam: String = "(func(__l): return __l.%s(%s)).call(%s)" % [mname, sp[1], left]
				return ("not " + lam) if derived_ne else lam
		var call: String = "%s.%s(%s)" % [left, mname, sp[1]]
		return ("not " + call) if derived_ne else call
	if low != "" and (b.op == "in" or b.op == "not in"):
		var ip: PackedStringArray = _ordered([b.left, b.right],
			func(i: int) -> String: return _expr(b.left) if i == 0 else _expr(b.right))
		var found: String = "%s(%s, %s, 0, 1) >= 0" % [_in_struct_text(b), ip[1], ip[0]]
		return found if b.op == "in" else "not (%s)" % found
	if low != "":
		var ep: PackedStringArray = _ordered([b.left, b.right],
			func(i: int) -> String: return _expr(b.left) if i == 0 else _expr(b.right))
		var eq: String = "%s(%s, %s)" % [_eqv_text(b), ep[0], ep[1]]
		return eq if b.op == "==" else "not " + eq
	var op: String = b.op
	if op == "not in":
		var np: PackedStringArray = _ordered([b.left, b.right],
			func(i: int) -> String: return _expr(b.left) if i == 0 else _expr(b.right))
		return "not (%s in %s)" % [np[0], np[1]]
	var p: int = PREC.get(op, PREC_ATOM)
	if (op == "and" or op == "or") and b.left is GateAST._Binary and (b.left as GateAST._Binary).op == op:
		var achain: Array = []
		var anode = b
		while anode is GateAST._Binary and (anode as GateAST._Binary).op == op:
			achain.append(anode)
			anode = (anode as GateAST._Binary).left
		achain.reverse()
		if achain.size() > 1:
			var saved_p: PackedStringArray = _pending
			var diag_mark: int = diagnostics.items.size()
			_pending = PackedStringArray()
			var parts: PackedStringArray = PackedStringArray()
			parts.append(_paren_below((achain[0] as GateAST._Binary).left, p))
			for n in achain:
				parts.append(_paren_below((n as GateAST._Binary).right, p + 1))
			var chain_pending: PackedStringArray = _pending
			_pending = saved_p
			if chain_pending.is_empty():
				return (" %s " % op).join(parts)
			diagnostics.items.resize(diag_mark)

	if op != "and" and op != "or" and b.left is GateAST._Binary:
		var spine_types: Dictionary = _left_spine_types(b)
		var chain: Array = []
		var node = b
		while node is GateAST._Binary:
			var nb: GateAST._Binary = node
			if nb.op == "and" or nb.op == "or" or nb.op == "not in":
				break
			var lt2: String = String(spine_types.get(nb, ""))
			if lt2 != "" and not (_ops_of(lt2) as Dictionary).is_empty():
				break
			if not (nb.left is GateAST._Binary):
				break
			var child: GateAST._Binary = nb.left
			if int(PREC.get(child.op, PREC_ATOM)) < int(PREC.get(nb.op, PREC_ATOM)):
				break
			if child.op == "and" or child.op == "or" or child.op == "not in":
				break
			chain.append(nb)
			node = child
		chain.reverse()
		if chain.size() > 1:
			var first: GateAST._Binary = chain[0]
			var nodes: Array = [first.left]
			for n in chain:
				nodes.append((n as GateAST._Binary).right)
			var texts: PackedStringArray = _ordered(nodes, func(i: int) -> String:
				if i == 0:
					return _paren_below(first.left, int(PREC.get(first.op, PREC_ATOM)))
				var bn: GateAST._Binary = chain[i - 1]
				return _paren_below(bn.right, int(PREC.get(bn.op, PREC_ATOM)) + 1))
			var out: String = texts[0]
			for i in chain.size():
				out += " %s %s" % [(chain[i] as GateAST._Binary).op, texts[i + 1]]
			return out
	if op == "and" or op == "or":
		var lhs: String = _paren_below(b.left, p)
		var saved: PackedStringArray = _pending
		_pending = PackedStringArray()
		var r: String = _lazy_part(b.right, false, p + 1) if _lazy_ctx() else _paren_below(b.right, p + 1)
		var rhs_pending: PackedStringArray = _pending
		_pending = saved
		if rhs_pending.is_empty():
			return "%s %s %s" % [lhs, op, r]
		return _guarded_operand(op, b.left, lhs, rhs_pending, r)
	var pair: PackedStringArray = _ordered([b.left, b.right], func(i: int) -> String:
		return _paren_below(b.left, p) if i == 0 else _paren_below(b.right, p + 1))
	return "%s %s %s" % [pair[0], op, pair[1]]


func _guarded_operand(op: String, left, lhs: String, rhs_pending: PackedStringArray, rhs: String) -> String:
	var t: String = _new_tmp()
	var seed: String = "false" if op == "and" else "true"
	var cond: String = lhs if op == "and" else _not_text(left, lhs)
	_hoist("var %s = %s" % [t, seed])
	_hoist("if %s:" % cond)
	_hoist_nested(rhs_pending)
	_hoist_in_block("%s = %s %s" % [t, "true and" if op == "and" else "false or", rhs])
	return t


func _emit_widen(w: GateAST._Widen) -> String:
	var inner = w.args[0]
	var text: String = _expr(inner)
	var subject: String = text
	var wrap: bool = false
	if not _repeatable(inner, text):
		var ctx: String = _no_hoist_ctx()
		if ctx == "":
			subject = _render_once(inner, text)
		elif ctx != "const" and ctx != "annotation":
			subject = "__gate_v"
			wrap = true
	var out: String
	var last: Array = w.guards[w.guards.size() - 1]
	if String(last[0]) == "null":
		out = "(%s(%s) if %s != null else null)" % [last[1], subject, subject]
	elif w.guards.size() == 1:
		out = "(%s(%s) if %s is %s else %s)" % [last[1], subject, subject, last[0], subject]
	else:
		var chain: String = "%s(%s)" % [last[1], subject]
		var tests: PackedStringArray = PackedStringArray(["%s is %s" % [subject, last[0]]])
		for i in range(w.guards.size() - 2, -1, -1):
			var g: Array = w.guards[i]
			chain = "(%s(%s) if %s is %s else %s)" % [g[1], subject, subject, g[0], chain]
			tests.insert(0, "%s is %s" % [subject, g[0]])
		out = "(%s if %s else %s)" % [chain, " or ".join(tests), subject]
	if wrap:
		return "(func(__gate_v): return %s).call(%s)" % [out, text]
	return out


func _emit_is(ie: GateAST._IsExpr) -> String:
	var tname: String = ie.type.name
	if not _is_known_native(tname) and _looks_like_interface(tname):
		_want_iface_helper()
		var expr: String = "__gate_is(%s, \"%s\")" % [_paren_below(ie.operand, PREC_TYPE_TEST), tname]
		return "not " + expr if ie.negated else expr
	var mapped: String = _map_type(ie.type)
	# `int[]` may be lowered as either, so both count. The lambda reads the operand once.
	var packed: String = _packed_twin(ie.type, mapped)
	if packed != "":
		var call: String = "(func(__gate_v): return __gate_v is %s or __gate_v is %s).call(%s)" \
			% [mapped, packed, _expr(ie.operand)]
		return "not " + call if ie.negated else call
	var operand: String = _paren_below(ie.operand, PREC_TYPE_TEST)
	var s: String = "%s is %s" % [operand, mapped]
	return "not (%s)" % s if ie.negated else s


func _check_struct_arity(name: String, st: Dictionary, c: GateAST._Call) -> void:
	var n_fields: int = (st["fields"] as Array).size()
	var given: int = c.args.size()
	if given <= n_fields and _defaults_cover(st, given):
		return
	diagnostics.error(
		"struct '%s' has %d field(s) but %d argument(s) were given"
			% [name, n_fields, given], c.line, c.col,
		"the constructor takes one value per field, in declaration order: %s."
			% ", ".join(PackedStringArray(st["fields"])))


func _partial_vector_ctor(c: GateAST._Call) -> Dictionary:
	var sname: String = ""
	var st: Dictionary = {}
	if c.callee is GateAST._Ident:
		sname = (c.callee as GateAST._Ident).name
		if CTOR_SHORTHAND.has(sname) and not _shorthand_taken(sname) and not GateTypes.shadowed.has(sname):
			return {}
		st = _ctor_struct_of(sname)
	elif c.callee is GateAST._Member and not (c.callee as GateAST._Member).safe:
		sname = (c.callee as GateAST._Member).name
		if not _is_namespace_ref((c.callee as GateAST._Member).target):
			return {}
		st = _struct_of(sname)
	if st.is_empty() or st["lowering"] != "vector" or c.args.is_empty() \
			or c.args.size() >= (st["fields"] as Array).size() or not _defaults_cover(st, c.args.size()):
		return {}
	return {"name": sname, "st": st}


func _defaults_cover(st: Dictionary, given: int) -> bool:
	if given == 0:
		return true
	var trefs: Array = st.get("typerefs", [])
	for fi in range(given, (st["fields"] as Array).size()):
		var tr = trefs[fi] if fi < trefs.size() else null
		if tr != null and (tr as GateAST._TypeRef).nullable:
			continue   # `T?` defaults to null
		if _default_kind(st, fi) == "none":
			return false
	return true


func _emit_call(c: GateAST._Call) -> String:
	if (c.callee is GateAST._Ident and (c.callee as GateAST._Ident).name == "preload"
			and c.args.size() == 1 and c.args[0] is GateAST._Literal):
		var lit: GateAST._Literal = c.args[0]
		if lit.kind == "string":
			var target: String = lit.raw
			if target.length() >= 2:
				target = target.substr(1, target.length() - 2)
			if target != "":
				_preload_targets[target] = true

	if c.callee is GateAST._Member:
		var cm: GateAST._Member = c.callee
		var sname: String = _soa_name(cm.target)
		if sname != "":
			var soa_text: String = _emit_soa_call(sname, cm, c)
			if soa_text == "" and c != _stmt_expr:
				diagnostics.error("'%s.%s()' changes the @soa array '%s' and has no value"
						% [sname, cm.name, sname], c.line, c.col,
					"@soa keeps each field in its own array, so this is several calls, not one "
					+ "value. Write it as its own statement.")
				return "null"
			return soa_text

	var search: String = _struct_search(c)
	if search != "":
		return search

	if c.callee is GateAST._Member and (c.callee as GateAST._Member).safe:
		var scm: GateAST._Member = c.callee
		var ssn: String = _observable_prop(scm.target)
		if ssn != "" and _struct_mutators(ssn).has(scm.name):
			if _no_hoist_ctx() != "":
				diagnostics.error("this changes the @observable '%s' in place, which needs statements"
						% _observable_lvalue(scm.target), c.line, c.col,
					"the call runs on a copy that is then assigned back, so the signal fires. "
					+ "Make the call inside a function.")
				return "null"
			var slv: String = _observable_lvalue(scm.target)
			var sres: String = _new_tmp()
			var st: String = _new_tmp()
			_fn_locals[st] = {"t": ssn, "e": ""}
			_var_types[st] = ssn
			var srecv: GateAST._Member = GateAST._Member.new()
			srecv.at(scm.line, scm.col)
			srecv.name = scm.name
			var sid: GateAST._Ident = GateAST._Ident.new()
			sid.at(scm.line, scm.col)
			sid.name = st
			srecv.target = sid
			var soc: GateAST._Call = GateAST._Call.new()
			soc.at(c.line, c.col)
			soc.callee = srecv
			soc.args = c.args
			var saved_sp: PackedStringArray = _pending
			_pending = PackedStringArray()
			var stext: String = _emit_call(soc)
			var inner: PackedStringArray = _pending
			_pending = saved_sp
			_hoist("var %s = null" % sres)
			_hoist("if %s != null:" % slv)
			_hoist("\tvar %s = %s._gate_copy()" % [st, slv])
			for h in inner:
				_hoist("\t" + h)
			_hoist("\t%s = %s" % [sres, stext])
			_hoist("\t%s = %s" % [slv, st])
			return sres

	var obs: Dictionary = _observable_call_root(c)
	if not obs.is_empty():
		if _no_hoist_ctx() != "":
			diagnostics.error("this changes the @observable '%s' in place, which needs statements"
					% _observable_lvalue(obs["node"]), c.line, c.col,
				"the call runs on a copy that is then assigned back, so the signal fires. "
				+ "Make the call inside a function.")
			return "null"
		var first_args: Array = _args_first(c)
		var opened: Array = _observable_open(obs, c.callee)
		var oc: GateAST._Call = GateAST._Call.new()
		oc.at(c.line, c.col)
		oc.callee = opened[2]
		oc.args = first_args
		var r: String = _new_tmp()
		_hoist("var %s = %s" % [r, _emit_call(oc)])
		_hoist("%s = %s" % [opened[0], opened[1]])
		return r

	var init_form: Dictionary = _init_call_form(c)
	if not init_form.is_empty():
		return _emit_init_call(c, init_form)
	var inst_form: Dictionary = _instantiate_form(c)
	if not inst_form.is_empty():
		return _emit_instantiate_init(inst_form)
	_warn_init_traps(c)

	var callee_fd: GateAST._FuncDecl = _gate_callee(c)
	if c.callee is GateAST._Member and (c.callee as GateAST._Member).safe and _no_hoist_ctx() != "":
		var im: GateAST._Member = c.callee
		var iargs: PackedStringArray = PackedStringArray()
		for ai in c.args.size():
			iargs.append(_lazy_part(c.args[ai], _arg_copies(c, callee_fd, ai)))
		return _safe_inplace(im.target, _postfix_base(im.target), ".%s(%s)"
			% [_method_emit_name(im.target, im.name, c.args.size(), im.member_class),
				", ".join(iargs)])
	if c.callee is GateAST._Member and (c.callee as GateAST._Member).safe:
		var sm: GateAST._Member = c.callee
		var recv: String = _render_once(sm.target, _postfix_base(sm.target))
		var saved_p: PackedStringArray = _pending
		_pending = PackedStringArray()
		var sargs: PackedStringArray = _ordered(c.args,
			func(i: int) -> String: return _arg_text(c, callee_fd, i))
		var arg_pending: PackedStringArray = _pending
		_pending = saved_p
		var sname: String = _method_emit_name(sm.target, sm.name, c.args.size(), sm.member_class)
		if _no_hoist == "guard" and arg_pending.is_empty() and _repeatable(sm.target, recv):
			return "(%s.%s(%s) if %s != null else null)" % [recv, sname, ", ".join(sargs), recv]
		var sres: String = _new_tmp()
		if arg_pending.is_empty() or _no_hoist_ctx() != "":
			_rehoist(arg_pending)
			_hoist("var %s = (%s.%s(%s) if %s != null else null)"
				% [sres, recv, sname, ", ".join(sargs), recv])
			return sres
		_hoist("var %s = null" % sres)
		_hoist("if %s != null:" % recv)
		_hoist_nested(arg_pending)
		_hoist_in_block("%s = %s.%s(%s)" % [sres, recv, sname, ", ".join(sargs)])
		return sres

	if (c.callee is GateAST._Ident and (c.callee as GateAST._Ident).name == "assert"
			and not _declared_funcs.has("assert") and _no_hoist_ctx() == ""):
		var saved_nh: String = _no_hoist
		_no_hoist = "assert"
		var aargs: PackedStringArray = PackedStringArray()
		for aa in c.args:
			aargs.append(_copy_value(aa))
		_no_hoist = saved_nh
		return "assert(%s)" % ", ".join(aargs)

	var stored: String = _struct_store(c)
	if stored != "":
		return stored

	var vpart: Dictionary = _partial_vector_ctor(c)
	if not vpart.is_empty():
		var vfields: Array = (vpart["st"] as Dictionary)["fields"]
		return _build_struct(vpart["st"], "", vfields.slice(0, c.args.size()), c.args, c)

	var recv_node = null
	if c.callee is GateAST._Member and _plain_callee(c.callee):
		recv_node = (c.callee as GateAST._Member).target
	var parts: Array = c.args.duplicate()
	if recv_node != null:
		parts.append(recv_node)
	var texts: PackedStringArray = _ordered(parts, func(i: int) -> String:
		return _arg_text(c, callee_fd, i) if i < c.args.size() else _postfix_base(recv_node))
	var args: PackedStringArray = texts.slice(0, c.args.size())
	var recv_text: String = texts[c.args.size()] if recv_node != null else ""

	if c.callee is GateAST._Ident:
		var n: String = (c.callee as GateAST._Ident).name
		if CTOR_SHORTHAND.has(n) and not _shorthand_taken(n) and not GateTypes.shadowed.has(n):
			return "%s(%s)" % [CTOR_SHORTHAND[n], ", ".join(args)]
		var st: Dictionary = _ctor_struct_of(n)
		if not st.is_empty():
			_check_struct_arity(n, st, c)
			if st["lowering"] == "vector":
				if args.is_empty():
					return _build_struct(st, "", [], [], c)
				return "%s(%s)" % [st["vector"], ", ".join(_vec_args(st, args))]
			var salias: String = _extern_alias(n)
			if salias != "":
				return "%s.%s.new(%s)" % [salias, n, ", ".join(args)]
			return "%s.new(%s)" % [n, ", ".join(args)]

	if c.callee is GateAST._Member and (c.callee as GateAST._Member).name == "new":
		var nm: GateAST._Member = c.callee
		var nref: String = _class_ref_text(nm.target)
		var nst: Dictionary = _struct_of(nref) if nref != "" else {}
		if not nst.is_empty() and not _fn_locals.has(nref.get_slice(".", 0)):
			if nst["lowering"] == "vector" or c.args.size() > (nst["fields"] as Array).size():
				_check_struct_arity(nref, nst, c)
			if nst["lowering"] == "vector":
				if args.is_empty():
					return _build_struct(nst, "", [], [], c)
				return "%s(%s)" % [nst["vector"], ", ".join(_vec_args(nst, args))]

	if c.callee is GateAST._Member:
		var qm: GateAST._Member = c.callee
		var qpath: String = _class_ref_text(qm)
		var qst: Dictionary = _struct_of(qpath) if qpath != "" else {}
		if qst.is_empty():
			qst = _struct_of(qm.name)
		if not qst.is_empty() and _is_namespace_ref(qm.target):
			_check_struct_arity(qm.name, qst, c)
			if qst["lowering"] == "vector":
				if args.is_empty():
					return _build_struct(qst, "", [], [], c)
				return "%s(%s)" % [qst["vector"], ", ".join(_vec_args(qst, args))]
			return "%s.%s.new(%s)" % [_expr(qm.target), qm.name, ", ".join(args)]

	if c.callee is GateAST._Ident:
		var base: String = (c.callee as GateAST._Ident).name
		var mangled: String = _resolve_overload(base, c.args.size())
		if mangled != "" and _overload_declared_by_chain(base, _cur_class):
			return "%s(%s)" % [mangled, ", ".join(args)]
	elif c.callee is GateAST._Member:
		var mem: GateAST._Member = c.callee
		var mangled2: String = _resolve_overload(mem.name, c.args.size())
		if mangled2 != "" and mem.member_class != "":
			if _overload_declared_by_chain(mem.name, mem.member_class):
				return "%s.%s(%s)" % [recv_text if recv_node != null else _postfix_base(mem.target),
					mangled2, ", ".join(args)]
		if mangled2 != "":
			var mrecv: String = recv_text if recv_node != null else _postfix_base(mem.target)
			if mem.target is GateAST._SelfExpr:
				if _overload_declared_by_chain(mem.name, _cur_class):
					return "%s.%s(%s)" % [mrecv, mangled2, ", ".join(args)]
				return "%s.%s(%s)" % [mrecv, mem.name, ", ".join(args)]
			var owner: String = _static_type_of(mem.target)
			if owner != "" and _overload_declared_by_chain(mem.name, owner):
				return "%s.%s(%s)" % [mrecv, mangled2, ", ".join(args)]
			if owner == "" and mem.target is GateAST._Ident:
				var tn: String = (mem.target as GateAST._Ident).name
				if _local_types.has(tn) or not _struct_of(tn).is_empty():
					owner = tn
			if owner == "" and mem.target is GateAST._Ident and (mem.target as GateAST._Ident).name == "super":
				owner = _cur_base
			if owner != "" and _overload_declared_by(mem.name, owner):
				return "%s.%s(%s)" % [mrecv, mangled2, ", ".join(args)]
			if owner == "":
				diagnostics.warn("'%s' is overloaded, and the type of the value it is called on is "
						% mem.name + "not known here, so this call cannot pick one", c.line, c.col,
					"GDScript will look for a method named '%s' itself. Give the value a type, or "
						% mem.name + "call it on one whose type GATE can see")
			if recv_node != null:
				return "%s.%s(%s)" % [mrecv, mem.name, ", ".join(args)]

	if recv_node != null:
		var cmm: GateAST._Member = c.callee
		return "%s.%s(%s)" % [recv_text, _member_name(
			cmm.member_class if cmm.member_class != "" else _owner_key(recv_node),
			(c.callee as GateAST._Member).name), ", ".join(args)]
	if c.callee is GateAST._Ident:
		var fname: String = (c.callee as GateAST._Ident).name
		if not _struct_of(fname).is_empty() and _ctor_struct_of(fname).is_empty():
			return "%s(%s)" % [fname, ", ".join(args)]   # a function, not the other file's struct
	_swizzle_exempt = c.callee
	var callee: String = _postfix_base(c.callee)
	_swizzle_exempt = null
	return "%s(%s)" % [callee, ", ".join(args)]


func _args_first(c: GateAST._Call) -> Array:
	var texts: PackedStringArray = _ordered(c.args,
		func(i: int) -> String: return _copy_value(c.args[i]))
	var out: Array = []
	for i in c.args.size():
		var text: String = texts[i]
		if not _stable(c.args[i], text):
			var t: String = _new_tmp()
			_hoist("var %s = %s" % [t, text])
			text = t
		var r: GateAST._RawExpr = GateAST._RawExpr.new()
		r.at(c.args[i].line, c.args[i].col)
		r.text = text
		out.append(r)
	return out


func _plain_callee(cm: GateAST._Member) -> bool:
	if cm.safe or _soa_name(cm.target) != "":
		return false
	if cm.target is GateAST._Ident and _soa_cursors.has((cm.target as GateAST._Ident).name):
		return false
	if cm.target is GateAST._Index and _soa_name((cm.target as GateAST._Index).target) != "":
		return false
	if not _vector_struct_of(cm.target).is_empty():
		return false
	if cm.target is GateAST._Ident and _scalar_names.has(
			"%s.%s" % [(cm.target as GateAST._Ident).name, cm.name]):
		return false
	if not _struct_of(cm.name).is_empty() and _is_namespace_ref(cm.target):
		return false
	return true


## `X.new({...})` sets properties only when GDScript would reject the call, i.e. when
## `_init` takes nothing. Otherwise the dictionary is an argument, as written.
func _init_call_form(c: GateAST._Call) -> Dictionary:
	if c.args.size() != 1 or not (c.args[0] is GateAST._DictLit):
		return {}
	var dl: GateAST._DictLit = c.args[0]
	for i in dl.keys.size():
		if not (dl.keys[i] is GateAST._Ident) or i >= dl.values.size() or dl.values[i] == null:
			return {}
	if c.callee is GateAST._Member:
		var cm: GateAST._Member = c.callee
		if cm.safe:
			return {}
		if cm.name == "new":
			var ref: String = _class_ref_text(cm.target)
			var generic: bool = cm.target is GateAST._Ident and (cm.target as GateAST._Ident).generic_base != ""
			if generic:
				ref = (cm.target as GateAST._Ident).generic_base
			if ref == "" or (cm.target is GateAST._Ident and _fn_locals.has(ref)):
				return {}
			var nst: Dictionary = _struct_of(ref) if not generic else {}
			if not nst.is_empty():
				return {} if _dict_positional(nst, dl) else {"name": ref, "dict": dl, "ctor": _expr(cm.target)}
			if _ctor_takes_params(_scope_class, ref, generic) != 0:
				return {}
			var ctor: String = _expr(cm.target)
			return {"name": ref, "dict": dl, "ctor": ctor}
		if not (cm.target is GateAST._Ident):
			return {}
		var nst: Dictionary = _struct_of(cm.name)
		if not nst.is_empty() and _is_namespace_ref(cm.target) and not _dict_positional(nst, dl):
			return {"name": cm.name, "dict": dl, "ctor": "%s.%s" % [_expr(cm.target), cm.name]}
		return {}
	if c.callee is GateAST._Ident:
		var sn: String = (c.callee as GateAST._Ident).name
		if CTOR_SHORTHAND.has(sn) and not _shorthand_taken(sn) and not GateTypes.shadowed.has(sn):
			return {}
		var st: Dictionary = _ctor_struct_of(sn)
		if st.is_empty() or _dict_positional(st, dl):
			return {}
		var salias: String = _extern_alias(sn)
		return {"name": sn, "dict": dl, "ctor": "%s.%s" % [salias, sn] if salias != "" else sn}
	return {}


func _dict_positional(st: Dictionary, dl: GateAST._DictLit) -> bool:
	var types: Array = st["types"]
	var trefs: Array = st.get("typerefs", [])
	if types.is_empty():
		return false
	var first = trefs[0] if not trefs.is_empty() else null
	var holds_dict: bool = (String(types[0]) == "Variant"
		or GateTypes.canonical(String(types[0])) == "Dictionary"
		or (first != null and (first as GateAST._TypeRef).is_dict()))
	if not holds_dict:
		return false
	if dl.keys.is_empty():
		return true
	for k in dl.keys:
		if not (st["fields"] as Array).has((k as GateAST._Ident).name):
			return true
	return false


func _emit_init_call(c: GateAST._Call, form: Dictionary) -> String:
	var dl: GateAST._DictLit = form["dict"]
	var name: String = form["name"]
	var st: Dictionary = _struct_of(name)
	var keys: Array = []
	var values: Array = []
	var ok: bool = _init_keys_distinct(dl)
	for i in dl.keys.size():
		var kid: GateAST._Ident = dl.keys[i]
		if i < dl.lua_keys.size() and dl.lua_keys[i]:
			diagnostics.error("initializer keys are written name: value", kid.line, kid.col,
				"write `{ %s: ... }`. With `=` it would be a dictionary whose key is the "
				% kid.name + "string \"%s\"." % kid.name)
			ok = false
			continue
		if not st.is_empty():
			if not (st["fields"] as Array).has(kid.name):
				diagnostics.error("struct '%s' has no field '%s'" % [name, kid.name],
					kid.line, kid.col,
					"its fields are: %s." % ", ".join(PackedStringArray(st["fields"])))
				ok = false
				continue
		elif _class_has_property(_scope_class, name, kid.name) == 0:
			diagnostics.error("'%s' has no property '%s'" % [name, kid.name], kid.line, kid.col,
				"initializer keys name properties of the object being built.")
			ok = false
			continue
		var packed: bool = not st.is_empty() and st["lowering"] == "vector"
		keys.append(kid.name if packed else _member_name(_name_key(_scope_class, name), kid.name))
		values.append(dl.values[i])
	if not ok:
		return "null"
	return _lower_init(name, String(form["ctor"]), keys, values, c)


func _init_keys_distinct(dl: GateAST._DictLit) -> bool:
	var seen: Dictionary = {}
	var ok: bool = true
	for k in dl.keys:
		var kid: GateAST._Ident = k
		if seen.has(kid.name):
			diagnostics.error("initializer key '%s' is given twice" % kid.name, kid.line, kid.col,
				"each property can be set once.")
			ok = false
		seen[kid.name] = true
	return ok


func _lower_init(name: String, ctor: String, keys: Array, values: Array, at_node = null) -> String:
	var st: Dictionary = _struct_of(name)
	if not st.is_empty():
		return _build_struct(st, ctor, keys, values, at_node)
	return _lower_construct(ctor + ".new()", ctor, keys, values)


func _default_kind(st: Dictionary, i: int) -> String:
	if not st.has("kinds"):
		st["kinds"] = {}
	if (st["kinds"] as Dictionary).has(i):
		return st["kinds"][i]
	var d = (st["defaults"] as Array)[i]
	var kind: String = "none"
	if d != null:
		if _portable_default(st, d, i):
			kind = "inline"
		elif st["lowering"] == "vector":
			kind = "site"
		elif _default_needs_instance(st, d):
			kind = "instance"
		else:
			kind = "helper"
	st["kinds"][i] = kind
	return kind


func _portable_default(st: Dictionary, e, i: int) -> bool:
	if e is GateAST._Literal:
		return true
	if e is GateAST._Unary:
		return _portable_default(st, (e as GateAST._Unary).operand, i)
	if e is GateAST._Binary:
		return (_portable_default(st, (e as GateAST._Binary).left, i)
			and _portable_default(st, (e as GateAST._Binary).right, i))
	if e is GateAST._Ternary:
		var t: GateAST._Ternary = e
		return (_portable_default(st, t.cond, i) and _portable_default(st, t.if_true, i)
			and _portable_default(st, t.if_false, i))
	if e is GateAST._ArrayLit:
		for el in (e as GateAST._ArrayLit).elements:
			if not _portable_default(st, el, i):
				return false
		return true
	if e is GateAST._Ident:
		var at: int = (st["fields"] as Array).find((e as GateAST._Ident).name)
		return at >= 0 and at < i and _struct_of(String(st["types"][at])).is_empty()
	return false


func _default_needs_instance(st: Dictionary, e) -> bool:
	if e == null or not (e is Object) or (e as Object).get_script() == null:
		return false
	if (e is GateAST._SelfExpr or e is GateAST._Lambda or e is GateAST._RawExpr
			or e is GateAST._AwaitExpr):
		return true
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		var methods: Dictionary = st.get("methods", {})
		if methods.has(n):
			return not methods[n]
		return n == "super" or (not (st["fields"] as Array).has(n)
			and not (st.get("consts", {}) as Dictionary).has(n)
			and ClassDB.class_has_method("RefCounted", n))
	for prop in (e as Object).get_property_list():
		var pn: String = prop["name"]
		if pn in ["script", "Built-in script", "RefCounted", "Object"]:
			continue
		var v = (e as Object).get(pn)
		if v is Array:
			for x in v:
				if _default_needs_instance(st, x):
					return true
		elif v is Object and _default_needs_instance(st, v):
			return true
	return false


func _default_refs(st: Dictionary, i: int) -> Array:
	var d = (st["defaults"] as Array)[i]
	var out: Array = []
	if d == null:
		return out
	var read: Dictionary = {}
	GateChecker.idents_in(d, read, true)
	var fields: Array = st["fields"]
	for j in i:
		if read.has(fields[j]):
			out.append(fields[j])
	return out


func _default_helper(st: Dictionary, i: int) -> String:
	var taken: Dictionary = {}
	for f in st["fields"]:
		taken[f] = true
	for m in st.get("methods", {}):
		taken[m] = true
	for k in st.get("consts", {}):
		taken[k] = true
	var n: String = "_gate_default_%s" % st["fields"][i]
	while taken.has(n):
		n = "_" + n
	return n


func _render_default(st: Dictionary, i: int, comps: Dictionary, ctor: String, at_node,
		comp_prec: Dictionary = {}) -> String:
	var kind: String = _default_kind(st, i)
	var tr = (st["typerefs"] as Array)[i]
	if kind == "none":
		return _default_for(tr, false) if tr != null else "null"
	if kind == "helper":
		var args: PackedStringArray = PackedStringArray()
		for r in _default_refs(st, i):
			args.append(String(comps[r]))
		return "%s.%s(%s)" % [ctor, _default_helper(st, i), ", ".join(args)]
	var d = (st["defaults"] as Array)[i]
	var qualified: Dictionary = {}
	if kind == "site":
		var read: Dictionary = {}
		GateChecker.idents_in(d, read, true)
		for n in read:
			if (st["fields"] as Array).has(n):
				continue
			var r: Dictionary = _site_name(st, String(n))
			if r.has("text"):
				qualified[n] = r["text"]
			elif r.has("why"):
				var line: int = at_node.line if at_node != null else d.line
				var col: int = at_node.col if at_node != null else d.col
				diagnostics.error("struct '%s' fills in '%s' with a default that reads '%s', %s"
						% [st["name"], st["fields"][i], n, r["why"]], line, col,
					"a struct lowered to %s has no scope of its own, so its defaults are written "
						% st["vector"] + "out where it is built. %s, or pass '%s'."
						% [r["fix"], st["fields"][i]])
				return "null"
	var saved: Dictionary = _ident_renames
	var saved_prec: Dictionary = _rename_prec
	_ident_renames = qualified
	_rename_prec = {}
	for f in comps:
		_ident_renames[f] = comps[f]
		if comp_prec.has(f):
			_rename_prec[f] = comp_prec[f]   # `b * 2` with b = `a + 1` needs parentheses
	var text: String = _expr(d) if st["lowering"] == "vector" else _copy_value(d)
	_ident_renames = saved
	_rename_prec = saved_prec
	return text


func _site_name(st: Dictionary, n: String) -> Dictionary:
	var found_top: bool = false
	if String(st.get("scope", "")) != "":
		var q: String = st["scope"]
		while true:
			var names: Dictionary = _names_of_scope(q)
			if names.has(n):
				if names[n] == "instance":
					return _instance_member(n)
				if q != ".":
					return {"text": "%s.%s" % [q, n]}
				found_top = true
				break
			if q == ".":
				break
			q = String(_class_parent.get(q, "."))
	else:
		var origin: String = String(_reg_origin.get(st["name"], ""))
		var chain: Array = _extern_container(st["decl"])
		for k in range(chain.size() - 1, -1, -1):
			var ccd: GateAST._ClassDecl = chain[k][1]
			var cn: Dictionary = GateChecker.scope_names(ccd.members, ccd.form == "namespace")
			if cn.has(n):
				if cn[n] == "instance":
					return _instance_member(n)
				return {"text": "%s.%s.%s" % [_origin_alias(origin), chain[k][0], n]}
		var mn: Dictionary = _reg_module_names.get(origin, {})
		if mn.has(n):
			if mn[n] == "instance":
				return _instance_member(n)
			return {"text": "%s.%s" % [_origin_alias(origin), n]}
	if _fn_locals.has(n):
		return {"why": "but a local named '%s' hides it here" % n, "fix": "Rename the local"}
	var s: String = _scope_class
	while s != "." and s != "":
		if _class_declares(s, n):
			var short: String = s.get_slice(".", s.get_slice_count(".") - 1)
			return {"why": "but '%s' declares its own '%s'" % [short, n],
				"fix": "Nothing reaches the '%s' it means from inside '%s'. Rename one" % [n, short]}
		s = String(_class_parent.get(s, "."))
	if not found_top and _names_of_scope(".").has(n):
		return {"why": "but this file declares its own '%s'" % n, "fix": "Rename it"}
	return {}


func _class_declares(key: String, n: String) -> bool:
	var q: String = key
	var seen: Dictionary = {}
	while q != "" and q != "." and not seen.has(q):
		seen[q] = true
		if _names_of_scope(q).has(n):
			return true
		var b: Dictionary = _base_of(q)
		q = String(b["key"]) if String(b["kind"]) == "local" else ""
	return false


func _name_in_scope(n: String) -> bool:
	if n == "" or not ((n[0] >= "a" and n[0] <= "z") or n[0] == "_"):
		return true   # a constant or a class, a global one such as KEY_A included
	if _fn_locals.has(n):
		return true
	if (GateInfer.GLOBAL_FUNCTIONS.has(n) or GateTypes.BUILTIN.has(n) or ClassDB.class_exists(n)
			or Engine.has_singleton(n) or ProjectSettings.has_setting("autoload/" + n)
			or _reg_script_classes.has(n) or _reg_classes.has(n)):
		return true
	var s: String = _scope_class
	var outer: Dictionary = {}
	while s != "" and not outer.has(s):
		outer[s] = true
		var q: String = s
		var seen: Dictionary = {}
		while q != "" and not seen.has(q):
			seen[q] = true
			if _names_of_scope(q).has(n):
				return true
			var b: Dictionary = _base_of(q) if (q == "." or _class_decls.has(q)) else {"kind": "ext", "name": q}
			match String(b["kind"]):
				"local":
					q = String(b["key"])
				"ext":
					var ext: String = String(b["name"])
					if not _ext_declares(ext, n):
						break
					return true
				"none":
					if _ext_declares("RefCounted", n):
						return true
					break
				_:
					return true   # a base by path: GATE cannot see what it declares
		if s == ".":
			break
		s = String(_class_parent.get(s, "."))
	return false


func _ext_declares(cls: String, n: String) -> bool:
	var c: String = cls
	for _guard in 64:
		if c == "":
			return false
		if ClassDB.class_exists(c):
			if (ClassDB.class_has_method(c, n) or ClassDB.class_has_signal(c, n)
					or ClassDB.class_has_integer_constant(c, n) or ClassDB.class_has_enum(c, n)):
				return true
			for p in ClassDB.class_get_property_list(c):
				if String(p["name"]) == n:
					return true
			return false
		if not _reg_classes.has(c):
			return true
		if GateChecker.scope_names((_reg_classes[c] as GateAST._ClassDecl).members, false).has(n):
			return true
		c = String(_reg_bases.get(c, "RefCounted"))
	return true


func _instance_member(n: String) -> Dictionary:
	return {"why": "which belongs to an instance",
		"fix": "It is built without an instance to read '%s' from. Make '%s' a const or static" % [n, n]}


func _names_of_scope(key: String) -> Dictionary:
	if not _scope_names.has(key):
		if key == ".":
			_scope_names[key] = GateChecker.scope_names(_module_members, false)
		elif _class_decls.has(key) and _class_decls[key] != null:
			var cd: GateAST._ClassDecl = _class_decls[key]
			_scope_names[key] = GateChecker.scope_names(cd.members, cd.form == "namespace")
		else:
			_scope_names[key] = {}
	return _scope_names[key]


func _extern_container(cd: GateAST._ClassDecl) -> Array:
	for table in [_reg_namespaces, _reg_classes]:
		for top in table:
			if not _extern_origin.has(top):
				continue
			var path: Array = _container_path(table[top], cd, String(top))
			if not path.is_empty():
				return path
	return []


func _container_path(outer: GateAST._ClassDecl, cd: GateAST._ClassDecl, prefix: String) -> Array:
	for m in outer.members:
		if m == cd:
			return [[prefix, outer]]
		if m is GateAST._ClassDecl:
			var inner: Array = _container_path(m, cd, "%s.%s" % [prefix, (m as GateAST._ClassDecl).name])
			if not inner.is_empty():
				return [[prefix, outer]] + inner
	return []


func _build_struct(st: Dictionary, ctor: String, keys: Array, values: Array, at_node) -> String:
	var fields: Array = st["fields"]
	var is_vec: bool = st["lowering"] == "vector"
	var ctx: String = _no_hoist_ctx()
	var slot: Dictionary = {}
	var last: int = -1
	var in_order: bool = true
	for i in keys.size():
		var at: int = fields.find(keys[i])
		if at < last:
			in_order = false
		slot[at] = i
		last = maxi(last, at)
	var upto: int = fields.size() - 1 if is_vec else last
	var read: Dictionary = {}
	var gaps_run_code: bool = false
	for fi0 in range(upto + 1):
		if not slot.has(fi0) and _default_kind(st, fi0) == "instance":
			return _build_keyed(st, ctor, keys, values, slot, in_order)
	for fi in range(upto + 1):
		if slot.has(fi):
			continue
		var kind: String = _default_kind(st, fi)
		if kind == "helper" or kind == "site":
			gaps_run_code = true
		for r in _default_refs(st, fi):
			read[fields.find(r)] = true
	var texts: PackedStringArray = _ordered(values, func(i: int) -> String:
		return _expr(values[i]) if is_vec else _copy_value(values[i]))
	var params: PackedStringArray = PackedStringArray()
	var args: PackedStringArray = PackedStringArray()
	var comps: Dictionary = {}
	var cprec: Dictionary = {}
	for i in keys.size():
		var fi: int = fields.find(keys[i])
		cprec[keys[i]] = _prec_of(values[i])
		if (ctx != "const" and not _stable(values[i], texts[i])
				and (not in_order or read.has(fi) or gaps_run_code)):
			if ctx == "":
				var t: String = _new_tmp()
				_hoist("var %s = %s" % [t, texts[i]])
				texts[i] = t
			else:
				params.append("__a%d" % params.size())
				args.append(texts[i])
				texts[i] = params[params.size() - 1]
			cprec[keys[i]] = PREC_ATOM
		comps[keys[i]] = texts[i]
	var parts: PackedStringArray = PackedStringArray()
	for fi in range(upto + 1):
		var fname: String = fields[fi]
		if not comps.has(fname):
			var dt: String = _render_default(st, fi, comps, ctor, at_node, cprec)
			var kind: String = _default_kind(st, fi)
			cprec[fname] = (_prec_of((st["defaults"] as Array)[fi]) if kind == "inline" or kind == "site"
				else PREC_ATOM)
			var pure: bool = kind == "inline" or (kind == "none"
				and _struct_of(String(st["types"][fi])).is_empty())
			if read.has(fi) and not pure and ctx != "const":
				if ctx == "":
					var t2: String = _new_tmp()
					_hoist("var %s = %s" % [t2, dt])
					dt = t2
					cprec[fname] = PREC_ATOM
				else:
					var l: int = at_node.line if at_node != null else 0
					var c: int = at_node.col if at_node != null else 0
					diagnostics.error("building this '%s' needs a temporary, and %s has nowhere to put one"
							% [st["name"], "a field initialiser" if ctx == "field" else "this place"], l, c,
						"the default of a later field reads '%s', whose default is not a constant. " % fname
						+ "Build the value inside a function, or pass '%s'." % fname)
			comps[fname] = dt
		parts.append(comps[fname])
	var built: String = ("%s(%s)" % [st["vector"], ", ".join(_vec_args(st, parts))] if is_vec
		else "%s.new(%s)" % [ctor, ", ".join(parts)])
	if params.is_empty():
		return built
	return "(func(%s): return %s).call(%s)" % [", ".join(params), built, ", ".join(args)]


func _has_instance_default(st: Dictionary) -> bool:
	for i in (st["fields"] as Array).size():
		if _default_kind(st, i) == "instance":
			return true
	return false


func _keyed_builder(st: Dictionary) -> String:
	var n: String = "_gate_keyed"
	while (st["fields"] as Array).has(n) or (st.get("methods", {}) as Dictionary).has(n) \
			or (st.get("consts", {}) as Dictionary).has(n):
		n = "_" + n
	return n


func _build_keyed(st: Dictionary, ctor: String, keys: Array, values: Array,
		slot: Dictionary, in_order: bool) -> String:
	var fields: Array = st["fields"]
	var ctx: String = _no_hoist_ctx()
	var texts: PackedStringArray = _ordered(values, func(i: int) -> String: return _copy_value(values[i]))
	var params: PackedStringArray = PackedStringArray()
	var args: PackedStringArray = PackedStringArray()
	for i in keys.size():
		if in_order or ctx == "const" or _stable(values[i], texts[i]):
			continue
		if ctx == "":
			var t: String = _new_tmp()
			_hoist("var %s = %s" % [t, texts[i]])
			texts[i] = t
		else:
			params.append("__a%d" % params.size())
			args.append(texts[i])
			texts[i] = params[params.size() - 1]
	var given: int = 0
	var parts: PackedStringArray = PackedStringArray()
	for fi in fields.size():
		if slot.has(fi):
			given |= 1 << fi
			parts.append(texts[int(slot[fi])])
		else:
			parts.append(_placeholder_for((st["typerefs"] as Array)[fi]))
	var built: String = "%s.%s(%d, %s)" % [ctor, _keyed_builder(st), given, ", ".join(parts)]
	if params.is_empty():
		return built
	return "(func(%s): return %s).call(%s)" % [", ".join(params), built, ", ".join(args)]


func _placeholder_for(tr) -> String:
	if tr == null or (tr as GateAST._TypeRef).nullable or (tr as GateAST._TypeRef).is_union():
		return "null"
	var t: GateAST._TypeRef = tr
	var fst: Dictionary = _struct_of(t.name) if t.array_depth == 0 and not t.is_dict() else {}
	if not fst.is_empty():
		return "null" if fst["lowering"] != "vector" else "%s()" % fst["vector"]
	return _default_for(t, false)


func _lower_construct(construct: String, cast: String, keys: Array, values: Array,
		temp_type: String = "") -> String:
	if _no_hoist_ctx() != "":
		_init_helper_scopes[_scope_class] = true
		var parts: PackedStringArray = PackedStringArray()
		for i in keys.size():
			parts.append("\"%s\": %s" % [keys[i], _copy_value(values[i])])
		return "(__gate_init(%s, {%s}) as %s)" % [construct, ", ".join(parts), cast]
	var t: String = _new_tmp()
	if temp_type == "":
		_hoist("var %s := %s" % [t, construct])
	else:
		_hoist("var %s: %s = %s" % [t, temp_type, construct])
	for i in keys.size():
		_hoist("%s.%s = %s" % [t, keys[i], _copy_value(values[i])])
	return t


func _instantiate_form(c: GateAST._Call) -> Dictionary:
	if not (c.callee is GateAST._Member) or c.args.size() != 1 or not (c.args[0] is GateAST._DictLit):
		return {}
	var cm: GateAST._Member = c.callee
	if cm.safe or cm.name != "instantiate":
		return {}
	var dl: GateAST._DictLit = c.args[0]
	for i in dl.keys.size():
		if not (dl.keys[i] is GateAST._Ident) or i >= dl.values.size() or dl.values[i] == null:
			return {}
	if GateTypes.canonical(_declared_type_of(cm.target)) != "PackedScene":
		return {}
	return {"recv": cm.target, "dict": dl}


func _emit_instantiate_init(form: Dictionary) -> String:
	var dl: GateAST._DictLit = form["dict"]
	var keys: Array = []
	var values: Array = []
	var ok: bool = _init_keys_distinct(dl)
	var root: String = _declared_scene_root(form["recv"])
	for i in dl.keys.size():
		var kid: GateAST._Ident = dl.keys[i]
		if i < dl.lua_keys.size() and dl.lua_keys[i]:
			diagnostics.error("initializer keys are written name: value", kid.line, kid.col,
				"write `{ %s: ... }`." % kid.name)
			ok = false
			continue
		if root != "" and _class_has_property(_scope_class, root, kid.name) == 0:
			diagnostics.error("'%s' has no property '%s'" % [root, kid.name], kid.line, kid.col,
				"the scene is declared PackedScene<%s>, so its root is a %s." % [root, root])
			ok = false
			continue
		keys.append(kid.name if root == "" else _member_name(root, kid.name))
		values.append(dl.values[i])
	if not ok:
		return "null"
	var construct: String = "%s.instantiate()" % _postfix_base(form["recv"])
	var root_text: String = _type_text_of_key(root)
	if root_text == "":
		root_text = "Node"
	return _lower_construct(construct, root_text, keys, values, root_text)


func _declared_scene_root(e) -> String:
	if e is GateAST._Expr and (e as GateAST._Expr).flow_type != null:
		return _name_key(_scope_class, _scene_root_name((e as GateAST._Expr).flow_type))
	var info: Dictionary = {}
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		info = (_fn_locals[n] as Dictionary) if _fn_locals.has(n) else _field_info(_scope_class, n)
	elif e is GateAST._Member and not (e as GateAST._Member).safe:
		var m: GateAST._Member = e
		var owner: String = _scope_class if m.target is GateAST._SelfExpr else _declared_type_of(m.target)
		if owner != "":
			info = _field_info(owner, m.name)
	return String(info.get("g", ""))


func _warn_init_traps(c: GateAST._Call) -> void:
	if c.args.size() != 1 or not (c.args[0] is GateAST._DictLit) or not (c.callee is GateAST._Member):
		return
	var cm: GateAST._Member = c.callee
	if cm.safe:
		return
	var dl: GateAST._DictLit = c.args[0]
	if cm.name == "new":
		var cls: String = _class_ref_text(cm.target)
		if (cls == "" or dl.keys.is_empty() or (cm.target is GateAST._Ident and _fn_locals.has(cls))
				or _ctor_takes_params(_scope_class, cls) != 1):
			return
		for j in dl.keys.size():
			var bk = dl.keys[j]
			if not (bk is GateAST._Ident) or (j < dl.lua_keys.size() and dl.lua_keys[j]):
				continue
			var bn: String = (bk as GateAST._Ident).name
			var prop: int = _class_has_property(_scope_class, cls, bn)
			if prop == -1 or _name_in_scope(bn):
				continue
			diagnostics.error("'%s' names nothing here, so `{ %s: ... }` is not a dictionary GDScript can "
					% [bn, bn] + "pass to %s._init" % cls, bk.line, bk.col,
				("%s._init takes a parameter, so the dictionary is its argument, as in GDScript, "
					% cls + "and a bare key is a variable. Write `{ \"%s\": ... }` to pass that key"
					% bn)
				+ ((", or drop _init's parameter (or assign `%s` after `%s.new()`) to set the property."
					% [bn, cls]) if prop == 1 else "."))
			return
		for i in dl.keys.size():
			var k = dl.keys[i]
			if not (k is GateAST._Ident) or (i < dl.lua_keys.size() and dl.lua_keys[i]):
				return
			if _class_has_property(_scope_class, cls, (k as GateAST._Ident).name) != 1:
				return
		diagnostics.warn(
			"this passes the dictionary to %s._init; property initialisation needs a "
				% cls + "constructor with no parameters", c.line, c.col,
			"the keys name %s's properties, but its _init takes a parameter, so " % cls
			+ "GDScript hands it the dictionary instead. Drop the parameter to set "
			+ "the properties, or write the assignments out.")
	elif cm.name == "instantiate":
		if cm.target is GateAST._SelfExpr or _declared_funcs.has("instantiate"):
			return
		var rt: String = GateTypes.canonical(_static_type_of(cm.target))
		if rt != "" and rt != "PackedScene":
			return
		diagnostics.warn("type the scene PackedScene<T> to initialise its properties",
			c.line, c.col,
			"without a static type this stays an ordinary call. If it is a scene, "
			+ "that passes the dictionary to instantiate(), which expects an edit "
			+ "state, and fails when it runs.")


func _is_namespace_ref(e) -> bool:
	if not (e is GateAST._Ident):
		return false
	var n: String = (e as GateAST._Ident).name
	return not _var_types.has(n) and not _fn_locals.has(n) and not _declares_value(_scope_class, n)


func _emit_soa_call(sname: String, cm: GateAST._Member, c: GateAST._Call) -> String:
	var info: Dictionary = _soa[sname]
	var arrays: Array = info["arrays"]
	var accessors: Array = info["accessors"]

	match cm.name:
		"size", "is_empty":
			return "%s.%s()" % [arrays[0], cm.name]
		"clear":
			for a in arrays:
				_hoist("%s.clear()" % a)
			return ""
		"resize":
			var n: String = _expr(c.args[0]) if not c.args.is_empty() else "0"
			var t: String = _new_tmp()
			_hoist("var %s = %s" % [t, n])
			for a in arrays:
				_hoist("%s.resize(%s)" % [a, t])
			return ""
		"append", "push_back":
			if c.args.is_empty():
				diagnostics.error("append() needs a value", c.line, c.col)
				return "null"
			var v: String = _copy_value(c.args[0])
			var tv: String = _new_tmp()
			_hoist("var %s = %s" % [tv, v])
			for i in arrays.size():
				_hoist("%s.append(%s.%s)" % [arrays[i], tv, accessors[i]])
			return ""
	diagnostics.error(
		"'%s' is an @soa array and does not support .%s()" % [sname, cm.name],
		cm.line, cm.col,
		"@soa supports size(), is_empty(), append(), resize(), clear() and indexed "
		+ "field access like `%s[i].field`. Remove @soa for anything else." % sname)
	return "null"


func _emit_fstring(fs: GateAST._FString) -> String:
	var fmt: String = ""
	var exprs: Array = []
	for part in fs.parts:
		if part is String:
			fmt += (part as String).replace("%", "%%")
		else:
			fmt += "%s"
			exprs.append(part)
	var args: PackedStringArray = _ordered(exprs, func(i: int) -> String: return _expr(exprs[i]))
	var q: String = fs.quote if fs.quote != "" else "\""
	if args.is_empty():
		return q + fmt + q
	if args.size() == 1:
		return "%s%s%s %% [%s]" % [q, fmt, q, args[0]]
	return "%s%s%s %% [%s]" % [q, fmt, q, ", ".join(args)]


func _lambda_block(head: String, hoisted: PackedStringArray, last: String, outer: int) -> String:
	var pad: String = "	".repeat(_indent + outer + 1)
	var lines: PackedStringArray = PackedStringArray()
	for h in hoisted:
		lines.append(pad + _deeper(h, outer + 1))
	lines.append(pad + _deeper(last, 1))
	return head + ":\n" + "\n".join(lines)

const MAX_COLLECTION_WIDTH := 96


func _collection(open_b: String, parts: PackedStringArray, close_b: String, elem_lines: PackedInt32Array = PackedInt32Array()) -> String:
	var one_line: String = open_b + ", ".join(parts) + close_b
	if parts.size() < 2 or one_line.length() <= MAX_COLLECTION_WIDTH:
		return one_line
	var base: int = _indent + _coll_depth
	var pad: String = "	".repeat(base + 1)
	var lines: PackedStringArray = PackedStringArray()
	lines.append(open_b)
	for i in parts.size():
		lines.append(pad + parts[i] + ("," if i < parts.size() - 1 else ","))
	lines.append("	".repeat(base) + close_b)
	if elem_lines.size() == parts.size():
		var srcs: Array = []
		for ln in elem_lines:
			srcs.append(ln)
		srcs.append(elem_lines[elem_lines.size() - 1])
		_pending_line_src = srcs
	return "\n".join(lines)


func _discards_safe_call(l: GateAST._Lambda) -> bool:
	if l.return_type != null and l.return_type.name != "void":
		return false   # the value is used, so the ternary is right
	var e = (l.body[0] as GateAST._ExprStmt).expr
	if not (e is GateAST._Call):
		return false
	var c: GateAST._Call = e
	return c.callee is GateAST._Member and (c.callee as GateAST._Member).safe


func _capture_copies(l: GateAST._Lambda) -> Dictionary:
	var out: Dictionary = {}
	if _fn_locals.is_empty() or _no_hoist_ctx() != "":
		return out
	var read: Dictionary = {}
	GateChecker.idents_in(l.body, read)
	var inner: Dictionary = GateChecker.local_names(l.params, l.body)
	for n in read:
		if inner.has(n) or not _fn_locals.has(n) or _ident_renames.has(n) or _soa_cursors.has(n):
			continue
		if _tmp_names.has(n) or (String(n).begins_with("__g") and String(n).substr(3, 1).is_valid_int()):
			continue   # GATE's own copy, made for this capture
		var id: GateAST._Ident = GateAST._Ident.new()
		id.at(l.line, l.col)
		id.name = String(n)
		var saved_p: PackedStringArray = _pending
		_pending = PackedStringArray()
		var ctext: String = _copy_value(id)
		var extra: PackedStringArray = _pending
		_pending = saved_p
		if ctext == String(n) and extra.is_empty():
			continue
		for h in extra:
			_hoist(h)
		var t: String = _new_tmp()
		_hoist("var %s = %s" % [t, ctext])
		out[String(n)] = t
	return out


func _emit_lambda(l: GateAST._Lambda) -> String:
	if not _soa_cursors.is_empty():
		var read: Dictionary = {}
		GateChecker.idents_in(l.body, read)
		for cn in read:
			if _soa_cursors.has(cn):
				diagnostics.error("'%s' is a value read from the @soa array '%s' and cannot be captured"
						% [cn, _soa_cursors[cn]["soa"]], l.line, l.col,
					"the lambda would read the columns when it runs, not the value it saw. Read "
					+ "the field into a local first, or keep the index and read `%s[i].field`."
						% _soa_cursors[cn]["soa"])
				return "null"
	var captures: Dictionary = _capture_copies(l)
	var saved_locals: Dictionary = _fn_locals.duplicate()
	var saved_types: Dictionary = _var_types.duplicate()
	var saved_depths: Dictionary = _var_depths.duplicate()
	var saved_dicts: Dictionary = _var_dict_values.duplicate()
	var saved_in_body: bool = _in_func_body
	var saved_no_hoist: String = _no_hoist
	var saved_renames: Dictionary = _ident_renames
	if not captures.is_empty():
		_ident_renames = _ident_renames.duplicate()
		_ident_renames.merge(captures, true)
	_in_func_body = true
	_no_hoist = ""
	for p in l.params:
		var pp: GateAST._Param = p
		if _ident_renames.has(pp.name):
			_ident_renames = _ident_renames.duplicate()
			_ident_renames.erase(pp.name)
		_fn_locals[pp.name] = _decl_info(_scope_class, pp.type)
		_shadow_name(pp.name)
		if pp.type != null:
			_var_types[pp.name] = pp.type.name
			_var_depths[pp.name] = pp.type.array_depth
	var saved_helper: bool = _in_gate_helper
	_in_gate_helper = saved_helper or _gate_lambda(l)
	var outer_pending: PackedStringArray = _pending   # the captures' copies: made with the lambda, outside it
	_pending = PackedStringArray()
	var out: String = _emit_lambda_inner(l, _coll_depth)
	_pending = outer_pending + _pending
	_in_gate_helper = saved_helper
	_ident_renames = saved_renames
	_in_func_body = saved_in_body
	_no_hoist = saved_no_hoist
	_fn_locals = saved_locals
	_var_types = saved_types
	_var_depths = saved_depths
	_var_dict_values = saved_dicts
	return out


func _emit_lambda_inner(l: GateAST._Lambda, outer: int) -> String:
	var head: String = "func%s(%s)" % [(" " + l.name) if l.name != "" else "", _params(l.params)]
	if l.return_type != null:
		head += " -> " + _map_type(l.return_type)
	var entry: PackedStringArray = PackedStringArray()
	for p in l.params:
		if _would_copy(p) and not _copies_first(l.body, (p as GateAST._Param).name):
			entry.append(_entry_copy(p))
	if l.body.size() == 1 and l.body[0] is GateAST._ReturnStmt:
		var r: GateAST._ReturnStmt = l.body[0]
		if r.value == null:
			return "%s: return" % head
		var saved_pending: PackedStringArray = _pending
		_pending = PackedStringArray()
		var rv: String = _copy_value(r.value)
		var hoisted: PackedStringArray = entry + _pending
		_pending = saved_pending
		if hoisted.is_empty():
			return "%s: return %s" % [head, rv]
		return _lambda_block(head, hoisted, "return " + rv, outer)
	elif (l.body.size() == 1 and l.body[0] is GateAST._ExprStmt
			and not _discards_safe_call(l)):
		var saved_pending2: PackedStringArray = _pending
		_pending = PackedStringArray()
		var ex: String = _expr((l.body[0] as GateAST._ExprStmt).expr)
		var hoisted2: PackedStringArray = entry + _pending
		_pending = saved_pending2
		var last: String = ex
		if l.return_type != null and l.return_type.name != "void":
			last = "return " + ex
		if hoisted2.is_empty():
			return "%s: %s" % [head, last]
		return _lambda_block(head, hoisted2, last, outer)
	var saved_out: PackedStringArray = _out
	var saved_map: Array[int] = _map
	var saved_indent: int = _indent
	_out = []
	_map = []
	_indent = saved_indent + outer + 1
	for ec2 in entry:
		_line(ec2, l.line)
	for s in l.body:
		_emit_statement(s)
	var body_lines: PackedStringArray = _out
	var body_map: Array[int] = _map
	_out = saved_out
	_map = saved_map
	_indent = saved_indent
	_pending_line_src = body_map.duplicate()
	if not l.body.is_empty() and l.body[l.body.size() - 1] is GateAST._MatchStmt:
		body_lines.append("	".repeat(_indent))
		_pending_line_src.append(body_map[body_map.size() - 1] if not body_map.is_empty() else l.line)
	return head + ":\n" + "\n".join(body_lines)


func _params(params: Array, fname: String = "", helpers: Array = []) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var earlier: PackedStringArray = PackedStringArray()
	for p in params:
		var pp: GateAST._Param = p
		var s: String = ("..." if pp.is_rest else "") + pp.name
		if pp.type != null:
			s += ": " + _map_type(pp.type)
		if pp.default != null:
			var infer: bool = pp.inferred and pp.type == null
			var value: String = ""
			var hoisted: PackedStringArray = PackedStringArray()
			var saved_no_hoist: String = _no_hoist
			if fname != "":
				var saved_in_body: bool = _in_func_body
				var saved_locals: Dictionary = _fn_locals
				var saved_pending: PackedStringArray = _pending
				_in_func_body = true
				_no_hoist = ""
				_fn_locals = {}
				for ep in params:
					if ep == p:
						break
					_fn_locals[(ep as GateAST._Param).name] = _decl_info(_scope_class, (ep as GateAST._Param).type)
				_pending = PackedStringArray()
				value = _expr(pp.default) if _would_copy(pp) else _copy_value(pp.default)
				hoisted = _pending
				_pending = saved_pending
				_fn_locals = saved_locals
				_in_func_body = saved_in_body
			else:
				_no_hoist = "param"
				value = _expr(pp.default) if _would_copy(pp) else _copy_value(pp.default)
			_no_hoist = saved_no_hoist
			if not hoisted.is_empty():
				var hname: String = "__gate_dflt_%s_%s" % [fname, pp.name]
				while _bound_names.has(hname):
					hname = "_" + hname
				var rtype: String = _type_text_of_key(_declared_type_of(pp.default)) if infer else ""
				helpers.append([hname, earlier.duplicate(), hoisted, value, rtype])
				value = "%s(%s)" % [hname, ", ".join(earlier)]
				if infer and rtype == "":
					infer = false   # nothing to infer from; Godot could not either
			s += (" := " if infer else " = ") + value
		parts.append(s)
		earlier.append(pp.name)
	return ", ".join(parts)

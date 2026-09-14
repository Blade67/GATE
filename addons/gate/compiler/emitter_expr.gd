@tool
extends "res://addons/gate/compiler/emitter_types.gd"

## Emitter layer 3: expressions.


func _emit_statement(s) -> void:
	push_error("[GATE] internal: _emit_statement not overridden")


func _expr(e) -> String:
	if e == null:
		return "null"

	if e is GateAST.Literal:
		return (e as GateAST.Literal).raw
	if e is GateAST.Ident:
		var iname: String = (e as GateAST.Ident).name
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
		var gb: String = (e as GateAST.Ident).generic_base
		if gb != "":
			var gt: GateAST.TypeRef = (e as GateAST.Ident).generic_type
			if gt != null:
				var st: GateAST.TypeRef = _substituted(gt)
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
		return iname
	if e is GateAST.SelfExpr:
		return "self"
	if e is GateAST.NodePathExpr:
		return (e as GateAST.NodePathExpr).raw
	if e is GateAST.RawExpr:
		return (e as GateAST.RawExpr).text

	if e is GateAST.Unary:
		var u: GateAST.Unary = e
		var op: String = u.op
		if op == "not":
			return "not %s" % _paren_below(u.operand, PREC_ATOM)
		if u.operand is GateAST.Binary and (u.operand as GateAST.Binary).op == "**":
			return "%s(%s)" % [op, _expr(u.operand)]
		if op == "+" and not u.tight and u.operand is GateAST.Literal:
			var raw: String = (u.operand as GateAST.Literal).raw
			if raw.begins_with("0x") or raw.begins_with("0b") or raw.begins_with("0X") or raw.begins_with("0B"):
				return "+(%s)" % raw
		return "%s%s" % [op, _paren_below(u.operand, PREC_UNARY)]

	if e is GateAST.Binary:
		return _emit_binary(e)

	if e is GateAST.NullCoalesce:
		return _emit_coalesce(e, false)

	if e is GateAST.Ternary:
		var t3: GateAST.Ternary = e
		var cond: String = _expr(t3.cond)
		var saved_p: PackedStringArray = _pending
		_pending = PackedStringArray()
		var av: String = _expr(t3.if_true)
		var ap: PackedStringArray = _pending
		_pending = PackedStringArray()
		var bv: String = _expr(t3.if_false)
		var bp: PackedStringArray = _pending
		_pending = saved_p
		if t3.if_true is GateAST.Lambda:
			av = "(%s)" % av
		if t3.if_false is GateAST.Lambda:
			bv = "(%s)" % bv
		if ap.is_empty() and bp.is_empty():
			if t3.if_false is GateAST.Ternary:
				return "%s if %s else %s" % [av, cond, bv]
			return "(%s if %s else %s)" % [av, cond, bv]
		var tmp: String = _new_tmp()
		_hoist("var %s = null" % tmp)
		_hoist("if %s:" % cond)
		for h in ap:
			_hoist("	" + h)
		_hoist("	%s = %s" % [tmp, av])
		_hoist("else:")
		for h2 in bp:
			_hoist("	" + h2)
		_hoist("	%s = %s" % [tmp, bv])
		return tmp

	if e is GateAST.Member and (e as GateAST.Member).target is GateAST.Ident:
		var sm: GateAST.Member = e
		var skey: String = "%s.%s" % [(sm.target as GateAST.Ident).name, sm.name]
		if _scalar_names.has(skey):
			return _scalar_names[skey]

	if e is GateAST.Member and (e as GateAST.Member).target is GateAST.SelfExpr \
			and _soa.has((e as GateAST.Member).name):
		return _expr(_as_ident(e))

	if e is GateAST.Member:
		var sw: Dictionary = _swizzle_of(e)
		if not sw.is_empty():
			return _emit_swizzle_read(e, sw)

	if e is GateAST.Member or e is GateAST.Index:
		var flat: String = _emit_postfix_spine(e)
		if flat != "":
			return flat

	if e is GateAST.Member:
		var m: GateAST.Member = e
		if m.target is GateAST.Ident and _soa_cursors.has((m.target as GateAST.Ident).name):
			var cur: Dictionary = _soa_cursors[(m.target as GateAST.Ident).name]
			var cinfo: Dictionary = _soa[cur["soa"]]
			var carr: String = _soa_field_array(cinfo, m.name)
			if carr == "":
				diagnostics.error("'%s' has no field '%s'" % [cinfo["struct"], m.name],
					m.line, m.col,
					"@soa exposes exactly the struct's fields: %s"
						% ", ".join(PackedStringArray(cinfo["fields"])))
				return "null"
			return "%s[%s]" % [carr, cur["idx"]]
		if m.target is GateAST.Index:
			var mix: GateAST.Index = m.target
			var sname: String = _soa_name(mix.target)
			if sname != "":
				var info: Dictionary = _soa[sname]
				var arr: String = _soa_field_array(info, m.name)
				if arr == "":
					diagnostics.error(
						"'%s' has no field '%s'" % [info["struct"], m.name], m.line, m.col)
					return "null"
				return "%s[%s]" % [arr, _expr(mix.index)]
		var vst: Dictionary = _vector_struct_of(m.target)
		if not vst.is_empty():
			var vfields: Array = vst["fields"]
			var fi: int = vfields.find(m.name)
			if fi >= 0:
				return "%s.%s" % [_postfix_base(m.target), GateTypes.VECTOR_COMPONENTS[fi]]
			diagnostics.error("'%s' has no field '%s'" % [vst["name"], m.name],
				m.line, m.col,
				"it lowered to %s, whose components are the struct's fields in order: %s"
					% [vst["vector"], ", ".join(PackedStringArray(vfields))])
			return "null"

		var base: String = _postfix_base(m.target)
		var mname: String = _member_name(m.member_class if m.member_class != "" else _owner_key(m.target), m.name)
		return "%s.%s" % [base, mname]

	if e is GateAST.Index:
		var ix: GateAST.Index = e
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

	if e is GateAST.Widen and not (e as GateAST.Widen).guards.is_empty():
		return _emit_widen(e)

	if e is GateAST.Call:
		return _emit_call(e)

	if e is GateAST.ArrayLit:
		var al: GateAST.ArrayLit = e
		var parts: PackedStringArray = PackedStringArray()
		var lines: PackedInt32Array = PackedInt32Array()
		_coll_depth += 1
		for el in al.elements:
			parts.append(_copy_value(el))
			lines.append((el as GateAST.Expr).line)
		_coll_depth -= 1
		return _collection("[", parts, "]", lines)

	if e is GateAST.DictLit:
		var dl: GateAST.DictLit = e
		var parts2: PackedStringArray = PackedStringArray()
		var lines2: PackedInt32Array = PackedInt32Array()
		_coll_depth += 1
		for i in dl.keys.size():
			lines2.append((dl.keys[i] as GateAST.Expr).line)
			var v = dl.values[i] if i < dl.values.size() else null
			var lua: bool = i < dl.lua_keys.size() and dl.lua_keys[i]
			if v == null:
				parts2.append(_expr(dl.keys[i]))
			elif lua:
				parts2.append("%s = %s" % [_expr(dl.keys[i]), _copy_value(v)])
			else:
				parts2.append("%s: %s" % [_expr(dl.keys[i]), _copy_value(v)])
		_coll_depth -= 1
		return _collection("{", parts2, "}", lines2)

	if e is GateAST.AwaitExpr:
		return "await " + _expr((e as GateAST.AwaitExpr).operand)

	if e is GateAST.CastExpr:
		var ce: GateAST.CastExpr = e
		if ce.type != null and ce.type.array_depth == 0 and not _is_known_native(ce.type.name) \
				and _looks_like_interface(ce.type.name):
			_want_iface_helper()
			return ("(func(__gate_v): return (__gate_v if __gate_is(__gate_v, \"%s\") else null))"
				% ce.type.name) + ".call(%s)" % _expr(ce.operand)
		var inner: String = _expr(ce.operand)
		# A lambda body extends as far right as it can, so it needs parentheses before
		# the cast or the cast lands inside the body.
		if ce.operand is GateAST.Lambda:
			inner = "(%s)" % inner
		if ce.operand is GateAST.CastExpr:
			return "%s as %s" % [inner, _map_type(ce.type)]
		return "(%s as %s)" % [inner, _map_type(ce.type)]

	if e is GateAST.IsExpr:
		return _emit_is(e)

	if e is GateAST.FString:
		return _emit_fstring(e)

	if e is GateAST.ObjectInit:
		var oi: GateAST.ObjectInit = e
		var oalias: String = _extern_alias(oi.type.name)
		var octor: String = "%s.%s" % [oalias, oi.type.name] if oalias != "" else oi.type.name
		return _lower_init(oi.type.name, octor, oi.keys, oi.values, oi)

	if e is GateAST.Lambda:
		return _emit_lambda(e)

	diagnostics.warn("unhandled expression kind", e.line, e.col)
	return "null"


func _needs_copy(e) -> bool:
	if e is GateAST.Call or e is GateAST.ObjectInit:
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


func _tmp_like(name: String, like) -> GateAST.Ident:
	var id: GateAST.Ident = _tmp_ident(name, like)
	id.flow_type = (like as GateAST.Expr).flow_type if like is GateAST.Expr else null
	var info: Dictionary = {"t": _declared_type_of(like), "e": ""}
	var tr: GateAST.TypeRef = _value_tref(like)
	if tr != null:
		info = _decl_info(_scope_class, tr)
	_fn_locals[name] = info
	var st: String = _static_type_of(like)
	if st != "":
		_var_types[name] = st
		_var_depths[name] = 0
	return id


func _raw_like(text: String, like) -> GateAST.RawExpr:
	var r: GateAST.RawExpr = GateAST.RawExpr.new()
	r.at(like.line, like.col)
	r.text = text
	return r


func _tmp_ident(name: String, at_node) -> GateAST.Ident:
	var id: GateAST.Ident = GateAST.Ident.new()
	id.at(at_node.line, at_node.col)
	id.name = name
	return id


func _emit_safe_member(m: GateAST.Member) -> String:
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


func _safe_step(m: GateAST.Member, base: String) -> String:
	var had_local: bool = _fn_locals.has(base)
	var was_local = _fn_locals.get(base)
	var had_type: bool = _var_types.has(base)
	var was_type = _var_types.get(base)
	var had_depth: bool = _var_depths.has(base)
	var was_depth = _var_depths.get(base)
	var had_tmp: bool = _tmp_names.has(base)
	var stand: GateAST.Ident = _tmp_like(base, m.target)
	_tmp_names[base] = true
	var step: GateAST.Member = GateAST.Member.new()
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
	if e is GateAST.Call or e is GateAST.ObjectInit or e is GateAST.Binary:
		return false   # a fresh value (an overloaded operator is a call)
	var tn: String = _static_type_of(e)
	if tn == "":
		return false
	var st: Dictionary = _struct_of(tn)
	return not st.is_empty() and st["lowering"] != "vector"


func _copy_value(e) -> String:
	if not _needs_copy(e):
		return _expr(e)
	return "%s._gate_copy()" % _postfix_base(e)


func _emit_postfix_spine(e) -> String:
	var steps: Array = []
	var node = e
	while true:
		if node is GateAST.Member:
			var m: GateAST.Member = node
			if m.safe or _soa_name(m.target) != "" or not _vector_struct_of(m.target).is_empty():
				return ""
			if not _swizzle_of(m).is_empty():
				return ""   # a swizzle is not a member access; let _expr rewrite it
			if m.target is GateAST.Ident and _soa_cursors.has((m.target as GateAST.Ident).name):
				return ""
			steps.push_front(node)
			node = m.target
		elif node is GateAST.Index:
			var ix: GateAST.Index = node
			if ix.safe or _soa_name(ix.target) != "":
				return ""
			steps.push_front(node)
			node = ix.target
		else:
			break
	if steps.size() < 32:
		return ""   # short enough for the readable path
	var out: String = _postfix_base(node)
	for st in steps:
		if st is GateAST.Member:
			out += ".%s" % (st as GateAST.Member).name
		else:
			out += "[%s]" % _expr((st as GateAST.Index).index)
	return out


func _postfix_base(e) -> String:
	return _paren_below(e, PREC_ATOM)


func _paren_below(e, floor_prec: int) -> String:
	var s: String = _expr(e)
	if _prec_of(e) < floor_prec:
		return "(%s)" % s
	return s


func _emit_binary(b: GateAST.Binary) -> String:
	var lt: String = _static_type_of(b.left)
	if lt != "" and _struct_ops.has(lt):
		var ops: Dictionary = _struct_ops[lt]
		if ops.has(b.op):
			return "%s.%s(%s)" % [_expr(b.left), ops[b.op], _expr(b.right)]
	var op: String = b.op
	if op == "not in":
		return "not (%s in %s)" % [_expr(b.left), _expr(b.right)]
	var p: int = PREC.get(op, PREC_ATOM)
	if (op == "and" or op == "or") and b.left is GateAST.Binary and (b.left as GateAST.Binary).op == op:
		var achain: Array = []
		var anode = b
		while anode is GateAST.Binary and (anode as GateAST.Binary).op == op:
			achain.push_front(anode)
			anode = (anode as GateAST.Binary).left
		if achain.size() > 1:
			var saved_p: PackedStringArray = _pending
			_pending = PackedStringArray()
			var parts: PackedStringArray = PackedStringArray()
			parts.append(_paren_below((achain[0] as GateAST.Binary).left, p))
			for n in achain:
				parts.append(_paren_below((n as GateAST.Binary).right, p + 1))
			var chain_pending: PackedStringArray = _pending
			_pending = saved_p
			if chain_pending.is_empty():
				return (" %s " % op).join(parts)
			for h in chain_pending:
				_hoist(h)

	if op != "and" and op != "or" and b.left is GateAST.Binary:
		var chain: Array = []
		var node = b
		while node is GateAST.Binary:
			var nb: GateAST.Binary = node
			if nb.op == "and" or nb.op == "or" or nb.op == "not in":
				break
			var lt2: String = _static_type_of(nb.left)
			if lt2 != "" and _struct_ops.has(lt2):
				break
			if not (nb.left is GateAST.Binary):
				break
			var child: GateAST.Binary = nb.left
			if int(PREC.get(child.op, PREC_ATOM)) < int(PREC.get(nb.op, PREC_ATOM)):
				break
			if child.op == "and" or child.op == "or" or child.op == "not in":
				break
			chain.push_front(nb)
			node = child
		if chain.size() > 1:
			var first: GateAST.Binary = chain[0]
			var out: String = _paren_below(first.left, int(PREC.get(first.op, PREC_ATOM)))
			for n in chain:
				var bn: GateAST.Binary = n
				var bp: int = PREC.get(bn.op, PREC_ATOM)
				out += " %s %s" % [bn.op, _paren_below(bn.right, bp + 1)]
			return out
	var lhs: String = _paren_below(b.left, p)
	if op == "and" or op == "or":
		var saved: PackedStringArray = _pending
		_pending = PackedStringArray()
		var r: String = _paren_below(b.right, p + 1)
		var rhs_pending: PackedStringArray = _pending
		_pending = saved
		if rhs_pending.is_empty():
			return "%s %s %s" % [lhs, op, r]
		return _guarded_operand(op, lhs, rhs_pending, r)
	var rhs: String = _paren_below(b.right, p + 1)
	return "%s %s %s" % [lhs, op, rhs]


func _guarded_operand(op: String, lhs: String, rhs_pending: PackedStringArray, rhs: String) -> String:
	var t: String = _new_tmp()
	var seed: String = "false" if op == "and" else "true"
	var cond: String = lhs if op == "and" else "not (%s)" % lhs
	_hoist("var %s = %s" % [t, seed])
	_hoist("if %s:" % cond)
	for h in rhs_pending:
		_hoist("	" + h)
	_hoist("	%s = %s" % [t, rhs])
	return t


func _emit_widen(w: GateAST.Widen) -> String:
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


func _emit_is(ie: GateAST.IsExpr) -> String:
	var operand: String = _paren_below(ie.operand, PREC_TYPE_TEST)
	var tname: String = ie.type.name
	if not _is_known_native(tname) and _looks_like_interface(tname):
		_needs_iface_helper = true
		var expr: String = "__gate_is(%s, \"%s\")" % [operand, tname]
		return "not " + expr if ie.negated else expr
	var s: String = "%s is %s" % [operand, _map_type(ie.type)]
	return "not (%s)" % s if ie.negated else s


func _check_struct_arity(name: String, st: Dictionary, c: GateAST.Call) -> void:
	var n_fields: int = (st["fields"] as Array).size()
	var given: int = c.args.size()
	var ok: bool = given <= n_fields
	if st["lowering"] == "vector" and given != 0:
		ok = given == n_fields
	if ok:
		return
	diagnostics.error(
		"struct '%s' has %d field(s) but %d argument(s) were given"
			% [name, n_fields, given], c.line, c.col,
		"the constructor takes one value per field, in declaration order: %s."
			% ", ".join(PackedStringArray(st["fields"])))


func _emit_call(c: GateAST.Call) -> String:
	if (c.callee is GateAST.Ident and (c.callee as GateAST.Ident).name == "preload"
			and c.args.size() == 1 and c.args[0] is GateAST.Literal):
		var lit: GateAST.Literal = c.args[0]
		if lit.kind == "string":
			var target: String = lit.raw
			if target.length() >= 2:
				target = target.substr(1, target.length() - 2)
			if target != "":
				_preload_targets[target] = true

	if c.callee is GateAST.Member:
		var cm: GateAST.Member = c.callee
		var sname: String = _soa_name(cm.target)
		if sname != "":
			return _emit_soa_call(sname, cm, c)

	var args: PackedStringArray = PackedStringArray()
	for a in c.args:
		args.append(_copy_value(a))

	if c.callee is GateAST.Member and (c.callee as GateAST.Member).safe:
		var sm: GateAST.Member = c.callee
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

	if c.callee is GateAST.Ident:
		var n: String = (c.callee as GateAST.Ident).name
		if CTOR_SHORTHAND.has(n) and not _declared_funcs.has(n):
			return "%s(%s)" % [CTOR_SHORTHAND[n], ", ".join(args)]
		var st: Dictionary = _struct_of(n)
		if not st.is_empty():
			_check_struct_arity(n, st, c)
			if st["lowering"] == "vector":
				return "%s(%s)" % [st["vector"], ", ".join(args)]
			var salias: String = _extern_alias(n)
			if salias != "":
				return "%s.%s.new(%s)" % [salias, n, ", ".join(args)]
			return "%s.new(%s)" % [n, ", ".join(args)]

	if c.callee is GateAST.Member:
		var qm: GateAST.Member = c.callee
		var qst: Dictionary = _struct_of(qm.name)
		if not qst.is_empty() and _is_namespace_ref(qm.target):
			_check_struct_arity(qm.name, qst, c)
			if qst["lowering"] == "vector":
				return "%s(%s)" % [qst["vector"], ", ".join(args)]
			return "%s.%s.new(%s)" % [_expr(qm.target), qm.name, ", ".join(args)]

	if c.callee is GateAST.Ident:
		var base: String = (c.callee as GateAST.Ident).name
		var mangled: String = _resolve_overload(base, c.args.size())
		if mangled != "" and _overload_declared_by_chain(base, _cur_class):
			return "%s(%s)" % [mangled, ", ".join(args)]
	elif c.callee is GateAST.Member:
		var mem: GateAST.Member = c.callee
		var mangled2: String = _resolve_overload(mem.name, c.args.size())
		if mangled2 != "":
			if mem.target is GateAST.SelfExpr:
				if _overload_declared_by_chain(mem.name, _cur_class):
					return "%s.%s(%s)" % [_postfix_base(mem.target), mangled2, ", ".join(args)]
				return "%s.%s(%s)" % [_postfix_base(mem.target), mem.name, ", ".join(args)]
			var owner: String = _static_type_of(mem.target)
			if owner != "" and _overload_declared_by_chain(mem.name, owner):
				return "%s.%s(%s)" % [_postfix_base(mem.target), mangled2, ", ".join(args)]
			if owner == "" and mem.target is GateAST.Ident:
				var tn: String = (mem.target as GateAST.Ident).name
				if _local_types.has(tn) or not _struct_of(tn).is_empty():
					owner = tn
			if owner == "" and mem.target is GateAST.Ident and (mem.target as GateAST.Ident).name == "super":
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
		var cmm: GateAST.Member = c.callee
		return "%s.%s(%s)" % [recv_text, _member_name(
			cmm.member_class if cmm.member_class != "" else _owner_key(recv_node),
			(c.callee as GateAST.Member).name), ", ".join(args)]
	if c.callee is GateAST.Ident:
		var fname: String = (c.callee as GateAST.Ident).name
		if not _struct_of(fname).is_empty() and _ctor_struct_of(fname).is_empty():
			return "%s(%s)" % [fname, ", ".join(args)]   # a function, not the other file's struct
	_swizzle_exempt = c.callee
	var callee: String = _postfix_base(c.callee)
	_swizzle_exempt = null
	return "%s(%s)" % [callee, ", ".join(args)]


func _args_first(c: GateAST.Call) -> Array:
	var texts: PackedStringArray = _ordered(c.args,
		func(i: int) -> String: return _copy_value(c.args[i]))
	var out: Array = []
	for i in c.args.size():
		var text: String = texts[i]
		if not _stable(c.args[i], text):
			var t: String = _new_tmp()
			_hoist("var %s = %s" % [t, text])
			text = t
		var r: GateAST.RawExpr = GateAST.RawExpr.new()
		r.at(c.args[i].line, c.args[i].col)
		r.text = text
		out.append(r)
	return out


func _plain_callee(cm: GateAST.Member) -> bool:
	if cm.safe or _soa_name(cm.target) != "":
		return false
	if cm.target is GateAST.Ident and _soa_cursors.has((cm.target as GateAST.Ident).name):
		return false
	if cm.target is GateAST.Index and _soa_name((cm.target as GateAST.Index).target) != "":
		return false
	if not _vector_struct_of(cm.target).is_empty():
		return false
	if cm.target is GateAST.Ident and _scalar_names.has(
			"%s.%s" % [(cm.target as GateAST.Ident).name, cm.name]):
		return false
	if not _struct_of(cm.name).is_empty() and _is_namespace_ref(cm.target):
		return false
	return true


## `X.new({...})` sets properties only when GDScript would reject the call, i.e. when
## `_init` takes nothing. Otherwise the dictionary is an argument, as written.
func _init_call_form(c: GateAST.Call) -> Dictionary:
	if c.args.size() != 1 or not (c.args[0] is GateAST.DictLit):
		return {}
	var dl: GateAST.DictLit = c.args[0]
	for i in dl.keys.size():
		if not (dl.keys[i] is GateAST.Ident) or i >= dl.values.size() or dl.values[i] == null:
			return {}
	if c.callee is GateAST.Member:
		var cm: GateAST.Member = c.callee
		if cm.safe:
			return {}
		if cm.name == "new":
			var ref: String = _class_ref_text(cm.target)
			var generic: bool = cm.target is GateAST.Ident and (cm.target as GateAST.Ident).generic_base != ""
			if generic:
				ref = (cm.target as GateAST.Ident).generic_base
			if ref == "" or (cm.target is GateAST.Ident and _fn_locals.has(ref)):
				return {}
			var nst: Dictionary = _struct_of(ref) if not generic else {}
			if not nst.is_empty():
				return {} if _dict_positional(nst, dl) else {"name": ref, "dict": dl, "ctor": _expr(cm.target)}
			if _ctor_takes_params(_scope_class, ref, generic) != 0:
				return {}
			var ctor: String = _expr(cm.target)
			return {"name": ref, "dict": dl, "ctor": ctor}
		if not (cm.target is GateAST.Ident):
			return {}
		var nst: Dictionary = _struct_of(cm.name)
		if not nst.is_empty() and _is_namespace_ref(cm.target) and not _dict_positional(nst, dl):
			return {"name": cm.name, "dict": dl, "ctor": "%s.%s" % [_expr(cm.target), cm.name]}
		return {}
	if c.callee is GateAST.Ident:
		var sn: String = (c.callee as GateAST.Ident).name
		if CTOR_SHORTHAND.has(sn) and not _shorthand_taken(sn) and not GateTypes.shadowed.has(sn):
			return {}
		var st: Dictionary = _ctor_struct_of(sn)
		if st.is_empty() or _dict_positional(st, dl):
			return {}
		var salias: String = _extern_alias(sn)
		return {"name": sn, "dict": dl, "ctor": "%s.%s" % [salias, sn] if salias != "" else sn}
	return {}


func _dict_positional(st: Dictionary, dl: GateAST.DictLit) -> bool:
	var types: Array = st["types"]
	var trefs: Array = st.get("typerefs", [])
	if types.is_empty():
		return false
	var first = trefs[0] if not trefs.is_empty() else null
	var holds_dict: bool = (String(types[0]) == "Variant"
		or GateTypes.canonical(String(types[0])) == "Dictionary"
		or (first != null and (first as GateAST.TypeRef).is_dict()))
	if not holds_dict:
		return false
	if dl.keys.is_empty():
		return true
	for k in dl.keys:
		if not (st["fields"] as Array).has((k as GateAST.Ident).name):
			return true
	return false


func _emit_init_call(c: GateAST.Call, form: Dictionary) -> String:
	var dl: GateAST.DictLit = form["dict"]
	var name: String = form["name"]
	var st: Dictionary = _struct_of(name)
	var keys: Array = []
	var values: Array = []
	var ok: bool = _init_keys_distinct(dl)
	for i in dl.keys.size():
		var kid: GateAST.Ident = dl.keys[i]
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


func _init_keys_distinct(dl: GateAST.DictLit) -> bool:
	var seen: Dictionary = {}
	var ok: bool = true
	for k in dl.keys:
		var kid: GateAST.Ident = k
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
	if e is GateAST.Literal:
		return true
	if e is GateAST.Unary:
		return _portable_default(st, (e as GateAST.Unary).operand, i)
	if e is GateAST.Binary:
		return (_portable_default(st, (e as GateAST.Binary).left, i)
			and _portable_default(st, (e as GateAST.Binary).right, i))
	if e is GateAST.Ternary:
		var t: GateAST.Ternary = e
		return (_portable_default(st, t.cond, i) and _portable_default(st, t.if_true, i)
			and _portable_default(st, t.if_false, i))
	if e is GateAST.ArrayLit:
		for el in (e as GateAST.ArrayLit).elements:
			if not _portable_default(st, el, i):
				return false
		return true
	if e is GateAST.Ident:
		var at: int = (st["fields"] as Array).find((e as GateAST.Ident).name)
		return at >= 0 and at < i and _struct_of(String(st["types"][at])).is_empty()
	return false


func _default_needs_instance(st: Dictionary, e) -> bool:
	if e == null or not (e is Object) or (e as Object).get_script() == null:
		return false
	if (e is GateAST.SelfExpr or e is GateAST.Lambda or e is GateAST.RawExpr
			or e is GateAST.AwaitExpr):
		return true
	if e is GateAST.Ident:
		var n: String = (e as GateAST.Ident).name
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

	return "%s(%s)" % [_postfix_base(c.callee), ", ".join(args)]


func _is_namespace_ref(e) -> bool:
	if not (e is GateAST.Ident):
		return false
	var n: String = (e as GateAST.Ident).name
	return not _var_types.has(n)


func _emit_soa_call(sname: String, cm: GateAST.Member, c: GateAST.Call) -> String:
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
			var v: String = _expr(c.args[0])
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


func _emit_fstring(fs: GateAST.FString) -> String:
	var fmt: String = ""
	var args: PackedStringArray = PackedStringArray()
	for part in fs.parts:
		if part is String:
			fmt += (part as String).replace("%", "%%")
		else:
			fmt += "%s"
			args.append(_expr(part))
	var q: String = fs.quote if fs.quote != "" else "\""
	if args.is_empty():
		return q + fmt + q
	if args.size() == 1:
		return "%s%s%s %% [%s]" % [q, fmt, q, args[0]]
	return "%s%s%s %% [%s]" % [q, fmt, q, ", ".join(args)]


func _lambda_block(head: String, hoisted: PackedStringArray, last: String) -> String:
	var pad: String = "	".repeat(_indent + 1)
	var lines: PackedStringArray = PackedStringArray()
	for h in hoisted:
		lines.append(pad + h)
	lines.append(pad + last)
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


func _discards_safe_call(l: GateAST.Lambda) -> bool:
	if l.return_type != null and l.return_type.name != "void":
		return false   # the value is used, so the ternary is right
	var e = (l.body[0] as GateAST.ExprStmt).expr
	if not (e is GateAST.Call):
		return false
	var c: GateAST.Call = e
	return c.callee is GateAST.Member and (c.callee as GateAST.Member).safe


func _emit_lambda(l: GateAST.Lambda) -> String:
	var head: String = "func%s(%s)" % [(" " + l.name) if l.name != "" else "", _params(l.params)]
	if l.return_type != null:
		head += " -> " + _map_type(l.return_type)
	if l.body.size() == 1 and l.body[0] is GateAST.ReturnStmt:
		var r: GateAST.ReturnStmt = l.body[0]
		if r.value == null:
			return "%s: return" % head
		var saved_pending: PackedStringArray = _pending
		_pending = PackedStringArray()
		var rv: String = _copy_value(r.value)
		var hoisted: PackedStringArray = _pending
		_pending = saved_pending
		if hoisted.is_empty():
			return "%s: return %s" % [head, rv]
		return _lambda_block(head, hoisted, "return " + rv)
	elif (l.body.size() == 1 and l.body[0] is GateAST.ExprStmt
			and not _discards_safe_call(l)):
		var saved_pending2: PackedStringArray = _pending
		_pending = PackedStringArray()
		var ex: String = _expr((l.body[0] as GateAST.ExprStmt).expr)
		var hoisted2: PackedStringArray = _pending
		_pending = saved_pending2
		var last: String = ex
		if l.return_type != null and l.return_type.name != "void":
			last = "return " + ex
		if hoisted2.is_empty():
			return "%s: %s" % [head, last]
		return _lambda_block(head, hoisted2, last)
	var saved_out: PackedStringArray = _out
	var saved_map: Array[int] = _map
	var saved_indent: int = _indent
	_out = []
	_map = []
	_indent = saved_indent + _coll_depth + 1
	for s in l.body:
		_emit_statement(s)
	var body_lines: PackedStringArray = _out
	var body_map: Array[int] = _map
	_out = saved_out
	_map = saved_map
	_indent = saved_indent
	_pending_line_src = body_map.duplicate()
	if not l.body.is_empty() and l.body[l.body.size() - 1] is GateAST.MatchStmt:
		body_lines.append("	".repeat(_indent))
		_pending_line_src.append(body_map[body_map.size() - 1] if not body_map.is_empty() else l.line)
	return head + ":\n" + "\n".join(body_lines)


func _params(params: Array) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for p in params:
		var pp: GateAST.Param = p
		var s: String = ("..." if pp.is_rest else "") + pp.name
		if pp.type != null:
			s += ": " + _map_type(pp.type)
		if pp.default != null:
			s += (" := " if pp.inferred and pp.type == null else " = ") + _copy_value(pp.default)
		parts.append(s)
	return ", ".join(parts)

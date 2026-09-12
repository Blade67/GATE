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
		var nc: GateAST.NullCoalesce = e
		var lhs: String = _expr(nc.left)
		if not _is_simple(nc.left) and not _is_bare_ident(lhs):
			var t: String = _new_tmp()
			_hoist("var %s = %s" % [t, lhs])
			lhs = t
		return "(%s if %s != null else %s)" % [lhs, lhs, _expr(nc.right)]

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
		if m.safe:
			if not _is_simple(m.target) and not _is_bare_ident(base):
				var t4: String = _new_tmp()
				_hoist("var %s = %s" % [t4, base])
				base = t4
			var res: String = _new_tmp()
			_hoist("var %s = (%s.%s if %s != null else null)" % [res, base, m.name, base])
			return res
		return "%s.%s" % [base, m.name]

	if e is GateAST.Index:
		var ix: GateAST.Index = e
		var base2: String = _postfix_base(ix.target)
		var idx: String = _expr(ix.index)
		if ix.safe:
			if not _is_simple(ix.target) and not _is_bare_ident(base2):
				var t5: String = _new_tmp()
				_hoist("var %s = %s" % [t5, base2])
				base2 = t5
			var res2: String = _new_tmp()
			_hoist("var %s = (%s[%s] if %s != null else null)" % [res2, base2, idx, base2])
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
		var t6: String = _new_tmp()
		var st: Dictionary = _struct_of(oi.type.name)
		if not st.is_empty() and st["lowering"] == "vector":
			var comps: PackedStringArray = PackedStringArray()
			var fields: Array = st["fields"]
			for f in fields:
				var idx2: int = oi.keys.find(f)
				comps.append(_expr(oi.values[idx2]) if idx2 >= 0 else "0")
			return "%s(%s)" % [st["vector"], ", ".join(comps)]
		var oalias: String = _extern_alias(oi.type.name)
		var octor: String = "%s.%s" % [oalias, oi.type.name] if oalias != "" else oi.type.name
		_hoist("var %s = %s.new()" % [t6, octor])
		for i in oi.keys.size():
			_hoist("%s.%s = %s" % [t6, oi.keys[i], _copy_value(oi.values[i])])
		return t6

	if e is GateAST.Lambda:
		return _emit_lambda(e)

	diagnostics.warn("unhandled expression kind", e.line, e.col)
	return "null"


func _needs_copy(e) -> bool:
	if e is GateAST.Call or e is GateAST.ObjectInit:
		return false
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
		var recv: String = _postfix_base(sm.target)
		if not _is_simple(sm.target) and not _is_bare_ident(recv):
			var rt: String = _new_tmp()
			_hoist("var %s = %s" % [rt, recv])
			recv = rt
		var sres: String = _new_tmp()
		_hoist("var %s = (%s.%s(%s) if %s != null else null)"
			% [sres, recv, sm.name, ", ".join(args), recv])
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
				return "%s.%s(%s)" % [_postfix_base(mem.target), mangled2, ", ".join(args)]

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

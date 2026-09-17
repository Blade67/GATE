@tool
class_name GateNullCheck
extends "res://addons/gate/compiler/nullcheck_env.gd"

## Flow-sensitive null analysis for values declared `T?`.
##
## Only nullable declared types participate, so ordinary GDScript cannot produce a
## false positive. Loops are analysed to a fixpoint.


func check(mod: GateAST.GateModule, diags: GateDiagnostics, registry = null) -> void:
	diagnostics = diags
	infer = GateInfer.new()
	infer.build(mod, registry)
	_opted_in = mod.uses_nullable
	_walk_members(mod.members, GateInfer.MODULE_CLASS)


func _walk_members(members: Array, cls: String) -> void:
	var saved_cls: String = _cls
	var saved_fields: Dictionary = _field_names
	var saved_engine: String = _engine_base
	_cls = cls
	_field_names = _fields_of(cls)
	_engine_base = infer.engine_root(cls)
	for m in members:
		if m is GateAST.GateFuncDecl:
			_check_func(m, cls)
		elif m is GateAST.GateClassDecl:
			var cd: GateAST.GateClassDecl = m
			if cd.form in ["interface", "trait"]:
				continue
			_walk_members(cd.members, cd.name)
		elif m is GateAST.GateVarDecl:
			var vd: GateAST.GateVarDecl = m
			_check_value_against(vd.type, vd.value, "'%s'" % vd.name, vd.line, vd.col)
	_cls = saved_cls
	_field_names = saved_fields
	_engine_base = saved_engine


func _static_field_names(cls: String) -> Dictionary:
	var out: Dictionary = {}
	for k in infer.static_fields:
		var key: String = String(k)
		if key.begins_with(cls + "."):
			var f: String = key.substr(cls.length() + 1)
			if not f.contains("."):
				out[f] = infer.static_fields[k]
	return out


func _fields_of(cls: String) -> Dictionary:
	var out: Dictionary = {}
	if cls == "":
		return out
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c):
		seen[c] = true
		for k in infer.fields:
			var key: String = String(k)
			if key.begins_with(c + "."):
				var f: String = key.substr(c.length() + 1)
				if not f.contains("."):
					out[f] = infer.fields[k]
		c = infer.bases.get(c, "")
	return out


func _declare_local(name: String, t) -> void:
	_local_names[name] = true
	if t != null:
		_locals[name] = t
	else:
		_locals.erase(name)
	_env.erase(name)


func _check_func(fd: GateAST.GateFuncDecl, cls: String) -> void:
	var saved_env: Dictionary = _env
	var saved_locals: Dictionary = _locals
	var saved_names: Dictionary = _local_names
	var saved_ret: GateAST.GateTypeRef = _ret
	_env = {}
	_locals = {}
	_local_names = {}
	_asserted = {}
	_ret = fd.return_type
	var saved_static: bool = _in_static
	_in_static = fd.is_static

	if cls != "" and not fd.is_static:
		var self_t: GateAST.GateTypeRef = GateAST.GateTypeRef.new()
		self_t.name = cls
		_locals["self"] = self_t
		for f in _field_names:
			_locals[f] = _field_names[f]
	elif cls != "":
		var statics: Dictionary = _static_field_names(cls)
		for f in statics:
			_locals[f] = statics[f]

	for p in fd.params:
		var pp: GateAST.GateParam = p
		_declare_local(pp.name, pp.type)
		if pp.type != null and pp.type.nullable:
			_env[pp.name] = S.MAYBE

	_walk_block(fd.body)

	_env = saved_env
	_locals = saved_locals
	_local_names = saved_names
	_ret = saved_ret
	_in_static = saved_static


func _walk_block(body: Array) -> bool:
	var exits: bool = false
	for s in body:
		if _walk_stmt(s):
			exits = true
	return exits


func _walk_stmt(s) -> bool:
	if s == null:
		return false

	if s is GateAST.GateAnnotatedStmt:
		return _walk_stmt((s as GateAST.GateAnnotatedStmt).stmt)

	if s is GateAST.GateVarDecl:
		var vd: GateAST.GateVarDecl = s
		if vd.value != null:
			_check_expr(vd.value)
		_check_value_against(vd.type, vd.value, "'%s'" % vd.name, vd.line, vd.col)
		if vd.type != null:
			_declare_local(vd.name, vd.type)
		else:
			_declare_local(vd.name, infer.type_of(vd.value, _locals))
		_kill_path(vd.name)
		_kill_index_var(vd.name)
		if vd.type != null and vd.type.nullable:
			_env[vd.name] = _state_of(vd.value)
		elif vd.type == null and vd.value != null and _locals.has(vd.name) and (_locals[vd.name] as GateAST.GateTypeRef).nullable:
			_env[vd.name] = _state_of(vd.value)
		return false

	if s is GateAST.GateAssignStmt:
		var a: GateAST.GateAssignStmt = s
		_check_expr(a.value)
		_check_expr(a.target)
		if a.op != "=":
			_check_value_operand(a.target, a.op, a.line, a.col)
		if a.op == "=" and a.target is GateAST.GateIdent:
			var tn: String = (a.target as GateAST.GateIdent).name
			if _local_names.has(tn) and _locals.has(tn):
				var newt: GateAST.GateTypeRef = infer.type_of(a.value, _locals)
				var oldt: GateAST.GateTypeRef = _locals[tn]
				if newt != null and oldt != null and newt.name != "" and newt.name != oldt.name:
					_locals.erase(tn)
		var path: String = _path_of(a.target)
		_kill_target(a.target)
		if path != "":
			if _tracked(a.target):
				if a.op == "=":
					_env[path] = _state_of(a.value)
				elif _is_value_typed(a.target):
					_env[path] = S.NOTNULL
				else:
					_env[path] = S.MAYBE
			elif a.op == "=":
				_check_value_against(_type_of(a.target), a.value,
					"'%s'" % path, a.line, a.col)
		return false

	if s is GateAST.GateExprStmt:
		_check_expr((s as GateAST.GateExprStmt).expr)
		_note_assert((s as GateAST.GateExprStmt).expr)
		return false

	if s is GateAST.GateReturnStmt:
		var r: GateAST.GateReturnStmt = s
		_check_expr(r.value)
		_check_return(r)
		return true

	if s is GateAST.GateSimpleStmt:
		var kw: String = (s as GateAST.GateSimpleStmt).keyword
		if kw == "break" and not _break_envs.is_empty():
			_break_envs[-1].append(_env.duplicate())
		elif kw == "continue" and not _continue_envs.is_empty():
			_continue_envs[-1].append(_env.duplicate())
		return kw in ["break", "continue"]

	if s is GateAST.GateIfStmt:
		return _walk_if(s)

	if s is GateAST.GateWhileStmt:
		_walk_while(s)
		return false

	if s is GateAST.GateForStmt:
		_walk_for(s)
		return false

	if s is GateAST.GateMatchStmt:
		return _walk_match(s)

	if s is GateAST.GateMultiAssign:
		var ma: GateAST.GateMultiAssign = s
		for v in ma.values:
			_check_expr(v)
		var paired: bool = ma.targets.size() == ma.values.size()
		for i in ma.targets.size():
			var t = ma.targets[i]
			if t is GateAST.GateIdent:
				_local_names[(t as GateAST.GateIdent).name] = true
			_check_expr(t)
			var p: String = _path_of(t)
			_kill_target(t)
			if p != "" and _tracked(t):
				_env[p] = _state_of(ma.values[i]) if paired else S.MAYBE
		return false

	if s is GateAST.GateFuncDecl:
		_check_func(s, _cls)
		return false

	if s is GateAST.GateClassDecl:
		_walk_members((s as GateAST.GateClassDecl).members, (s as GateAST.GateClassDecl).name)
		return false

	return false


func _walk_if(st: GateAST.GateIfStmt) -> bool:
	_check_expr(st.cond)
	var before: Dictionary = _env.duplicate()

	_env = _narrow(before, st.cond, true)
	var then_exits: bool = _walk_block(st.then_body)
	var branch_states: Array = []
	if not then_exits:
		branch_states.append(_env.duplicate())

	var else_env: Dictionary = _narrow(before, st.cond, false)
	var all_exit: bool = then_exits

	for pair in st.elifs:
		_env = else_env.duplicate()
		_check_expr(pair[0])
		_env = _narrow(else_env, pair[0], true)
		var e_exits: bool = _walk_block(pair[1])
		if not e_exits:
			branch_states.append(_env.duplicate())
		all_exit = all_exit and e_exits
		else_env = _narrow(else_env, pair[0], false)

	if not st.else_body.is_empty():
		_env = else_env.duplicate()
		var else_exits: bool = _walk_block(st.else_body)
		if not else_exits:
			branch_states.append(_env.duplicate())
		all_exit = all_exit and else_exits
	else:
		branch_states.append(else_env)
		all_exit = false

	if branch_states.is_empty():
		_env = before
		return all_exit
	var joined: Dictionary = branch_states[0]
	for i in range(1, branch_states.size()):
		joined = _join(joined, branch_states[i])
	_env = joined
	return all_exit

const MAX_LOOP_PASSES := 6
const MAX_LOOP_PASSES_CAP := 24


func _loop_fixpoint(entry: Dictionary, cond, body: Array) -> Dictionary:
	var cur: Dictionary = entry.duplicate()
	_quiet += 1
	_continue_envs.append([])
	var limit: int = mini(maxi(MAX_LOOP_PASSES, entry.size() + 1), MAX_LOOP_PASSES_CAP)
	var settled: bool = false
	var moving: Dictionary = {}
	for _pass in limit:
		_env = _narrow(cur, cond, true) if cond != null else cur.duplicate()
		_walk_block(body)
		var nxt: Dictionary = _join(cur, _env)
		for ce in _continue_envs[-1]:
			nxt = _join(nxt, ce)
		_continue_envs[-1] = []
		moving = _env_diff(nxt, cur)
		if moving.is_empty():
			settled = true
			break
		cur = nxt
	_continue_envs.pop_back()
	_quiet -= 1
	if not settled:
		for k in moving:
			cur[k] = S.MAYBE
	return cur


func _env_diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in a:
		if b.get(k) != a[k]:
			out[k] = true
	for k2 in b:
		if not a.has(k2):
			out[k2] = true
	return out


func _walk_while(w: GateAST.GateWhileStmt) -> void:
	var entry: Dictionary = _env.duplicate()
	var stable: Dictionary = _loop_fixpoint(entry, w.cond, w.body)
	_env = stable.duplicate()
	_check_expr(w.cond)
	_env = _narrow(stable, w.cond, true)
	_break_envs.append([])
	_continue_envs.append([])
	_walk_block(w.body)
	_env = _join(_env, _narrow(stable, w.cond, false))
	for be2 in _break_envs[-1]:
		_env = _join(_env, be2)
	_break_envs.pop_back()
	_continue_envs.pop_back()


func _walk_for(f: GateAST.GateForStmt) -> void:
	_check_expr(f.iterable)
	var it: GateAST.GateTypeRef = infer.type_of(f.iterable, _locals)
	if f.var_names.size() == 2 and it != null and it.is_dict() and not f.is_enumerate:
		_declare_local(f.var_names[0], it.dict_key)
		_declare_local(f.var_names[1], it.dict_value)
	else:
		var et: GateAST.GateTypeRef = f.var_type
		if et == null:
			et = infer.element_type(it)
		for i in f.var_names.size():
			_declare_local(f.var_names[i],
				et if i == f.var_names.size() - 1 else null)
	for n in f.var_names:
		_local_names[n] = true
		_kill_path(n)
		_kill_index_var(n)

	var entry: Dictionary = _env.duplicate()
	var stable: Dictionary = _loop_fixpoint(entry, null, f.body)
	_env = stable.duplicate()
	_break_envs.append([])
	_continue_envs.append([])
	_walk_block(f.body)
	_env = _join(_env, stable)
	for be in _break_envs[-1]:
		_env = _join(_env, be)
	_break_envs.pop_back()
	_continue_envs.pop_back()


func _walk_match(mt: GateAST.GateMatchStmt) -> bool:
	_check_expr(mt.subject)
	var before: Dictionary = _env.duplicate()
	var joined = null
	var exhaustive: bool = false
	var has_null_arm: bool = false
	for br0 in mt.branches:
		if _is_null_pattern(br0[0]):
			has_null_arm = true
	for br in mt.branches:
		_env = before.duplicate()
		var subj: String = _path_of(mt.subject)
		if subj != "" and _tracked(mt.subject) and has_null_arm:
			_env[subj] = S.NULL if _is_null_pattern(br[0]) else S.NOTNULL
		var bound: Array = _pattern_bindings(br[0])
		var saved_names: Dictionary = _local_names.duplicate()
		for bn in bound:
			_local_names[bn] = true
			_env[bn] = S.MAYBE
		if br[1] != null:
			_check_expr(br[1])
			_apply_narrow(_env, br[1], true)
		if br[1] == null and _is_wildcard(br[0]):
			exhaustive = true
		var exits: bool = _walk_block(br[2])
		_local_names = saved_names
		if exits:
			continue
		joined = _env.duplicate() if joined == null else _join(joined, _env)
	if joined == null:
		_env = before
		return exhaustive and not mt.branches.is_empty()
	_env = joined if exhaustive else _join(joined, before)
	return false


func _pattern_bindings(patterns: Array) -> Array:
	var out: Array = []
	for p in patterns:
		var text: String = ""
		if p is GateAST.GateRawExpr:
			text = (p as GateAST.GateRawExpr).text
		elif p is GateAST.GateIdent:
			continue
		else:
			continue
		text = _outside_strings(text)
		var i: int = 0
		while true:
			i = text.find("var ", i)
			if i < 0:
				break
			if i > 0 and _is_name_char(text[i - 1]):
				i += 4
				continue
			var j: int = i + 4
			var name: String = ""
			while j < text.length() and _is_name_char(text[j]):
				name += text[j]
				j += 1
			if name != "":
				out.append(name)
			i = j
	return out


static func _outside_strings(text: String) -> String:
	var out: String = ""
	var i: int = 0
	var quote: String = ""
	while i < text.length():
		var c: String = text[i]
		if quote != "":
			if c == "\\" and i + 1 < text.length():
				out += "  "
				i += 2
				continue
			if c == quote:
				quote = ""
			out += " "
			i += 1
			continue
		if c == "\"" or c == "'":
			quote = c
			out += " "
			i += 1
			continue
		out += c
		i += 1
	return out


static func _is_name_char(c: String) -> bool:
	return ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
		or (c >= "0" and c <= "9") or c == "_" or c.unicode_at(0) >= 0x80)


func _is_null_pattern(patterns: Array) -> bool:
	for p in patterns:
		if p is GateAST.GateLiteral and (p as GateAST.GateLiteral).kind == "null":
			return true
		if p is GateAST.GateRawExpr and (p as GateAST.GateRawExpr).text.strip_edges() == "null":
			return true
	return false


func _is_wildcard(patterns: Array) -> bool:
	for p in patterns:
		if p is GateAST.GateRawExpr and (p as GateAST.GateRawExpr).text.strip_edges() == "_":
			return true
		if p is GateAST.GateIdent and (p as GateAST.GateIdent).name == "_":
			return true
	return false


func _narrow(env: Dictionary, cond, truth: bool) -> Dictionary:
	var out: Dictionary = env.duplicate()
	_apply_narrow(out, cond, truth)
	return out


func _apply_narrow(env: Dictionary, cond, truth: bool) -> void:
	if cond == null:
		return

	if cond is GateAST.GateUnary and (cond as GateAST.GateUnary).op == "not":
		_apply_narrow(env, (cond as GateAST.GateUnary).operand, not truth)
		return

	if cond is GateAST.GateBinary:
		var b: GateAST.GateBinary = cond
		if b.op == "and":
			if truth:
				_apply_narrow(env, b.left, true)
				_apply_narrow(env, b.right, true)
			return
		if b.op == "or":
			if not truth:
				_apply_narrow(env, b.left, false)
				_apply_narrow(env, b.right, false)
			return
		if b.op == "!=" or b.op == "==":
			var operand = null
			if _is_null_literal(b.right):
				operand = b.left
			elif _is_null_literal(b.left):
				operand = b.right
			if operand != null:
				var path: String = _path_of(operand)
				if path != "" and _tracked(operand):
					env[path] = S.NOTNULL if ((b.op == "!=") == truth) else S.NULL
			return
		return

	if cond is GateAST.GateIsExpr:
		var ie: GateAST.GateIsExpr = cond
		var ip: String = _path_of(ie.operand)
		if ip != "" and _tracked(ie.operand) and (truth != ie.negated):
			env[ip] = S.NOTNULL
		return

	if cond is GateAST.GateCall:
		var cc: GateAST.GateCall = cond
		if cc.callee is GateAST.GateIdent and (cc.callee as GateAST.GateIdent).name == "is_instance_valid" and cc.args.size() == 1:
			var ip2: String = _path_of(cc.args[0])
			if ip2 != "" and _tracked(cc.args[0]):
				env[ip2] = S.NOTNULL if truth else S.MAYBE
			return

	var p: String = _path_of(cond)
	if p != "" and _tracked(cond):
		env[p] = S.NOTNULL if truth else S.NULL


func _note_assert(e) -> void:
	if not (e is GateAST.GateCall):
		return
	var c: GateAST.GateCall = e
	if not (c.callee is GateAST.GateIdent) or (c.callee as GateAST.GateIdent).name != "assert":
		return
	if c.args.is_empty():
		return
	var probe: Dictionary = {}
	_apply_narrow(probe, c.args[0], true)
	for k in probe:
		if probe[k] == S.NOTNULL:
			_asserted[k] = true


func _is_null_literal(e) -> bool:
	return e is GateAST.GateLiteral and (e as GateAST.GateLiteral).kind == "null"


func _state_of(value) -> int:
	if value == null or _is_null_literal(value):
		return S.NULL
	if value is GateAST.GateLiteral:
		return S.NOTNULL
	if value is GateAST.GateNullCoalesce:
		return _state_of((value as GateAST.GateNullCoalesce).right)
	if value is GateAST.GateArrayLit or value is GateAST.GateDictLit \
		or value is GateAST.GateObjectInit or value is GateAST.GateFString \
		or value is GateAST.GateLambda:
		return S.NOTNULL
	if value is GateAST.GateCastExpr:
		var ct: GateAST.GateTypeRef = (value as GateAST.GateCastExpr).type
		return S.MAYBE if (ct == null or ct.nullable) else S.NOTNULL
	if value is GateAST.GateCall:
		var t: GateAST.GateTypeRef = infer.type_of(value, _locals)
		if t == null:
			return S.MAYBE
		return S.MAYBE if t.nullable else S.NOTNULL
	var p: String = _path_of(value)
	if p != "":
		return _state(p) if _tracked(value) else S.NOTNULL
	return S.MAYBE


func _nullness(value) -> int:
	if value == null or _is_null_literal(value):
		return S.NULL
	var p: String = _path_of(value)
	if p != "" and _tracked(value):
		return _state(p)
	if value is GateAST.GateNullCoalesce:
		return _nullness((value as GateAST.GateNullCoalesce).right)
	var vt: GateAST.GateTypeRef = _type_of(value)
	if vt != null and vt.nullable:
		return S.MAYBE
	return S.NOTNULL


func _is_untyped(t: GateAST.GateTypeRef) -> bool:
	return t == null or t.nullable or t.name == "" or t.name == "Variant" or t.name == "void"

## The superset rule: a hard error is only raised for something plain GDScript
## cannot express. `var x: Thing = null` is legal, so renaming a `.gd` to `.gate`
## must not reject it.
func _check_value_against(decl: GateAST.GateTypeRef, value, what: String, line: int, col: int) -> void:
	if _is_untyped(decl) or value == null:
		return
	if _is_null_literal(value):
		if decl.strict:
			_err("cannot assign null to %s, which is not nullable" % what, line, col,
				"declare it as `%s? ...` to allow null" % decl.describe())
		elif _opted_in:
			_warn("null assigned to %s, declared '%s'" % [what, decl.describe()],
				line, col,
				"GDScript allows this; write `%s?` to say so deliberately, and GATE "
				% decl.describe() + "will check every use of it")
		return
	var st: int = _nullness(value)
	if st == S.NOTNULL:
		return
	var src: String = _path_of(value)
	var desc: String = "'%s'" % src if src != "" else "the value"
	if st == S.NULL:
		_err("%s is null, but %s is not nullable" % [desc, what], line, col,
			"declare it `%s? ...` to allow null" % decl.describe())
	else:
		_err("%s may be null, but %s is not nullable" % [desc, what], line, col,
			"guard it with `if %s != null:` first, or declare the target `%s? ...`"
				% [src if src != "" else "value", decl.describe()])


func _check_return(r: GateAST.GateReturnStmt) -> void:
	if _is_untyped(_ret):
		return
	if r.value == null:
		return
	if _is_null_literal(r.value):
		if _opted_in:
			_warn("returning null from a function declared '%s'" % _ret.describe(),
				r.line, r.col,
				"declare the return type `%s?` and GATE will check every caller"
					% _ret.describe())
		return
	var st: int = _nullness(r.value)
	if st == S.NOTNULL:
		return
	var src: String = _path_of(r.value)
	var desc: String = "'%s'" % src if src != "" else "the returned value"
	_err("%s %s null, but the return type is '%s'"
			% [desc, "is" if st == S.NULL else "may be", _ret.describe()],
		r.line, r.col,
		"guard it before returning, or declare the return type `%s?`" % _ret.describe())


func _check_expr(e) -> void:
	if e == null:
		return

	if e is GateAST.GateMember or e is GateAST.GateIndex:
		var spine: Array = []
		var cur = e
		while cur is GateAST.GateMember or cur is GateAST.GateIndex:
			spine.append(cur)
			cur = (cur as GateAST.GateMember).target if cur is GateAST.GateMember else (cur as GateAST.GateIndex).target
		for node in spine:
			if node is GateAST.GateMember:
				var mm: GateAST.GateMember = node
				if not mm.safe:
					_report_deref(mm.target, mm.line, mm.col, ".%s" % mm.name)
			else:
				var ii: GateAST.GateIndex = node
				if not ii.safe:
					_report_deref(ii.target, ii.line, ii.col, "[...]")
				_check_expr(ii.index)
				_check_value_operand(ii.index, "[...]", ii.line, ii.col)
		_check_expr(cur)
		return

	if e is GateAST.GateCall:
		var c: GateAST.GateCall = e
		_check_expr(c.callee)
		for a in c.args:
			_check_expr(a)
		_check_call_site(c)
		_apply_call_effects(c)
		return

	if e is GateAST.GateBinary:
		var b: GateAST.GateBinary = e
		if b.op == "and" or b.op == "or":
			_check_expr(b.left)
			var saved: Dictionary = _env.duplicate()
			_env = _narrow(_env, b.left, b.op == "and")
			_check_expr(b.right)
			_env = saved
			return
		var spine: Array = []
		var cur = b
		while cur is GateAST.GateBinary:
			var cb: GateAST.GateBinary = cur
			if cb.op == "and" or cb.op == "or":
				break
			spine.append(cb)
			cur = cb.left
		_check_expr(cur)
		for n in spine:
			var nb: GateAST.GateBinary = n
			_check_expr(nb.right)
			_check_value_operands(nb)
		return

	if e is GateAST.GateTernary:
		var t: GateAST.GateTernary = e
		_check_expr(t.cond)
		var saved3: Dictionary = _env.duplicate()
		_env = _narrow(saved3, t.cond, true)
		_check_expr(t.if_true)
		_env = _narrow(saved3, t.cond, false)
		_check_expr(t.if_false)
		_env = saved3
		return

	if e is GateAST.GateNullCoalesce:
		var nc: GateAST.GateNullCoalesce = e
		if not (nc.left is GateAST.GateMember and (nc.left as GateAST.GateMember).safe) \
			and not (nc.left is GateAST.GateIndex and (nc.left as GateAST.GateIndex).safe):
			_check_expr(nc.left)
		_check_expr(nc.right)
		return

	if e is GateAST.GateLambda:
		_check_lambda(e)
		return

	if e is GateAST.GateAwaitExpr:
		_check_expr((e as GateAST.GateAwaitExpr).operand)
		_invalidate_across_suspend()
		return

	if e is GateAST.GateUnary:
		var un: GateAST.GateUnary = e
		_check_expr(un.operand)
		if un.op == "-" or un.op == "~":
			_check_value_operand(un.operand, un.op, un.line, un.col)
		return
	if e is GateAST.GateCastExpr:
		_check_expr((e as GateAST.GateCastExpr).operand); return
	if e is GateAST.GateIsExpr:
		_check_expr((e as GateAST.GateIsExpr).operand); return
	if e is GateAST.GateArrayLit:
		for el in (e as GateAST.GateArrayLit).elements: _check_expr(el)
		return
	if e is GateAST.GateDictLit:
		var d: GateAST.GateDictLit = e
		for k in d.keys: _check_expr(k)
		for v in d.values: _check_expr(v)
		return
	if e is GateAST.GateObjectInit:
		var oi: GateAST.GateObjectInit = e
		for v2 in oi.values: _check_expr(v2)
		return
		return
	if e is GateAST.GateFString:
		for part in (e as GateAST.GateFString).parts:
			if not (part is String): _check_expr(part)
		return


func _check_lambda(lam: GateAST.GateLambda) -> void:
	var saved_env: Dictionary = _env
	var saved_locals: Dictionary = _locals.duplicate()
	var saved_names: Dictionary = _local_names.duplicate()
	var saved_ret: GateAST.GateTypeRef = _ret
	var carried: Dictionary = {}
	for k in _env:
		var key: String = String(k)
		if key == "self" or key.begins_with("self."):
			continue
		if key.contains(".") or key.contains("["):
			continue
		if _local_names.has(key):
			carried[key] = _env[k]
	_env = carried
	_ret = lam.return_type
	for p in lam.params:
		var pp: GateAST.GateParam = p
		_declare_local(pp.name, pp.type)
		if pp.type != null and pp.type.nullable:
			_env[pp.name] = S.MAYBE
	_walk_block(lam.body)
	if lam.expr_body != null:
		_check_expr(lam.expr_body)
	_env = saved_env
	_locals = saved_locals
	_local_names = saved_names
	_ret = saved_ret


func _is_numeric_expr(e) -> bool:
	if e is GateAST.GateLiteral:
		var raw: String = (e as GateAST.GateLiteral).raw
		return raw.length() > 0 and (raw[0] == "-" or raw[0] == "+" or raw[0] == "."
			or (raw[0] >= "0" and raw[0] <= "9"))
	var t: GateAST.GateTypeRef = _type_of(e)
	if t == null:
		return false
	return GateTypes.canonical(t.name) in ["int", "float"]


func _is_string_expr(e) -> bool:
	if e is GateAST.GateLiteral:
		var raw: String = (e as GateAST.GateLiteral).raw
		return raw.begins_with("\"") or raw.begins_with("'")
	if e is GateAST.GateFString:
		return true
	var t: GateAST.GateTypeRef = _type_of(e)
	if t == null:
		return false
	return GateTypes.canonical(t.name) in ["String", "StringName"]

const VALUE_OPS := ["+", "-", "*", "/", "%", "**", "<<", ">>", "&", "|", "^",
	"<", ">", "<=", ">="]


func _is_value_typed(e) -> bool:
	var t: GateAST.GateTypeRef = _type_of(e)
	return t != null and GateTypes.BUILTIN.has(GateTypes.canonical(t.name))


func _check_value_operand(side, op: String, line: int, col: int) -> void:
	var path: String = _path_of(side)
	if path == "" or not _tracked(side):
		return
	if _state(path) == S.NOTNULL:
		return
	var t: GateAST.GateTypeRef = _type_of(side)
	if t == null or not t.nullable:
		return
	if not GateTypes.BUILTIN.has(GateTypes.canonical(t.name)):
		return
	_err("'%s' may be null, and '%s' has no null case" % [path, op], line, col,
		"guard it with `if %s != null:`, or supply a fallback with `%s ?? ...`"
			% [path, path])


func _check_value_operands(b: GateAST.GateBinary) -> void:
	if not VALUE_OPS.has(b.op):
		return
	if b.op == "%" and not _is_numeric_expr(b.left):
		return
	for side in [b.left, b.right]:
		var path: String = _path_of(side)
		if path == "" or not _tracked(side):
			continue
		if _state(path) == S.NOTNULL:
			continue
		var t: GateAST.GateTypeRef = _type_of(side)
		if t == null or not t.nullable:
			continue
		if not GateTypes.BUILTIN.has(GateTypes.canonical(t.name)):
			continue
		_err("'%s' may be null, and '%s' has no null case" % [path, b.op],
			b.line, b.col,
			"guard it with `if %s != null:`, or supply a fallback with `%s ?? ...`"
				% [path, path])


func _report_deref(target, line: int, col: int, access: String) -> void:
	if (target is GateAST.GateMember and (target as GateAST.GateMember).safe) \
		or (target is GateAST.GateIndex and (target as GateAST.GateIndex).safe):
		var op: String = "?[...]"
		if target is GateAST.GateMember:
			op = "?." + (target as GateAST.GateMember).name
		var safe_access: String = "?" + access
		if access.begins_with("."):
			safe_access = "?" + access
		_err("'%s' yields null when its left side is null, so '%s' is unchecked"
				% [op, access],
			line, col,
			"keep the chain safe with `%s%s`, or use `??` to supply a fallback first"
				% [op, safe_access])
		return

	if target is GateAST.GateCall:
		var t: GateAST.GateTypeRef = infer.type_of(target, _locals)
		if t != null and t.nullable:
			var fname: String = "the call"
			var callee = (target as GateAST.GateCall).callee
			if callee is GateAST.GateMember:
				fname = "'%s()'" % (callee as GateAST.GateMember).name
			elif callee is GateAST.GateIdent:
				fname = "'%s()'" % (callee as GateAST.GateIdent).name
			_err("%s may return null; '%s' is unchecked" % [fname, access],
				line, col,
				"assign it to a variable and guard it, or use `?%s`" % access)
		return

	var path: String = _path_of(target)
	if path == "" or not _tracked(target):
		return
	var st: int = _state(path)
	if st == S.NOTNULL:
		return
	if st == S.NULL:
		_err("'%s' is null here; '%s%s' will fail" % [path, path, access],
			line, col, "assign a value before using it")
	elif _asserted.has(path):
		_err("'%s' may be null; '%s%s' is unchecked" % [path, path, access],
			line, col,
			"the `assert(%s != null)` above does not count: Godot strips assert() " % path
			+ "from release builds, so an exported game reaches this line with '%s' " % path
			+ "still null. Use `if %s == null: return`, or `%s?%s`." % [path, path, access])
	else:
		_err("'%s' may be null; '%s%s' is unchecked" % [path, path, access],
			line, col,
			"guard it with `if %s != null:`, or use `%s?%s`" % [path, path, access])

const CALLABLE_INVOKERS := GateInfer.CALLABLE_INVOKERS


func _apply_call_effects(c: GateAST.GateCall) -> void:
	var r: Dictionary = _resolve_callee(c)
	var fd = r["fd"]
	if fd != null:
		var fx = infer.effects_of(fd)
		if fx != null:
			for sfx in fx.self_paths:
				_kill_self_suffix(r["recv"], sfx)
			for j in fx.param_paths:
				if j >= c.args.size():
					continue
				var ap: String = _path_of(c.args[j])
				for sfx2 in fx.param_paths[j]:
					_kill_suffix(ap, sfx2)
			return
	if GateInfer.PURE_GLOBALS.has(r["name"]):
		return
	if (r["name"] in CALLABLE_INVOKERS
			or (GateInfer.SYNC_HIGHER_ORDER.has(r["name"]) and _has_lambda_arg(c))):
		_invalidate_under("self")
		_kill_path("self")
		_kill_self_suffix(r["recv"], "*")
	elif r["recv"] == "self" and infer.is_engine_method(_engine_base, r["name"]):
		pass
	else:
		_kill_self_suffix(r["recv"], "*")
	for a in c.args:
		_kill_suffix(_path_of(a), "*")


func _has_lambda_arg(c: GateAST.GateCall) -> bool:
	for a in c.args:
		if a is GateAST.GateLambda:
			return true
	return false


func _resolve_callee(c: GateAST.GateCall) -> Dictionary:
	var out: Dictionary = {"fd": null, "recv": "", "name": ""}

	if c.callee is GateAST.GateIdent:
		var n: String = (c.callee as GateAST.GateIdent).name
		out["name"] = n
		if _cls != "":
			var own2 = _pick_arity(infer.method_candidates(_cls, n), c.args.size())
			if own2 != null:
				out["fd"] = own2
				out["recv"] = "self"
				return out
		var fd = _pick_arity(infer.module_functions.get(n, []), c.args.size())
		if fd != null:
			out["fd"] = fd
			out["recv"] = "self"
			return out
		if _cls != "":
			fd = _pick_arity(infer.method_candidates(_cls, n), c.args.size())
			if fd != null:
				out["fd"] = fd
				out["recv"] = "self"
				return out
		out["recv"] = "self"
		return out

	if c.callee is GateAST.GateMember:
		var m: GateAST.GateMember = c.callee
		out["name"] = m.name
		if m.target is GateAST.GateIdent and (m.target as GateAST.GateIdent).name == "super":
			out["recv"] = "self"
			out["fd"] = _pick_arity(
				infer.method_candidates(String(infer.bases.get(_cls, "")), m.name),
				c.args.size())
			return out
		if m.name == "new":
			if m.target is GateAST.GateIdent:
				out["fd"] = _pick_arity(
					infer.method_candidates((m.target as GateAST.GateIdent).name, "_init"),
					c.args.size())
			return out
		out["recv"] = _path_of(m.target)
		var rt: GateAST.GateTypeRef = infer.type_of(m.target, _locals)
		if rt != null and rt.array_depth == 0 and not rt.is_dict():
			out["fd"] = _pick_arity(infer.method_candidates(rt.name, m.name), c.args.size())
		return out

	return out


func _pick_arity(cands: Array, given: int):
	for f in cands:
		if _accepts(f, given):
			return f
	return null


func _candidates(c: GateAST.GateCall) -> Array:
	if c.callee is GateAST.GateIdent:
		var n: String = (c.callee as GateAST.GateIdent).name
		if _cls != "":
			var own: Array = infer.method_candidates(_cls, n)
			if not own.is_empty():
				return own
		var mf: Array = infer.module_functions.get(n, [])
		if not mf.is_empty():
			return mf
		return []
	if c.callee is GateAST.GateMember:
		var m: GateAST.GateMember = c.callee
		if m.name == "new":
			return []
		var recv: GateAST.GateTypeRef = infer.type_of(m.target, _locals)
		if recv != null and recv.array_depth == 0 and not recv.is_dict():
			return infer.method_candidates(recv.name, m.name)
	return []


func _accepts(fd: GateAST.GateFuncDecl, given: int) -> bool:
	var required: int = 0
	var has_rest: bool = false
	for p in fd.params:
		var pp: GateAST.GateParam = p
		if pp.is_rest: has_rest = true
		elif pp.default == null: required += 1
	return given >= required and (has_rest or given <= fd.params.size())


func _check_call_site(c: GateAST.GateCall) -> void:
	var cands: Array = _candidates(c)
	if cands.is_empty():
		return
	var given: int = c.args.size()
	var fd: GateAST.GateFuncDecl = null
	for f in cands:
		if _accepts(f, given):
			fd = f
			break

	if fd == null:
		var counts: PackedStringArray = PackedStringArray()
		for f2 in cands:
			var d: GateAST.GateFuncDecl = f2
			var req: int = 0
			for p in d.params:
				if (p as GateAST.GateParam).default == null and not (p as GateAST.GateParam).is_rest:
					req += 1
			counts.append(str(req) if req == d.params.size() else "%d-%d" % [req, d.params.size()])
		_err("'%s' takes %s argument(s) but %d given"
			% [(cands[0] as GateAST.GateFuncDecl).name, " or ".join(counts), given],
			c.line, c.col)
		return

	for i in mini(c.args.size(), fd.params.size()):
		var param: GateAST.GateParam = fd.params[i]
		if param.type == null or param.type.nullable:
			continue
		if not param.type.strict and _is_null_literal(c.args[i]):
			continue
		var st: int = _nullness(c.args[i])
		if st == S.NOTNULL:
			continue
		var argp: String = _path_of(c.args[i])
		var what: String = "'%s'" % argp if argp != "" else "argument %d" % (i + 1)
		if st == S.NULL:
			_err("%s is null, but '%s' parameter '%s' is not nullable"
					% [what, fd.name, param.name],
				c.line, c.col,
				"declare it `%s? %s` to accept null" % [param.type.describe(), param.name])
		else:
			_err("%s may be null, but '%s' parameter '%s' is not nullable"
					% [what, fd.name, param.name],
				c.line, c.col,
				"guard it first, or declare the parameter `%s? %s`"
					% [param.type.describe(), param.name])

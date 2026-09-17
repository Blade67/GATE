@tool
extends RefCounted

## Escape analysis for class-lowered struct locals.
##
## A local is replaced only if every mention of it is its own declaration, a field
## read, or a field write. Anything else disqualifies it. Getting this wrong gives
## a wrong answer rather than a crash, so the pass is deliberately blunt.

var replaceable: Dictionary = {}

var _cand: Dictionary = {}

var _shadowed: Dictionary = {}      ## name -> true
var _owner = null


func analyse(body: Array, owner, params: Array = []) -> Dictionary:
	replaceable = {}
	_cand = {}
	_owner = owner
	_shadowed = {}
	for prm in params:
		if "name" in prm:
			_shadowed[String(prm.name)] = true
	_collect(body)
	if _cand.is_empty():
		return replaceable
	_check(body)
	replaceable = _cand
	return replaceable


func _collect(stmts: Array) -> void:
	for s in stmts:
		_collect_stmt(s)


func _collect_stmt(s) -> void:
	if s == null:
		return
	if s is GateAST.GateAnnotatedStmt:
		_collect_stmt((s as GateAST.GateAnnotatedStmt).stmt)
		return
	if s is GateAST.GateVarDecl:
		var vd: GateAST.GateVarDecl = s
		var sname: String = _struct_ctor_name(vd.value)
		if (sname != "" and not vd.is_const and vd.type == null and not vd.inferred
				and vd.setter == "" and vd.inline_accessors == ""):
			if _cand.has(vd.name):
				_cand.erase(vd.name)   # declared twice: not worth reasoning about
			else:
				_cand[vd.name] = sname
		return
	for sub in _child_blocks(s):
		_collect(sub)


func _struct_ctor_name(e) -> String:
	if not (e is GateAST.GateCall):
		return ""
	var c: GateAST.GateCall = e
	if not (c.callee is GateAST.GateIdent):
		return ""
	var n: String = (c.callee as GateAST.GateIdent).name
	if _owner == null:
		return ""
	if _shadowed.has(n):
		return ""
	var st: Dictionary = _owner._struct_of(n)
	if st.is_empty() or st["lowering"] == "vector":
		return ""
	return n


func _check(stmts: Array) -> void:
	for s in stmts:
		_check_stmt(s)


func _check_stmt(s) -> void:
	if s == null:
		return

	if s is GateAST.GateVarDecl:
		var vd: GateAST.GateVarDecl = s
		if _cand.has(vd.name) and _struct_ctor_name(vd.value) != "":
			for a in (vd.value as GateAST.GateCall).args:
				_expr(a)
			return
		_expr(vd.value)
		return

	if s is GateAST.GateAssignStmt:
		var a2: GateAST.GateAssignStmt = s
		if _is_field_of_candidate(a2.target):
			_expr(a2.value)
			return
		_expr(a2.target)
		_expr(a2.value)
		return

	if s is GateAST.GateReturnStmt:
		_expr((s as GateAST.GateReturnStmt).value)
		return

	if s is GateAST.GateExprStmt:
		_expr((s as GateAST.GateExprStmt).expr)
		return

	if s is GateAST.GateMultiAssign:
		var ma: GateAST.GateMultiAssign = s
		for t in ma.targets:
			_expr(t)
		for v in ma.values:
			_expr(v)
		return

	if s is GateAST.GateAnnotatedStmt:
		_check_stmt((s as GateAST.GateAnnotatedStmt).stmt)
		return

	if s is GateAST.GateRawStmt:
		_cand.clear()
		return

	if s is GateAST.GateForStmt:
		var f: GateAST.GateForStmt = s
		for vn in f.var_names:
			_cand.erase(String(vn))
		_expr(f.iterable)
	elif s is GateAST.GateIfStmt:
		_expr((s as GateAST.GateIfStmt).cond)
		for pair in (s as GateAST.GateIfStmt).elifs:
			_expr(pair[0])
	elif s is GateAST.GateWhileStmt:
		_expr((s as GateAST.GateWhileStmt).cond)
	elif s is GateAST.GateMatchStmt:
		var ms: GateAST.GateMatchStmt = s
		_expr(ms.subject)
		for br in ms.branches:
			for pat in br[0]:
				_expr(pat)
			_expr(br[1])

	for sub in _child_blocks(s):
		_check(sub)


func _is_field_of_candidate(e) -> bool:
	if not (e is GateAST.GateMember):
		return false
	var m: GateAST.GateMember = e
	if m.safe:
		return false   # `d?.f` implies d may be null, which a value never is
	if not (m.target is GateAST.GateIdent):
		return false
	var n: String = (m.target as GateAST.GateIdent).name
	if not _cand.has(n):
		return false
	if _owner == null:
		return false
	var st: Dictionary = _owner._struct_of(String(_cand[n]))
	# The member has to be a declared field. `v.len2()` is shaped like a field read,
	# and treating it as one deletes `v` and leaves the call behind.
	return not st.is_empty() and st["fields"].has(m.name)


func _erase_named_in_text(text: String) -> void:
	var bare: String = ""
	for ch in text:
		bare += ch if (ch == "_" or ch.is_valid_identifier()
			or (ch >= "0" and ch <= "9")) else " "
	for tok in bare.split(" ", false):
		_cand.erase(tok)


func _disqualify_all(n) -> void:
	if n == null or _cand.is_empty():
		return
	if n is GateAST.GateIdent:
		_cand.erase((n as GateAST.GateIdent).name)
		return
	if n is Array:
		for x in n:
			_disqualify_all(x)
		return
	if not (n is Object):
		return
	for prop in (n as Object).get_property_list():
		var pn: String = prop["name"]
		if pn in ["script", "Built-in script", "RefCounted", "Object"]:
			continue
		var v = (n as Object).get(pn)
		if v is Array or (v is Object and v.get_script() != null):
			_disqualify_all(v)
		elif v is String and n is GateAST.GateRawExpr:
			_erase_named_in_text(v)


func _expr(e) -> void:
	if e == null or _cand.is_empty():
		return

	if e is GateAST.GateIdent:
		_cand.erase((e as GateAST.GateIdent).name)
		return

	if e is GateAST.GateRawExpr:
		_erase_named_in_text((e as GateAST.GateRawExpr).text)
		return

	if e is GateAST.GateMember:
		var m: GateAST.GateMember = e
		if _is_field_of_candidate(m):
			return   # `d.field` - the whole point
		_expr(m.target)
		return

	if e is GateAST.GateLambda:
		_disqualify_all(e)
		return

	if e is GateAST.GateCall:
		var c: GateAST.GateCall = e
		_expr(c.callee)
		for a in c.args:
			_expr(a)
		return
	if e is GateAST.GateBinary:
		_expr((e as GateAST.GateBinary).left)
		_expr((e as GateAST.GateBinary).right)
		return
	if e is GateAST.GateUnary:
		_expr((e as GateAST.GateUnary).operand)
		return
	if e is GateAST.GateTernary:
		var t: GateAST.GateTernary = e
		_expr(t.cond); _expr(t.if_true); _expr(t.if_false)
		return
	if e is GateAST.GateIndex:
		_expr((e as GateAST.GateIndex).target)
		_expr((e as GateAST.GateIndex).index)
		return
	if e is GateAST.GateArrayLit:
		for el in (e as GateAST.GateArrayLit).elements:
			_expr(el)
		return
	if e is GateAST.GateDictLit:
		var d: GateAST.GateDictLit = e
		for k in d.keys:
			_expr(k)
		for v in d.values:
			_expr(v)
		return
	if e is GateAST.GateCastExpr:
		_expr((e as GateAST.GateCastExpr).operand)
		return
	if e is GateAST.GateIsExpr:
		_expr((e as GateAST.GateIsExpr).operand)
		return
	if e is GateAST.GateNullCoalesce:
		_expr((e as GateAST.GateNullCoalesce).left)
		_expr((e as GateAST.GateNullCoalesce).right)
		return
	if e is GateAST.GateAwaitExpr:
		_expr((e as GateAST.GateAwaitExpr).operand)
		return
	if e is GateAST.GateFString:
		for part in (e as GateAST.GateFString).parts:
			if not (part is String):
				_expr(part)
		return
	if e is GateAST.GateObjectInit:
		for v2 in (e as GateAST.GateObjectInit).values:
			_expr(v2)
		return


static func _child_blocks(s) -> Array:
	if s is GateAST.GateAnnotatedStmt:
		return _child_blocks((s as GateAST.GateAnnotatedStmt).stmt)
	if s is GateAST.GateIfStmt:
		var i: GateAST.GateIfStmt = s
		var out: Array = [i.then_body]
		for pair in i.elifs:
			out.append(pair[1])
		out.append(i.else_body)
		return out
	if s is GateAST.GateForStmt:
		return [(s as GateAST.GateForStmt).body]
	if s is GateAST.GateWhileStmt:
		return [(s as GateAST.GateWhileStmt).body]
	if s is GateAST.GateMatchStmt:
		var out2: Array = []
		for br in (s as GateAST.GateMatchStmt).branches:
			out2.append(br[2])
		return out2
	return []

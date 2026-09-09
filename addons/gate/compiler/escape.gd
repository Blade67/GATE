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
	if s is GateAST.AnnotatedStmt:
		_collect_stmt((s as GateAST.AnnotatedStmt).stmt)
		return
	if s is GateAST.VarDecl:
		var vd: GateAST.VarDecl = s
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
	if not (e is GateAST.Call):
		return ""
	var c: GateAST.Call = e
	if not (c.callee is GateAST.Ident):
		return ""
	var n: String = (c.callee as GateAST.Ident).name
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

	if s is GateAST.VarDecl:
		var vd: GateAST.VarDecl = s
		if _cand.has(vd.name) and _struct_ctor_name(vd.value) != "":
			for a in (vd.value as GateAST.Call).args:
				_expr(a)
			return
		_expr(vd.value)
		return

	if s is GateAST.AssignStmt:
		var a2: GateAST.AssignStmt = s
		if _is_field_of_candidate(a2.target):
			_expr(a2.value)
			return
		_expr(a2.target)
		_expr(a2.value)
		return

	if s is GateAST.ReturnStmt:
		_expr((s as GateAST.ReturnStmt).value)
		return

	if s is GateAST.ExprStmt:
		_expr((s as GateAST.ExprStmt).expr)
		return

	if s is GateAST.MultiAssign:
		var ma: GateAST.MultiAssign = s
		for t in ma.targets:
			_expr(t)
		for v in ma.values:
			_expr(v)
		return

	if s is GateAST.AnnotatedStmt:
		_check_stmt((s as GateAST.AnnotatedStmt).stmt)
		return

	if s is GateAST.RawStmt:
		_cand.clear()
		return

	if s is GateAST.ForStmt:
		var f: GateAST.ForStmt = s
		for vn in f.var_names:
			_cand.erase(String(vn))
		_expr(f.iterable)
	elif s is GateAST.IfStmt:
		_expr((s as GateAST.IfStmt).cond)
		for pair in (s as GateAST.IfStmt).elifs:
			_expr(pair[0])
	elif s is GateAST.WhileStmt:
		_expr((s as GateAST.WhileStmt).cond)
	elif s is GateAST.MatchStmt:
		var ms: GateAST.MatchStmt = s
		_expr(ms.subject)
		for br in ms.branches:
			for pat in br[0]:
				_expr(pat)
			_expr(br[1])

	for sub in _child_blocks(s):
		_check(sub)


func _is_field_of_candidate(e) -> bool:
	if not (e is GateAST.Member):
		return false
	var m: GateAST.Member = e
	if m.safe:
		return false   # `d?.f` implies d may be null, which a value never is
	if not (m.target is GateAST.Ident):
		return false
	var n: String = (m.target as GateAST.Ident).name
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
	if n is GateAST.Ident:
		_cand.erase((n as GateAST.Ident).name)
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
		elif v is String and n is GateAST.RawExpr:
			_erase_named_in_text(v)


func _expr(e) -> void:
	if e == null or _cand.is_empty():
		return

	if e is GateAST.Ident:
		_cand.erase((e as GateAST.Ident).name)
		return

	if e is GateAST.RawExpr:
		_erase_named_in_text((e as GateAST.RawExpr).text)
		return

	if e is GateAST.Member:
		var m: GateAST.Member = e
		if _is_field_of_candidate(m):
			return   # `d.field` - the whole point
		_expr(m.target)
		return

	if e is GateAST.Lambda:
		_disqualify_all(e)
		return

	if e is GateAST.Call:
		var c: GateAST.Call = e
		_expr(c.callee)
		for a in c.args:
			_expr(a)
		return
	if e is GateAST.Binary:
		_expr((e as GateAST.Binary).left)
		_expr((e as GateAST.Binary).right)
		return
	if e is GateAST.Unary:
		_expr((e as GateAST.Unary).operand)
		return
	if e is GateAST.Ternary:
		var t: GateAST.Ternary = e
		_expr(t.cond); _expr(t.if_true); _expr(t.if_false)
		return
	if e is GateAST.Index:
		_expr((e as GateAST.Index).target)
		_expr((e as GateAST.Index).index)
		return
	if e is GateAST.ArrayLit:
		for el in (e as GateAST.ArrayLit).elements:
			_expr(el)
		return
	if e is GateAST.DictLit:
		var d: GateAST.DictLit = e
		for k in d.keys:
			_expr(k)
		for v in d.values:
			_expr(v)
		return
	if e is GateAST.CastExpr:
		_expr((e as GateAST.CastExpr).operand)
		return
	if e is GateAST.IsExpr:
		_expr((e as GateAST.IsExpr).operand)
		return
	if e is GateAST.NullCoalesce:
		_expr((e as GateAST.NullCoalesce).left)
		_expr((e as GateAST.NullCoalesce).right)
		return
	if e is GateAST.AwaitExpr:
		_expr((e as GateAST.AwaitExpr).operand)
		return
	if e is GateAST.FString:
		for part in (e as GateAST.FString).parts:
			if not (part is String):
				_expr(part)
		return
	if e is GateAST.ObjectInit:
		for v2 in (e as GateAST.ObjectInit).values:
			_expr(v2)
		return


static func _child_blocks(s) -> Array:
	if s is GateAST.AnnotatedStmt:
		return _child_blocks((s as GateAST.AnnotatedStmt).stmt)
	if s is GateAST.IfStmt:
		var i: GateAST.IfStmt = s
		var out: Array = [i.then_body]
		for pair in i.elifs:
			out.append(pair[1])
		out.append(i.else_body)
		return out
	if s is GateAST.ForStmt:
		return [(s as GateAST.ForStmt).body]
	if s is GateAST.WhileStmt:
		return [(s as GateAST.WhileStmt).body]
	if s is GateAST.MatchStmt:
		var out2: Array = []
		for br in (s as GateAST.MatchStmt).branches:
			out2.append(br[2])
		return out2
	return []

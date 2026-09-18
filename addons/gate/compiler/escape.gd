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
var _declared: Dictionary = {}      ## local name -> how many times the body declares it
var _owner = null


func analyse(body: Array, owner, params: Array = []) -> Dictionary:
	replaceable = {}
	_cand = {}
	_owner = owner
	_shadowed = {}
	for prm in params:
		if "name" in prm:
			_shadowed[String(prm.name)] = true
	_declared = {}
	_collect(body)
	for n in _declared:
		if int(_declared[n]) > 1:
			_cand.erase(n)   # one name, two locals: the replaced fields would be read for both
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
	if s is GateAST._AnnotatedStmt:
		if (s as GateAST._AnnotatedStmt).stmt != null:
			_collect_stmt((s as GateAST._AnnotatedStmt).stmt)
		return
	if s is GateAST._VarDecl:
		var vd: GateAST._VarDecl = s
		_declare(vd.name)
		var sname: String = _struct_ctor_name(vd.value)
		if (sname != "" and not vd.is_const and vd.type == null and not vd.inferred
				and vd.setter == "" and vd.inline_accessors == ""):
			_cand[vd.name] = sname
		return
	if s is GateAST._ForStmt:
		for vn in (s as GateAST._ForStmt).var_names:
			_declare(String(vn))
	elif s is GateAST._MultiAssign and (s as GateAST._MultiAssign).destructure:
		for t in (s as GateAST._MultiAssign).targets:
			if t is GateAST._Ident:
				_declare((t as GateAST._Ident).name)
	elif s is GateAST._MatchStmt:
		for br in (s as GateAST._MatchStmt).branches:
			for pat in br[0]:
				if pat is GateAST._TypePattern:
					_declare((pat as GateAST._TypePattern).bind_name)
				elif pat is GateAST._RawExpr:
					for bn in _owner._pattern_binds((pat as GateAST._RawExpr).text):
						_declare(String(bn))
	for sub in _child_blocks(s):
		_collect(sub)


func _declare(n: String) -> void:
	_declared[n] = int(_declared.get(n, 0)) + 1


func _struct_ctor_name(e) -> String:
	if not (e is GateAST._Call):
		return ""
	var c: GateAST._Call = e
	if not (c.callee is GateAST._Ident):
		return ""
	var n: String = (c.callee as GateAST._Ident).name
	if _owner == null:
		return ""
	if _shadowed.has(n):
		return ""
	var st: Dictionary = _owner._ctor_struct_of(n)
	if st.is_empty() or st["lowering"] == "vector":
		return ""
	if not _owner._init_call_form(c).is_empty():
		return ""
	for i in range(c.args.size(), (st["fields"] as Array).size()):
		if _owner._default_kind(st, i) == "instance":
			return ""   # only the struct's own _init can compute this default
	return n


func _check(stmts: Array) -> void:
	for s in stmts:
		_check_stmt(s)


func _check_stmt(s) -> void:
	if s == null:
		return

	if s is GateAST._VarDecl:
		var vd: GateAST._VarDecl = s
		if _cand.has(vd.name) and _struct_ctor_name(vd.value) != "":
			for a in (vd.value as GateAST._Call).args:
				_expr(a)
			return
		_expr(vd.value)
		return

	if s is GateAST._AssignStmt:
		var a2: GateAST._AssignStmt = s
		if _is_field_of_candidate(a2.target):
			_expr(a2.value)
			return
		_expr(a2.target)
		_expr(a2.value)
		return

	if s is GateAST._ReturnStmt:
		_expr((s as GateAST._ReturnStmt).value)
		return

	if s is GateAST._ExprStmt:
		_expr((s as GateAST._ExprStmt).expr)
		return

	if s is GateAST._MultiAssign:
		var ma: GateAST._MultiAssign = s
		for t in ma.targets:
			_expr(t)
		for v in ma.values:
			_expr(v)
		return

	if s is GateAST._AnnotatedStmt:
		if (s as GateAST._AnnotatedStmt).stmt != null:
			_check_stmt((s as GateAST._AnnotatedStmt).stmt)
		return

	if s is GateAST._RawStmt:
		_cand.clear()
		return

	if s is GateAST._ForStmt:
		var f: GateAST._ForStmt = s
		for vn in f.var_names:
			_cand.erase(String(vn))
		_expr(f.iterable)
	elif s is GateAST._IfStmt:
		_expr((s as GateAST._IfStmt).cond)
		for pair in (s as GateAST._IfStmt).elifs:
			_expr(pair[0])
	elif s is GateAST._WhileStmt:
		_expr((s as GateAST._WhileStmt).cond)
	elif s is GateAST._MatchStmt:
		var ms: GateAST._MatchStmt = s
		_expr(ms.subject)
		for br in ms.branches:
			for pat in br[0]:
				_expr(pat)
			_expr(br[1])

	for sub in _child_blocks(s):
		_check(sub)


func _is_field_of_candidate(e) -> bool:
	if not (e is GateAST._Member):
		return false
	var m: GateAST._Member = e
	if m.safe:
		return false   # `d?.f` implies d may be null, which a value never is
	if not (m.target is GateAST._Ident):
		return false
	var n: String = (m.target as GateAST._Ident).name
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
	if n is GateAST._Ident:
		_cand.erase((n as GateAST._Ident).name)
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
		elif v is String and n is GateAST._RawExpr:
			_erase_named_in_text(v)


func _expr(e) -> void:
	if e == null or _cand.is_empty():
		return

	if e is GateAST._Ident:
		_cand.erase((e as GateAST._Ident).name)
		return

	if e is GateAST._RawExpr:
		_erase_named_in_text((e as GateAST._RawExpr).text)
		return

	if e is GateAST._Member:
		var m: GateAST._Member = e
		if _is_field_of_candidate(m):
			return   # `d.field` - the whole point
		_expr(m.target)
		return

	if e is GateAST._Lambda:
		_disqualify_all(e)
		return

	if e is GateAST._Call:
		var c: GateAST._Call = e
		_expr(c.callee)
		for a in c.args:
			_expr(a)
		return
	if e is GateAST._Binary:
		_expr((e as GateAST._Binary).left)
		_expr((e as GateAST._Binary).right)
		return
	if e is GateAST._Unary:
		_expr((e as GateAST._Unary).operand)
		return
	if e is GateAST._Ternary:
		var t: GateAST._Ternary = e
		_expr(t.cond); _expr(t.if_true); _expr(t.if_false)
		return
	if e is GateAST._Index:
		_expr((e as GateAST._Index).target)
		_expr((e as GateAST._Index).index)
		return
	if e is GateAST._ArrayLit:
		for el in (e as GateAST._ArrayLit).elements:
			_expr(el)
		return
	if e is GateAST._DictLit:
		var d: GateAST._DictLit = e
		for k in d.keys:
			_expr(k)
		for v in d.values:
			_expr(v)
		return
	if e is GateAST._CastExpr:
		_expr((e as GateAST._CastExpr).operand)
		return
	if e is GateAST._IsExpr:
		_expr((e as GateAST._IsExpr).operand)
		return
	if e is GateAST._NullCoalesce:
		_expr((e as GateAST._NullCoalesce).left)
		_expr((e as GateAST._NullCoalesce).right)
		return
	if e is GateAST._AwaitExpr:
		_expr((e as GateAST._AwaitExpr).operand)
		return
	if e is GateAST._FString:
		for part in (e as GateAST._FString).parts:
			if not (part is String):
				_expr(part)
		return
	if e is GateAST._ObjectInit:
		for v2 in (e as GateAST._ObjectInit).values:
			_expr(v2)
		return


static func _child_blocks(s) -> Array:
	if s is GateAST._AnnotatedStmt:
		if (s as GateAST._AnnotatedStmt).stmt == null:
			return []
		return _child_blocks((s as GateAST._AnnotatedStmt).stmt)
	if s is GateAST._IfStmt:
		var i: GateAST._IfStmt = s
		var out: Array = [i.then_body]
		for pair in i.elifs:
			out.append(pair[1])
		out.append(i.else_body)
		return out
	if s is GateAST._ForStmt:
		return [(s as GateAST._ForStmt).body]
	if s is GateAST._WhileStmt:
		return [(s as GateAST._WhileStmt).body]
	if s is GateAST._MatchStmt:
		var out2: Array = []
		for br in (s as GateAST._MatchStmt).branches:
			out2.append(br[2])
		return out2
	return []

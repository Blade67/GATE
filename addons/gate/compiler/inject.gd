@tool
class_name GateInject
extends RefCounted

## Merges generated statements into the user's own functions. Injected code keeps the
## line of the annotation that asked for it, so a failed assert maps back to `@required`.
## A trait's members are shared by every class that uses it, so they are cloned first.


static func run(mod: GateAST._Module, diags: GateDiagnostics, super_calls: Dictionary = {},
		traits: Dictionary = {}) -> void:
	var main_name: String = mod.class_name_decl
	if main_name == "":
		main_name = mod.path.get_file().get_basename()
	var local: Dictionary = {}
	_local_traits(mod.members, local)
	_reline_foreign_traits(mod.members, traits, local)
	_run_class(mod, mod.members, main_name, super_calls, mod.is_tool, diags)


static func _local_traits(members: Array, out: Dictionary) -> void:
	for m in members:
		if m is GateAST._ClassDecl:
			if (m as GateAST._ClassDecl).form == "trait":
				out[m] = true
			_local_traits((m as GateAST._ClassDecl).members, out)


static func _reline_foreign_traits(members: Array, traits: Dictionary, local: Dictionary) -> void:
	for m in members:
		if not (m is GateAST._ClassDecl):
			continue
		var cd: GateAST._ClassDecl = m
		_reline_foreign_traits(cd.members, traits, local)
		for tname in cd.traits:
			var decl: Variant = traits.get(tname, null)
			if not (decl is GateAST._ClassDecl) or local.has(decl):
				continue
			for i in cd.members.size():
				if _from_trait(decl as GateAST._ClassDecl, cd.members[i]):
					cd.members[i] = _relined(clone(cd.members[i]), cd.line)


static func _from_trait(decl: GateAST._ClassDecl, m) -> bool:
	if decl.members.has(m):
		return true
	if not (m is GateAST._ASTNode):
		return false
	var node: GateAST._ASTNode = m
	for tm in decl.members:
		if tm.get_script() == node.get_script() and (tm as GateAST._ASTNode).line == node.line 				and (tm as GateAST._ASTNode).col == node.col:
			return true
	return false


static func _relined(node: Variant, line: int) -> Variant:
	if node is Array:
		for x in node:
			_relined(x, line)
	elif node is GateAST._ASTNode:
		var n: GateAST._ASTNode = node
		n.line = line
		if n is GateAST._Stmt:
			(n as GateAST._Stmt).injected = true
		if n is GateAST._VarDecl:
			(n as GateAST._VarDecl).setter_line = line
		for p in n.get_property_list():
			if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				var v: Variant = n.get(p["name"])
				if v is GateAST._ASTNode or v is Array:
					_relined(v, line)
	return node


static func _run_class(owner: Object, members: Array, cls_name: String, super_calls: Dictionary,
		is_tool: bool, diags: GateDiagnostics) -> void:
	var inherited: Dictionary = super_calls.get(owner, {})
	var asserts: Array = []
	var guarded: Array = []    ## [_VarDecl, its @export_if]
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			if cd.form in ["class", "namespace"]:
				_run_class(cd, cd.members, cd.name, super_calls, is_tool, diags)
		elif m is GateAST._VarDecl:
			var vd: GateAST._VarDecl = m
			var req: GateAST._Annotation = annotation(vd.annotations, "required")
			if req != null:
				asserts.append(_required_assert(vd, cls_name, req.line, req.col))
			var ei: GateAST._Annotation = annotation(vd.annotations, "export_if")
			if ei != null and ei.args.size() == 1:
				guarded.append([vd, ei])
	if not asserts.is_empty():
		var line: int = (asserts[0] as GateAST._Stmt).line
		var checks: Array = asserts
		if is_tool:
			checks = [_outside_editor(asserts, line)]
		prepend_to(members, "_ready", "_ready() -> void", checks, line,
			[super_call([], line)] if inherited.has("_ready") else [])
	if not guarded.is_empty():
		_export_if(members, guarded, inherited.has("_validate_property"), diags)


static func _export_if(members: Array, guarded: Array, inherited: bool, diags: GateDiagnostics) -> void:
	var props: Dictionary = {}
	for m in members:
		if m is GateAST._VarDecl and not (m as GateAST._VarDecl).is_const:
			props[(m as GateAST._VarDecl).name] = m
	var reads: Dictionary = {}
	for g in guarded:
		for r in condition_reads((g[1] as GateAST._Annotation).args[0]):
			reads[r] = true
	var param: String = "property"
	var own: GateAST._FuncDecl = find_func(members, "_validate_property")
	if own != null and not own.params.is_empty():
		param = (own.params[0] as GateAST._Param).name
	else:
		while reads.has(param) or props.has(param):
			param = "_" + param
	var stmts: Array = []
	var notified: Dictionary = {}
	for g in guarded:
		var vd: GateAST._VarDecl = g[0]
		var ei: GateAST._Annotation = g[1]
		var cond: GateAST._Expr = ei.args[0]
		if reads.has(param):
			cond = _through_self(cond, param)
		stmts.append(_hide_unless(param, emitted_name(vd), cond, ei.line, ei.col))
		for read in condition_reads(ei.args[0]):
			if props.has(read) and not notified.has(read):
				notified[read] = true
				_notify_on_set(members, props[read], ei.line, ei.col, diags)
	var line: int = (stmts[0] as GateAST._Stmt).line
	prepend_to(members, "_validate_property",
		"_validate_property(%s: Dictionary) -> void" % param, stmts, line,
		[super_call([param], line)] if inherited else [])


static func _through_self(cond: GateAST._Expr, name: String) -> GateAST._Expr:
	if cond is GateAST._Ident and (cond as GateAST._Ident).name == name:
		var s: GateAST._SelfExpr = GateAST._SelfExpr.new()
		s.at(cond.line, cond.col)
		var m: GateAST._Member = GateAST._Member.new()
		m.target = s
		m.name = name
		m.at(cond.line, cond.col)
		return m
	var copy: GateAST._ASTNode = clone(cond)
	for p in copy.get_property_list():
		if not (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var v = copy.get(p["name"])
		if v is GateAST._Expr and not (copy is GateAST._Member and p["name"] == "name"):
			copy.set(p["name"], _through_self(v, name))
		elif v is Array:
			var out: Array = []
			for x in v:
				out.append(_through_self(x, name) if x is GateAST._Expr else x)
			copy.set(p["name"], out)
	if copy is GateAST._Call and (cond as GateAST._Call).callee is GateAST._Ident:
		(copy as GateAST._Call).callee = clone((cond as GateAST._Call).callee)
	return copy


static func super_call(args: Array, line: int) -> GateAST._Stmt:
	var callee: GateAST._Ident = GateAST._Ident.new()
	callee.name = "super"
	var call: GateAST._Call = GateAST._Call.new()
	call.callee = callee
	for a in args:
		var id: GateAST._Ident = GateAST._Ident.new()
		id.name = String(a)
		id.at(line, 1)
		call.args.append(id)
	var st: GateAST._ExprStmt = GateAST._ExprStmt.new()
	st.expr = call
	for n in [callee, call, st]:
		(n as GateAST._ASTNode).at(line, 1)
	return st


## A @tool script runs `_ready` in the editor too, where an unset node is normal.
static func _outside_editor(body: Array, line: int) -> GateAST._Stmt:
	var engine: GateAST._Ident = GateAST._Ident.new()
	engine.name = "Engine"
	var member: GateAST._Member = GateAST._Member.new()
	member.target = engine
	member.name = "is_editor_hint"
	var call: GateAST._Call = GateAST._Call.new()
	call.callee = member
	var neg: GateAST._Unary = GateAST._Unary.new()
	neg.op = "not"
	neg.operand = call
	var st: GateAST._IfStmt = GateAST._IfStmt.new()
	st.cond = neg
	st.then_body = body
	for n in [engine, member, call, neg, st]:
		(n as GateAST._ASTNode).at(line, 1)
	for s in body:
		(s as GateAST._Stmt).injected = true
	return st


static func _hide_unless(param: String, prop: String, cond: GateAST._Expr, line: int, col: int) -> GateAST._Stmt:
	var p1: GateAST._Ident = GateAST._Ident.new()
	p1.name = param
	var pname: GateAST._Member = GateAST._Member.new()
	pname.target = p1
	pname.name = "name"
	var lit: GateAST._Literal = GateAST._Literal.new()
	lit.kind = "string"
	lit.raw = "\"%s\"" % prop
	var eq: GateAST._Binary = GateAST._Binary.new()
	eq.op = "=="
	eq.left = pname
	eq.right = lit
	var neg: GateAST._Unary = GateAST._Unary.new()
	neg.op = "not"
	neg.operand = cond
	var test: GateAST._Binary = GateAST._Binary.new()
	test.op = "and"
	test.left = eq
	test.right = neg
	var p2: GateAST._Ident = GateAST._Ident.new()
	p2.name = param
	var usage: GateAST._Member = GateAST._Member.new()
	usage.target = p2
	usage.name = "usage"
	var bit: GateAST._Ident = GateAST._Ident.new()
	bit.name = "PROPERTY_USAGE_EDITOR"
	var mask: GateAST._Unary = GateAST._Unary.new()
	mask.op = "~"
	mask.operand = bit
	var assign: GateAST._AssignStmt = GateAST._AssignStmt.new()
	assign.target = usage
	assign.op = "&="
	assign.value = mask
	assign.injected = true
	var st: GateAST._IfStmt = GateAST._IfStmt.new()
	st.cond = test
	st.then_body = [assign]
	for n in [p1, pname, lit, eq, neg, test, p2, usage, bit, mask, assign, st]:
		(n as GateAST._ASTNode).at(line, col)
	return st


static func _notify_on_set(members: Array, vd: GateAST._VarDecl, line: int, col: int,
		diags: GateDiagnostics) -> void:
	var fname: String = inline_setter(vd)
	if fname != "":
		var fd: GateAST._FuncDecl = find_func(members, fname)
		if fd == null:
			return   # the checker has reported it
		var mine: GateAST._FuncDecl = _own(members, fd)
		mine.body = notify_every_exit(mine.body, line, col)
		return
	var prop: GateAST._VarDecl = _own(members, vd)
	prop.notify_line = line
	if prop.setter != "" and not _parse_set_block(prop):
		diags.error(("GATE cannot read the setter of '%s' to add the notification "
			+ "@export_if needs") % prop.name, line, col,
			"write it as a `set = <function>` accessor instead, and GATE adds the "
			+ "notification to that function.")


static func _notify(line: int, col: int) -> GateAST._Stmt:
	var callee: GateAST._Ident = GateAST._Ident.new()
	callee.name = "notify_property_list_changed"
	var call: GateAST._Call = GateAST._Call.new()
	call.callee = callee
	var st: GateAST._ExprStmt = GateAST._ExprStmt.new()
	st.expr = call
	st.injected = true
	for n in [callee, call, st]:
		(n as GateAST._ASTNode).at(line, col)
	return st


static func notify_every_exit(body: Array, line: int, col: int) -> Array:
	var out: Array = _before_returns(body, line, col)
	if out.is_empty() or not (out[out.size() - 1] is GateAST._ReturnStmt):
		out.append(_notify(line, col))
	return out


## The notify goes before every return, so an early exit still updates the inspector.
static func _before_returns(body: Array, line: int, col: int) -> Array:
	var out: Array = []
	for s in body:
		if s is GateAST._ReturnStmt:
			out.append(_notify(line, col))
		elif s is GateAST._IfStmt:
			var st: GateAST._IfStmt = s
			st.then_body = _before_returns(st.then_body, line, col)
			for pair in st.elifs:
				pair[1] = _before_returns(pair[1], line, col)
			st.else_body = _before_returns(st.else_body, line, col)
		elif s is GateAST._ForStmt:
			(s as GateAST._ForStmt).body = _before_returns((s as GateAST._ForStmt).body, line, col)
		elif s is GateAST._WhileStmt:
			(s as GateAST._WhileStmt).body = _before_returns((s as GateAST._WhileStmt).body, line, col)
		elif s is GateAST._MatchStmt:
			for br in (s as GateAST._MatchStmt).branches:
				br[2] = _before_returns(br[2], line, col)
		out.append(s)
	return out


static func _parse_set_block(vd: GateAST._VarDecl) -> bool:
	if vd.set_ast != null:
		vd.set_ast.body = notify_every_exit(vd.set_ast.body, vd.notify_line, 1)
		vd.set_forced = true
		return true
	var lines: PackedStringArray = vd.setter.split("\n")
	var first: int = -1
	var last: int = -1
	for i in accessor_lines(vd.setter):
		var t: String = lines[i].strip_edges()
		if t.begins_with("#"):
			continue
		if first >= 0 and last < 0:
			last = i - 1
		if first < 0 and (t.begins_with("set(") or t.begins_with("set (")):
			first = i
	if first < 0:
		return true   # a getter only: the checker has reported it
	if last < 0:
		last = lines.size() - 1
	while last > first and lines[last].strip_edges() == "":
		last -= 1
	var head: String = lines[first].strip_edges()
	var open: int = head.find("(")
	var close: int = head.find(")", open)
	var colon: int = head.find(":", close)
	if open < 0 or close < 0 or colon < 0:
		return false
	var src_line: int = (vd.setter_line if vd.setter_line > 0 else vd.line) + first
	var body: String = "func __gate_set(%s):%s\n" % [head.substr(open + 1, close - open - 1), head.substr(colon + 1)]
	for i in range(first + 1, last + 1):
		body += lines[i] + "\n"
	var src: String = "\n".repeat(maxi(src_line - 1, 0)) + body
	var d: GateDiagnostics = GateDiagnostics.new()
	var toks: Array[GateLexer._Token] = GateLexer.new().tokenize(body, d, maxi(src_line, 1))
	var mod: GateAST._Module = GateParser.new().parse(toks, src, d)
	if d.has_errors() or mod.members.size() != 1 or not (mod.members[0] is GateAST._FuncDecl):
		return false
	var fd: GateAST._FuncDecl = mod.members[0]
	fd.body = notify_every_exit(fd.body, vd.notify_line, 1)
	vd.set_ast = fd
	vd.set_span = [first, last]
	return true


static func expand_accessors(members: Array) -> void:
	var i: int = 0
	while i < members.size():
		var m = members[i]
		if m is GateAST._ClassDecl:
			expand_accessors((m as GateAST._ClassDecl).members)
		elif m is GateAST._VarDecl and (m as GateAST._VarDecl).setter != "":
			var vd: GateAST._VarDecl = m
			var made: Array = []
			var got: Array = _parse_accessor(vd, "get")
			if not got.is_empty():
				vd.get_ast = got[0]
				vd.get_span = got[1]
				made.append(got[0])
			var set_: Array = _parse_accessor(vd, "set")
			if not set_.is_empty():
				vd.set_ast = set_[0]
				vd.set_span = set_[1]
				made.append(set_[0])
			for k in made.size():
				members.insert(i + 1 + k, made[k])
			i += made.size()
		i += 1


static func _parse_accessor(vd: GateAST._VarDecl, kind: String) -> Array:
	var lines: PackedStringArray = vd.setter.split("\n")
	var tops: Array = accessor_lines(vd.setter)
	var first: int = -1
	var last: int = -1
	for i in tops:
		var t: String = lines[i].strip_edges()
		if t.begins_with("#"):
			continue
		if first >= 0 and last < 0:
			last = i - 1
		var is_head: bool = t.begins_with(kind + "(") or t.begins_with(kind + " (") \
			if kind == "set" else (t.begins_with("get:") or t.begins_with("get :"))
		if first < 0 and is_head:
			first = i
	if first < 0:
		return []
	if last < 0:
		last = lines.size() - 1
	while last > first and (lines[last].strip_edges() == "" or lines[last].strip_edges().begins_with("#")):
		last -= 1
	var head: String = lines[first].strip_edges()
	var params: String = ""
	var colon: int = head.find(":")
	if kind == "set":
		var open: int = head.find("(")
		var close: int = head.find(")", open)
		colon = head.find(":", close)
		if open < 0 or close < 0 or colon < 0:
			return []
		params = head.substr(open + 1, close - open - 1)
	if colon < 0:
		return []
	var src_line: int = (vd.setter_line if vd.setter_line > 0 else vd.line) + first
	var body: String = "%sfunc __gate_%s_%s(%s):%s\n" % ["static " if vd.is_static else "", kind,
		vd.name, params, head.substr(colon + 1)]
	for i in range(first + 1, last + 1):
		body += lines[i] + "\n"
	var src: String = "\n".repeat(maxi(src_line - 1, 0)) + body
	var d: GateDiagnostics = GateDiagnostics.new()
	var toks: Array[GateLexer._Token] = GateLexer.new().tokenize(body, d, maxi(src_line, 1))
	var mod: GateAST._Module = GateParser.new().parse(toks, src, d)
	if d.has_errors() or mod.members.size() != 1 or not (mod.members[0] is GateAST._FuncDecl):
		return []
	var fd: GateAST._FuncDecl = mod.members[0]
	fd.accessor = true
	if kind == "set" and fd.params.size() == 1 and (fd.params[0] as GateAST._Param).type == null \
			and vd.type != null:
		(fd.params[0] as GateAST._Param).type = vd.type   # Godot types it as the property
	return [fd, [first, last]]


static func accessor_lines(setter: String) -> Array:
	var lines: PackedStringArray = setter.split("\n")
	var in_text: Array = []
	var open_string: bool = false
	for l in lines:
		in_text.append(open_string)
		if GateEmitter._triple_quotes_in(l) % 2 == 1:
			open_string = not open_string
	var top: int = -1
	for i in lines.size():
		if not in_text[i] and lines[i].strip_edges() != "" and (top < 0 or indent_of(lines[i]) < top):
			top = indent_of(lines[i])
	var out: Array = []
	for i in lines.size():
		if not in_text[i] and lines[i].strip_edges() != "" and indent_of(lines[i]) == top:
			out.append(i)
	return out


static func indent_of(line: String) -> int:
	var n: int = 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return n


static func find_func(members: Array, fname: String) -> GateAST._FuncDecl:
	for m in members:
		if m is GateAST._FuncDecl and (m as GateAST._FuncDecl).name == fname:
			return m
	return null


static func inline_setter(vd: GateAST._VarDecl) -> String:
	if vd.inline_accessors == "":
		return ""
	var re: RegEx = RegEx.create_from_string("\\bset\\s*=\\s*([A-Za-z_][A-Za-z0-9_]*)")
	var hit: RegExMatch = re.search(vd.inline_accessors)
	return hit.get_string(1) if hit != null else ""


static func _own(members: Array, node: GateAST._ASTNode) -> GateAST._ASTNode:
	var i: int = members.find(node)
	var copy: GateAST._ASTNode = clone(node)
	if i >= 0:
		members[i] = copy
	return copy


static func clone(node):
	if node is Array:
		var arr: Array = []
		for x in node:
			arr.append(clone(x))
		return arr
	if not (node is GateAST._ASTNode):
		return node
	var copy: GateAST._ASTNode = (node as Object).get_script().new()
	for p in (node as Object).get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			copy.set(p["name"], clone((node as Object).get(p["name"])))
	return copy


static func condition_reads(e) -> Array:
	var out: Array = []
	_reads(e, out)
	return out


static func _reads(e, out: Array) -> void:
	if e == null:
		return
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		if not out.has(n):
			out.append(n)
	elif e is GateAST._Member:
		var mb: GateAST._Member = e
		if mb.target is GateAST._SelfExpr:
			if not out.has(mb.name):
				out.append(mb.name)
		else:
			_reads(mb.target, out)
	elif e is GateAST._Call:
		var c: GateAST._Call = e
		if not (c.callee is GateAST._Ident):
			_reads(c.callee, out)
		for a in c.args:
			_reads(a, out)
	elif e is GateAST._Binary:
		_reads((e as GateAST._Binary).left, out)
		_reads((e as GateAST._Binary).right, out)
	elif e is GateAST._Unary:
		_reads((e as GateAST._Unary).operand, out)
	elif e is GateAST._Ternary:
		_reads((e as GateAST._Ternary).cond, out)
		_reads((e as GateAST._Ternary).if_true, out)
		_reads((e as GateAST._Ternary).if_false, out)
	elif e is GateAST._NullCoalesce:
		_reads((e as GateAST._NullCoalesce).left, out)
		_reads((e as GateAST._NullCoalesce).right, out)
	elif e is GateAST._Index:
		_reads((e as GateAST._Index).target, out)
		_reads((e as GateAST._Index).index, out)
	elif e is GateAST._IsExpr:
		_reads((e as GateAST._IsExpr).operand, out)
	elif e is GateAST._CastExpr:
		_reads((e as GateAST._CastExpr).operand, out)
	elif e is GateAST._ArrayLit:
		for x in (e as GateAST._ArrayLit).elements:
			_reads(x, out)
	elif e is GateAST._DictLit:
		var dl: GateAST._DictLit = e
		for i in dl.keys.size():
			var lua: bool = i < dl.lua_keys.size() and bool(dl.lua_keys[i])
			if not lua:   # `{a = 1}` names a key; `{a: 1}` reads a
				_reads(dl.keys[i], out)
		for v in dl.values:
			_reads(v, out)


static func will_define(members: Array) -> Array:
	var out: Array = []
	for m in members:
		if not (m is GateAST._VarDecl):
			continue
		var vd: GateAST._VarDecl = m
		if annotation(vd.annotations, "required") != null and not out.has("_ready"):
			out.append("_ready")
		if annotation(vd.annotations, "export_if") != null and not out.has("_validate_property"):
			out.append("_validate_property")
	return out


static func annotation(annotations: Array, name: String) -> GateAST._Annotation:
	for a in annotations:
		if (a as GateAST._Annotation).name == name:
			return a
	return null


static func is_export(name: String) -> bool:
	return name.begins_with("export") and not (name in
		["export_group", "export_subgroup", "export_category"])


static func has_export(annotations: Array) -> bool:
	for a in annotations:
		if is_export((a as GateAST._Annotation).name):
			return true
	return false


static func emitted_name(vd: GateAST._VarDecl) -> String:
	if vd.visibility == "priv" and not vd.name.begins_with("_"):
		return "_" + vd.name
	return vd.name


static func prepend_to(cls_members: Array, fname: String, sig: String, stmts: Array, line: int,
		after: Array = []) -> void:
	for s in stmts + after:
		(s as GateAST._Stmt).injected = true
	var fd: GateAST._FuncDecl = find_func(cls_members, fname)
	if fd != null:
		var mine: GateAST._FuncDecl = _own(cls_members, fd)
		var body: Array = stmts.duplicate()
		body.append_array(mine.body)
		mine.body = body
		return
	var made: GateAST._FuncDecl = parse_func(sig)
	made.body = stmts + after
	made.injected = true
	made.at(line, 1)
	for p in made.params:
		(p as GateAST._Param).at(line, 1)
	cls_members.append(made)


static func parse_func(sig: String) -> GateAST._FuncDecl:
	var src: String = "func %s:\n\tpass\n" % sig
	var d: GateDiagnostics = GateDiagnostics.new()
	var mod: GateAST._Module = GateParser.new().parse(GateLexer.new().tokenize(src, d), src, d)
	return mod.members[0] as GateAST._FuncDecl


static func _required_assert(vd: GateAST._VarDecl, cls_name: String, line: int, col: int) -> GateAST._Stmt:
	var name: String = emitted_name(vd)
	var target: GateAST._Ident = GateAST._Ident.new()
	target.name = name
	var nul: GateAST._Literal = GateAST._Literal.new()
	nul.kind = "null"
	nul.raw = "null"
	var cmp: GateAST._Binary = GateAST._Binary.new()
	cmp.op = "!="
	cmp.left = target
	cmp.right = nul
	var msg: GateAST._Literal = GateAST._Literal.new()
	msg.kind = "string"
	msg.raw = "\"%s\"" % ("%s.%s is @required but was not set in the inspector"
		% [cls_name, name]).c_escape()
	var callee: GateAST._Ident = GateAST._Ident.new()
	callee.name = "assert"
	var call: GateAST._Call = GateAST._Call.new()
	call.callee = callee
	call.args = [cmp, msg]
	var st: GateAST._ExprStmt = GateAST._ExprStmt.new()
	st.expr = call
	for n in [target, nul, cmp, msg, callee, call, st]:
		(n as GateAST._ASTNode).at(line, col)
	return st

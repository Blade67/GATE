@tool
class_name GateParser
extends "res://addons/gate/compiler/parser_expr.gd"

## Parser layer 4: statements, declarations, and the module.
##
## Anything this cannot decompose is kept as source text and re-emitted verbatim,
## so an unfamiliar GDScript construct degrades to pass-through, not an error.


func parse(tokens: Array, source: String, diags: GateDiagnostics) -> GateAST.Module:
	diagnostics = diags
	_toks = tokens
	_i = 0
	_lines = source.split("\n")
	_panic = false
	_saw_nullable = false
	_saw_alias = false
	_saw_gate_type = false
	_alias_names = {}
	_names_scanned = false
	_generic_names = {}
	_templates_scanned = false
	_templates = {}
	_seed_aliases()

	var mod: GateAST.Module = GateAST.Module.new()
	_skip_newlines()
	while not _at_end():
		var m: GateAST.Stmt = _parse_module_member(mod)
		if m != null:
			mod.members.append(m)
		_drain_extras(mod.members)
		while _match_op(";"):
			if _at_stmt_end():
				break
			var m2: GateAST.Stmt = _parse_module_member(mod)
			if m2 != null:
				mod.members.append(m2)
			_drain_extras(mod.members)
		_skip_newlines()
	mod.generic_uses = _generic_uses
	mod.uses_nullable = _saw_nullable
	mod.has_aliases = _saw_alias
	mod.uses_gate_types = _saw_gate_type
	return mod

const FILE_ANNOTATIONS := ["tool", "icon", "static_unload", "abstract"]


func _annotation_is_file_level() -> bool:
	var name: String = _cur().value.substr(1)
	if not FILE_ANNOTATIONS.has(name):
		return false
	if name != "abstract":
		return true
	var i: int = _i + 1
	while i < _toks.size():
		var t: GateLexer.Token = _toks[i]
		if t.type == GateLexer.T.NEWLINE or t.type == GateLexer.T.COMMENT or t.type == GateLexer.T.ANNOTATION:
			i += 1
			continue
		return not (t.is_kw("class") or t.is_kw("func") or t.is_kw("static"))
	return true


func _parse_module_member(mod: GateAST.Module) -> GateAST.Stmt:
	if _check(GateLexer.T.ANNOTATION) and _annotation_is_file_level():
		var fa: GateAST.Annotation = _parse_one_annotation()
		if fa != null:
			mod.header_annotations.append(fa)
			if fa.name == "tool":
				mod.is_tool = true
		_skip_newlines()
		return null

	if _check(GateLexer.T.COMMENT):
		var c: GateAST.CommentStmt = GateAST.CommentStmt.new()
		c.text = _advance().value
		return c

	if _check_kw("class_name"):
		var cn_tok: GateLexer.Token = _advance()
		mod.class_name_line = cn_tok.line
		if _check(GateLexer.T.IDENT):
			mod.class_name_decl = _advance().value
		if _match_op(","):
			if _check(GateLexer.T.STRING): mod.icon = _advance().value
		if _check_kw("extends"):
			mod.extends_line = _advance().line
			mod.extends_type = _parse_extends_type()
		return null

	if _check_kw("extends"):
		mod.extends_line = _advance().line
		mod.extends_type = _parse_extends_type()
		return null

	return _parse_member()


func _parse_one_annotation() -> GateAST.Annotation:
	if not _check(GateLexer.T.ANNOTATION):
		return null
	var t: GateLexer.Token = _advance()
	var a: GateAST.Annotation = GateAST.Annotation.new()
	a.name = t.value.substr(1)
	a.at(t.line, t.col)
	if _check_op("("):
		_advance()
		_skip_newlines()
		while not _at_end() and not _check_op(")"):
			var before: int = _i
			a.args.append(_parse_expr())
			_skip_newlines()
			if not _match_op(","):
				break
			_skip_newlines()
			if _i == before:
				break  # no progress: malformed input, let recovery take over
		_match_op(")")
	return a


func _parse_annotations() -> Array:
	var out: Array = []
	while _check(GateLexer.T.ANNOTATION):
		var a: GateAST.Annotation = _parse_one_annotation()
		if a == null:
			break
		out.append(a)
		_skip_newlines()
	return out


func _parse_member() -> GateAST.Stmt:
	var start_line: int = _cur().line
	var annotations: Array = _parse_annotations()

	var visibility: String = ""
	var is_static: bool = false
	var is_abstract: bool = false
	var is_virtual: bool = false
	var is_override: bool = false
	var is_final: bool = false

	while true:
		if _check_kw("pub"): _advance(); visibility = "pub"
		elif _check_kw("priv"): _advance(); visibility = "priv"
		elif _check_kw("static"): _advance(); is_static = true
		elif _check_kw("abstract"): _advance(); is_abstract = true
		elif _check_kw("virtual"): _advance(); is_virtual = true
		elif _check_kw("override"): _advance(); is_override = true
		elif _check_kw("final"): _advance(); is_final = true
		else: break

	if _check_kw("class") or _check_kw("struct") or _check_kw("interface") \
		or _check_kw("trait") or _check_kw("namespace"):
		var cd: GateAST.ClassDecl = _parse_class_like()
		if cd != null:
			cd.annotations = annotations
			cd.is_abstract = is_abstract
		return cd

	if _cur().type == GateLexer.T.KEYWORD and _looks_like_func_type_decl():
		var vd3: GateAST.VarDecl = _parse_typed_decl()
		if vd3 != null:
			vd3.annotations = annotations
			vd3.visibility = visibility
			vd3.is_static = is_static
		return vd3

	if _check_kw("func") or _check_kw("operator"):
		var fd: GateAST.FuncDecl = _parse_func()
		if fd != null:
			fd.annotations = annotations
			fd.visibility = visibility
			fd.is_static = is_static
			fd.is_abstract = is_abstract
			fd.is_virtual = is_virtual
			fd.is_override = is_override
			fd.is_final = is_final
		return fd

	if _check_kw("signal"):
		var sd: GateAST.SignalDecl = _parse_signal()
		if sd != null:
			(sd as GateAST.SignalDecl).annotations = annotations
		return sd

	if _check_kw("enum"):
		var ed: GateAST.EnumDecl = _parse_enum()
		if ed != null:
			(ed as GateAST.EnumDecl).annotations = annotations
		return ed

	if _check_kw("var") or _check_kw("const"):
		var vd: GateAST.VarDecl = _parse_var_decl(true)
		if vd != null:
			vd.annotations = annotations
			vd.visibility = visibility
			vd.is_static = is_static
			return vd
		_skip_to_statement_end()
		var vraw: GateAST.RawStmt = _raw_from(start_line, maxi(_cur().line, start_line))
		return vraw

	if _cur().type == GateLexer.T.IDENT and _at_type_alias():
		_saw_alias = true
		return _parse_type_alias()

	if _looks_like_typed_decl() or (_cur().type == GateLexer.T.OP and _looks_like_paren_type_decl()):
		var vd2: GateAST.VarDecl = _parse_typed_decl()
		if vd2 != null:
			vd2.annotations = annotations
			vd2.visibility = visibility
			vd2.is_static = is_static
		return vd2

	if _check_op("<") or _check_op("<<") or (_check(GateLexer.T.IDENT)
			and (_peek(1).is_op("<") or _peek(1).is_op("<<"))):
		_err("this declaration's type does not parse",
			"check the brackets: `<a | b>`, `<a, b>`, `Box<T>`, and `>>` closes two")
		_skip_to_statement_end()
		return null

	_skip_to_statement_end()
	var raw: GateAST.RawStmt = _raw_from(start_line, maxi(_cur().line, start_line))
	return raw


func _parse_class_like() -> GateAST.ClassDecl:
	var kw: GateLexer.Token = _advance()
	var cd: GateAST.ClassDecl = GateAST.ClassDecl.new()
	cd.form = kw.value
	cd.at(kw.line, kw.col)

	if not _at_name():
		_err("expected a name after '%s'" % kw.value)
		_skip_to_statement_end()
		return null
	cd.name = _advance().value

	if _check_op("<"):
		_advance()
		while not _at_end() and not _check_op(">"):
			if _check(GateLexer.T.IDENT):
				cd.generic_params.append(_advance().value)
			if not _match_op(","):
				break
		_expect_op(">", "to close generic parameters")

	if _match_kw("extends"):
		cd.extends_type = _parse_extends_type()

	while true:
		if _match_kw("implements"):
			while _check(GateLexer.T.IDENT):
				cd.implements.append(_advance().value)
				if not _match_op(","): break
		elif _match_kw("with"):
			while _check(GateLexer.T.IDENT):
				cd.traits.append(_advance().value)
				if not _match_op(","): break
		elif _match_kw("requires"):
			while _check(GateLexer.T.IDENT):
				cd.requires.append(_advance().value)
				if not _match_op(","): break
		else:
			break

	_expect_op(":", "after the class header")
	cd.members = _parse_block(true)
	return cd


func _parse_func() -> GateAST.FuncDecl:
	var kw: GateLexer.Token = _advance()  # func | operator
	var fd: GateAST.FuncDecl = GateAST.FuncDecl.new()
	fd.at(kw.line, kw.col)

	if kw.value == "operator":
		fd.is_operator = true
		if _check(GateLexer.T.OP):
			fd.operator_symbol = _advance().value
			fd.name = "__op_" + _op_ident(fd.operator_symbol)
		else:
			_err("expected an operator symbol after 'operator'")
			return null
	else:
		if not (_check(GateLexer.T.IDENT) or _check(GateLexer.T.KEYWORD)):
			if _check_op("("):
				_err("a lambda on its own is never called; assign it to a variable",
					"Godot rejects this too (\"Standalone lambdas cannot be accessed\").")
			else:
				_err("expected a function name")
			_skip_to_statement_end()
			return null
		fd.name = _advance().value

	if not _expect_op("(", "after the function name"):
		_skip_to_statement_end()
		return null
	fd.params = _parse_params()
	_expect_op(")", "to close the parameter list")

	if _match_op("->"):
		fd.return_type = _parse_type()

	if not _check_op(":"):
		if _at_stmt_end():
			fd.body = []
			return fd
		_err("expected ':' after the function signature, found '%s'" % _cur().value,
			"add a ':' and a body, or leave it bodyless to declare it abstract")
		_skip_to_statement_end()
		return null
	_advance()

	if _check(GateLexer.T.COMMENT):
		_advance()

	if _check(GateLexer.T.NEWLINE):
		var save: int = _i
		_skip_newlines()
		if _check(GateLexer.T.INDENT):
			_i = save
			fd.body = _parse_block(false)
		else:
			_i = save
			_skip_newlines()
			fd.body = []
	else:
		fd.body = _parse_inline_body()
	return fd


func _op_ident(sym: String) -> String:
	const MAP := {
		"+": "add", "-": "sub", "*": "mul", "/": "div", "%": "mod",
		"==": "eq", "!=": "ne", "<": "lt", ">": "gt", "<=": "le", ">=": "ge",
		"**": "pow", "&": "band", "|": "bor", "^": "bxor",
	}
	return MAP.get(sym, "op")


func _parse_signal() -> GateAST.SignalDecl:
	var kw: GateLexer.Token = _advance()
	var sd: GateAST.SignalDecl = GateAST.SignalDecl.new()
	sd.at(kw.line, kw.col)
	if _at_name():
		sd.name = _advance().value
	if _match_op("("):
		sd.params = _parse_params()
		_expect_op(")", "to close the signal parameter list")
	return sd


func _parse_enum() -> GateAST.EnumDecl:
	var kw: GateLexer.Token = _advance()
	var ed: GateAST.EnumDecl = GateAST.EnumDecl.new()
	ed.at(kw.line, kw.col)
	if _at_name():
		ed.name = _advance().value
	if _expect_op("{", "to open the enum body"):
		_skip_newlines()
		while not _at_end() and not _check_op("}"):
			_skip_newlines()
			if _at_name():
				ed.keys.append(_advance().value)
				if _match_op("="):
					ed.values.append(_parse_expr())
				else:
					ed.values.append(null)
			_skip_newlines()
			if not _match_op(","):
				break
			_skip_newlines()
		_expect_op("}", "to close the enum body")
	return ed


func _parse_var_decl(strict_end := false) -> GateAST.VarDecl:
	var entry: int = _i
	var kw: GateLexer.Token = _advance()  # var | const
	var vd: GateAST.VarDecl = GateAST.VarDecl.new()
	vd.at(kw.line, kw.col)
	vd.is_const = kw.value == "const"

	if _check_op("["):
		return null if not _rewind_to(kw) else null

	if vd.is_const and (_looks_like_typed_decl() or _looks_like_paren_type_decl()):
		vd.type = _parse_type()
		vd.type.strict = true
	if not (_check(GateLexer.T.IDENT) or _check(GateLexer.T.KEYWORD)):
		_err("expected a variable name after '%s'" % kw.value)
		_skip_to_statement_end()
		return null
	vd.name = _advance().value
	if vd.type != null:
		if _match_op("="):
			vd.value = _parse_expr()
		else:
			_err("a constant needs a value", "write `const %s %s = ...`" % [vd.type.describe(), vd.name])
		return vd

	if _match_op(":="):
		vd.inferred = true
		vd.value = _parse_expr()
	elif _check_op(":") and _peek(1).type in [GateLexer.T.NEWLINE, GateLexer.T.COMMENT]:
		pass
	elif _match_op(":"):
		if _check_op("="):
			vd.inferred = true
		else:
			vd.type = _parse_type()
		if _match_op("="):
			vd.value = _parse_expr()
	elif _match_op("="):
		vd.value = _parse_expr()

	_parse_accessors(vd)
	# An accessor block and a block-bodied lambda both consume past the declaration
	# line, so neither counts as leftover tokens.
	var value_took_a_block: bool = (vd.value is GateAST.Lambda
		and (vd.value as GateAST.Lambda).block_body)
	if (strict_end and vd.setter == "" and vd.inline_accessors == ""
			and not value_took_a_block
			and not _at_stmt_end() and not _check_op(";")):
		_i = entry
		return null
	return vd


func _parse_accessors(vd: GateAST.VarDecl) -> void:
	if _check_op(":"):
		var start: int = _cur().line
		var colon_col: int = _cur().col
		_skip_to_statement_end()
		var save: int = _i
		_skip_newlines()
		if _check(GateLexer.T.INDENT):
			var depth: int = 0
			while not _at_end():
				if _check(GateLexer.T.INDENT): depth += 1
				elif _check(GateLexer.T.DEDENT):
					depth -= 1
					if depth == 0:
						_advance()
						break
				_advance()
			var raw: String = _raw_from(start + 1, _cur().line - 1).text
			while raw.length() > 0 and raw.unicode_at(raw.length() - 1) in [10, 13]:
				raw = raw.substr(0, raw.length() - 1)
			var kept: PackedStringArray = raw.split("\n")
			while kept.size() > 0:
				var last: String = String(kept[kept.size() - 1]).strip_edges()
				if last == "" or last.begins_with("#"):
					kept.remove_at(kept.size() - 1)
					continue
				break
			vd.setter = "\n".join(kept)
			vd.setter_line = start + 1
		else:
			var line_text: String = _raw_from(start, start).text
			if colon_col - 1 < line_text.length():
				var tail: String = line_text.substr(colon_col - 1).strip_edges()
				while tail.length() > 0 and tail.unicode_at(tail.length() - 1) in [10, 13]:
					tail = tail.substr(0, tail.length() - 1)
				if tail != "" and tail != ":":
					vd.inline_accessors = tail
			_i = save


func _parse_typed_decl() -> GateAST.VarDecl:
	var start: GateLexer.Token = _cur()
	var vd: GateAST.VarDecl = GateAST.VarDecl.new()
	vd.at(start.line, start.col)
	vd.type = _parse_type()
	vd.type.strict = true
	if not _at_name():
		_err("expected a variable name after the type")
		_skip_to_statement_end()
		return null
	vd.name = _advance().value

	var extra_names: Array = []
	while _check_op(",") and _peek(1).type == GateLexer.T.IDENT:
		_advance()
		extra_names.append(_advance().value)

	if _check_op("{"):
		_advance()
		while not _at_end() and not _check_op("}"):
			if not (_check(GateLexer.T.IDENT) or _check(GateLexer.T.KEYWORD)):
				break
			var acc: String = _advance().value
			if acc in ["get", "set"]:
				if not vd.accessor_requirement.has(acc):
					vd.accessor_requirement.append(acc)
			else:
				_err("expected `get` or `set` in a property requirement, found '%s'" % acc)
			if not _match_op(","):
				break
		_expect_op("}", "to close the property requirement")
		return vd

	if _match_op("="):
		vd.value = _parse_expr()
	_parse_accessors(vd)

	for n in extra_names:
		var clone: GateAST.VarDecl = GateAST.VarDecl.new()
		clone.at(vd.line, vd.col)
		clone.name = n
		clone.type = vd.type
		clone.is_static = vd.is_static
		clone.visibility = vd.visibility
		_extra_decls.append(clone)
	return vd

const MAX_BLOCK_DEPTH := 48


func _parse_block(is_class_body: bool) -> Array:
	var out: Array = []
	if _block_depth >= MAX_BLOCK_DEPTH:
		if not _depth_reported:
			var bt: GateLexer.Token = _cur()
			diagnostics.error(
				"blocks nest more than %d levels deep" % MAX_BLOCK_DEPTH, bt.line, bt.col,
				"GATE's parser is written in GDScript and recurses once per level, so it "
				+ "runs out of stack well before Godot's own parser does. Extract the "
				+ "inner blocks into functions.")
			_depth_reported = true
			_panic = true
			diagnostics.seal()
		return out
	_block_depth += 1
	var r: Array = _parse_block_body(is_class_body)
	_block_depth -= 1
	return r


func _parse_block_body(is_class_body: bool) -> Array:
	var out: Array = []
	_skip_newlines()
	if not _check(GateLexer.T.INDENT):
		return out
	_advance()  # INDENT
	while not _at_end() and not _check(GateLexer.T.DEDENT):
		_skip_newlines()
		if _check(GateLexer.T.DEDENT) or _at_end():
			break
		var s: GateAST.Stmt = _parse_member() if is_class_body else _parse_statement()
		if s != null:
			out.append(s)
		_drain_extras(out)
		while _match_op(";"):
			if _at_stmt_end():
				break
			var s2: GateAST.Stmt = _parse_member() if is_class_body else _parse_statement()
			if s2 != null:
				out.append(s2)
			_drain_extras(out)
		_skip_newlines()
	if _check(GateLexer.T.DEDENT):
		_advance()
	return out


func _drain_extras(into: Array) -> void:
	if _extra_decls.is_empty():
		return
	into.append_array(_extra_decls)
	_extra_decls = []


func _parse_lambda_inline_body(limit_line: int = 0) -> Array:
	var body_col: int = _cur().col if limit_line == 0 and not _at_end() else -1
	var out: Array = []
	_in_inline_lambda += 1
	while true:
		var before: int = _i
		var saved_col: int = _stmt_col
		if limit_line == 0:
			_stmt_col = _cur().col
		var s: GateAST.Stmt = _parse_statement()
		_stmt_col = saved_col
		if s != null:
			out.append(s)
		if _i == before:
			break
		while _match_op(";"):
			if _at_stmt_end():
				break
			var s2: GateAST.Stmt = _parse_statement()
			if s2 != null:
				out.append(s2)
		if _at_end() or _check(GateLexer.T.NEWLINE) or _check(GateLexer.T.DEDENT):
			break
		while _check(GateLexer.T.COMMENT):
			_advance()
		if _at_end() or _check(GateLexer.T.NEWLINE) or _check(GateLexer.T.DEDENT):
			break
		if limit_line > 0 and _cur().line > limit_line:
			break
		if body_col >= 0 and _cur().col < body_col:
			break
		if (_check_op(")") or _check_op("]") or _check_op("}") or _check_op(",")
				or _check_op(":")):
			break
		if s == null:
			break
	_in_inline_lambda -= 1
	return out


func _parse_inline_body() -> Array:
	var out: Array = []
	var s: GateAST.Stmt = _parse_statement()
	if s != null:
		out.append(s)
	while _match_op(";"):
		if _at_stmt_end():
			break
		var s2: GateAST.Stmt = _parse_statement()
		if s2 != null:
			out.append(s2)
	return out

const DECLARATION_KEYWORDS := ["var", "const", "func", "class", "static",
		"signal", "enum", "class_name"]


func _starts_declaration() -> bool:
	for kw in DECLARATION_KEYWORDS:
		if _check_kw(kw):
			return true
	return _looks_like_typed_decl()


func _parse_statement() -> GateAST.Stmt:
	_skip_newlines()
	if _at_end() or _check(GateLexer.T.DEDENT):
		return null

	var start_line: int = _cur().line

	if _check(GateLexer.T.COMMENT):
		var c: GateAST.CommentStmt = GateAST.CommentStmt.new()
		var ct: GateLexer.Token = _advance()
		c.text = ct.value
		c.at(ct.line, ct.col)
		return c

	if _check(GateLexer.T.ANNOTATION):
		var probe: int = _i
		var anns: Array = _parse_annotations()
		_skip_newlines()
		if _starts_declaration():
			_i = probe
			return _parse_member()
		var inner: GateAST.Stmt = _parse_statement()
		if inner == null:
			return null
		var wrapped: GateAST.AnnotatedStmt = GateAST.AnnotatedStmt.new()
		wrapped.at(inner.line, inner.col)
		wrapped.annotations = anns
		wrapped.stmt = inner
		return wrapped

	if _check_kw("if"): return _parse_if()
	if _check_kw("for"): return _parse_for()
	if _check_kw("while"): return _parse_while()
	if _check_kw("match") and _match_starts_a_statement(): return _parse_match()
	if _check_kw("return"):
		var kw: GateLexer.Token = _advance()
		var r: GateAST.ReturnStmt = GateAST.ReturnStmt.new()
		r.at(kw.line, kw.col)
		if not _at_stmt_end() and _cur().line == kw.line:
			r.value = _parse_expr()
		return r
	if _check_kw("pass") or _check_kw("break") or _check_kw("continue") or _check_kw("breakpoint"):
		var k: GateLexer.Token = _advance()
		var ss: GateAST.SimpleStmt = GateAST.SimpleStmt.new()
		ss.keyword = k.value
		ss.at(k.line, k.col)
		return ss
	if _check_kw("var") or _check_kw("const"):
		if _peek(1).is_op("["):
			return _parse_destructure()
		var vd: GateAST.VarDecl = _parse_var_decl()
		if vd == null:
			var raw: GateAST.RawStmt = _raw_from(start_line, _cur().line)
			_skip_to_statement_end()
			return raw
		return vd
	if _cur().type == GateLexer.T.KEYWORD and _looks_like_func_type_decl():
		return _parse_typed_decl()
	if _check_kw("func"):
		return _parse_func()
	if (_check_kw("class") or _check_kw("struct")) and _is_name_token(_peek(1)):
		return _parse_class_like()
	if _cur().type == GateLexer.T.IDENT and _at_type_alias():
		_saw_alias = true
		return _parse_type_alias()
	if _looks_like_typed_decl() or (_cur().type == GateLexer.T.OP and _looks_like_paren_type_decl()):
		return _parse_typed_decl()

	return _parse_expression_statement(start_line)


func _parse_if() -> GateAST.IfStmt:
	var kw: GateLexer.Token = _advance()
	var st: GateAST.IfStmt = GateAST.IfStmt.new()
	st.at(kw.line, kw.col)
	st.cond = _parse_expr()
	_expect_op(":", "after the condition")
	st.then_body = _parse_body_after_colon(kw)
	while true:
		_skip_newlines()
		# An `elif`/`else` belongs to the `if` at its own column. Inside brackets there
		# is no DEDENT to enforce that.
		if _cur().line != kw.line and _cur().col != kw.col:
			break
		if _check_kw("elif"):
			_advance()
			var c: GateAST.Expr = _parse_expr()
			_expect_op(":", "after the condition")
			st.elifs.append([c, _parse_body_after_colon(kw)])
		elif _check_kw("else"):
			st.else_line = _cur().line
			_advance()
			_expect_op(":", "after 'else'")
			st.else_body = _parse_body_after_colon(kw)
			break
		else:
			break
	return st


func _parse_body_after_colon(owner: GateLexer.Token = null) -> Array:
	if _check(GateLexer.T.COMMENT):
		_advance()
	if _check(GateLexer.T.NEWLINE):
		return _parse_block(false)
	if owner != null and not _at_end() and _cur().line > owner.line:
		return _parse_bracketed_block(owner.col)
	return _parse_inline_body()


func _parse_bracketed_block(owner_col: int) -> Array:
	var out: Array = []
	while not _at_end():
		if _check(GateLexer.T.NEWLINE) or _check(GateLexer.T.DEDENT):
			break
		if _check_op(")") or _check_op("]") or _check_op("}") or _check_op(","):
			break
		if _cur().col <= owner_col:
			break
		var before: int = _i
		var saved_col: int = _stmt_col
		_stmt_col = _cur().col
		var st: GateAST.Stmt = _parse_statement()
		_stmt_col = saved_col
		if st != null:
			out.append(st)
		while _match_op(";"):
			if _at_stmt_end():
				break
			var st2: GateAST.Stmt = _parse_statement()
			if st2 != null:
				out.append(st2)
		if _i == before:
			break
	return out


func _parse_for() -> GateAST.ForStmt:
	var kw: GateLexer.Token = _advance()
	var st: GateAST.ForStmt = GateAST.ForStmt.new()
	st.at(kw.line, kw.col)
	if _at_name():
		st.var_names.append(_advance().value)
	if _match_op(","):
		if _at_name():
			st.var_names.append(_advance().value)
	if _match_op(":"):
		st.var_type = _parse_type()
	if not _match_kw("in"):
		_err("expected 'in' in a for loop")
	st.iterable = _parse_expr()
	if st.iterable is GateAST.Call:
		var c: GateAST.Call = st.iterable
		if c.callee is GateAST.Ident and (c.callee as GateAST.Ident).name == "enumerate":
			st.is_enumerate = true
	_expect_op(":", "after the for header")
	st.body = _parse_body_after_colon(kw)
	return st


func _parse_while() -> GateAST.WhileStmt:
	var kw: GateLexer.Token = _advance()
	var st: GateAST.WhileStmt = GateAST.WhileStmt.new()
	st.at(kw.line, kw.col)
	st.cond = _parse_expr()
	_expect_op(":", "after the condition")
	st.body = _parse_body_after_colon(kw)
	return st


func _match_starts_a_statement() -> bool:
	var nxt: GateLexer.Token = _peek(1)
	if nxt.type == GateLexer.T.OP:
		return not (nxt.value in [".", "?.", "[", "?[", "=", ":=", ",", ")", "]", "}",
			"+=", "-=", "*=", "/=", "%=", "**=", "&=", "|=", "^=", "<<=", ">>="])
	return true


func _parse_match() -> GateAST.MatchStmt:
	var kw: GateLexer.Token = _advance()
	var st: GateAST.MatchStmt = GateAST.MatchStmt.new()
	st.at(kw.line, kw.col)
	st.subject = _parse_expr()
	_expect_op(":", "after the match subject")
	_skip_newlines()
	var bracketed: bool = false
	if _check(GateLexer.T.INDENT):
		_advance()
	elif not _at_end() and _cur().line > kw.line and _cur().col > kw.col:
		bracketed = true
	else:
		return st
	while not _at_end() and not _check(GateLexer.T.DEDENT):
		_skip_newlines()
		if _check(GateLexer.T.DEDENT) or _at_end():
			break
		if bracketed:
			if _check_op(")") or _check_op("]") or _check_op("}") or _check_op(","):
				break
			if _check(GateLexer.T.NEWLINE) or _cur().col <= kw.col:
				break
		var arm_kw: GateLexer.Token = _cur()
		var patterns: Array = []
		patterns.append(_scan_pattern())
		while _match_op(","):
			patterns.append(_scan_pattern())
		var guard: GateAST.Expr = null
		if _match_kw("when"):
			guard = _parse_expr()
		_expect_op(":", "after the match pattern")
		var body: Array = _parse_body_after_colon(arm_kw)
		st.branches.append([patterns, guard, body])
		_skip_newlines()
	if not bracketed and _check(GateLexer.T.DEDENT):
		_advance()
	return st


func _scan_pattern() -> GateAST.Expr:
	var start: GateLexer.Token = _cur()
	var depth: int = 0
	while not _at_end():
		var t: GateLexer.Token = _cur()
		if t.type == GateLexer.T.OP:
			if t.value in ["(", "[", "{", "?["]:
				depth += 1
			elif t.value in [")", "]", "}"]:
				depth -= 1
			elif depth == 0 and (t.value == ":" or t.value == ","):
				break
		elif depth == 0 and t.is_kw("when"):
			break
		elif t.type == GateLexer.T.NEWLINE and depth <= 0:
			break
		_advance()
	var r: GateAST.RawExpr = GateAST.RawExpr.new()
	r.at(start.line, start.col)
	r.text = _span_text(start, _cur())
	return r


func _parse_destructure() -> GateAST.Stmt:
	var kw: GateLexer.Token = _advance()  # var/const
	var st: GateAST.MultiAssign = GateAST.MultiAssign.new()
	st.at(kw.line, kw.col)
	st.declares = true
	st.destructure = true
	_expect_op("[", "to open the destructuring pattern")
	while not _at_end() and not _check_op("]"):
		if _check(GateLexer.T.IDENT):
			var id: GateAST.Ident = GateAST.Ident.new()
			var t: GateLexer.Token = _advance()
			id.name = t.value
			id.at(t.line, t.col)
			st.targets.append(id)
		if not _match_op(","):
			break
	_expect_op("]", "to close the destructuring pattern")
	_expect_op("=", "in a destructuring assignment")
	st.values.append(_parse_expr())
	return st


func _comma_starts_multi_assign() -> bool:
	var depth: int = 0
	var i: int = _i
	while i < _toks.size():
		var t: GateLexer.Token = _toks[i]
		if t.type == GateLexer.T.NEWLINE or t.type == GateLexer.T.EOF or t.type == GateLexer.T.DEDENT:
			return false
		if t.type == GateLexer.T.OP:
			if t.value in ["(", "[", "{"]:
				depth += 1
			elif t.value in [")", "]", "}"]:
				if depth == 0:
					return false
				depth -= 1
			elif depth == 0 and t.value == "=":
				return true
			elif depth == 0 and (t.value == ";" or t.value == ":"):
				return false
		i += 1
	return false


func _comma_is_enclosed() -> bool:
	var depth: int = 0
	var i: int = _i
	while i < _toks.size():
		var t: GateLexer.Token = _toks[i]
		if t.type == GateLexer.T.NEWLINE or t.type == GateLexer.T.EOF or t.type == GateLexer.T.DEDENT:
			return false
		if t.type == GateLexer.T.OP:
			if t.value in ["(", "[", "{"]:
				depth += 1
			elif t.value in [")", "]", "}"]:
				if depth == 0:
					return true
				depth -= 1
		i += 1
	return false


func _parse_expression_statement(start_line: int) -> GateAST.Stmt:
	var first: GateAST.Expr = _parse_expr()
	if first == null:
		var raw: GateAST.RawStmt = _raw_from(start_line, _cur().line)
		_skip_to_statement_end()
		return raw

	if _check_op(","):
		if _comma_starts_multi_assign():
			var targets: Array = [first]
			while _match_op(","):
				targets.append(_parse_expr())
			if _match_op("="):
				var st: GateAST.MultiAssign = GateAST.MultiAssign.new()
				st.at(first.line, first.col)
				st.targets = targets
				st.values.append(_parse_expr())
				while _match_op(","):
					st.values.append(_parse_expr())
				return st
		elif not _comma_is_enclosed():
			var raw2: GateAST.RawStmt = _raw_from(start_line, _cur().line)
			_skip_to_statement_end()
			return raw2

	const ASSIGN_OPS := ["=", "+=", "-=", "*=", "/=", "%=", "**=", "&=", "|=", "^=", "<<=", ">>="]
	if _check(GateLexer.T.OP) and _cur().value in ASSIGN_OPS:
		var op: String = _advance().value
		var a: GateAST.AssignStmt = GateAST.AssignStmt.new()
		a.at(first.line, first.col)
		a.target = first
		a.op = op
		a.value = _parse_expr()
		return a

	var es: GateAST.ExprStmt = GateAST.ExprStmt.new()
	es.at(first.line, first.col)
	es.expr = first
	return es

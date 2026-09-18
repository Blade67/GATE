@tool
class_name GateParser
extends "res://addons/gate/compiler/parser_expr.gd"

## Parser layer 4: statements, declarations, and the module.
##
## Anything this cannot decompose is kept as source text and re-emitted verbatim,
## so an unfamiliar GDScript construct degrades to pass-through, not an error.


func parse(tokens: Array, source: String, diags: GateDiagnostics) -> GateAST._Module:
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

	var mod: GateAST._Module = GateAST._Module.new()
	_skip_newlines()
	while not _at_end():
		var before: int = diags.error_count()
		var m: GateAST._Stmt = _parse_module_member(mod)
		if m != null:
			mod.members.append(m)
		_drain_extras(mod.members)
		_expect_stmt_end(before)
		while _match_op(";"):
			if _at_stmt_end():
				break
			var before2: int = diags.error_count()
			var m2: GateAST._Stmt = _parse_module_member(mod)
			if m2 != null:
				mod.members.append(m2)
			_drain_extras(mod.members)
			_expect_stmt_end(before2)
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
		var t: GateLexer._Token = _toks[i]
		if t.type == GateLexer._T.NEWLINE or t.type == GateLexer._T.COMMENT or t.type == GateLexer._T.ANNOTATION:
			i += 1
			continue
		return not (t.is_kw("class") or t.is_kw("func") or t.is_kw("static"))
	return true


func _parse_module_member(mod: GateAST._Module) -> GateAST._Stmt:
	if _check(GateLexer._T.ANNOTATION) and _annotation_is_file_level():
		var fa: GateAST._Annotation = _parse_one_annotation()
		if fa != null:
			mod.header_annotations.append(fa)
			if fa.name == "tool":
				mod.is_tool = true
		_skip_newlines()
		return null

	if _check(GateLexer._T.COMMENT):
		var c: GateAST._CommentStmt = GateAST._CommentStmt.new()
		c.text = _advance().value
		return c

	if _check_kw("class_name"):
		var cn_tok: GateLexer._Token = _advance()
		mod.class_name_line = cn_tok.line
		if _check(GateLexer._T.IDENT):
			mod.class_name_decl = _advance().value
		if _match_op(","):
			if _check(GateLexer._T.STRING): mod.icon = _advance().value
		if _check_kw("extends"):
			mod.extends_line = _advance().line
			mod.extends_type = _parse_extends_type()
		return null

	if _check_kw("extends"):
		mod.extends_line = _advance().line
		mod.extends_type = _parse_extends_type()
		return null

	return _parse_member()


func _parse_one_annotation() -> GateAST._Annotation:
	if not _check(GateLexer._T.ANNOTATION):
		return null
	var t: GateLexer._Token = _advance()
	var a: GateAST._Annotation = GateAST._Annotation.new()
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
	while _check(GateLexer._T.ANNOTATION):
		var a: GateAST._Annotation = _parse_one_annotation()
		if a == null:
			break
		out.append(a)
		_skip_newlines()
	return out


func _parse_member() -> GateAST._Stmt:
	var start_line: int = _cur().line
	if _check(GateLexer._T.INDENT):
		if _stray_indent():
			return null
		return _raw_block()
	var annotations: Array = _parse_annotations()
	# Annotations that close a block have nothing to attach to; keep them as they are.
	if not annotations.is_empty() and (_check(GateLexer._T.DEDENT) or _at_end()):
		var lone: GateAST._AnnotatedStmt = GateAST._AnnotatedStmt.new()
		lone.at(start_line, 0)
		lone.annotations = annotations
		return lone

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
		elif _check_kw("abstract") and _abstract_is_modifier(): _advance(); is_abstract = true
		elif _check_kw("virtual"): _advance(); is_virtual = true
		elif _check_kw("override"): _advance(); is_override = true
		elif _check_kw("final"): _advance(); is_final = true
		elif visibility != "" and _check(GateLexer._T.ANNOTATION):
			annotations.append_array(_parse_annotations())   # `priv @export var x`
		else: break

	if not (_check_kw("func") or _check_kw("operator")):
		_reject_method_modifiers(is_final, is_virtual, is_override)

	if _check_kw("class") or _check_kw("struct") or _check_kw("interface") \
		or _check_kw("trait") or _check_kw("namespace"):
		var cd: GateAST._ClassDecl = _parse_class_like()
		if cd != null:
			cd.annotations = annotations
			cd.is_abstract = is_abstract
		return cd

	if _cur().type == GateLexer._T.KEYWORD and _looks_like_func_type_decl():
		var vd3: GateAST._VarDecl = _parse_typed_decl()
		if vd3 != null:
			vd3.annotations = annotations
			vd3.visibility = visibility
			vd3.is_static = is_static
		return vd3

	if _check_kw("func") or _check_kw("operator"):
		var fd: GateAST._FuncDecl = _parse_func()
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
		var sd: GateAST._SignalDecl = _parse_signal()
		if sd != null:
			(sd as GateAST._SignalDecl).annotations = annotations
		return sd

	if _check_kw("enum"):
		var ed: GateAST._EnumDecl = _parse_enum()
		if ed != null:
			(ed as GateAST._EnumDecl).annotations = annotations
		return ed

	if _check_kw("var") or _check_kw("const"):
		_leftover = -1
		var vd: GateAST._VarDecl = _parse_var_decl(true)
		if vd != null:
			vd.annotations = annotations
			vd.visibility = visibility
			vd.is_static = is_static
			return vd
		if _leftover >= 0 and _starts_a_second_statement(_leftover):
			var lt: GateLexer._Token = _toks[_leftover]
			diagnostics.error("expected the end of the statement, found '%s'" % lt.value,
				lt.line, lt.col,
				"GDScript takes one statement per line; separate two with `;` or a line break. "
				+ "A missing operator or comma reads as a second statement here.")
			_leftover = -1
			_skip_to_statement_end()
			return null
		_skip_to_statement_end()
		var vraw: GateAST._RawStmt = _raw_from(start_line, maxi(_cur().line, start_line))
		return vraw

	if _cur().type == GateLexer._T.IDENT and _at_type_alias():
		_saw_alias = true
		return _parse_type_alias()

	if _looks_like_typed_decl() or (_cur().type == GateLexer._T.OP and _looks_like_paren_type_decl()):
		var vd2: GateAST._VarDecl = _parse_typed_decl()
		if vd2 != null:
			vd2.annotations = annotations
			vd2.visibility = visibility
			vd2.is_static = is_static
		return vd2

	if _check_op("<") or _check_op("<<") or (_check(GateLexer._T.IDENT)
			and (_peek(1).is_op("<") or _peek(1).is_op("<<"))):
		_err("this declaration's type does not parse",
			"check the brackets: `<a | b>`, `<a, b>`, `Box<T>`, and `>>` closes two")
		_skip_to_statement_end()
		return null

	_skip_to_statement_end()
	var raw: GateAST._RawStmt = _raw_from(start_line, maxi(_cur().line, start_line))
	return raw


func _reject_method_modifiers(is_final: bool, is_virtual: bool, is_override: bool) -> void:
	var on_class: bool = _check_kw("class") or _check_kw("struct") or _check_kw("interface") \
		or _check_kw("trait") or _check_kw("namespace")
	var hint: String = "GDScript cannot stop a class from being extended; mark the methods " \
		+ "that must not change instead" if on_class \
		else "declare it `const` if the value must not change. A subclass that redeclares a " \
			+ "field is an error in GDScript whether or not it says so here"
	for pair in [[is_final, "final"], [is_virtual, "virtual"], [is_override, "override"]]:
		if pair[0]:
			_err("`%s` applies to a method" % pair[1], hint)


func _raw_block() -> GateAST._RawStmt:
	var start_line: int = _toks[_i + 1].line if _i + 1 < _toks.size() else _cur().line
	var end_line: int = start_line
	var depth: int = 0
	while not _at_end():
		if _check(GateLexer._T.INDENT):
			depth += 1
		elif _check(GateLexer._T.DEDENT):
			depth -= 1
			if depth == 0:
				_advance()
				break
		elif not _check(GateLexer._T.NEWLINE):
			end_line = maxi(end_line, _cur().line)
		_advance()
	return _raw_from(start_line, end_line)


func _stray_indent() -> bool:
	var j: int = _i - 1
	while j >= 0 and _toks[j].type in [GateLexer._T.NEWLINE, GateLexer._T.COMMENT]:
		j -= 1
	if j >= 0 and _toks[j].is_op(":"):
		return false
	var reported: bool = false
	for d in diagnostics.items:
		if d.level == GateDiagnostics._Level.ERROR and j >= 0 and d.line == _toks[j].line:
			reported = true   # the line above already failed; this is its body
	if not reported:
		_err("unexpected indentation in a class body",
			"indent a line only inside the block it belongs to; this one is not in a function, "
			+ "a class or a property")
	var depth: int = 0
	while not _at_end():
		if _check(GateLexer._T.INDENT):
			depth += 1
		elif _check(GateLexer._T.DEDENT):
			depth -= 1
			if depth == 0:
				_advance()
				break
		_advance()
	return true


const MEMBER_MODIFIERS := ["pub", "priv", "static", "abstract", "virtual", "override", "final"]
const ABSTRACT_TARGETS := ["class", "struct", "interface", "trait", "namespace", "func", "operator"]


func _abstract_is_modifier() -> bool:
	var j: int = _i + 1
	while j < _toks.size():
		var t: GateLexer._Token = _toks[j]
		if t.type != GateLexer._T.KEYWORD:
			return false
		if t.value in ABSTRACT_TARGETS:
			return true
		if not t.value in MEMBER_MODIFIERS:
			return false
		j += 1
	return false


func _parse_class_like() -> GateAST._ClassDecl:
	var kw: GateLexer._Token = _advance()
	var cd: GateAST._ClassDecl = GateAST._ClassDecl.new()
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
			if _check(GateLexer._T.IDENT):
				cd.generic_params.append(_advance().value)
			if not _match_op(","):
				break
		_expect_op(">", "to close generic parameters")

	if _match_kw("extends"):
		cd.extends_type = _parse_extends_type()

	while true:
		if _match_kw("implements"):
			while _check(GateLexer._T.IDENT):
				cd.implements.append(_advance().value)
				if not _match_op(","): break
		elif _match_kw("with"):
			while _check(GateLexer._T.IDENT):
				cd.traits.append(_advance().value)
				if not _match_op(","): break
		elif _match_kw("requires"):
			while _check(GateLexer._T.IDENT):
				cd.requires.append(_advance().value)
				if not _match_op(","): break
		else:
			break

	_expect_op(":", "after the class header")
	cd.members = _parse_block(true)
	return cd


func _parse_func() -> GateAST._FuncDecl:
	var kw: GateLexer._Token = _advance()  # func | operator
	var fd: GateAST._FuncDecl = GateAST._FuncDecl.new()
	fd.at(kw.line, kw.col)

	if kw.value == "operator":
		fd.is_operator = true
		if _check(GateLexer._T.OP):
			fd.operator_symbol = _advance().value
			fd.name = "__op_" + _op_ident(fd.operator_symbol)
		else:
			_err("expected an operator symbol after 'operator'")
			return null
	else:
		if not (_check(GateLexer._T.IDENT) or _check(GateLexer._T.KEYWORD)):
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

	if _check(GateLexer._T.COMMENT):
		_advance()

	if _check(GateLexer._T.NEWLINE):
		var save: int = _i
		_skip_newlines()
		if _check(GateLexer._T.INDENT):
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


func _parse_signal() -> GateAST._SignalDecl:
	var kw: GateLexer._Token = _advance()
	var sd: GateAST._SignalDecl = GateAST._SignalDecl.new()
	sd.at(kw.line, kw.col)
	if _at_name():
		sd.name = _advance().value
	if _match_op("("):
		sd.params = _parse_params()
		_expect_op(")", "to close the signal parameter list")
	return sd


func _parse_enum() -> GateAST._EnumDecl:
	var kw: GateLexer._Token = _advance()
	var ed: GateAST._EnumDecl = GateAST._EnumDecl.new()
	ed.at(kw.line, kw.col)
	if _at_name():
		ed.name = _advance().value
	# The opening brace may sit on the next line.
	var k: int = _i
	while k < _toks.size() and (_toks[k].type == GateLexer._T.NEWLINE or _toks[k].type == GateLexer._T.COMMENT):
		k += 1
	if k < _toks.size() and _toks[k].is_op("{"):
		_i = k
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


func _parse_var_decl(strict_end := false) -> GateAST._VarDecl:
	var entry: int = _i
	var kw: GateLexer._Token = _advance()  # var | const
	var vd: GateAST._VarDecl = GateAST._VarDecl.new()
	vd.at(kw.line, kw.col)
	vd.is_const = kw.value == "const"

	if _check_op("["):
		return null if not _rewind_to(kw) else null

	if vd.is_const and (_looks_like_typed_decl() or _looks_like_paren_type_decl()):
		vd.type = _parse_type()
		vd.type.strict = true
	if not (_check(GateLexer._T.IDENT) or _check(GateLexer._T.KEYWORD)):
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
	elif _check_op(":") and _peek(1).type in [GateLexer._T.NEWLINE, GateLexer._T.COMMENT]:
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
	var value_took_a_block: bool = (vd.value is GateAST._Lambda
		and (vd.value as GateAST._Lambda).block_body)
	if (strict_end and vd.setter == "" and vd.inline_accessors == ""
			and not value_took_a_block
			and not _at_stmt_end() and not _check_op(";")):
		_leftover = _i
		_i = entry
		return null
	return vd


func _parse_accessors(vd: GateAST._VarDecl) -> void:
	if _check_op(":"):
		var start: int = _cur().line
		var colon_col: int = _cur().col
		_skip_to_statement_end()
		var save: int = _i
		_skip_newlines()
		if _check(GateLexer._T.INDENT):
			var depth: int = 0
			while not _at_end():
				if _check(GateLexer._T.INDENT): depth += 1
				elif _check(GateLexer._T.DEDENT):
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


func _parse_typed_decl() -> GateAST._VarDecl:
	var start: GateLexer._Token = _cur()
	var vd: GateAST._VarDecl = GateAST._VarDecl.new()
	vd.at(start.line, start.col)
	vd.type = _parse_type()
	vd.type.strict = true
	if not _at_name():
		_err("expected a variable name after the type")
		_skip_to_statement_end()
		return null
	vd.name = _advance().value

	var extra_names: Array = []
	while _check_op(",") and _peek(1).type == GateLexer._T.IDENT:
		_advance()
		extra_names.append(_advance().value)

	if _check_op("{"):
		_advance()
		while not _at_end() and not _check_op("}"):
			if not (_check(GateLexer._T.IDENT) or _check(GateLexer._T.KEYWORD)):
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
		var clone: GateAST._VarDecl = GateAST._VarDecl.new()
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
			var bt: GateLexer._Token = _cur()
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
	if not _check(GateLexer._T.INDENT):
		return out
	_advance()  # INDENT
	while not _at_end() and not _check(GateLexer._T.DEDENT):
		_skip_newlines()
		if _check(GateLexer._T.DEDENT) or _at_end():
			break
		var before: int = diagnostics.error_count()
		var s: GateAST._Stmt = _parse_member() if is_class_body else _parse_statement()
		if s != null:
			out.append(s)
		_drain_extras(out)
		_expect_stmt_end(before)
		while _match_op(";"):
			if _at_stmt_end():
				break
			var before2: int = diagnostics.error_count()
			var s2: GateAST._Stmt = _parse_member() if is_class_body else _parse_statement()
			if s2 != null:
				out.append(s2)
			_drain_extras(out)
			_expect_stmt_end(before2)
		_skip_newlines()
	if _check(GateLexer._T.DEDENT):
		_advance()
	return out


const STATEMENT_STARTERS := ["var", "const", "func", "class", "signal", "enum", "static",
	"if", "for", "while", "match", "return", "pass", "break", "continue", "breakpoint",
	"struct", "interface", "trait", "namespace"]


func _starts_a_second_statement(at: int) -> bool:
	var t: GateLexer._Token = _toks[at]
	if t.type == GateLexer._T.KEYWORD:
		return STATEMENT_STARTERS.has(t.value)
	if t.type in [GateLexer._T.STRING, GateLexer._T.FSTRING, GateLexer._T.NUMBER]:
		return true
	if t.type == GateLexer._T.OP:
		return t.value in [")", "]", "}", ","]
	return (t.type == GateLexer._T.IDENT and at + 1 < _toks.size()
		and _toks[at + 1].is_op("("))


var _leftover: int = -1


func _expect_stmt_end(errors_before: int) -> void:
	if _at_stmt_end() or _check_op(";") or _check(GateLexer._T.INDENT):
		return
	if diagnostics.error_count() > errors_before:
		_skip_to_statement_end()   # this statement already said what is wrong
		return
	var j: int = _i - 1
	while j >= 0 and _toks[j].type in [GateLexer._T.NEWLINE, GateLexer._T.INDENT,
			GateLexer._T.DEDENT, GateLexer._T.COMMENT]:
		j -= 1
	if j < 0 or _toks[j].line < _cur().line:
		return   # the statement ran to the end of its line; a block took the NEWLINE
	if not _starts_a_second_statement(_i):
		return   # a construct GATE does not model, such as Godot 3's `setget`: passed through
	_err("expected the end of the statement, found '%s'" % _cur().value,
		"GDScript takes one statement per line; separate two with `;` or a line break. "
		+ "A missing operator or comma reads as a second statement here.")
	_skip_to_statement_end()


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
		var s: GateAST._Stmt = _parse_statement()
		_stmt_col = saved_col
		if s != null:
			out.append(s)
		if _i == before:
			break
		while _match_op(";"):
			if _at_stmt_end():
				break
			var s2: GateAST._Stmt = _parse_statement()
			if s2 != null:
				out.append(s2)
		if _at_end() or _check(GateLexer._T.NEWLINE) or _check(GateLexer._T.DEDENT):
			break
		while _check(GateLexer._T.COMMENT):
			_advance()
		if _at_end() or _check(GateLexer._T.NEWLINE) or _check(GateLexer._T.DEDENT):
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
	var s: GateAST._Stmt = _parse_statement()
	if s != null:
		out.append(s)
	while _match_op(";"):
		if _at_stmt_end():
			break
		var s2: GateAST._Stmt = _parse_statement()
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


func _parse_statement() -> GateAST._Stmt:
	_skip_newlines()
	if _at_end() or _check(GateLexer._T.DEDENT):
		return null

	var start_line: int = _cur().line

	if _check(GateLexer._T.COMMENT):
		var c: GateAST._CommentStmt = GateAST._CommentStmt.new()
		var ct: GateLexer._Token = _advance()
		c.text = ct.value
		c.at(ct.line, ct.col)
		return c

	if _check(GateLexer._T.ANNOTATION):
		var probe: int = _i
		var anns: Array = _parse_annotations()
		_skip_newlines()
		if not anns.is_empty() and (_check(GateLexer._T.DEDENT) or _at_end()):
			var lone_stmt: GateAST._AnnotatedStmt = GateAST._AnnotatedStmt.new()
			lone_stmt.at(start_line, 0)
			lone_stmt.annotations = anns
			return lone_stmt
		if _starts_declaration():
			_i = probe
			return _parse_member()
		var inner: GateAST._Stmt = _parse_statement()
		if inner == null:
			return null
		var wrapped: GateAST._AnnotatedStmt = GateAST._AnnotatedStmt.new()
		wrapped.at(inner.line, inner.col)
		wrapped.annotations = anns
		wrapped.stmt = inner
		return wrapped

	if _check_kw("if"): return _parse_if()
	if _check_kw("for"): return _parse_for()
	if _check_kw("while"): return _parse_while()
	if _check_kw("match") and _match_starts_a_statement(): return _parse_match()
	if _check_kw("return"):
		var kw: GateLexer._Token = _advance()
		var r: GateAST._ReturnStmt = GateAST._ReturnStmt.new()
		r.at(kw.line, kw.col)
		if not _at_stmt_end() and _cur().line == kw.line:
			r.value = _parse_expr()
		return r
	if _check_kw("pass") or _check_kw("break") or _check_kw("continue") or _check_kw("breakpoint"):
		var k: GateLexer._Token = _advance()
		var ss: GateAST._SimpleStmt = GateAST._SimpleStmt.new()
		ss.keyword = k.value
		ss.at(k.line, k.col)
		return ss
	if _check_kw("var") or _check_kw("const"):
		if _peek(1).is_op("["):
			return _parse_destructure()
		var vd: GateAST._VarDecl = _parse_var_decl()
		if vd == null:
			var raw: GateAST._RawStmt = _raw_from(start_line, _cur().line)
			_skip_to_statement_end()
			return raw
		return vd
	if _cur().type == GateLexer._T.KEYWORD and _looks_like_func_type_decl():
		return _parse_typed_decl()
	if _check_kw("func"):
		return _parse_func()
	if (_check_kw("class") or _check_kw("struct")) and _is_name_token(_peek(1)):
		return _parse_class_like()
	if _cur().type == GateLexer._T.IDENT and _at_type_alias():
		_saw_alias = true
		return _parse_type_alias()
	if _looks_like_typed_decl() or (_cur().type == GateLexer._T.OP and _looks_like_paren_type_decl()):
		return _parse_typed_decl()

	return _parse_expression_statement(start_line)


## Where a line's first token starts: an inline `if` after `else:` belongs there.
func _line_start_col(idx: int) -> int:
	var j: int = idx
	while j > 0:
		var prev: GateLexer._Token = _toks[j - 1]
		if prev.line != _toks[idx].line:
			break
		if prev.type in [GateLexer._T.NEWLINE, GateLexer._T.INDENT, GateLexer._T.DEDENT]:
			break
		j -= 1
	return _toks[j].col


func _parse_if() -> GateAST._IfStmt:
	var anchor_col: int = _line_start_col(_i)
	var kw: GateLexer._Token = _advance()
	var st: GateAST._IfStmt = GateAST._IfStmt.new()
	st.at(kw.line, kw.col)
	st.cond = _parse_expr()
	_expect_op(":", "after the condition")
	st.then_body = _parse_body_after_colon(kw)
	while true:
		_skip_newlines()
		# An `elif`/`else` belongs to the `if` at its own column. Inside brackets there
		# is no DEDENT to enforce that.
		if _cur().line != kw.line and _cur().col != anchor_col:
			break
		if _check_kw("elif"):
			_advance()
			var c: GateAST._Expr = _parse_expr()
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


func _parse_body_after_colon(owner: GateLexer._Token = null) -> Array:
	if _check(GateLexer._T.COMMENT):
		_advance()
	if _check(GateLexer._T.NEWLINE):
		return _parse_block(false)
	if owner != null and not _at_end() and _cur().line > owner.line:
		return _parse_bracketed_block(owner.col)
	return _parse_inline_body()


func _parse_bracketed_block(owner_col: int) -> Array:
	var out: Array = []
	while not _at_end():
		if _check(GateLexer._T.NEWLINE) or _check(GateLexer._T.DEDENT):
			break
		if _check_op(")") or _check_op("]") or _check_op("}") or _check_op(","):
			break
		if _cur().col <= owner_col:
			break
		var before: int = _i
		var saved_col: int = _stmt_col
		_stmt_col = _cur().col
		var st: GateAST._Stmt = _parse_statement()
		_stmt_col = saved_col
		if st != null:
			out.append(st)
		while _match_op(";"):
			if _at_stmt_end():
				break
			var st2: GateAST._Stmt = _parse_statement()
			if st2 != null:
				out.append(st2)
		if _i == before:
			break
	return out


func _parse_for() -> GateAST._ForStmt:
	var kw: GateLexer._Token = _advance()
	var st: GateAST._ForStmt = GateAST._ForStmt.new()
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
	if st.iterable is GateAST._Call:
		var c: GateAST._Call = st.iterable
		if c.callee is GateAST._Ident and (c.callee as GateAST._Ident).name == "enumerate":
			st.is_enumerate = true
	_expect_op(":", "after the for header")
	st.body = _parse_body_after_colon(kw)
	return st


func _parse_while() -> GateAST._WhileStmt:
	var kw: GateLexer._Token = _advance()
	var st: GateAST._WhileStmt = GateAST._WhileStmt.new()
	st.at(kw.line, kw.col)
	st.cond = _parse_expr()
	_expect_op(":", "after the condition")
	st.body = _parse_body_after_colon(kw)
	return st


func _match_starts_a_statement() -> bool:
	var nxt: GateLexer._Token = _peek(1)
	if nxt.type == GateLexer._T.OP:
		return not (nxt.value in [".", "?.", "?[", "=", ":=", ",", ")", "]", "}",
			"+=", "-=", "*=", "/=", "%=", "**=", "&=", "|=", "^=", "<<=", ">>="])
	return true


func _parse_match() -> GateAST._MatchStmt:
	var kw: GateLexer._Token = _advance()
	var st: GateAST._MatchStmt = GateAST._MatchStmt.new()
	st.at(kw.line, kw.col)
	st.subject = _parse_expr()
	_expect_op(":", "after the match subject")
	_skip_newlines()
	var bracketed: bool = false
	if _check(GateLexer._T.INDENT):
		_advance()
	elif not _at_end() and _cur().line > kw.line and _cur().col > kw.col:
		bracketed = true
	else:
		return st
	while not _at_end() and not _check(GateLexer._T.DEDENT):
		_skip_newlines()
		if _check(GateLexer._T.DEDENT) or _at_end():
			break
		if bracketed:
			if _check_op(")") or _check_op("]") or _check_op("}") or _check_op(","):
				break
			if _check(GateLexer._T.NEWLINE) or _cur().col <= kw.col:
				break
		var arm_kw: GateLexer._Token = _cur()
		var patterns: Array = []
		var type_tests: Array = []
		patterns.append(_scan_arm_pattern(type_tests))
		while _match_op(","):
			patterns.append(_scan_arm_pattern(type_tests))
		if not type_tests.is_empty() and patterns.size() > 1:
			var tt: GateAST._IsExpr = type_tests[0]
			diagnostics.error(
				"a type pattern binds a name, and GDScript does not allow bindings in an arm with several patterns",
				tt.line, tt.col,
				"give each type its own arm, or bind with `var %s when ...` and test the type in the guard"
					% (tt.operand as GateAST._Ident).name)
		var guard: GateAST._Expr = null
		if _match_kw("when"):
			guard = _parse_expr()
		if not type_tests.is_empty():
			if guard == null:
				guard = type_tests[0]
			else:
				var both: GateAST._Binary = GateAST._Binary.new()
				both.at(guard.line, guard.col)
				both.op = "and"
				both.left = type_tests[0]
				both.right = guard
				guard = both
		_expect_op(":", "after the match pattern")
		var body: Array = _parse_body_after_colon(arm_kw)
		st.branches.append([patterns, guard, body])
		_skip_newlines()
	if not bracketed and _check(GateLexer._T.DEDENT):
		_advance()
	return st


## `Circle c` becomes `var c`, and `c is Circle` goes into the arm's guard.
func _scan_arm_pattern(type_tests: Array) -> GateAST._Expr:
	if not _type_pattern_ahead():
		return _scan_pattern()
	var start: GateLexer._Token = _cur()
	var saw_nullable: bool = _saw_nullable
	var tr: GateAST._TypeRef = _parse_type()
	_saw_nullable = saw_nullable
	if not tr.generic_args.is_empty():
		_generic_uses.append(tr)
	var name_tok: GateLexer._Token = _advance()
	if tr.nullable:
		diagnostics.error("a type pattern never matches null, so it cannot be nullable",
			start.line, start.col,
			"write `%s %s:`, and give null its own arm if it needs one"
				% [tr.describe().trim_suffix("?"), name_tok.value])
		tr.nullable = false
	var pat: GateAST._TypePattern = GateAST._TypePattern.new()
	pat.at(start.line, start.col)
	pat.text = "var " + name_tok.value
	pat.bind_name = name_tok.value
	pat.type = tr
	var id: GateAST._Ident = GateAST._Ident.new()
	id.at(name_tok.line, name_tok.col)
	id.name = name_tok.value
	var test: GateAST._IsExpr = GateAST._IsExpr.new()
	test.at(start.line, start.col)
	test.operand = id
	test.type = tr
	type_tests.append(test)
	return pat


## A type, a name, then `:`, `,` or `when`. GDScript never puts a name right after
## another in a pattern, so this cannot take one Godot accepts. A bare `Node2D:`
## is left alone.
func _type_pattern_ahead() -> bool:
	var n: int = _toks.size()
	var j: int = _pattern_type_end(_i)
	if j < 0:
		return false
	if j + 1 >= n:
		return false
	var name_tok: GateLexer._Token = _toks[j]
	if not _is_name_token(name_tok) or name_tok.is_kw("when"):
		return false
	var after: GateLexer._Token = _toks[j + 1]
	return after.is_op(":") or after.is_op(",") or after.is_kw("when")


func _pattern_type_end(from: int) -> int:
	var n: int = _toks.size()
	if from >= n:
		return -1
	var t: GateLexer._Token = _toks[from]
	var j: int = from + 1
	if t.is_op("{"):
		var db: int = 0
		j = from
		while j < n:
			var bt: GateLexer._Token = _toks[j]
			if bt.type == GateLexer._T.OP:
				if bt.value == "{":
					db += 1
				elif bt.value == "}":
					db -= 1
					if db == 0:
						j += 1
						break
				elif bt.value != "," and not TYPE_ARG_OPS.has(bt.value):
					return -1
			elif bt.type != GateLexer._T.IDENT and bt.type != GateLexer._T.KEYWORD:
				return -1
			j += 1
		if db != 0:
			return -1
	elif t.is_op("<") or t.is_op("<<"):
		var close: int = _generic_span_end(from, false)
		if close < 0:
			return -1
		j = close + 1
	elif t.is_kw("func") and from + 1 < n and _toks[from + 1].is_op("("):
		var dp: int = 0
		j = from + 1
		while j < n:
			var pt: GateLexer._Token = _toks[j]
			if pt.type == GateLexer._T.NEWLINE or pt.type == GateLexer._T.EOF:
				return -1
			if pt.is_op("("):
				dp += 1
			elif pt.is_op(")"):
				dp -= 1
				if dp == 0:
					j += 1
					break
			j += 1
		if dp != 0:
			return -1
		if j < n and _toks[j].is_op("->"):
			return _pattern_type_end(j + 1)
		return j
	elif t.type != GateLexer._T.IDENT:
		return -1
	while j + 1 < n and _toks[j].is_op(".") and _toks[j + 1].type == GateLexer._T.IDENT:
		j += 2
	if j < n and (_toks[j].is_op("<") or _toks[j].is_op("<<")):
		var gclose: int = _generic_span_end(j, false)
		if gclose < 0:
			return -1
		j = gclose + 1
	while j < n and (_toks[j].is_op("[") or _toks[j].is_op("?[")):
		var d2: int = 0
		while j < n:
			var b: GateLexer._Token = _toks[j]
			if b.type == GateLexer._T.OP:
				if b.value == "[" or b.value == "?[":
					d2 += 1
				elif b.value == "]":
					d2 -= 1
					if d2 == 0:
						j += 1
						break
				elif not TYPE_ARG_OPS.has(b.value):
					return -1
			elif b.type != GateLexer._T.IDENT and b.type != GateLexer._T.KEYWORD:
				return -1
			j += 1
		if d2 != 0:
			return -1
	if j < n and _toks[j].is_op("?"):
		j += 1
	return j


func _scan_pattern() -> GateAST._Expr:
	var start: GateLexer._Token = _cur()
	var depth: int = 0
	var prev: GateLexer._Token = null
	while not _at_end():
		var t: GateLexer._Token = _cur()
		var before: GateLexer._Token = prev
		if depth > 0 and prev != null and t.type == GateLexer._T.IDENT \
			and (prev.type == GateLexer._T.IDENT or prev.is_op(">") or prev.is_op("]")
				or prev.is_op("?")):
			diagnostics.error(
				"a type pattern must be a whole arm pattern, not part of an array or dictionary pattern",
				t.line, t.col,
				"bind it with `var %s` there and test the type in a `when` guard: `... when %s is ...`"
					% [t.value, t.value])
		prev = t
		if t.type == GateLexer._T.OP:
			if t.value in ["(", "[", "{", "?["]:
				depth += 1
			elif t.value in [")", "]", "}"]:
				depth -= 1
			elif depth == 0 and (t.value == ":" or t.value == ","):
				break
		elif depth == 0 and t.is_kw("when") and before != null and not before.is_op(".") \
			and not before.is_kw("var"):
			break
		elif t.type == GateLexer._T.NEWLINE and depth <= 0:
			break
		_advance()
	var r: GateAST._RawExpr = GateAST._RawExpr.new()
	r.at(start.line, start.col)
	r.text = _span_text(start, _cur())
	return r


func _parse_destructure() -> GateAST._Stmt:
	var kw: GateLexer._Token = _advance()  # var/const
	var st: GateAST._MultiAssign = GateAST._MultiAssign.new()
	st.at(kw.line, kw.col)
	st.declares = true
	st.destructure = true
	_expect_op("[", "to open the destructuring pattern")
	while not _at_end() and not _check_op("]"):
		if _check(GateLexer._T.IDENT):
			var id: GateAST._Ident = GateAST._Ident.new()
			var t: GateLexer._Token = _advance()
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
		var t: GateLexer._Token = _toks[i]
		if t.type == GateLexer._T.NEWLINE or t.type == GateLexer._T.EOF or t.type == GateLexer._T.DEDENT:
			return false
		if t.type == GateLexer._T.OP:
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
		var t: GateLexer._Token = _toks[i]
		if t.type == GateLexer._T.NEWLINE or t.type == GateLexer._T.EOF or t.type == GateLexer._T.DEDENT:
			return false
		if t.type == GateLexer._T.OP:
			if t.value in ["(", "[", "{"]:
				depth += 1
			elif t.value in [")", "]", "}"]:
				if depth == 0:
					return true
				depth -= 1
		i += 1
	return false


func _parse_expression_statement(start_line: int) -> GateAST._Stmt:
	var first: GateAST._Expr = _parse_expr()
	if first == null:
		var raw: GateAST._RawStmt = _raw_from(start_line, _cur().line)
		_skip_to_statement_end()
		return raw

	if _check_op(","):
		if _comma_starts_multi_assign():
			var targets: Array = [first]
			while _match_op(","):
				targets.append(_parse_expr())
			if _match_op("="):
				var st: GateAST._MultiAssign = GateAST._MultiAssign.new()
				st.at(first.line, first.col)
				st.targets = targets
				st.values.append(_parse_expr())
				while _match_op(","):
					st.values.append(_parse_expr())
				return st
		elif not _comma_is_enclosed():
			var raw2: GateAST._RawStmt = _raw_from(start_line, _cur().line)
			_skip_to_statement_end()
			return raw2

	const ASSIGN_OPS := ["=", "+=", "-=", "*=", "/=", "%=", "**=", "&=", "|=", "^=", "<<=", ">>="]
	if _check(GateLexer._T.OP) and _cur().value in ASSIGN_OPS:
		var op: String = _advance().value
		var a: GateAST._AssignStmt = GateAST._AssignStmt.new()
		a.at(first.line, first.col)
		a.target = first
		a.op = op
		a.value = _parse_expr()
		return a

	var es: GateAST._ExprStmt = GateAST._ExprStmt.new()
	es.at(first.line, first.col)
	es.expr = first
	return es

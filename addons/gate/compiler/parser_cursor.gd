@tool
extends RefCounted

## Parser layer 1: the token cursor and error recovery.

var diagnostics: GateDiagnostics

var _toks: Array = []

var _i: int = 0

var _lines: PackedStringArray = []

var _panic: bool = false

var _expr_depth: int = 0
var _depth_reported: bool = false

var _block_depth: int = 0

var _in_inline_lambda: int = 0

var _extra_decls: Array = []

var _generic_uses: Array = []

var _saw_nullable: bool = false


func _peek(offset: int = 0) -> GateLexer.Token:
	var idx: int = _i + offset
	if idx >= _toks.size():
		return _toks[_toks.size() - 1]
	return _toks[idx]


func _cur() -> GateLexer.Token: return _peek(0)


func _at_end() -> bool: return _cur().type == GateLexer.T.EOF


func _advance() -> GateLexer.Token:
	var t: GateLexer.Token = _cur()
	if not _at_end():
		_i += 1
	return t

var _stmt_col: int = 0


func _continues_line() -> bool:
	if _stmt_col <= 0 or _i <= 0 or _at_end():
		return true
	if _toks[_i - 1].line >= _cur().line:
		return true
	return _cur().col > _stmt_col


func _at_stmt_end() -> bool:
	if _check(GateLexer.T.NEWLINE) or _check(GateLexer.T.COMMENT) or _check(GateLexer.T.DEDENT) or _at_end():
		return true
	if _in_inline_lambda > 0:
		return _check_op(",") or _check_op(")") or _check_op("]") or _check_op("}")
	return false


func _at_name() -> bool:
	return _is_name_token(_cur())


func _is_name_token(t: GateLexer.Token) -> bool:
	if t.type == GateLexer.T.IDENT:
		return true
	return t.type == GateLexer.T.KEYWORD and (GateLexer.is_gate_only_keyword(t.value)
		or GateLexer.is_contextual_keyword(t.value))


func _check_op(v: String) -> bool: return _cur().is_op(v)


func _check_kw(v: String) -> bool: return _cur().is_kw(v)


func _check(t: int) -> bool: return _cur().type == t


func _match_op(v: String) -> bool:
	if _check_op(v):
		_advance()
		return true
	return false


func _match_kw(v: String) -> bool:
	if _check_kw(v):
		_advance()
		return true
	return false


func _expect_op(v: String, ctx: String) -> bool:
	if _match_op(v):
		return true
	_err("expected '%s' %s, found '%s'" % [v, ctx, _cur().value])
	return false


func _err(msg: String, hint: String = "") -> void:
	var t: GateLexer.Token = _cur()
	diagnostics.error(msg, t.line, t.col, hint)


func _skip_newlines() -> void:
	while _check(GateLexer.T.NEWLINE) or _check(GateLexer.T.COMMENT):
		_advance()


func _skip_to_statement_end() -> void:
	var depth: int = 0
	while not _at_end():
		var t: GateLexer.Token = _cur()
		if t.type == GateLexer.T.OP:
			if t.value in ["(", "[", "{"]: depth += 1
			elif t.value in [")", "]", "}"]: depth -= 1
		if t.type == GateLexer.T.NEWLINE and depth <= 0:
			return
		_advance()


func _span_text(a: GateLexer.Token, b: GateLexer.Token) -> String:
	if a.line < 1 or a.line > _lines.size():
		return ""
	if a.line == b.line:
		return _lines[a.line - 1].substr(a.col - 1, maxi(0, b.col - a.col)).strip_edges()
	var parts: PackedStringArray = PackedStringArray()
	for i in range(a.line - 1, mini(b.line, _lines.size())):
		var l: String = _lines[i]
		if i == b.line - 1:
			l = l.substr(0, maxi(0, b.col - 1))
		if i == a.line - 1:
			l = l.substr(a.col - 1)
		parts.append(l.strip_edges())
	return " ".join(parts)


func _raw_from(start_line: int, end_line: int) -> GateAST.RawStmt:
	var r: GateAST.RawStmt = GateAST.RawStmt.new()
	var parts: PackedStringArray = PackedStringArray()
	for i in range(start_line - 1, mini(end_line, _lines.size())):
		if i >= 0 and i < _lines.size():
			parts.append(_lines[i])
	r.text = "\n".join(parts)
	r.line = start_line
	return r


func _rewind_to(_t: GateLexer.Token) -> bool:
	return false

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

var _alias_names: Dictionary = {}
var _saw_alias: bool = false
var _saw_gate_type: bool = false

var known_generics: Dictionary = {}
var known_aliases: Dictionary = {}
var _generic_names: Dictionary = {}


var _names_scanned: bool = false


var _templates: Dictionary = {}
var _templates_scanned: bool = false


func _is_generic_name(n: String) -> bool:
	if not _templates_scanned:
		_templates_scanned = true
		_templates = known_generics.duplicate()
		for i in _toks.size() - 2:
			var t: GateLexer._Token = _toks[i]
			if t.type == GateLexer._T.KEYWORD and (t.value == "class" or t.value == "struct") \
					and _toks[i + 1].type == GateLexer._T.IDENT and _toks[i + 2].is_op("<"):
				_templates[_toks[i + 1].value] = true
	if not _templates.has(n):
		return false
	if not _names_scanned:
		_names_scanned = true
		_prescan_names()
	if not _generic_names.has(n):
		return false
	for span in _shadow_spans.get(n, []):
		if _i >= int(span[0]) and _i < int(span[1]):
			return false
	return true


func _prescan_names() -> void:
	_generic_names = known_generics.duplicate()
	var shadows: Dictionary = {}
	var spans: Dictionary = {}
	var blocks: Array = []        ## per open block: [inside a function, [[name, from], ...]]
	var pending = null            ## the block this line opens, once its INDENT comes
	var attach: Array = []        ## parameters and loop variables, scoped to the next block
	var header_func: bool = false
	var n: int = _toks.size()
	for i in n - 1:
		var t: GateLexer._Token = _toks[i]
		var in_func: bool = header_func or (not blocks.is_empty() and blocks[-1][0])
		if t.type == GateLexer._T.NEWLINE:
			var k: int = i + 1
			while k < n and _toks[k].type in [GateLexer._T.NEWLINE, GateLexer._T.COMMENT]:
				k += 1   # blank and comment lines sit between a header and its block
			if k < n and _toks[k].type == GateLexer._T.INDENT:
				if pending == null:
					pending = [in_func, attach]
				else:
					(pending[1] as Array).append_array(attach)
			else:
				_close_spans(attach, i, spans)
			attach = []
			header_func = false
			continue
		if t.type == GateLexer._T.INDENT:
			blocks.append(pending if pending != null else [in_func, []])
			pending = null
			continue
		if t.type == GateLexer._T.DEDENT:
			if not blocks.is_empty():
				_close_spans(blocks.pop_back()[1], i, spans)
			continue
		if t.type == GateLexer._T.IDENT:
			var declared: int = _type_first_name(i)
			if declared >= 0:
				_bind_name(_toks[declared].value, declared, in_func, header_func, blocks, attach, shadows)
			continue
		if t.type != GateLexer._T.KEYWORD:
			continue
		if t.value == "enum":
			_enum_keys(i + 1, shadows)
		if t.value == "func":
			header_func = true
			_param_names(i + 1, attach)
			continue
		if t.value == "for":
			var j: int = i + 1
			while j < n and _toks[j].type == GateLexer._T.IDENT:
				attach.append([_toks[j].value, j])
				if j + 2 < n and _toks[j + 1].is_op(","):
					j += 2
				else:
					break
			continue
		var nx: GateLexer._Token = _toks[i + 1]
		if not (nx.type == GateLexer._T.IDENT):
			continue
		if t.value == "class" or t.value == "struct":
			if i + 2 < n and _toks[i + 2].is_op("<"):
				_generic_names[nx.value] = true
			else:
				shadows[nx.value] = true
		elif t.value == "var" or t.value == "const":
			_bind_name(nx.value, i + 1, in_func, header_func, blocks, attach, shadows)
		elif t.value == "enum" or t.value == "class_name":
			shadows[nx.value] = true
	for b in blocks:
		_close_spans(b[1], n, spans)
	_close_spans(attach, n, spans)
	for s in shadows:
		_generic_names.erase(s)
	_shadow_spans = spans
	_alias_shadows = shadows.merged(spans)


static func _bind_name(name: String, at: int, in_func: bool, header_func: bool, blocks: Array,
		attach: Array, shadows: Dictionary) -> void:
	if header_func:
		attach.append([name, at])
	elif in_func and not blocks.is_empty():
		(blocks[-1][1] as Array).append([name, at])
	else:
		shadows[name] = true


static func _close_spans(bound: Array, to: int, spans: Dictionary) -> void:
	for b in bound:
		if not spans.has(b[0]):
			spans[b[0]] = []
		(spans[b[0]] as Array).append([b[1], to])


var _alias_shadows: Dictionary = {}
var _shadow_spans: Dictionary = {}   ## name -> [[from, to], ...]: token spans where a local hides a template


func _generics_at(at: int) -> Dictionary:
	var out: Dictionary = _generic_names.duplicate()
	for nm in _shadow_spans:
		for span in _shadow_spans[nm]:
			if at >= int(span[0]) and at < int(span[1]):
				out.erase(nm)
	return out


func _shift_spans(at: int) -> void:
	for nm in _shadow_spans:
		for span in _shadow_spans[nm]:
			if int(span[0]) >= at:
				span[0] = int(span[0]) + 1
			if int(span[1]) >= at:
				span[1] = int(span[1]) + 1


func _type_first_name(i: int) -> int:
	var n: int = _toks.size()
	if i > 0:
		var prev: GateLexer._Token = _toks[i - 1]
		if not (prev.type in [GateLexer._T.NEWLINE, GateLexer._T.INDENT, GateLexer._T.DEDENT,
				GateLexer._T.COMMENT, GateLexer._T.ANNOTATION] or prev.is_kw("static")
				or prev.is_kw("pub") or prev.is_kw("priv")):
			return -1
	var j: int = i + 1
	var depth: int = 0
	while j < n:
		var tk: GateLexer._Token = _toks[j]
		if tk.type == GateLexer._T.NEWLINE or tk.type == GateLexer._T.EOF:
			return -1
		if tk.is_op("<"):
			depth += 1
		elif tk.is_op("<<"):
			depth += 2
		elif tk.is_op(">"):
			depth -= 1
		elif tk.is_op(">>"):
			depth -= 2
		elif depth == 0 and (tk.is_op("[") or tk.is_op("?[")) and j + 1 < n and _toks[j + 1].is_op("]"):
			j += 1
		elif depth == 0 and not tk.is_op("?"):
			break
		if depth < 0:
			return -1
		j += 1
	if j + 1 >= n or _toks[j].type != GateLexer._T.IDENT:
		return -1
	var after: GateLexer._Token = _toks[j + 1]
	if after.type == GateLexer._T.NEWLINE or after.type == GateLexer._T.COMMENT \
			or after.is_op("=") or after.is_op(":") or after.is_op(","):
		return j
	return -1


func _enum_keys(from: int, shadows: Dictionary) -> void:
	var n: int = _toks.size()
	var j: int = from
	if j < n and _toks[j].type == GateLexer._T.IDENT:
		j += 1
	if j >= n or not _toks[j].is_op("{"):
		return
	var depth: int = 0
	var expect_key: bool = false
	while j < n:
		var tk: GateLexer._Token = _toks[j]
		if tk.is_op("{") or tk.is_op("(") or tk.is_op("["):
			depth += 1
			expect_key = depth == 1
		elif tk.is_op("}") or tk.is_op(")") or tk.is_op("]"):
			depth -= 1
			if depth == 0:
				return
		elif depth == 1 and tk.is_op(","):
			expect_key = true
		elif expect_key and tk.type == GateLexer._T.IDENT:
			shadows[tk.value] = true
			expect_key = false
		elif tk.type != GateLexer._T.NEWLINE and tk.type != GateLexer._T.INDENT \
				and tk.type != GateLexer._T.DEDENT and tk.type != GateLexer._T.COMMENT:
			expect_key = false
		j += 1


## Parameter names of a function or lambda. A name is one followed by `:`, `,`, `)`
## or `=`, so the type in `Box<int> b` is not taken for one.
func _param_names(from: int, out: Array) -> void:
	var n: int = _toks.size()
	var j: int = from
	if j < n and _toks[j].type == GateLexer._T.IDENT:
		j += 1
	if j >= n or not _toks[j].is_op("("):
		return
	var depth: int = 0
	var after_sep: bool = false
	while j < n:
		var tk: GateLexer._Token = _toks[j]
		if tk.type in [GateLexer._T.NEWLINE, GateLexer._T.INDENT, GateLexer._T.DEDENT, GateLexer._T.COMMENT]:
			j += 1
			continue
		if tk.is_op("(") or tk.is_op("[") or tk.is_op("{"):
			depth += 1
		elif tk.is_op(")") or tk.is_op("]") or tk.is_op("}"):
			depth -= 1
			if depth == 0:
				return
		elif depth == 1 and after_sep and tk.type == GateLexer._T.IDENT and j + 1 < n:
			var nt: GateLexer._Token = _toks[j + 1]
			if nt.is_op(":") or nt.is_op(",") or nt.is_op(")") or nt.is_op("="):
				out.append([tk.value, j])
		after_sep = depth == 1 and (tk.is_op("(") or tk.is_op(","))
		j += 1


func _seed_aliases() -> void:
	if known_aliases.is_empty():
		return
	if not _names_scanned:
		_names_scanned = true
		_prescan_names()
	for a in known_aliases:
		if not _alias_shadows.has(a):
			_alias_names[a] = true


func _peek(offset: int = 0) -> GateLexer._Token:
	var idx: int = _i + offset
	if idx >= _toks.size():
		return _toks[_toks.size() - 1]
	return _toks[idx]


func _cur() -> GateLexer._Token: return _peek(0)


func _at_end() -> bool: return _cur().type == GateLexer._T.EOF


func _advance() -> GateLexer._Token:
	var t: GateLexer._Token = _cur()
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
	if _check(GateLexer._T.NEWLINE) or _check(GateLexer._T.COMMENT) or _check(GateLexer._T.DEDENT) or _at_end():
		return true
	if _in_inline_lambda > 0:
		return _check_op(",") or _check_op(")") or _check_op("]") or _check_op("}")
	return false


func _at_name() -> bool:
	return _is_name_token(_cur())


func _is_name_token(t: GateLexer._Token) -> bool:
	if t.type == GateLexer._T.IDENT:
		return true
	return t.type == GateLexer._T.KEYWORD and (GateLexer.is_gate_only_keyword(t.value)
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
	var t: GateLexer._Token = _cur()
	diagnostics.error(msg, t.line, t.col, hint)


func _skip_newlines() -> void:
	while _check(GateLexer._T.NEWLINE) or _check(GateLexer._T.COMMENT):
		_advance()


func _skip_to_statement_end() -> void:
	var depth: int = 0
	while not _at_end():
		var t: GateLexer._Token = _cur()
		if t.type == GateLexer._T.OP:
			if t.value in ["(", "[", "{"]: depth += 1
			elif t.value in [")", "]", "}"]: depth -= 1
		if t.type == GateLexer._T.NEWLINE and depth <= 0:
			return
		_advance()


func _span_text(a: GateLexer._Token, b: GateLexer._Token) -> String:
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


func _raw_from(start_line: int, end_line: int) -> GateAST._RawStmt:
	var r: GateAST._RawStmt = GateAST._RawStmt.new()
	var parts: PackedStringArray = PackedStringArray()
	for i in range(start_line - 1, mini(end_line, _lines.size())):
		if i >= 0 and i < _lines.size():
			parts.append(_lines[i])
	r.text = "\n".join(parts)
	r.line = start_line
	return r


func _rewind_to(_t: GateLexer._Token) -> bool:
	return false

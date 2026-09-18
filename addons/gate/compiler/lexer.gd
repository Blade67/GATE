@tool
class_name GateLexer
extends RefCounted

## Indentation-aware tokenizer. Emits INDENT/DEDENT, and suppresses them
## inside brackets the way GDScript does.

enum _T {
	NEWLINE, INDENT, DEDENT, EOF,
	IDENT, KEYWORD, NUMBER, STRING, FSTRING, ANNOTATION, NODEPATH, COMMENT,
	OP,
}

const KEYWORDS := {
	"if": true, "elif": true, "else": true, "for": true, "while": true, "match": true,
	"when": true, "break": true, "continue": true, "pass": true, "return": true,
	"class": true, "class_name": true, "extends": true, "is": true, "in": true,
	"as": true, "self": true, "super": true, "signal": true, "func": true,
	"static": true, "const": true, "enum": true, "var": true, "breakpoint": true,
	"preload": true, "await": true, "assert": true, "void": true, "abstract": true,
	"and": true, "or": true, "not": true, "true": true, "false": true, "null": true,
	"struct": true, "interface": true, "trait": true, "namespace": true,
	"implements": true, "with": true, "pub": true, "priv": true,
	"override": true, "virtual": true, "final": true, "operator": true,
	"requires": true,
}

const GATE_ONLY := {
	"struct": true, "interface": true, "trait": true, "namespace": true,
	"implements": true, "with": true, "pub": true, "priv": true,
	"override": true, "virtual": true, "final": true, "operator": true,
	"requires": true,
}


static func is_gate_only_keyword(v: String) -> bool:
	return GATE_ONLY.has(v)

const CONTEXTUAL_KEYWORDS := {"match": true, "when": true, "abstract": true}


static func is_contextual_keyword(v: String) -> bool:
	return CONTEXTUAL_KEYWORDS.has(v)

const OPS3 := ["**=", "<<=", ">>=", "..."]
const OPS2 := [
	"==", "!=", "<=", ">=", "->", ":=", "+=", "-=", "*=", "/=", "%=",
	"**", "<<", ">>", "&&", "||", "??", "?.", "?[", "&=", "|=", "^=", "..",
]


class _Token extends RefCounted:
	var type: int
	var value: String
	var line: int
	var col: int
	var extra: String = ""
	var prefix: String = ""

	func _init(p_type: int, p_value: String, p_line: int, p_col: int) -> void:
		type = p_type
		value = p_value
		line = p_line
		col = p_col

	func is_op(v: String) -> bool:
		return type == _T.OP and value == v

	func is_kw(v: String) -> bool:
		return type == _T.KEYWORD and value == v

	func _to_string() -> String:
		return "[%s %s @%d:%d]" % [_T.keys()[type], value, line, col]

var tokens: Array[_Token] = []
var diagnostics: GateDiagnostics

var _src: String = ""
var _n: int = 0
var _i: int = 0
var _line: int = 1
var _line_start: int = 0
var _indents: Array[int] = [0]
var _indent_char: String = ""
var _depth: int = 0


func _col() -> int:
	return _i - _line_start + 1


func _is_quote(c: String) -> bool:
	return c == "\"" or c == "'"


func _push(t: int, v: String, line: int = -1, col: int = -1) -> _Token:
	var tok: _Token = _Token.new(t, v, line if line >= 0 else _line, col if col >= 0 else _col())
	tokens.append(tok)
	return tok


func tokenize(src: String, diags: GateDiagnostics, first_line: int = 1) -> Array[_Token]:
	diagnostics = diags
	tokens = []
	if src.length() > 0 and src.unicode_at(0) == 0xFEFF:
		src = src.substr(1)
	_src = src
	_n = src.length()
	_i = 0
	_line = first_line
	_line_start = 0
	_indents = [0]
	_indent_char = ""
	_depth = 0

	var at_line_start: bool = true

	while _i < _n:
		if at_line_start and _depth == 0:
			at_line_start = false
			if not _handle_indent():
				continue
			continue

		var c: String = _src[_i]

		if c == "\n":
			_newline_token()
			at_line_start = _depth == 0
			continue
		if c == "\r":
			_i += 1
			continue
		if c == " " or c == "\t":
			_i += 1
			continue
		if c == "\\":
			var bs_col: int = _col()
			_i += 1
			if _i < _n and _src[_i] == "\r":
				_i += 1
			if _i >= _n or _src[_i] != "\n":
				diagnostics.error("Expected new line after \"\\\".", _line, bs_col,
					"a `\\` outside a string joins the next line, so it must end this one: "
					+ "remove what follows it, or check for a missing closing quote above")
			while _i < _n and _src[_i] != "\n":
				_i += 1
			if _i < _n:
				_i += 1
				_line += 1
				_line_start = _i
			while _i < _n:
				var j: int = _i
				while j < _n and (_src[j] == " " or _src[j] == "\t" or _src[j] == "\r"):
					j += 1
				if j >= _n or _src[j] != "#":
					break
				_i = j
				_skip_comment()
				if _i < _n and _src[_i] == "\n":
					_i += 1
					_line += 1
					_line_start = _i
			continue
		if c == "#":
			if _depth > 0:
				_skip_comment()
			else:
				_lex_comment()
			continue
		if c == "\"" or c == "'":
			_lex_string(false)
			continue
		if c in ["f", "r", "&", "^"] and _i + 1 < _n and _is_quote(_src[_i + 1]):
			var is_f: bool = c == "f"
			_i += 1
			_lex_string(is_f, "" if is_f else c)
			continue
		if c >= "0" and c <= "9":
			_lex_number()
			continue
		if (c == "." and _i + 1 < _n and _src[_i + 1] >= "0" and _src[_i + 1] <= "9"
				and not _prev_ends_expr()):
			_lex_number()
			continue
		if c == "@":
			_lex_prefixed(_T.ANNOTATION)
			continue
		if c == "$" or c == "%":
			# `%` is a unique-node path only in prefix position. After anything that can end
			# an expression it is modulo, which is how Godot's own tokenizer decides.
			# Godot allows whitespace between the sigil and the name.
			var k: int = _i + 1
			while k < _n and (_src[k] == " " or _src[k] == "	"):
				k += 1
			var nxt: String = _src[k] if k < _n else ""
			var path_like: bool = nxt != "" and (_is_word_start(nxt) or _is_quote(nxt))
			if c == "%" and (not path_like or _prev_ends_expr()):
				_lex_operator()
				continue
			_lex_nodepath()
			continue
		if _is_word_start(c):
			_lex_word()
			continue
		_lex_operator()

	if _depth != 0:
		diagnostics.error("unbalanced brackets at end of file", _line, _col(),
			"a '(', '[' or '{' was never closed")
	_push(_T.NEWLINE, "")
	while _indents.size() > 1:
		_indents.pop_back()
		_push(_T.DEDENT, "")
	_push(_T.EOF, "")
	return tokens


func _newline_token() -> void:
	if _depth == 0:
		_push(_T.NEWLINE, "")
	_i += 1
	_line += 1
	_line_start = _i


func _handle_indent() -> bool:
	var col: int = 0
	var start: int = _i
	while _i < _n:
		var c: String = _src[_i]
		if c == " ":
			col += 1
			_i += 1
		elif c == "\t":
			col += 4
			_i += 1
		else:
			break
	if _i >= _n:
		return false
	var c2: String = _src[_i]
	if c2 == "\n" or c2 == "\r":
		return false
	if c2 == "#":
		return false
	if not _indent_chars_agree(_src.substr(start, _i - start)):
		_i = _n   # Godot stops here; what follows would only report the same mistake again
		return false
	if col > _indents[-1]:
		_indents.append(col)
		_push(_T.INDENT, "", _line, start - _line_start + 1)
	else:
		while col < _indents[-1]:
			_indents.pop_back()
			_push(_T.DEDENT, "", _line, start - _line_start + 1)
		if col != _indents[-1]:
			diagnostics.error("inconsistent indentation", _line, col + 1,
				"expected %d spaces, found %d" % [_indents[-1], col])
	return false


## Godot fixes the indentation character at the first indented line of code -
## blank lines, comments, string contents and continuations do not count - and
## refuses a later line indented with the other one, or with both.
func _indent_chars_agree(ws: String) -> bool:
	if ws == "":
		return true
	if ws.contains(" ") and ws.contains("	"):
		diagnostics.error("Mixed use of tabs and spaces for indentation.", _line, 1,
			"indent with one character throughout; the editor's Convert Indentation fixes a file")
		return false
	var ch: String = ws[0]
	if _indent_char == "":
		_indent_char = ch
		return true
	if ch == _indent_char:
		return true
	var used: String = "tab" if ch == "	" else "space"
	var before: String = "tab" if _indent_char == "	" else "space"
	diagnostics.error("Used %s character for indentation instead of %s as used before in the file."
			% [used, before], _line, 1,
		"indent with one character throughout; the editor's Convert Indentation fixes a file")
	return false


func _skip_comment() -> void:
	while _i < _n and _src[_i] != "\n":
		_i += 1


func _lex_comment() -> void:
	var line: int = _line
	var col: int = _col()
	var start: int = _i
	while _i < _n and _src[_i] != "\n":
		_i += 1
	_push(_T.COMMENT, _src.substr(start, _i - start), line, col)


func _lex_string(is_fstring: bool, prefix: String = "") -> void:
	var line: int = _line
	var col: int = _col() - (1 if prefix != "" or is_fstring else 0)
	var quote: String = _src[_i]
	var triple: bool = false
	if _i + 2 < _n and _src[_i + 1] == quote and _src[_i + 2] == quote:
		triple = true
		_i += 3
	else:
		_i += 1
	var body_start: int = _i
	var closed: bool = false
	var spans_lines: bool = false
	while _i < _n:
		var c: String = _src[_i]
		if c == "\\":
			if _i + 1 < _n and _src.unicode_at(_i + 1) == 10:
				_line += 1
				_i += 2
				_line_start = _i
				continue
			_i += 2
			continue
		if c == "\n":
			_line += 1
			_i += 1
			_line_start = _i
			if not triple:
				spans_lines = true
			continue
		if c == quote:
			if triple:
				if _i + 2 < _n and _src[_i + 1] == quote and _src[_i + 2] == quote:
					closed = true
					break
				_i += 1
				continue
			closed = true
			break
		_i += 1
	if not closed:
		diagnostics.error("unterminated string literal", line, col)
		var t: _Token = _push(_T.STRING, "\"\"", line, col)
		return
	if spans_lines:
		diagnostics.warn("string literal spans more than one line", line, col,
			"if a closing quote is missing, this is not what you meant")
	var body: String = _src.substr(body_start, _i - body_start)
	_i += 3 if triple else 1
	var tok: _Token = _push(_T.FSTRING if is_fstring else _T.STRING, body, line, col)
	tok.extra = quote if not triple else quote.repeat(3)
	tok.prefix = prefix


func _lex_number() -> void:
	var line: int = _line
	var col: int = _col()
	var start: int = _i
	var seen_dot: bool = false
	var is_hex: bool = false
	if _src[_i] == "0" and _i + 1 < _n and (_src[_i + 1] == "x" or _src[_i + 1] == "b"):
		is_hex = true
		_i += 2
	while _i < _n:
		var c: String = _src[_i]
		if c >= "0" and c <= "9":
			_i += 1
		elif c == "_":
			_i += 1
		elif is_hex and ((c >= "a" and c <= "f") or (c >= "A" and c <= "F")):
			_i += 1
		elif c == "." and not seen_dot and not is_hex:
			if _i + 1 < _n and _src[_i + 1] == ".":
				break
			seen_dot = true
			_i += 1
		elif not is_hex and (c == "e" or c == "E") and _i + 1 < _n \
			and (_src[_i + 1].is_valid_int() or _src[_i + 1] == "-" or _src[_i + 1] == "+"):
			_i += 2
		else:
			break
	_push(_T.NUMBER, _src.substr(start, _i - start), line, col)


func _lex_prefixed(kind: int) -> void:
	var line: int = _line
	var col: int = _col()
	var start: int = _i
	_i += 1
	while _i < _n and _is_word(_src[_i]):
		_i += 1
	_push(kind, _src.substr(start, _i - start), line, col)


func _lex_nodepath() -> void:
	var line: int = _line
	var col: int = _col()
	var start: int = _i
	_i += 1
	var k: int = _i
	while k < _n and (_src[k] == " " or _src[k] == "	"):
		k += 1
	if k < _n and (_is_word_start(_src[k]) or _is_quote(_src[k])):
		_i = k
	if _i < _n and (_src[_i] == "\"" or _src[_i] == "'"):
		var q: String = _src[_i]
		_i += 1
		while _i < _n and _src[_i] != q:
			_i += 1
		_i += 1
	else:
		while _i < _n and (_is_word(_src[_i]) or _src[_i] == "/" or _src[_i] == "%"):
			_i += 1
	_push(_T.NODEPATH, _src.substr(start, _i - start), line, col)


func _lex_word() -> void:
	var line: int = _line
	var col: int = _col()
	var start: int = _i
	while _i < _n and _is_word(_src[_i]):
		_i += 1
	var w: String = _src.substr(start, _i - start)
	_push(_T.KEYWORD if KEYWORDS.has(w) else _T.IDENT, w, line, col)


func _lex_operator() -> void:
	var line: int = _line
	var col: int = _col()
	var c: String = _src[_i]
	if c == "(" or c == "[" or c == "{":
		_depth += 1
	elif c == ")" or c == "]" or c == "}":
		_depth = maxi(0, _depth - 1)

	if _i + 2 < _n:
		var three: String = _src.substr(_i, 3)
		if three in OPS3:
			_i += 3
			_push(_T.OP, three, line, col)
			return
	if _i + 1 < _n:
		var two: String = _src.substr(_i, 2)
		if two in OPS2:
			_i += 2
			_push(_T.OP, two, line, col)
			return
	_i += 1
	_push(_T.OP, c, line, col)


func _prev_ends_expr() -> bool:
	for i in range(tokens.size() - 1, -1, -1):
		var t: _Token = tokens[i]
		if t.type == _T.COMMENT:
			continue
		match t.type:
			_T.IDENT, _T.NUMBER, _T.STRING, _T.FSTRING, _T.NODEPATH:
				return true
			_T.KEYWORD:
				if CONTEXTUAL_KEYWORDS.has(t.value):
					return _contextual_is_name(i)
				return (t.value in ["self", "super", "true", "false", "null"]
					or GATE_ONLY.has(t.value))
			_T.OP:
				return t.value in [")", "]", "}"]
			_:
				return false
	return false


func _contextual_is_name(i: int) -> bool:
	var t: _Token = tokens[i]
	var j: int = i - 1
	while j >= 0 and tokens[j].type == _T.COMMENT:
		j -= 1
	var prev: _Token = tokens[j] if j >= 0 else null
	if prev != null and prev.type == _T.OP and prev.value == ".":
		return true
	match t.value:
		"match":
			return prev != null and not (prev.type in [_T.NEWLINE, _T.INDENT, _T.DEDENT]
				or (prev.type == _T.OP and prev.value == ";"))
		"when":
			if prev == null:
				return true
			var after_pattern: bool = prev.type in [_T.IDENT, _T.NUMBER, _T.STRING, _T.NODEPATH] \
				or (prev.type == _T.OP and prev.value in [")", "]", "}"]) \
				or (prev.type == _T.KEYWORD and prev.value in ["true", "false", "null"])
			return not after_pattern
	return true


func _is_word_start(c: String) -> bool:
	return ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
		or c.unicode_at(0) >= 0x80)


func _is_word(c: String) -> bool:
	return _is_word_start(c) or (c >= "0" and c <= "9")

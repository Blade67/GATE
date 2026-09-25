@tool
class_name GatePreprocess
extends RefCounted

## Resolves @if / @elif / @else / @endif before the lexer ever sees the file.
## A dropped line is blanked, not deleted, so every later line keeps its
## original number and the sourcemap needs no change. A line inside a
## triple-quoted string is never read as a directive.

const CMP_OPS := {">": true, "<": true, ">=": true, "<=": true, "==": true, "!=": true}

const COND_HINT: String = ("conditions use a symbol, !, && , ||, parentheses, and a "
	+ "comparison against GODOT_VERSION.")


class _Frame:
	var line: int = 0
	var parent_active: bool = true
	var branch_true: bool = false
	var any_true: bool = false
	var seen_else: bool = false

	func active() -> bool:
		return parent_active and branch_true


class _Cursor:
	var toks: Array = []
	var pos: int = 0

	func peek() -> Dictionary:
		return toks[pos] if pos < toks.size() else {"kind": "eof", "value": ""}

	func advance() -> Dictionary:
		var t: Dictionary = peek()
		pos += 1
		return t


## Cheap enough to call before deciding whether a file needs anything else here: a
## substring test, true even inside a string. A fast "definitely nothing to do".
static func has_directive(src: String) -> bool:
	return src.contains("@if") or src.contains("@elif") or src.contains("@else") or src.contains("@endif")


static func run(src: String, diags: GateDiagnostics, defines: Dictionary) -> String:
	if not has_directive(src):
		return src
	for msg in (defines.get(GateDefines.ERRORS_KEY, []) as Array):
		diags.error(String(msg), 1, 1, COND_HINT)
	var inside: Dictionary = GateCompiler.lines_inside_strings(src)
	var lines: PackedStringArray = src.split("\n")
	var stack: Array[_Frame] = []
	for i in lines.size():
		if inside.has(i):
			# Inside a triple-quoted string: never a directive, but still ordinary code as far as
			# blanking goes - an inactive frame blanks it exactly like any other line.
			if not _active(stack):
				lines[i] = ""
			continue
		# Stripped before _kind_of() looks at it: GDScript needs no space before a `#`, so
		# "@else#x" is the token "@else" plus a comment. Seen whole it matched no directive
		# at all and was treated as ordinary code, blanking an @else branch with no error.
		var trimmed: String = _strip_trailing_comment(lines[i].strip_edges())
		var kind: String = _kind_of(trimmed)
		if kind == "":
			if not _active(stack):
				lines[i] = ""
			continue
		var line_no: int = i + 1
		_apply(kind, trimmed, line_no, diags, defines, stack)
		lines[i] = ""
	for f in stack:
		diags.error("@if on this line is never closed with a matching @endif", f.line, 1, COND_HINT)
	return "\n".join(lines)


## A directive line never legitimately contains `#`, so one there is always a trailing
## comment - the one thing a GDScript user expects to be able to add anywhere.
static func _strip_trailing_comment(trimmed: String) -> String:
	var at: int = trimmed.find("#")
	if at < 0:
		return trimmed
	return trimmed.substr(0, at).strip_edges()


static func _kind_of(trimmed: String) -> String:
	if trimmed.begins_with("@if") and (trimmed.length() == 3 or trimmed[3] == " " or trimmed[3] == "\t"):
		return "if"
	if trimmed.begins_with("@elif") and (trimmed.length() == 5 or trimmed[5] == " " or trimmed[5] == "\t"):
		return "elif"
	if trimmed == "@else" or (trimmed.begins_with("@else") and (trimmed[5] == " " or trimmed[5] == "\t")):
		return "else"
	if trimmed == "@endif" or (trimmed.begins_with("@endif") and (trimmed[6] == " " or trimmed[6] == "\t")):
		return "endif"
	return ""


static func _active(stack: Array) -> bool:
	if stack.is_empty():
		return true
	return (stack[stack.size() - 1] as _Frame).active()


static func _apply(kind: String, trimmed: String, line_no: int, diags: GateDiagnostics,
		defines: Dictionary, stack: Array) -> void:
	if kind == "if":
		var f: _Frame = _Frame.new()
		f.line = line_no
		f.parent_active = _active(stack)
		var val: bool = _eval(trimmed.substr(3), line_no, diags, defines)
		f.branch_true = val
		f.any_true = val
		stack.append(f)
		return
	if kind == "elif":
		if stack.is_empty():
			diags.error("@elif with no matching @if", line_no, 1, COND_HINT)
			return
		var fe: _Frame = stack[stack.size() - 1]
		if fe.seen_else:
			diags.error("@elif cannot follow @else in the same @if", line_no, 1, COND_HINT)
			return
		var val2: bool = _eval(trimmed.substr(5), line_no, diags, defines)
		fe.branch_true = (not fe.any_true) and val2
		fe.any_true = fe.any_true or val2
		return
	if kind == "else":
		if stack.is_empty():
			diags.error("@else with no matching @if", line_no, 1, COND_HINT)
			return
		if trimmed != "@else":
			diags.error("@else takes no condition", line_no, 1, COND_HINT)
			return
		var fs: _Frame = stack[stack.size() - 1]
		if fs.seen_else:
			diags.error("this @if already has an @else", line_no, 1, COND_HINT)
			return
		fs.seen_else = true
		fs.branch_true = not fs.any_true
		fs.any_true = true
		return
	if kind == "endif":
		if stack.is_empty():
			diags.error("@endif with no matching @if", line_no, 1, COND_HINT)
			return
		if trimmed != "@endif":
			diags.error("@endif takes no condition", line_no, 1, COND_HINT)
			return
		stack.remove_at(stack.size() - 1)


static func _eval(text: String, line_no: int, diags: GateDiagnostics, defines: Dictionary) -> bool:
	var trimmed: String = text.strip_edges()
	if trimmed == "":
		diags.error("expected a condition after @if / @elif", line_no, 1, COND_HINT)
		return false
	var cur: _Cursor = _Cursor.new()
	cur.toks = _tokenize(trimmed, line_no, diags)
	var v: bool = _parse_or(cur, line_no, diags, defines)
	if cur.peek()["kind"] != "eof":
		diags.error("unexpected text in condition: '%s'" % String(cur.peek()["value"]), line_no, 1, COND_HINT)
	return v


static func _parse_or(cur: _Cursor, line_no: int, diags: GateDiagnostics, defines: Dictionary) -> bool:
	var v: bool = _parse_and(cur, line_no, diags, defines)
	while cur.peek()["kind"] == "op" and cur.peek()["value"] == "||":
		cur.advance()
		var rhs: bool = _parse_and(cur, line_no, diags, defines)
		v = v or rhs
	return v


static func _parse_and(cur: _Cursor, line_no: int, diags: GateDiagnostics, defines: Dictionary) -> bool:
	var v: bool = _parse_unary(cur, line_no, diags, defines)
	while cur.peek()["kind"] == "op" and cur.peek()["value"] == "&&":
		cur.advance()
		var rhs: bool = _parse_unary(cur, line_no, diags, defines)
		v = v and rhs
	return v


static func _parse_unary(cur: _Cursor, line_no: int, diags: GateDiagnostics, defines: Dictionary) -> bool:
	if cur.peek()["kind"] == "op" and cur.peek()["value"] == "!":
		cur.advance()
		return not _parse_unary(cur, line_no, diags, defines)
	return _parse_atom(cur, line_no, diags, defines)


static func _parse_atom(cur: _Cursor, line_no: int, diags: GateDiagnostics, defines: Dictionary) -> bool:
	var t: Dictionary = cur.peek()
	if t["kind"] == "op" and t["value"] == "(":
		cur.advance()
		var v: bool = _parse_or(cur, line_no, diags, defines)
		if cur.peek()["kind"] == "op" and cur.peek()["value"] == ")":
			cur.advance()
		else:
			diags.error("missing ')' in condition", line_no, 1, COND_HINT)
		return v
	if t["kind"] == "ident":
		cur.advance()
		var name: String = String(t["value"])
		var nxt: Dictionary = cur.peek()
		if nxt["kind"] == "op" and CMP_OPS.has(nxt["value"]):
			var op: String = String(cur.advance()["value"])
			return _comparison(name, op, cur, line_no, diags, defines)
		if name == "GODOT_VERSION":
			diags.error("GODOT_VERSION can only be used in a comparison, such as GODOT_VERSION >= 4.7",
				line_no, 1, COND_HINT)
			return false
		if not defines.has(name):
			diags.error(("unknown compile-time symbol '%s': not one of Godot's built-ins and not "
				+ "listed in the project setting gate/compiler/defines") % name, line_no, 1, COND_HINT)
			return false
		return bool(defines[name])
	diags.error("expected a symbol, '!' or '(' in condition", line_no, 1, COND_HINT)
	if t["kind"] != "eof":
		cur.advance()
	return false


static func _comparison(name: String, op: String, cur: _Cursor, line_no: int,
		diags: GateDiagnostics, defines: Dictionary) -> bool:
	if name != "GODOT_VERSION":
		diags.error("'%s' cannot be compared; only GODOT_VERSION can be compared" % name,
			line_no, 1, COND_HINT)
		if cur.peek()["kind"] == "num":
			cur.advance()
		return false
	var t: Dictionary = cur.peek()
	if t["kind"] != "num":
		diags.error("expected a version number such as 4.7 after '%s'" % op, line_no, 1, COND_HINT)
		return false
	cur.advance()
	var parts: PackedStringArray = String(t["value"]).split(".")
	var lit: Array = [0, 0, 0]
	for i in mini(parts.size(), 3):
		lit[i] = int(parts[i])
	var running: Array = defines.get("GODOT_VERSION", [0, 0, 0])
	return _compare_version(running, lit, op)


static func _compare_version(running: Array, lit: Array, op: String) -> bool:
	var c: int = 0
	for i in 3:
		var a: int = int(running[i])
		var b: int = int(lit[i])
		if a != b:
			c = -1 if a < b else 1
			break
	if op == ">":
		return c > 0
	if op == "<":
		return c < 0
	if op == ">=":
		return c >= 0
	if op == "<=":
		return c <= 0
	if op == "==":
		return c == 0
	return c != 0


static func _tokenize(text: String, line_no: int, diags: GateDiagnostics) -> Array:
	var toks: Array = []
	var i: int = 0
	var n: int = text.length()
	while i < n:
		var c: String = text[i]
		if c == " " or c == "\t":
			i += 1
			continue
		if c == "(" or c == ")":
			toks.append({"kind": "op", "value": c})
			i += 1
			continue
		if c == "!":
			if i + 1 < n and text[i + 1] == "=":
				toks.append({"kind": "op", "value": "!="})
				i += 2
			else:
				toks.append({"kind": "op", "value": "!"})
				i += 1
			continue
		if c == "&" and i + 1 < n and text[i + 1] == "&":
			toks.append({"kind": "op", "value": "&&"})
			i += 2
			continue
		if c == "|" and i + 1 < n and text[i + 1] == "|":
			toks.append({"kind": "op", "value": "||"})
			i += 2
			continue
		if c == ">" or c == "<":
			if i + 1 < n and text[i + 1] == "=":
				toks.append({"kind": "op", "value": c + "="})
				i += 2
			else:
				toks.append({"kind": "op", "value": c})
				i += 1
			continue
		if c == "=" and i + 1 < n and text[i + 1] == "=":
			toks.append({"kind": "op", "value": "=="})
			i += 2
			continue
		var is_alpha: bool = (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or c == "_"
		if is_alpha:
			var j: int = i
			while j < n:
				var cj: String = text[j]
				var ok_char: bool = ((cj >= "A" and cj <= "Z") or (cj >= "a" and cj <= "z")
					or (cj >= "0" and cj <= "9") or cj == "_")
				if not ok_char:
					break
				j += 1
			toks.append({"kind": "ident", "value": text.substr(i, j - i)})
			i = j
			continue
		if c >= "0" and c <= "9":
			var j2: int = i
			while j2 < n and ((text[j2] >= "0" and text[j2] <= "9") or text[j2] == "."):
				j2 += 1
			toks.append({"kind": "num", "value": text.substr(i, j2 - i)})
			i = j2
			continue
		diags.error("unexpected character '%s' in condition" % c, line_no, 1, COND_HINT)
		i += 1
	return toks

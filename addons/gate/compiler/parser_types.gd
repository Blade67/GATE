@tool
extends "res://addons/gate/compiler/parser_cursor.gd"

## Parser layer 2: the type grammar, and the lookahead that separates a
## type-first declaration from an expression statement.


func _parse_extends_type() -> GateAST.TypeRef:
	if _check(GateLexer.T.STRING):
		var t: GateLexer.Token = _cur()
		_advance()
		var q: String = t.extra if t.extra != "" else "\""
		var tr: GateAST.TypeRef = GateAST.TypeRef.new()
		tr.at(t.line, t.col)
		tr.name = q + t.value + q
		tr.is_path_literal = true
		return tr
	return _parse_type()


func _parse_type() -> GateAST.TypeRef:
	var t: GateAST.TypeRef = GateAST.TypeRef.new()
	var start: GateLexer.Token = _cur()
	t.at(start.line, start.col)

	if _match_op("{"):
		var first: GateAST.TypeRef = _parse_type()
		if _match_op(","):
			t.dict_key = first
			t.dict_value = _parse_type()
		else:
			t.set_elem = first
		_expect_op("}", "to close the type")
	else:
		if not (_check(GateLexer.T.IDENT) or _check(GateLexer.T.KEYWORD)):
			_err("expected a type name, found '%s'" % _cur().value)
			t.name = "Variant"
			return t
		t.name = _advance().value
		while _check_op(".") and _peek(1).type == GateLexer.T.IDENT:
			_advance()
			t.name += "." + _advance().value
		if _check_op("<") and not _never_generic(t.name) and _closes_generic_args():
			_advance()
			while not _at_end() and not _check_op(">"):
				t.generic_args.append(_parse_type())
				if not _match_op(","):
					break
			_expect_op(">", "to close generic arguments")
		if _check_op("[") and _peek(1).type != GateLexer.T.OP:
			_advance()
			t.generic_args.append(_parse_type())
			while _match_op(","):
				t.generic_args.append(_parse_type())
			_expect_op("]", "to close the type argument")

	while true:
		if _check_op("[") and _peek(1).is_op("]"):
			_advance(); _advance()
			t.array_depth += 1
		elif _check_op("?[") and _peek(1).is_op("]"):
			_advance(); _advance()
			t.elem_nullable = true
			t.array_depth += 1
			_saw_nullable = true
		elif _check_op("?"):
			_advance()
			t.nullable = true
			_saw_nullable = true
		elif _check_op("??"):
			_err("a type can only be marked nullable once",
				"write `%s?`; `??` is the null-coalescing operator, not part of a type."
					% t.name)
			_advance()
			t.nullable = true
			_saw_nullable = true
		else:
			break
	return t


func _looks_like_typed_decl() -> bool:
	var t: GateLexer.Token = _cur()
	if t.is_op("{"):
		var j: int = _i
		var depth: int = 0
		while j < _toks.size():
			var tk: GateLexer.Token = _toks[j]
			if tk.type == GateLexer.T.OP and tk.value == "{": depth += 1
			elif tk.type == GateLexer.T.OP and tk.value == "}":
				depth -= 1
				if depth == 0:
					var nxt: GateLexer.Token = _toks[j + 1] if j + 1 < _toks.size() else null
					return nxt != null and nxt.type == GateLexer.T.IDENT
			elif tk.type == GateLexer.T.NEWLINE:
				return false
			j += 1
		return false

	if t.type != GateLexer.T.IDENT:
		return false

	var j2: int = _i + 1
	while j2 < _toks.size():
		var tk2: GateLexer.Token = _toks[j2]
		if tk2.type == GateLexer.T.OP and (tk2.value == "[" or tk2.value == "?["):
			var nxt2: GateLexer.Token = _toks[j2 + 1] if j2 + 1 < _toks.size() else null
			if nxt2 != null and nxt2.type == GateLexer.T.OP and nxt2.value == "]":
				j2 += 2
				continue
			var d3: int = 0
			var k3: int = j2
			while k3 < _toks.size():
				var b: GateLexer.Token = _toks[k3]
				if b.type == GateLexer.T.NEWLINE:
					return false
				if b.type == GateLexer.T.OP and (b.value == "[" or b.value == "?["): d3 += 1
				elif b.type == GateLexer.T.OP and b.value == "]":
					d3 -= 1
					if d3 == 0:
						k3 += 1
						break
				k3 += 1
			if k3 == j2:
				return false
			j2 = k3
			continue
		if tk2.type == GateLexer.T.OP and tk2.value == "?":
			j2 += 1
			continue
		if tk2.type == GateLexer.T.OP and tk2.value == "<":
			if not _is_type_looking(t.value):
				return false
			var depth2: int = 0
			while j2 < _toks.size():
				var g: GateLexer.Token = _toks[j2]
				if g.type == GateLexer.T.OP and g.value == "<": depth2 += 1
				elif g.type == GateLexer.T.OP and g.value == ">":
					depth2 -= 1
					if depth2 == 0:
						j2 += 1
						break
				elif g.type == GateLexer.T.NEWLINE:
					return false
				j2 += 1
			continue
		break
	if j2 >= _toks.size():
		return false
	var name_tok: GateLexer.Token = _toks[j2]
	if not _is_name_token(name_tok):
		return false
	if j2 == _i + 1 and not _is_type_looking(t.value):
		return false
	var after: GateLexer.Token = _toks[j2 + 1] if j2 + 1 < _toks.size() else null
	if after == null:
		return false
	if after.type == GateLexer.T.OP and after.value == "{":
		var inner: GateLexer.Token = _toks[j2 + 2] if j2 + 2 < _toks.size() else null
		return inner != null and inner.value in ["get", "set"]
	# A comment is a token, so a trailing one sits where the NEWLINE would be.
	return after.type == GateLexer.T.NEWLINE \
		or after.type == GateLexer.T.COMMENT \
		or (after.type == GateLexer.T.OP and after.value in ["=", ":", ","])


func _is_type_looking(name: String) -> bool:
	if GateTypes.SHORTHAND.has(name):
		return true
	if name.length() > 0 and name[0] == name[0].to_upper() and name[0] != "_":
		return true
	if GateTypes.BUILTIN.has(name):
		return true
	for sh in GateTypes.SHORTHAND:
		if GateTypes.SHORTHAND[sh].to_lower() == name.to_lower():
			return true
	return false


func _check_generic_instantiation() -> bool:
	if not _peek(1).is_op("<"):
		return false
	if not _is_type_looking(_cur().value):
		return false
	var j: int = _i + 1
	var depth: int = 0
	while j < _toks.size():
		var tk: GateLexer.Token = _toks[j]
		if tk.type == GateLexer.T.OP and tk.value == "<":
			depth += 1
		elif tk.type == GateLexer.T.OP and tk.value == ">":
			depth -= 1
			if depth == 0:
				var nxt: GateLexer.Token = _toks[j + 1] if j + 1 < _toks.size() else null
				return nxt != null and nxt.type == GateLexer.T.OP and nxt.value in [".", "("]
		elif tk.type == GateLexer.T.NEWLINE:
			return false
		j += 1
	return false

const TYPE_ARG_OPS := [".", ",", "<", ">", "[", "]", "?", "?["]

## A builtin scalar takes no type arguments, ever. Without this, `[v as int < i,
## j > i]` is read as `int<i, j>`.
func _never_generic(name: String) -> bool:
	if GateTypes.SHORTHAND.has(name):
		return true
	return GateTypes.BUILTIN.has(name) and name != "Array" and name != "Dictionary"


func _closes_generic_args() -> bool:
	var depth: int = 0
	var i: int = _i
	while i < _toks.size():
		var t: GateLexer.Token = _toks[i]
		if t.type == GateLexer.T.NEWLINE or t.type == GateLexer.T.EOF:
			return false
		if t.type == GateLexer.T.OP:
			if t.value == "<":
				depth += 1
			elif t.value == ">":
				depth -= 1
				if depth == 0:
					return true
			elif not TYPE_ARG_OPS.has(t.value):
				return false
		elif depth >= 1 and t.type != GateLexer.T.IDENT and not t.is_kw("void"):
			return false
		i += 1
	return false


static func mangle_generic(t: GateAST.TypeRef) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for g in t.generic_args:
		var one: String = String(g.name).replace(".", "_")
		if not g.generic_args.is_empty():
			one = mangle_generic(g)
		for _d in g.array_depth:
			one += "_arr"
		if g.nullable:
			one += "_opt"
		parts.append(one)
	return "__%s_%s" % [t.name, "_".join(parts)]

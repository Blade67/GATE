@tool
extends "res://addons/gate/compiler/parser_cursor.gd"

## Parser layer 2: the type grammar, and the lookahead that separates a
## type-first declaration from an expression statement.


func _parse_extends_type() -> GateAST._TypeRef:
	if _check(GateLexer._T.STRING):
		var t: GateLexer._Token = _cur()
		_advance()
		var q: String = t.extra if t.extra != "" else "\""
		var tr: GateAST._TypeRef = GateAST._TypeRef.new()
		tr.at(t.line, t.col)
		tr.name = q + t.value + q
		tr.is_path_literal = true
		while _check_op(".") and _peek(1).type == GateLexer._T.IDENT:
			_advance()
			tr.name += "." + _advance().value
		return tr
	return _parse_type()


func _parse_type() -> GateAST._TypeRef:
	var t: GateAST._TypeRef = GateAST._TypeRef.new()
	var start: GateLexer._Token = _cur()
	t.at(start.line, start.col)

	if _match_op("{"):
		var first: GateAST._TypeRef = _parse_type()
		if _match_op(","):
			t.dict_key = first
			t.dict_value = _parse_type()
		else:
			t.set_elem = first
		_expect_op("}", "to close the type")
	elif _check_op("<") or _check_op("<<"):
		_parse_type_list(t)
	elif _check_kw("func") and _peek(1).is_op("("):
		_parse_func_type(t)
		return t
	elif _check_op("(") and _peek(1).is_kw("func"):
		_advance()
		t = _parse_type()
		_expect_op(")", "to close the parenthesised type")
	else:
		if not (_check(GateLexer._T.IDENT) or _check(GateLexer._T.KEYWORD)):
			_err("expected a type name, found '%s'" % _cur().value)
			t.name = "Variant"
			return t
		t.name = _advance().value
		while _check_op(".") and _peek(1).type == GateLexer._T.IDENT:
			_advance()
			t.name += "." + _advance().value
		if (_check_op("<") or _check_op("<<")) and not _never_generic(t.name) \
				and _closes_generic_args():
			_split_generic_span(_i)
			_advance()
			if _check_op(">"):
				_err("expected a type argument inside `<>`",
					"write the type, as in `%s<Enemy>`, or drop the brackets" % t.name)
			while not _at_end() and not _check_op(">"):
				t.generic_args.append(_parse_type())
				if not _match_op(","):
					break
			_expect_op(">", "to close generic arguments")
		if _check_op("[") and _peek(1).type != GateLexer._T.OP:
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
		elif _check_op("??") and _tested_type > 0:
			break   # `x as Foo ?? d`: after a cast's type, `??` is the operator
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


func _parse_type_list(t: GateAST._TypeRef) -> void:
	_saw_gate_type = true
	_split_generic_span(_i)
	_advance()  # '<'
	var members: Array = []
	var sep: String = ""
	var mixed: bool = false
	while not _at_end() and not _check_op(">"):
		var before: int = _i
		members.append(_parse_type())
		if _check_op("|") or _check_op(","):
			if sep != "" and _cur().value != sep and not mixed:
				mixed = true
				_err("a type list is either a union (|) or a tuple (,), not both",
					"write `<a | b>` for a value that is one of several types, or `<a, b>` "
					+ "for a fixed-length array whose elements have these types")
			sep = _cur().value
			_advance()
			if _check_op(">"):
				_err("expected a type after '%s'" % sep, "remove the trailing '%s'" % sep)
		elif _i == before:
			break
		else:
			break
	if members.is_empty():
		_err("expected a type inside `<>`")
	_expect_op(">", "to close the type list")
	if sep == "|":
		t.name = "Variant"
		t.union_members = members
	else:
		t.name = "Array"
		t.tuple_elems = members


func _parse_func_type(t: GateAST._TypeRef) -> void:
	_saw_gate_type = true
	_advance()  # func
	_advance()  # (
	t.name = "Callable"
	t.is_func_type = true
	_skip_newlines()
	while not _at_end() and not _check_op(")"):
		var before: int = _i
		t.shaped().callable_params.append(_parse_type())
		_skip_newlines()
		if not _match_op(","):
			break
		_skip_newlines()
		if _i == before:
			break
	_expect_op(")", "to close the parameter types")
	if _match_op("->"):
		t.callable_return = _parse_type()
	else:
		var v: GateAST._TypeRef = GateAST._TypeRef.new()
		v.at(t.line, t.col)
		v.name = "void"
		t.callable_return = v


func _looks_like_func_type_decl() -> bool:
	if not (_check_kw("func") and _peek(1).is_op("(")):
		return false
	var j: int = _skip_type_span(_i)
	if j < 0 or j >= _toks.size() or _toks[j].is_op(":"):
		return false
	return _decl_name_follows(j)


func _looks_like_paren_type_decl() -> bool:
	if not (_check_op("(") and _peek(1).is_kw("func")):
		return false
	var j: int = _skip_type_span(_i)
	return j >= 0 and j < _toks.size() and _decl_name_follows(j)


func _skip_type_span(j: int) -> int:
	if j >= _toks.size():
		return -1
	var t: GateLexer._Token = _toks[j]
	if t.is_op("(") and j + 1 < _toks.size() and _toks[j + 1].is_kw("func"):
		var inner: int = _skip_type_span(j + 1)
		if inner < 0 or inner >= _toks.size() or not _toks[inner].is_op(")"):
			return -1
		return _skip_type_suffixes(inner + 1)
	if t.is_kw("func"):
		if j + 1 >= _toks.size() or not _toks[j + 1].is_op("("):
			return -1
		var depth: int = 0
		var k: int = j + 1
		while k < _toks.size():
			var b: GateLexer._Token = _toks[k]
			if b.type == GateLexer._T.NEWLINE or b.type == GateLexer._T.EOF:
				return -1
			if b.is_op("("): depth += 1
			elif b.is_op(")"):
				depth -= 1
				if depth == 0:
					break
			k += 1
		if k >= _toks.size():
			return -1
		k += 1
		if k < _toks.size() and _toks[k].is_op("->"):
			return _skip_type_span(k + 1)
		return k
	var i: int = j
	if t.is_op("<") or t.is_op("<<"):
		var close: int = _generic_span_end(j, false)
		if close < 0:
			return -1
		i = close + 1
	elif t.is_op("{"):
		var d: int = 0
		while i < _toks.size():
			var c: GateLexer._Token = _toks[i]
			if c.type == GateLexer._T.NEWLINE:
				return -1
			if c.is_op("{"): d += 1
			elif c.is_op("}"):
				d -= 1
				if d == 0:
					break
			i += 1
		i += 1
	elif t.type == GateLexer._T.IDENT or t.is_kw("void"):
		i += 1
		while i + 1 < _toks.size() and _toks[i].is_op(".") and _toks[i + 1].type == GateLexer._T.IDENT:
			i += 2
		if i < _toks.size() and (_toks[i].is_op("<") or _toks[i].is_op("<<")):
			var gclose: int = _generic_span_end(i, true)
			if gclose >= 0:
				i = gclose + 1
	else:
		return -1
	return _skip_type_suffixes(i)


func _skip_type_suffixes(i: int) -> int:
	while i < _toks.size():
		var s: GateLexer._Token = _toks[i]
		if s.is_op("?") or s.is_op("??"):
			i += 1
		elif (s.is_op("[") or s.is_op("?[")) and i + 1 < _toks.size() and _toks[i + 1].is_op("]"):
			i += 2
		else:
			break
	return i


func _at_type_alias() -> bool:
	if not (_cur().type == GateLexer._T.IDENT and _cur().value == "type"
			and _peek(1).type == GateLexer._T.IDENT):
		return false
	if _peek(2).is_op("="):
		return true
	if _peek(2).is_op("<"):
		var close: int = _generic_span_end(_i + 2, true)
		return close >= 0 and close + 1 < _toks.size() and _toks[close + 1].is_op("=")
	return false


func _parse_type_alias() -> GateAST._TypeAliasDecl:
	var kw: GateLexer._Token = _advance()  # type
	var ad: GateAST._TypeAliasDecl = GateAST._TypeAliasDecl.new()
	ad.at(kw.line, kw.col)
	ad.name = _advance().value
	if _check_op("<"):
		_err("a type alias cannot take type parameters",
			"write the type out where it is used, or declare a generic class")
		_skip_to_statement_end()
		return null
	_advance()  # =
	ad.target = _parse_type()
	_alias_names[ad.name] = true
	if not _at_stmt_end() and not _check_op(";"):
		_err("unexpected '%s' after the aliased type" % _cur().value)
		_skip_to_statement_end()
	return ad


var _tested_type: int = 0


func _parse_tested_type(kw: String) -> GateAST._TypeRef:
	_tested_type += 1
	var tr: GateAST._TypeRef = _parse_type()
	_tested_type -= 1
	# `x is Box<float>` names the class, so it has to exist even if nothing builds one.
	if not tr.generic_args.is_empty():
		_generic_uses.append(tr)
	return tr


func _looks_like_typed_decl() -> bool:
	var t: GateLexer._Token = _cur()
	if t.type == GateLexer._T.OP and (t.value == "<" or t.value == "<<"):
		var close: int = _generic_span_end(_i, false)
		if close < 0:
			return false
		var j: int = close + 1
		while j < _toks.size():
			var s: GateLexer._Token = _toks[j]
			if s.is_op("?"):
				j += 1
			elif (s.is_op("[") or s.is_op("?[")) and j + 1 < _toks.size() and _toks[j + 1].is_op("]"):
				j += 2
			else:
				break
		return _decl_name_follows(j)
	if t.is_op("{"):
		var j: int = _i
		var depth: int = 0
		while j < _toks.size():
			var tk: GateLexer._Token = _toks[j]
			if tk.type == GateLexer._T.OP and tk.value == "{": depth += 1
			elif tk.type == GateLexer._T.OP and tk.value == "}":
				depth -= 1
				if depth == 0:
					var nxt: GateLexer._Token = _toks[j + 1] if j + 1 < _toks.size() else null
					return nxt != null and nxt.type == GateLexer._T.IDENT
			elif tk.type == GateLexer._T.NEWLINE:
				return false
			j += 1
		return false

	if t.type != GateLexer._T.IDENT:
		return false

	var j2: int = _i + 1
	while j2 < _toks.size():
		var tk2: GateLexer._Token = _toks[j2]
		if tk2.type == GateLexer._T.OP and (tk2.value == "[" or tk2.value == "?["):
			var nxt2: GateLexer._Token = _toks[j2 + 1] if j2 + 1 < _toks.size() else null
			if nxt2 != null and nxt2.type == GateLexer._T.OP and nxt2.value == "]":
				j2 += 2
				continue
			var d3: int = 0
			var k3: int = j2
			while k3 < _toks.size():
				var b: GateLexer._Token = _toks[k3]
				if b.type == GateLexer._T.NEWLINE:
					return false
				if b.type == GateLexer._T.OP and (b.value == "[" or b.value == "?["): d3 += 1
				elif b.type == GateLexer._T.OP and b.value == "]":
					d3 -= 1
					if d3 == 0:
						k3 += 1
						break
				k3 += 1
			if k3 == j2:
				return false
			j2 = k3
			continue
		if tk2.type == GateLexer._T.OP and tk2.value == "?":
			j2 += 1
			continue
		if (tk2.is_op(".") and j2 + 1 < _toks.size() and _toks[j2 + 1].type == GateLexer._T.IDENT
				and _is_type_looking(t.value) and _is_type_looking(_toks[j2 + 1].value)
				and t.value[0] == t.value[0].to_upper()):
			j2 += 2
			continue
		if tk2.type == GateLexer._T.OP and (tk2.value == "<" or tk2.value == "<<"):
			if not _is_type_looking(t.value):
				return false
			if tk2.value == "<<" and not (_is_generic_name(t.value) or BUILTIN_GENERICS.has(t.value)):
				return false
			var close: int = _generic_span_end(j2, tk2.value == "<<")
			if close < 0:
				return false
			j2 = close + 1
			continue
		break
	if j2 >= _toks.size():
		return false
	if not _is_name_token(_toks[j2]):
		return false
	if j2 == _i + 1 and not _is_type_looking(t.value):
		return false
	return _decl_name_follows(j2)


func _decl_name_follows(j2: int) -> bool:
	if j2 >= _toks.size():
		return false
	var name_tok: GateLexer._Token = _toks[j2]
	if not _is_name_token(name_tok):
		return false
	var after: GateLexer._Token = _toks[j2 + 1] if j2 + 1 < _toks.size() else null
	if after == null:
		return false
	if after.type == GateLexer._T.OP and after.value == "{":
		var inner: GateLexer._Token = _toks[j2 + 2] if j2 + 2 < _toks.size() else null
		return inner != null and inner.value in ["get", "set"]
	# A comment is a token, so a trailing one sits where the NEWLINE would be.
	return after.type == GateLexer._T.NEWLINE \
		or after.type == GateLexer._T.COMMENT \
		or (after.type == GateLexer._T.OP and after.value in ["=", ":", ","])


func _is_type_looking(name: String) -> bool:
	if GateTypes.is_shorthand(name) or _alias_names.has(name):
		return true
	if GateTypes.shadowed.has(name):
		return true   # `class vec2` declared here or in the project: a type all the same
	if name.length() > 0 and name[0] == name[0].to_upper() and name[0] != "_":
		return true
	if GateTypes.BUILTIN.has(name):
		return true
	for sh in GateTypes.SHORTHAND:
		if GateTypes.SHORTHAND[sh].to_lower() == name.to_lower():
			return true
	return false


func _qualified_generic_ahead() -> bool:
	if not _peek(1).is_op(".") or _peek(2).type != GateLexer._T.IDENT:
		return false
	var open: GateLexer._Token = _peek(3)
	if not (open.is_op("<") or open.is_op("<<")):
		return false
	if not _is_generic_name(_peek(2).value):
		return false
	return _generic_after(_i + 3, open.value == "<<")


func _check_generic_instantiation() -> bool:
	var nx: GateLexer._Token = _peek(1)
	if nx.type != GateLexer._T.OP or not (nx.value == "<" or nx.value == "<<"):
		return false
	return _is_generic_name(_cur().value) and _generic_after(_i + 1, nx.value == "<<")


func _generic_after(from: int, strict: bool) -> bool:
	var close: int = _generic_span_end(from, strict)
	if close < 0 or close + 2 >= _toks.size():
		return false
	return _toks[close + 1].is_op(".") and _is_name_token(_toks[close + 2])


const BUILTIN_GENERICS := {"Array": true, "Dictionary": true, "PackedScene": true}


func _generic_span_end(from: int, strict: bool) -> int:
	var depth: int = 0
	var i: int = from
	while i < _toks.size():
		var t: GateLexer._Token = _toks[i]
		if t.type == GateLexer._T.NEWLINE or t.type == GateLexer._T.EOF:
			return -1
		if t.type == GateLexer._T.OP:
			if t.value == "<":
				depth += 1
			elif t.value == "<<":
				depth += 2
			elif t.value == ">" or t.value == ">>":
				depth -= 1 if t.value == ">" else 2
				if depth == 0:
					return i
				if depth < 0:
					return -1
			elif strict and not TYPE_ARG_OPS.has(t.value):
				return -1
		elif strict and depth >= 1 and t.type != GateLexer._T.IDENT and not t.is_kw("void") \
				and not t.is_kw("func"):
			return -1
		i += 1
	return -1


func _split_generic_span(from: int) -> void:
	var end: int = _generic_span_end(from, false)
	if end < 0:
		return
	var i: int = from
	while i <= end:
		var t: GateLexer._Token = _toks[i]
		if t.type == GateLexer._T.OP and (t.value == ">>" or t.value == "<<"):
			var half: String = t.value.substr(0, 1)
			_toks[i] = GateLexer._Token.new(GateLexer._T.OP, half, t.line, t.col)
			_toks.insert(i + 1, GateLexer._Token.new(GateLexer._T.OP, half, t.line, t.col + 1))
			_shift_spans(i + 1)
			end += 1
			i += 1
		i += 1

const TYPE_ARG_OPS := [".", ",", "<", ">", "<<", ">>", "[", "]", "?", "?[", "|", "(", ")", "->", "{", "}"]

## A builtin scalar takes no type arguments, ever. Without this, `[v as int < i,
## j > i]` is read as `int<i, j>`.
func _never_generic(name: String) -> bool:
	if GateTypes.is_shorthand(name):
		return true
	return GateTypes.BUILTIN.has(name) and name != "Array" and name != "Dictionary"


func _closes_generic_args() -> bool:
	return _generic_span_end(_i, true) >= 0


static func mangle_generic(t: GateAST._TypeRef) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for g in t.generic_args:
		var one: String = String(g.name).replace(".", "_")
		if not g.generic_args.is_empty():
			one = mangle_generic(g)
		elif g.is_union() or g.is_tuple() or g.is_func_type or g.is_dict() or g.is_set():
			one = _mangle_shape(g)
		for _d in g.array_depth:
			one += "_arr"
		if g.nullable:
			one += "_opt"
		parts.append(one)
	return "__%s_%s" % [t.name, "_".join(parts)]


static func _mangle_shape(g: GateAST._TypeRef) -> String:
	if g.is_dict():
		return "D_%s_%s" % [_mangle_part(g.dict_key), _mangle_part(g.dict_value)]
	if g.is_set():
		return "S_%s" % _mangle_part(g.set_elem)
	var head: String = "U" if g.is_union() else ("T" if g.is_tuple() else "F")
	var ps: PackedStringArray = PackedStringArray()
	if g.is_union():
		ps = union_parts(g)
	else:
		for k in (g.tuple_elems if g.is_tuple() else g.callable_params):
			ps.append(_mangle_part(k))
	var s: String = head + "_" + "_".join(ps)
	if g.is_func_type:
		s += "__" + _mangle_part(g.callable_return)
	return s


static func union_parts(g: GateAST._TypeRef) -> PackedStringArray:
	var ps: PackedStringArray = PackedStringArray()
	for m in g.union_members:
		var mt: GateAST._TypeRef = m
		var parts: PackedStringArray = union_parts(mt) if mt.is_union() and mt.array_depth == 0 \
			and not mt.nullable else PackedStringArray([_mangle_part(mt)])
		for p in parts:
			if not ps.has(p):
				ps.append(p)
	ps.sort()
	return ps


static func _mangle_part(k: GateAST._TypeRef) -> String:
	if k == null:
		return "Variant"
	var one: String = GateTypes.canonical(k.name).replace(".", "_")
	if not k.generic_args.is_empty():
		one = mangle_generic(k)
	elif k.is_union() or k.is_tuple() or k.is_func_type or k.is_dict() or k.is_set():
		one = _mangle_shape(k)
	for _d in k.array_depth:
		one += "_arr"
	if k.nullable:
		one += "_opt"
	return one

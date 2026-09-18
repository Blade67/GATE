@tool
extends "res://addons/gate/compiler/parser_types.gd"

## Parser layer 3: expressions, by precedence climbing.


func _parse_block(is_class_body: bool) -> Array:
	push_error("[GATE] internal: _parse_block not overridden")
	return []


func _parse_inline_body() -> Array:
	push_error("[GATE] internal: _parse_inline_body not overridden")
	return []


func _parse_lambda_inline_body(_limit_line: int = 0) -> Array:
	push_error("[GATE] internal: _parse_lambda_inline_body not overridden")
	return []

const MAX_EXPR_DEPTH := 48


func _parse_expr() -> GateAST._Expr:
	if _expr_depth >= MAX_EXPR_DEPTH:
		var t: GateLexer._Token = _cur()
		if not _depth_reported:
			diagnostics.error(
				"expression nests more than %d levels deep" % MAX_EXPR_DEPTH, t.line, t.col,
				"GATE's parser is written in GDScript and recurses once per level, so it "
				+ "runs out of stack well before Godot's own parser does. Split the "
				+ "expression into named intermediates.")
			_depth_reported = true
			_panic = true
			diagnostics.seal()
		var bad: GateAST._Literal = GateAST._Literal.new()
		bad.at(t.line, t.col)
		bad.raw = "null"
		return bad
	_expr_depth += 1
	var e: GateAST._Expr = _parse_cast()
	_expr_depth -= 1
	return e


func _parse_ternary() -> GateAST._Expr:
	var e: GateAST._Expr = _parse_coalesce()
	if e is GateAST._Lambda and (e as GateAST._Lambda).block_body:
		return e
	if _in_inline_lambda > 0 and _check_kw("if") and _if_opens_a_block():
		return e
	if _check_kw("if"):
		_advance()
		var t: GateAST._Ternary = GateAST._Ternary.new()
		t.at(e.line, e.col)
		t.if_true = e
		t.cond = _parse_ternary()
		if _match_kw("else"):
			t.if_false = _parse_ternary()
		else:
			_err("expected 'else' in a ternary expression")
		return t
	return e


func _parse_coalesce() -> GateAST._Expr:
	var left: GateAST._Expr = _parse_or()
	while _check_op("??"):
		var t: GateLexer._Token = _advance()
		var n: GateAST._NullCoalesce = GateAST._NullCoalesce.new()
		n.at(t.line, t.col)
		n.left = left
		n.right = _parse_or()
		left = n
	return left


func _parse_or() -> GateAST._Expr:
	var left: GateAST._Expr = _parse_and()
	while _check_kw("or") or _check_op("||"):
		var t: GateLexer._Token = _advance()
		left = _mk_binary("or", left, _parse_and(), t)
	return left


func _parse_and() -> GateAST._Expr:
	var left: GateAST._Expr = _parse_not()
	while _check_kw("and") or _check_op("&&"):
		var t: GateLexer._Token = _advance()
		left = _mk_binary("and", left, _parse_not(), t)
	return left


func _parse_not() -> GateAST._Expr:
	if _check_kw("not") or _check_op("!"):
		var t: GateLexer._Token = _advance()
		var u: GateAST._Unary = GateAST._Unary.new()
		u.at(t.line, t.col)
		u.op = "not"
		u.operand = _parse_not()
		return u
	return _parse_content_test()

const CMP_OPS := ["==", "!=", "<", ">", "<=", ">="]


func _parse_content_test() -> GateAST._Expr:
	var left: GateAST._Expr = _parse_comparison()
	while true:
		if _check_kw("in"):
			var t: GateLexer._Token = _advance()
			left = _mk_binary("in", left, _parse_comparison(), t)
			continue
		if _check_kw("not") and _peek(1).is_kw("in"):
			var t2: GateLexer._Token = _advance()
			_advance()
			left = _mk_binary("not in", left, _parse_comparison(), t2)
			continue
		break
	return left

## Left-associative, as in GDScript. There is no comparison chaining: `a == b == c`
## is `(a == b) == c`, which is legal and useful when `c` is a bool.
func _parse_comparison() -> GateAST._Expr:
	var left: GateAST._Expr = _parse_bitor()
	while _check(GateLexer._T.OP) and _cur().value in CMP_OPS:
		var t: GateLexer._Token = _advance()
		left = _mk_binary(t.value, left, _parse_bitor(), t)
	return left

## `is` sits at PREC_TYPE_TEST, between `**` and `await`. It binds tighter than
## every arithmetic, bitwise and shift operator, not merely tighter than
## comparison. Verified against Godot 4.7.2:
##
##   "%s" % V is int  ->  "%s" % (V is int)  ->  "true"
func _parse_type_test() -> GateAST._Expr:
	var operand: GateAST._Expr = _parse_await_level()
	while _check_kw("is"):
		var t: GateLexer._Token = _advance()
		var ise: GateAST._IsExpr = GateAST._IsExpr.new()
		ise.at(t.line, t.col)
		if _check_kw("not"):
			_advance()
			ise.negated = true
		ise.operand = operand
		ise.type = _parse_tested_type("is")
		operand = ise
	return operand


func _mk_binary(op: String, l: GateAST._Expr, r: GateAST._Expr, t: GateLexer._Token) -> GateAST._Binary:
	var b: GateAST._Binary = GateAST._Binary.new()
	b.at(t.line, t.col)
	b.op = op
	b.left = l
	b.right = r
	return b


func _parse_bitor() -> GateAST._Expr:
	var l: GateAST._Expr = _parse_bitxor()
	while _check_op("|"):
		var t: GateLexer._Token = _advance()
		l = _mk_binary("|", l, _parse_bitxor(), t)
	return l


func _parse_bitxor() -> GateAST._Expr:
	var l: GateAST._Expr = _parse_bitand()
	while _check_op("^"):
		var t: GateLexer._Token = _advance()
		l = _mk_binary("^", l, _parse_bitand(), t)
	return l


func _parse_bitand() -> GateAST._Expr:
	var l: GateAST._Expr = _parse_shift()
	while _check_op("&"):
		var t: GateLexer._Token = _advance()
		l = _mk_binary("&", l, _parse_shift(), t)
	return l


func _parse_shift() -> GateAST._Expr:
	var l: GateAST._Expr = _parse_additive()
	while _check_op("<<") or _check_op(">>"):
		var t: GateLexer._Token = _advance()
		l = _mk_binary(t.value, l, _parse_additive(), t)
	return l


func _parse_additive() -> GateAST._Expr:
	var l: GateAST._Expr = _parse_multiplicative()
	while (_check_op("+") or _check_op("-")) and _continues_line():
		var t: GateLexer._Token = _advance()
		l = _mk_binary(t.value, l, _parse_multiplicative(), t)
	return l


func _parse_multiplicative() -> GateAST._Expr:
	var l: GateAST._Expr = _parse_unary()
	while (_check_op("*") or _check_op("/") or _check_op("%")) and _continues_line():
		var t: GateLexer._Token = _advance()
		l = _mk_binary(t.value, l, _parse_unary(), t)
	return l


func _is_adjacent(a: GateLexer._Token, b: GateLexer._Token) -> bool:
	return a.line == b.line and b.col == a.col + a.value.length()


func _parse_unary() -> GateAST._Expr:
	if _check_kw("not") or _check_op("!"):
		var nt: GateLexer._Token = _advance()
		var nu: GateAST._Unary = GateAST._Unary.new()
		nu.at(nt.line, nt.col)
		nu.op = "not"
		nu.operand = _parse_content_test()
		return nu
	if _check_op("-") or _check_op("+") or _check_op("~"):
		var t: GateLexer._Token = _advance()
		if (t.value != "~" and _check(GateLexer._T.NUMBER)
				and _peek(1).is_op("**") and _is_adjacent(t, _cur())):
			var num: GateLexer._Token = _advance()
			var lit: GateAST._Literal = GateAST._Literal.new()
			lit.at(t.line, t.col)
			lit.raw = t.value + num.value
			var base: GateAST._Expr = lit
			while _check_op("**"):
				var pt: GateLexer._Token = _advance()
				base = _mk_binary("**", base, _parse_power_operand(), pt)
			return base
		var u: GateAST._Unary = GateAST._Unary.new()
		u.at(t.line, t.col)
		u.op = t.value
		u.tight = _check(GateLexer._T.NUMBER) and _is_adjacent(t, _cur())
		u.operand = _parse_unary()
		return u
	return _parse_power()


func _parse_power() -> GateAST._Expr:
	var base: GateAST._Expr = _parse_type_test()
	while _check_op("**"):
		var t: GateLexer._Token = _advance()
		base = _mk_binary("**", base, _parse_power_operand(), t)
	return base


func _parse_power_operand() -> GateAST._Expr:
	if _check_kw("not") or _check_op("!"):
		var nt: GateLexer._Token = _advance()
		var nu: GateAST._Unary = GateAST._Unary.new()
		nu.at(nt.line, nt.col)
		nu.op = "not"
		nu.operand = _parse_content_test()
		return nu
	if _check_op("-") or _check_op("+") or _check_op("~"):
		var t: GateLexer._Token = _advance()
		var u: GateAST._Unary = GateAST._Unary.new()
		u.at(t.line, t.col)
		u.op = t.value
		u.operand = _parse_power_operand()
		return u
	return _parse_type_test()


func _parse_await_level() -> GateAST._Expr:
	if _check_kw("await"):
		var t: GateLexer._Token = _advance()
		var a: GateAST._AwaitExpr = GateAST._AwaitExpr.new()
		a.at(t.line, t.col)
		a.operand = _parse_await_level()
		return a
	return _parse_postfix()

## `as` binds looser than everything except assignment, and left-associatively.
## Verified against Godot 4.7.2:
##
##   1 == 1 as int  ->  (1 == 1) as int  ->  1
func _parse_cast() -> GateAST._Expr:
	var e: GateAST._Expr = _parse_ternary()
	if not _check_kw("as"):
		return e
	while _check_kw("as"):
		var t: GateLexer._Token = _advance()
		var c: GateAST._CastExpr = GateAST._CastExpr.new()
		c.at(t.line, t.col)
		c.operand = e
		c.type = _parse_tested_type("as")
		e = c
		e = _parse_cast_tail(e)
	return e


func _if_opens_a_block() -> bool:
	var depth: int = 0
	var i: int = _i + 1
	while i < _toks.size():
		var t: GateLexer._Token = _toks[i]
		if t.type == GateLexer._T.OP:
			if t.value in ["(", "[", "{"]:
				depth += 1
			elif t.value in [")", "]", "}"]:
				if depth == 0:
					return false
				depth -= 1
			elif t.value == ":" and depth == 0:
				return true
		elif t.is_kw("else") and depth == 0:
			return false
		elif t.type == GateLexer._T.NEWLINE or t.type == GateLexer._T.EOF:
			return false
		i += 1
	return false


func _parse_cast_tail(e: GateAST._Expr) -> GateAST._Expr:
	while true:
		var before: GateAST._Expr = e
		if _check_kw("is"):
			var it: GateLexer._Token = _advance()
			var ise: GateAST._IsExpr = GateAST._IsExpr.new()
			ise.at(it.line, it.col)
			if _check_kw("not"):
				_advance()
				ise.negated = true
			ise.operand = e
			ise.type = _parse_tested_type("is")
			e = ise
			continue
		e = _parse_binary_tail(e, 1)
		if _check_op("??"):
			var qt: GateLexer._Token = _advance()
			var nc: GateAST._NullCoalesce = GateAST._NullCoalesce.new()
			nc.at(qt.line, qt.col)
			nc.left = e
			nc.right = _parse_or()
			e = nc
			continue
		if _in_inline_lambda > 0 and _check_kw("if") and _if_opens_a_block():
			break
		if _check_kw("if"):
			_advance()
			var tern: GateAST._Ternary = GateAST._Ternary.new()
			tern.at(e.line, e.col)
			tern.if_true = e
			tern.cond = _parse_ternary()
			if _match_kw("else"):
				tern.if_false = _parse_ternary()
			else:
				_err("expected 'else' in a ternary expression")
			e = tern
			continue
		if e == before:
			break
	return e

const BINARY_PREC := {
	"or": 1, "and": 2,
	"in": 4, "not in": 4,
	"==": 5, "!=": 5, "<": 5, ">": 5, "<=": 5, ">=": 5,
	"|": 6, "^": 7, "&": 8,
	"<<": 9, ">>": 9,
	"+": 10, "-": 10,
	"*": 11, "/": 11, "%": 11,
	"**": 13,
}


func _binary_op_here() -> String:
	var t: GateLexer._Token = _cur()
	if t.type == GateLexer._T.OP and BINARY_PREC.has(t.value):
		return t.value
	if t.is_kw("and") or t.is_kw("or") or t.is_kw("in"):
		return t.value
	if t.is_kw("not") and _peek(1).is_kw("in"):
		return "not in"
	return ""


func _parse_binary_tail(lhs: GateAST._Expr, min_prec: int) -> GateAST._Expr:
	while true:
		var op: String = _binary_op_here()
		if op == "" or int(BINARY_PREC[op]) < min_prec:
			break
		var t: GateLexer._Token = _advance()
		if op == "not in":
			_advance()
		var rhs: GateAST._Expr = _parse_unary()
		while true:
			var op2: String = _binary_op_here()
			if op2 == "" or int(BINARY_PREC[op2]) <= int(BINARY_PREC[op]):
				break
			rhs = _parse_binary_tail(rhs, int(BINARY_PREC[op2]))
		lhs = _mk_binary(op, lhs, rhs, t)
	return lhs


func _parse_postfix() -> GateAST._Expr:
	var e: GateAST._Expr = _parse_primary()
	while true:
		if (_check_op("(") or _check_op("[")) and not _continues_line():
			break
		if _check_op("."):
			var t: GateLexer._Token = _advance()
			var m: GateAST._Member = GateAST._Member.new()
			m.at(t.line, t.col)
			m.target = e
			if _check(GateLexer._T.IDENT) or _check(GateLexer._T.KEYWORD):
				m.name = _advance().value
			e = m
		elif _check_op("?."):
			var t2: GateLexer._Token = _advance()
			var m2: GateAST._Member = GateAST._Member.new()
			m2.at(t2.line, t2.col)
			m2.target = e
			m2.safe = true
			if _check(GateLexer._T.IDENT) or _check(GateLexer._T.KEYWORD):
				m2.name = _advance().value
			e = m2
		elif _check_op("["):
			var t3: GateLexer._Token = _advance()
			var ix: GateAST._Index = GateAST._Index.new()
			ix.at(t3.line, t3.col)
			ix.target = e
			_skip_newlines()
			ix.index = _parse_expr()
			_skip_newlines()
			_expect_op("]", "to close the index")
			e = ix
		elif _check_op("?["):
			var t4: GateLexer._Token = _advance()
			var ix2: GateAST._Index = GateAST._Index.new()
			ix2.at(t4.line, t4.col)
			ix2.target = e
			ix2.safe = true
			_skip_newlines()
			ix2.index = _parse_expr()
			_skip_newlines()
			_expect_op("]", "to close the index")
			e = ix2
		elif _check_op("("):
			var t5: GateLexer._Token = _advance()
			var c: GateAST._Call = GateAST._Call.new()
			c.at(t5.line, t5.col)
			c.callee = e
			_skip_newlines()
			while not _at_end() and not _check_op(")"):
				_skip_newlines()
				if _check_op(")"): break
				c.args.append(_parse_expr())
				_skip_newlines()
				if not _match_op(","):
					break
				_skip_newlines()
			_expect_op(")", "to close the call")
			e = c
		elif _check_op("{") and e is GateAST._Ident and _is_type_looking((e as GateAST._Ident).name):
			var t6: GateLexer._Token = _advance()
			var cname: String = (e as GateAST._Ident).name
			var first_key: String = ""
			var depth: int = 1
			while not _at_end():
				var bt: GateLexer._Token = _cur()
				if bt.type == GateLexer._T.OP and bt.value == "{":
					depth += 1
				elif bt.type == GateLexer._T.OP and bt.value == "}":
					depth -= 1
					if depth == 0:
						_advance()
						break
				elif first_key == "" and depth == 1 and bt.type == GateLexer._T.IDENT:
					first_key = bt.value
				_advance()
			diagnostics.error(
				"%s { … } initializers were removed; write %s.new({ %s: … })"
					% [cname, cname, first_key if first_key != "" else "name"],
				t6.line, t6.col,
				"keys are written name: value inside the argument. A struct is built "
				+ "the same way without .new: %s({ %s: … })."
					% [cname, first_key if first_key != "" else "name"])
		else:
			break
	return e


func _parse_primary() -> GateAST._Expr:
	var t: GateLexer._Token = _cur()

	if t.type == GateLexer._T.NUMBER:
		_advance()
		var l: GateAST._Literal = GateAST._Literal.new()
		l.at(t.line, t.col); l.raw = t.value; l.kind = "number"
		return l
	if t.type == GateLexer._T.STRING:
		_advance()
		var s: GateAST._Literal = GateAST._Literal.new()
		s.at(t.line, t.col)
		s.raw = t.prefix + t.extra + t.value + t.extra
		s.kind = "string"
		return s
	if t.type == GateLexer._T.FSTRING:
		_advance()
		return _build_fstring(t)
	if t.type == GateLexer._T.NODEPATH:
		_advance()
		var np: GateAST._NodePathExpr = GateAST._NodePathExpr.new()
		np.at(t.line, t.col); np.raw = t.value
		return np
	if t.type == GateLexer._T.ANNOTATION:
		_advance()
		var ai: GateAST._Ident = GateAST._Ident.new()
		ai.at(t.line, t.col); ai.name = t.value
		return ai
	if t.is_kw("true") or t.is_kw("false"):
		_advance()
		var b: GateAST._Literal = GateAST._Literal.new()
		b.at(t.line, t.col); b.raw = t.value; b.kind = "bool"
		return b
	if t.is_kw("null"):
		_advance()
		var n: GateAST._Literal = GateAST._Literal.new()
		n.at(t.line, t.col); n.raw = "null"; n.kind = "null"
		return n
	if t.is_kw("self"):
		_advance()
		var se: GateAST._SelfExpr = GateAST._SelfExpr.new()
		se.at(t.line, t.col)
		return se
	if t.is_kw("super") or t.is_kw("preload") or t.is_kw("assert") or t.is_kw("is") or t.is_kw("in"):
		_advance()
		var kid: GateAST._Ident = GateAST._Ident.new()
		kid.at(t.line, t.col); kid.name = t.value
		return kid
	if t.type == GateLexer._T.IDENT:
		if _qualified_generic_ahead():
			var qual: GateLexer._Token = _advance()   # the namespace or class
			_advance()                               # '.'
			t = _cur()
			_err("a generic is instantiated by its own name, not through '%s'" % qual.value,
				"write `%s<...>`: a namespace qualifies the plain classes and structs it holds, "
					% t.value + "but a generic, an interface and a trait take the direct name")
		if _check_generic_instantiation():
			_advance()
			_split_generic_span(_i)
			var gtype: GateAST._TypeRef = GateAST._TypeRef.new()
			gtype.at(t.line, t.col)
			gtype.name = t.value
			_advance()  # '<'
			while not _at_end() and not _check_op(">"):
				gtype.generic_args.append(_parse_type())
				if not _match_op(","):
					break
			_expect_op(">", "to close generic arguments")
			_generic_uses.append(gtype)
			var gid: GateAST._Ident = GateAST._Ident.new()
			gid.at(t.line, t.col)
			gid.name = mangle_generic(gtype)
			gid.generic_base = gtype.name
			gid.generic_type = gtype
			return gid
		_advance()
		var id: GateAST._Ident = GateAST._Ident.new()
		id.at(t.line, t.col); id.name = t.value
		return id
	if t.is_op("("):
		_advance()
		_skip_newlines()
		var inner: GateAST._Expr = _parse_expr()
		_skip_newlines()
		_expect_op(")", "to close the group")
		return inner
	if t.is_op("["):
		_advance()
		var arr: GateAST._ArrayLit = GateAST._ArrayLit.new()
		arr.at(t.line, t.col)
		_skip_newlines()
		while not _at_end() and not _check_op("]"):
			_skip_newlines()
			if _check_op("]"): break
			arr.elements.append(_parse_expr())
			_skip_newlines()
			if not _match_op(","):
				break
			_skip_newlines()
		_expect_op("]", "to close the array literal")
		return arr
	if t.is_op("{"):
		_advance()
		var d: GateAST._DictLit = GateAST._DictLit.new()
		d.at(t.line, t.col)
		_skip_newlines()
		while not _at_end() and not _check_op("}"):
			_skip_newlines()
			if _check_op("}"): break
			var k: GateAST._Expr = _parse_expr()
			if _match_op(":"):
				d.keys.append(k)
				d.lua_keys.append(false)
				_skip_newlines()
				d.values.append(_parse_expr())
			elif _match_op("="):
				d.keys.append(k)
				d.lua_keys.append(true)
				_skip_newlines()
				d.values.append(_parse_expr())
			else:
				d.keys.append(k)
				d.lua_keys.append(false)
				d.values.append(null)
			_skip_newlines()
			if not _match_op(","):
				break
			_skip_newlines()
		_expect_op("}", "to close the dictionary literal")
		return d
	if t.is_kw("func"):
		return _parse_lambda()

	if t.type == GateLexer._T.KEYWORD and (GateLexer.is_gate_only_keyword(t.value)
			or GateLexer.is_contextual_keyword(t.value)):
		_advance()
		var kid: GateAST._Ident = GateAST._Ident.new()
		kid.at(t.line, t.col)
		kid.name = t.value
		return kid

	_err("unexpected token '%s'" % t.value)
	_advance()
	var re: GateAST._RawExpr = GateAST._RawExpr.new()
	re.at(t.line, t.col)
	re.text = t.value
	return re


func _parse_lambda() -> GateAST._Expr:
	var kw: GateLexer._Token = _advance()
	var lam: GateAST._Lambda = GateAST._Lambda.new()
	lam.at(kw.line, kw.col)
	if _check(GateLexer._T.IDENT):
		lam.name = _advance().value  # optional lambda name
	_expect_op("(", "in a lambda")
	lam.params = _parse_params()
	_expect_op(")", "to close the lambda parameters")
	if _match_op("->"):
		lam.return_type = _parse_type()
	var colon: GateLexer._Token = _cur()
	_expect_op(":", "before the lambda body")
	if _check(GateLexer._T.COMMENT):
		_advance()
	if _check(GateLexer._T.NEWLINE):
		lam.body = _parse_block(false)
		lam.block_body = true
	else:
		var limit: int = colon.line if _cur().line == colon.line else 0
		lam.body = _parse_lambda_inline_body(limit)
	return lam


func _build_fstring(t: GateLexer._Token) -> GateAST._Expr:
	var fs: GateAST._FString = GateAST._FString.new()
	fs.at(t.line, t.col)
	fs.quote = t.extra
	var body: String = t.value
	var buf: String = ""
	var i: int = 0
	while i < body.length():
		var c: String = body[i]
		if c == "{":
			if i + 1 < body.length() and body[i + 1] == "{":
				buf += "{"
				i += 2
				continue
			if buf != "":
				fs.parts.append(buf)
				buf = ""
			var j: int = _placeholder_end(body, i + 1)
			if j < 0:
				diagnostics.error("this f-string placeholder is never closed", t.line, t.col,
					"write `{{` and `}}` for braces in the text. A quote of the same kind as the "
					+ "f-string's own must be escaped inside a placeholder")
				return fs
			var inner: String = body.substr(i + 1, j - i - 1).strip_edges()
			if inner == "":
				diagnostics.error("this f-string placeholder has no expression", t.line, t.col,
					"write `{{}}` for a literal pair of braces")
			else:
				fs.parts.append(_parse_subexpression(_unescape_quotes(inner, fs.quote), t.line))
			i = j + 1
			continue
		if c == "}" and i + 1 < body.length() and body[i + 1] == "}":
			buf += "}"
			i += 2
			continue
		buf += c
		i += 1
	if buf != "":
		fs.parts.append(buf)
	return fs


static func _unescape_quotes(src: String, quote: String) -> String:
	if not src.contains("\\"):
		return src
	var q: String = quote.substr(0, 1)
	var out: String = ""
	var i: int = 0
	while i < src.length():
		var c: String = src[i]
		if c != "\\" or i + 1 >= src.length():
			out += c
			i += 1
			continue
		var nxt: String = src[i + 1]
		out += nxt if (nxt == q or nxt == "\\") else c + nxt
		i += 2
	return out


static func _placeholder_end(body: String, from: int) -> int:
	var depth: int = 1
	var i: int = from
	while i < body.length():
		var c: String = body[i]
		if c == "\\" and i + 1 < body.length() and (body[i + 1] == "\"" or body[i + 1] == "'"):
			i = _escaped_string_end(body, i)
			if i < 0:
				return -1
			continue
		if c == "\\":
			i += 2
			continue
		if c == "\"" or c == "'":
			i = _string_end(body, i)
			if i < 0:
				return -1
			continue
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				return i
		i += 1
	return -1


static func _string_end(body: String, i: int) -> int:
	var quote: String = body[i]
	var j: int = i + 1
	while j < body.length():
		if body[j] == "\\":
			j += 2
			continue
		if body[j] == quote:
			return j + 1
		j += 1
	return -1


static func _escaped_string_end(body: String, i: int) -> int:
	var quote: String = body[i + 1]
	var j: int = i + 2
	while j < body.length():
		if body[j] != "\\" or j + 1 >= body.length():
			j += 1
			continue
		if body[j + 1] == quote:
			return j + 2
		j += 2
	return -1


func _parse_subexpression(src: String, line: int) -> GateAST._Expr:
	var lx: GateLexer = GateLexer.new()
	var sub_diags: GateDiagnostics = GateDiagnostics.new()
	sub_diags.file = diagnostics.file
	var toks: Array[GateLexer._Token] = lx.tokenize(src, sub_diags)
	var p: GateParser = GateParser.new()
	p.diagnostics = sub_diags
	p._toks = toks
	p._i = 0
	if src.contains("<") and not _names_scanned:
		_names_scanned = true
		_prescan_names()
	p._names_scanned = true
	p._generic_names = _generics_at(_i)
	p._templates_scanned = true
	p._templates = p._generic_names
	p._alias_names = _alias_names
	p._lines = PackedStringArray([src])
	var e: GateAST._Expr = p._parse_expr()
	for d in sub_diags.items:
		d.line = line
		diagnostics.items.append(d)
	if e == null:
		var re: GateAST._RawExpr = GateAST._RawExpr.new()
		re.text = src
		return re
	return e


func _parse_params() -> Array:
	var out: Array = []
	_skip_newlines()
	while not _at_end() and not _check_op(")"):
		_skip_newlines()
		if _check_op(")"):
			break
		var p: GateAST._Param = GateAST._Param.new()
		if _match_op("..."):
			p.is_rest = true
		if not (_check(GateLexer._T.IDENT) or _check(GateLexer._T.KEYWORD)):
			break
		var nt: GateLexer._Token = _advance()
		p.name = nt.value
		p.at(nt.line, nt.col)
		if _check_op(":"):
			_advance()
			if _check_op("="):
				p.inferred = true
			elif not _check_op(")") and not _check_op(","):
				p.type = _parse_type()
		if _check_op(":="):
			_advance()
			p.inferred = true
			p.default = _parse_expr()
		elif _match_op("="):
			p.default = _parse_expr()
		out.append(p)
		_skip_newlines()
		if not _match_op(","):
			break
		_skip_newlines()
	return out

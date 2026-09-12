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


func _parse_expr() -> GateAST.Expr:
	if _expr_depth >= MAX_EXPR_DEPTH:
		var t: GateLexer.Token = _cur()
		if not _depth_reported:
			diagnostics.error(
				"expression nests more than %d levels deep" % MAX_EXPR_DEPTH, t.line, t.col,
				"GATE's parser is written in GDScript and recurses once per level, so it "
				+ "runs out of stack well before Godot's own parser does. Split the "
				+ "expression into named intermediates.")
			_depth_reported = true
			_panic = true
			diagnostics.seal()
		var bad: GateAST.Literal = GateAST.Literal.new()
		bad.at(t.line, t.col)
		bad.raw = "null"
		return bad
	_expr_depth += 1
	var e: GateAST.Expr = _parse_cast()
	_expr_depth -= 1
	return e


func _parse_ternary() -> GateAST.Expr:
	var e: GateAST.Expr = _parse_coalesce()
	if e is GateAST.Lambda and (e as GateAST.Lambda).block_body:
		return e
	if _in_inline_lambda > 0 and _check_kw("if") and _if_opens_a_block():
		return e
	if _check_kw("if"):
		_advance()
		var t: GateAST.Ternary = GateAST.Ternary.new()
		t.at(e.line, e.col)
		t.if_true = e
		t.cond = _parse_ternary()
		if _match_kw("else"):
			t.if_false = _parse_ternary()
		else:
			_err("expected 'else' in a ternary expression")
		return t
	return e


func _parse_coalesce() -> GateAST.Expr:
	var left: GateAST.Expr = _parse_or()
	while _check_op("??"):
		var t: GateLexer.Token = _advance()
		var n: GateAST.NullCoalesce = GateAST.NullCoalesce.new()
		n.at(t.line, t.col)
		n.left = left
		n.right = _parse_or()
		left = n
	return left


func _parse_or() -> GateAST.Expr:
	var left: GateAST.Expr = _parse_and()
	while _check_kw("or") or _check_op("||"):
		var t: GateLexer.Token = _advance()
		left = _mk_binary("or", left, _parse_and(), t)
	return left


func _parse_and() -> GateAST.Expr:
	var left: GateAST.Expr = _parse_not()
	while _check_kw("and") or _check_op("&&"):
		var t: GateLexer.Token = _advance()
		left = _mk_binary("and", left, _parse_not(), t)
	return left


func _parse_not() -> GateAST.Expr:
	if _check_kw("not") or _check_op("!"):
		var t: GateLexer.Token = _advance()
		var u: GateAST.Unary = GateAST.Unary.new()
		u.at(t.line, t.col)
		u.op = "not"
		u.operand = _parse_not()
		return u
	return _parse_content_test()

const CMP_OPS := ["==", "!=", "<", ">", "<=", ">="]


func _parse_content_test() -> GateAST.Expr:
	var left: GateAST.Expr = _parse_comparison()
	while true:
		if _check_kw("in"):
			var t: GateLexer.Token = _advance()
			left = _mk_binary("in", left, _parse_comparison(), t)
			continue
		if _check_kw("not") and _peek(1).is_kw("in"):
			var t2: GateLexer.Token = _advance()
			_advance()
			left = _mk_binary("not in", left, _parse_comparison(), t2)
			continue
		break
	return left

## Left-associative, as in GDScript. There is no comparison chaining: `a == b == c`
## is `(a == b) == c`, which is legal and useful when `c` is a bool.
func _parse_comparison() -> GateAST.Expr:
	var left: GateAST.Expr = _parse_bitor()
	while _check(GateLexer.T.OP) and _cur().value in CMP_OPS:
		var t: GateLexer.Token = _advance()
		left = _mk_binary(t.value, left, _parse_bitor(), t)
	return left

## `is` sits at PREC_TYPE_TEST, between `**` and `await`. It binds tighter than
## every arithmetic, bitwise and shift operator, not merely tighter than
## comparison. Verified against Godot 4.7.2:
##
##   "%s" % V is int  ->  "%s" % (V is int)  ->  "true"
func _parse_type_test() -> GateAST.Expr:
	var operand: GateAST.Expr = _parse_await_level()
	while _check_kw("is"):
		var t: GateLexer.Token = _advance()
		var ise: GateAST.IsExpr = GateAST.IsExpr.new()
		ise.at(t.line, t.col)
		if _check_kw("not"):
			_advance()
			ise.negated = true
		ise.operand = operand
		ise.type = _parse_tested_type("is")
		operand = ise
	return operand


func _mk_binary(op: String, l: GateAST.Expr, r: GateAST.Expr, t: GateLexer.Token) -> GateAST.Binary:
	var b: GateAST.Binary = GateAST.Binary.new()
	b.at(t.line, t.col)
	b.op = op
	b.left = l
	b.right = r
	return b


func _parse_bitor() -> GateAST.Expr:
	var l: GateAST.Expr = _parse_bitxor()
	while _check_op("|"):
		var t: GateLexer.Token = _advance()
		l = _mk_binary("|", l, _parse_bitxor(), t)
	return l


func _parse_bitxor() -> GateAST.Expr:
	var l: GateAST.Expr = _parse_bitand()
	while _check_op("^"):
		var t: GateLexer.Token = _advance()
		l = _mk_binary("^", l, _parse_bitand(), t)
	return l


func _parse_bitand() -> GateAST.Expr:
	var l: GateAST.Expr = _parse_shift()
	while _check_op("&"):
		var t: GateLexer.Token = _advance()
		l = _mk_binary("&", l, _parse_shift(), t)
	return l


func _parse_shift() -> GateAST.Expr:
	var l: GateAST.Expr = _parse_additive()
	while _check_op("<<") or _check_op(">>"):
		var t: GateLexer.Token = _advance()
		l = _mk_binary(t.value, l, _parse_additive(), t)
	return l


func _parse_additive() -> GateAST.Expr:
	var l: GateAST.Expr = _parse_multiplicative()
	while (_check_op("+") or _check_op("-")) and _continues_line():
		var t: GateLexer.Token = _advance()
		l = _mk_binary(t.value, l, _parse_multiplicative(), t)
	return l


func _parse_multiplicative() -> GateAST.Expr:
	var l: GateAST.Expr = _parse_unary()
	while (_check_op("*") or _check_op("/") or _check_op("%")) and _continues_line():
		var t: GateLexer.Token = _advance()
		l = _mk_binary(t.value, l, _parse_unary(), t)
	return l


func _is_adjacent(a: GateLexer.Token, b: GateLexer.Token) -> bool:
	return a.line == b.line and b.col == a.col + a.value.length()


func _parse_unary() -> GateAST.Expr:
	if _check_kw("not") or _check_op("!"):
		var nt: GateLexer.Token = _advance()
		var nu: GateAST.Unary = GateAST.Unary.new()
		nu.at(nt.line, nt.col)
		nu.op = "not"
		nu.operand = _parse_content_test()
		return nu
	if _check_op("-") or _check_op("+") or _check_op("~"):
		var t: GateLexer.Token = _advance()
		if (t.value != "~" and _check(GateLexer.T.NUMBER)
				and _peek(1).is_op("**") and _is_adjacent(t, _cur())):
			var num: GateLexer.Token = _advance()
			var lit: GateAST.Literal = GateAST.Literal.new()
			lit.at(t.line, t.col)
			lit.raw = t.value + num.value
			var base: GateAST.Expr = lit
			while _check_op("**"):
				var pt: GateLexer.Token = _advance()
				base = _mk_binary("**", base, _parse_power_operand(), pt)
			return base
		var u: GateAST.Unary = GateAST.Unary.new()
		u.at(t.line, t.col)
		u.op = t.value
		u.tight = _check(GateLexer.T.NUMBER) and _is_adjacent(t, _cur())
		u.operand = _parse_unary()
		return u
	return _parse_power()


func _parse_power() -> GateAST.Expr:
	var base: GateAST.Expr = _parse_type_test()
	while _check_op("**"):
		var t: GateLexer.Token = _advance()
		base = _mk_binary("**", base, _parse_power_operand(), t)
	return base


func _parse_power_operand() -> GateAST.Expr:
	if _check_kw("not") or _check_op("!"):
		var nt: GateLexer.Token = _advance()
		var nu: GateAST.Unary = GateAST.Unary.new()
		nu.at(nt.line, nt.col)
		nu.op = "not"
		nu.operand = _parse_content_test()
		return nu
	if _check_op("-") or _check_op("+") or _check_op("~"):
		var t: GateLexer.Token = _advance()
		var u: GateAST.Unary = GateAST.Unary.new()
		u.at(t.line, t.col)
		u.op = t.value
		u.operand = _parse_power_operand()
		return u
	return _parse_type_test()


func _parse_await_level() -> GateAST.Expr:
	if _check_kw("await"):
		var t: GateLexer.Token = _advance()
		var a: GateAST.AwaitExpr = GateAST.AwaitExpr.new()
		a.at(t.line, t.col)
		a.operand = _parse_await_level()
		return a
	return _parse_postfix()

## `as` binds looser than everything except assignment, and left-associatively.
## Verified against Godot 4.7.2:
##
##   1 == 1 as int  ->  (1 == 1) as int  ->  1
func _parse_cast() -> GateAST.Expr:
	var e: GateAST.Expr = _parse_ternary()
	if not _check_kw("as"):
		return e
	while _check_kw("as"):
		var t: GateLexer.Token = _advance()
		var c: GateAST.CastExpr = GateAST.CastExpr.new()
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
		var t: GateLexer.Token = _toks[i]
		if t.type == GateLexer.T.OP:
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
		elif t.type == GateLexer.T.NEWLINE or t.type == GateLexer.T.EOF:
			return false
		i += 1
	return false


func _parse_cast_tail(e: GateAST.Expr) -> GateAST.Expr:
	while true:
		var before: GateAST.Expr = e
		if _check_kw("is"):
			var it: GateLexer.Token = _advance()
			var ise: GateAST.IsExpr = GateAST.IsExpr.new()
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
			var qt: GateLexer.Token = _advance()
			var nc: GateAST.NullCoalesce = GateAST.NullCoalesce.new()
			nc.at(qt.line, qt.col)
			nc.left = e
			nc.right = _parse_or()
			e = nc
			continue
		if _in_inline_lambda > 0 and _check_kw("if") and _if_opens_a_block():
			break
		if _check_kw("if"):
			_advance()
			var tern: GateAST.Ternary = GateAST.Ternary.new()
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
	var t: GateLexer.Token = _cur()
	if t.type == GateLexer.T.OP and BINARY_PREC.has(t.value):
		return t.value
	if t.is_kw("and") or t.is_kw("or") or t.is_kw("in"):
		return t.value
	if t.is_kw("not") and _peek(1).is_kw("in"):
		return "not in"
	return ""


func _parse_binary_tail(lhs: GateAST.Expr, min_prec: int) -> GateAST.Expr:
	while true:
		var op: String = _binary_op_here()
		if op == "" or int(BINARY_PREC[op]) < min_prec:
			break
		var t: GateLexer.Token = _advance()
		if op == "not in":
			_advance()
		var rhs: GateAST.Expr = _parse_unary()
		while true:
			var op2: String = _binary_op_here()
			if op2 == "" or int(BINARY_PREC[op2]) <= int(BINARY_PREC[op]):
				break
			rhs = _parse_binary_tail(rhs, int(BINARY_PREC[op2]))
		lhs = _mk_binary(op, lhs, rhs, t)
	return lhs


func _parse_postfix() -> GateAST.Expr:
	var e: GateAST.Expr = _parse_primary()
	while true:
		if (_check_op("(") or _check_op("[")) and not _continues_line():
			break
		if _check_op("."):
			var t: GateLexer.Token = _advance()
			var m: GateAST.Member = GateAST.Member.new()
			m.at(t.line, t.col)
			m.target = e
			if _check(GateLexer.T.IDENT) or _check(GateLexer.T.KEYWORD):
				m.name = _advance().value
			e = m
		elif _check_op("?."):
			var t2: GateLexer.Token = _advance()
			var m2: GateAST.Member = GateAST.Member.new()
			m2.at(t2.line, t2.col)
			m2.target = e
			m2.safe = true
			if _check(GateLexer.T.IDENT) or _check(GateLexer.T.KEYWORD):
				m2.name = _advance().value
			e = m2
		elif _check_op("["):
			var t3: GateLexer.Token = _advance()
			var ix: GateAST.Index = GateAST.Index.new()
			ix.at(t3.line, t3.col)
			ix.target = e
			_skip_newlines()
			ix.index = _parse_expr()
			_skip_newlines()
			_expect_op("]", "to close the index")
			e = ix
		elif _check_op("?["):
			var t4: GateLexer.Token = _advance()
			var ix2: GateAST.Index = GateAST.Index.new()
			ix2.at(t4.line, t4.col)
			ix2.target = e
			ix2.safe = true
			_skip_newlines()
			ix2.index = _parse_expr()
			_skip_newlines()
			_expect_op("]", "to close the index")
			e = ix2
		elif _check_op("("):
			var t5: GateLexer.Token = _advance()
			var c: GateAST.Call = GateAST.Call.new()
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
		elif _check_op("{") and e is GateAST.Ident and _is_type_looking((e as GateAST.Ident).name):
			var t6: GateLexer.Token = _advance()
			var oi: GateAST.ObjectInit = GateAST.ObjectInit.new()
			oi.at(t6.line, t6.col)
			var tr: GateAST.TypeRef = GateAST.TypeRef.new()
			tr.name = (e as GateAST.Ident).name
			oi.type = tr
			_skip_newlines()
			while not _at_end() and not _check_op("}"):
				_skip_newlines()
				if not _check(GateLexer.T.IDENT):
					break
				oi.keys.append(_advance().value)
				_expect_op("=", "in an object initializer")
				oi.values.append(_parse_expr())
				_skip_newlines()
				if not _match_op(","):
					break
				_skip_newlines()
			_expect_op("}", "to close the object initializer")
			e = oi
		else:
			break
	return e


func _parse_primary() -> GateAST.Expr:
	var t: GateLexer.Token = _cur()

	if t.type == GateLexer.T.NUMBER:
		_advance()
		var l: GateAST.Literal = GateAST.Literal.new()
		l.at(t.line, t.col); l.raw = t.value; l.kind = "number"
		return l
	if t.type == GateLexer.T.STRING:
		_advance()
		var s: GateAST.Literal = GateAST.Literal.new()
		s.at(t.line, t.col)
		s.raw = t.prefix + t.extra + t.value + t.extra
		s.kind = "string"
		return s
	if t.type == GateLexer.T.FSTRING:
		_advance()
		return _build_fstring(t)
	if t.type == GateLexer.T.NODEPATH:
		_advance()
		var np: GateAST.NodePathExpr = GateAST.NodePathExpr.new()
		np.at(t.line, t.col); np.raw = t.value
		return np
	if t.type == GateLexer.T.ANNOTATION:
		_advance()
		var ai: GateAST.Ident = GateAST.Ident.new()
		ai.at(t.line, t.col); ai.name = t.value
		return ai
	if t.is_kw("true") or t.is_kw("false"):
		_advance()
		var b: GateAST.Literal = GateAST.Literal.new()
		b.at(t.line, t.col); b.raw = t.value; b.kind = "bool"
		return b
	if t.is_kw("null"):
		_advance()
		var n: GateAST.Literal = GateAST.Literal.new()
		n.at(t.line, t.col); n.raw = "null"; n.kind = "null"
		return n
	if t.is_kw("self"):
		_advance()
		var se: GateAST.SelfExpr = GateAST.SelfExpr.new()
		se.at(t.line, t.col)
		return se
	if t.is_kw("super") or t.is_kw("preload") or t.is_kw("assert") or t.is_kw("is") or t.is_kw("in"):
		_advance()
		var kid: GateAST.Ident = GateAST.Ident.new()
		kid.at(t.line, t.col); kid.name = t.value
		return kid
	if t.type == GateLexer.T.IDENT:
		if _check_generic_instantiation():
			_advance()
			_split_generic_span(_i)
			var gtype: GateAST.TypeRef = GateAST.TypeRef.new()
			gtype.at(t.line, t.col)
			gtype.name = t.value
			_advance()  # '<'
			while not _at_end() and not _check_op(">"):
				gtype.generic_args.append(_parse_type())
				if not _match_op(","):
					break
			_expect_op(">", "to close generic arguments")
			_generic_uses.append(gtype)
			var gid: GateAST.Ident = GateAST.Ident.new()
			gid.at(t.line, t.col)
			gid.name = mangle_generic(gtype)
			gid.generic_base = gtype.name
			return gid
		_advance()
		var id: GateAST.Ident = GateAST.Ident.new()
		id.at(t.line, t.col); id.name = t.value
		return id
	if t.is_op("("):
		_advance()
		_skip_newlines()
		var inner: GateAST.Expr = _parse_expr()
		_skip_newlines()
		_expect_op(")", "to close the group")
		return inner
	if t.is_op("["):
		_advance()
		var arr: GateAST.ArrayLit = GateAST.ArrayLit.new()
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
		var d: GateAST.DictLit = GateAST.DictLit.new()
		d.at(t.line, t.col)
		_skip_newlines()
		while not _at_end() and not _check_op("}"):
			_skip_newlines()
			if _check_op("}"): break
			var k: GateAST.Expr = _parse_expr()
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

	if t.type == GateLexer.T.KEYWORD and (GateLexer.is_gate_only_keyword(t.value)
			or GateLexer.is_contextual_keyword(t.value)):
		_advance()
		var kid: GateAST.Ident = GateAST.Ident.new()
		kid.at(t.line, t.col)
		kid.name = t.value
		return kid

	_err("unexpected token '%s'" % t.value)
	_advance()
	var re: GateAST.RawExpr = GateAST.RawExpr.new()
	re.at(t.line, t.col)
	re.text = t.value
	return re


func _parse_lambda() -> GateAST.Expr:
	var kw: GateLexer.Token = _advance()
	var lam: GateAST.Lambda = GateAST.Lambda.new()
	lam.at(kw.line, kw.col)
	if _check(GateLexer.T.IDENT):
		lam.name = _advance().value  # optional lambda name
	_expect_op("(", "in a lambda")
	lam.params = _parse_params()
	_expect_op(")", "to close the lambda parameters")
	if _match_op("->"):
		lam.return_type = _parse_type()
	var colon: GateLexer.Token = _cur()
	_expect_op(":", "before the lambda body")
	if _check(GateLexer.T.COMMENT):
		_advance()
	if _check(GateLexer.T.NEWLINE):
		lam.body = _parse_block(false)
		lam.block_body = true
	else:
		var limit: int = colon.line if _cur().line == colon.line else 0
		lam.body = _parse_lambda_inline_body(limit)
	return lam


func _build_fstring(t: GateLexer.Token) -> GateAST.Expr:
	var fs: GateAST.FString = GateAST.FString.new()
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
			var depth: int = 1
			var j: int = i + 1
			while j < body.length() and depth > 0:
				if body[j] == "{": depth += 1
				elif body[j] == "}": depth -= 1
				if depth == 0: break
				j += 1
			var inner: String = body.substr(i + 1, j - i - 1)
			fs.parts.append(_parse_subexpression(inner, t.line))
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


func _parse_subexpression(src: String, line: int) -> GateAST.Expr:
	var lx: GateLexer = GateLexer.new()
	var sub_diags: GateDiagnostics = GateDiagnostics.new()
	sub_diags.file = diagnostics.file
	var toks: Array[GateLexer.Token] = lx.tokenize(src, sub_diags)
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
	var e: GateAST.Expr = p._parse_expr()
	for d in sub_diags.items:
		d.line = line
		diagnostics.items.append(d)
	if e == null:
		var re: GateAST.RawExpr = GateAST.RawExpr.new()
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
		var p: GateAST.Param = GateAST.Param.new()
		if _match_op("..."):
			p.is_rest = true
		if not (_check(GateLexer.T.IDENT) or _check(GateLexer.T.KEYWORD)):
			break
		var nt: GateLexer.Token = _advance()
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

@tool
class_name GateInfer
extends "res://addons/gate/compiler/infer_core.gd"

## Interprocedural effect analysis on top of `infer_core.gd`.
##
## A function is summarised as the access paths it can write, relative to its
## receiver and each parameter, so the null analysis invalidates only those.


func build(mod: GateAST.GateModule, registry = null) -> void:
	fields.clear(); methods.clear(); bases.clear(); module_functions.clear()
	if registry != null:
		for k in registry.fields: fields[k] = registry.fields[k]
		for k in registry.methods: methods[k] = registry.methods[k].duplicate()
		for k in registry.bases: bases[k] = registry.bases[k]
	_index(mod.members, MODULE_CLASS)
	if mod.extends_type != null:
		bases[MODULE_CLASS] = mod.extends_type.name
	if mod.class_name_decl != "":
		bases[mod.class_name_decl] = MODULE_CLASS
	for m in mod.members:
		if m is GateAST.GateFuncDecl:
			var fd: GateAST.GateFuncDecl = m
			if not module_functions.has(fd.name):
				module_functions[fd.name] = []
			module_functions[fd.name].append(fd)
	_build_effects()


class GateEffects extends RefCounted:
	var self_paths: Array = []   ## suffixes relative to the receiver
	var param_paths: Dictionary = {}        ## param index -> Array of suffixes

	func add_self(sfx: String) -> bool:
		if sfx == "" or self_paths.has(sfx): return false
		self_paths.append(sfx)
		return true

	func add_param(i: int, sfx: String) -> bool:
		if sfx == "" or i < 0: return false
		if not param_paths.has(i): param_paths[i] = []
		if param_paths[i].has(sfx): return false
		param_paths[i].append(sfx)
		return true

const PURE_GLOBALS := {
	"print": true, "printerr": true, "printraw": true, "printt": true,
	"prints": true, "print_rich": true, "print_debug": true, "push_error": true,
	"push_warning": true, "str": true, "len": true, "typeof": true, "assert": true,
	"is_instance_valid": true, "is_instance_of": true, "hash": true, "weakref": true,
	"var_to_str": true, "str_to_var": true, "instance_from_id": true,
	"abs": true, "absi": true, "absf": true, "sign": true, "signi": true, "signf": true,
	"min": true, "mini": true, "minf": true, "max": true, "maxi": true, "maxf": true,
	"clamp": true, "clampi": true, "clampf": true, "floor": true, "ceil": true,
	"round": true, "roundi": true, "sqrt": true, "pow": true, "range": true,
	"lerp": true, "lerpf": true, "inverse_lerp": true, "snapped": true,
	"deg_to_rad": true, "rad_to_deg": true, "randi": true, "randf": true,
	"randi_range": true, "randf_range": true, "sin": true, "cos": true, "tan": true,
	"atan2": true, "fmod": true, "posmod": true, "is_equal_approx": true,
	"is_zero_approx": true, "nearest_po2": true, "wrapi": true, "wrapf": true,
}

var _fx: Dictionary = {}
var _fx_owner: Dictionary = {}
var _fields_by_class: Dictionary = {}


func effects_of(fd) -> GateEffects:
	return _fx.get(fd, null)

const MAX_EFFECT_PASSES := 12


func _build_effects() -> void:
	_fx.clear(); _fx_owner.clear(); _fields_by_class.clear()

	for k in fields:
		var fkey: String = String(k)
		var fdot: int = fkey.rfind(".")
		if fdot <= 0:
			continue
		var fcls: String = fkey.substr(0, fdot)
		if not _fields_by_class.has(fcls):
			_fields_by_class[fcls] = {}
		_fields_by_class[fcls][fkey.substr(fdot + 1)] = true

	for k2 in methods:
		var mkey: String = String(k2)
		var mdot: int = mkey.rfind(".")
		if mdot <= 0:
			continue
		var mcls: String = mkey.substr(0, mdot)
		for f in methods[k2]:
			_fx_owner[f] = mcls
			_fx[f] = GateEffects.new()
	for n in module_functions:
		for f2 in module_functions[n]:
			if not _fx.has(f2):
				_fx_owner[f2] = ""
				_fx[f2] = GateEffects.new()

	var limit: int = maxi(MAX_EFFECT_PASSES, _fx.size() + 1)
	var still_moving: Dictionary = {}
	for _pass in limit:
		still_moving = {}
		for f3 in _fx:
			if _scan_effects(f3):
				still_moving[f3] = true
		if still_moving.is_empty():
			return
	_widen_effects(still_moving)


func _widen_effects(which: Dictionary) -> void:
	for f in which:
		var e: GateEffects = _fx[f]
		e.self_paths = ["*"]
		e.param_paths.clear()
		var fd: GateAST.GateFuncDecl = f
		for i in fd.params.size():
			e.param_paths[i] = ["*"]


func _has_field(cls: String, fname: String) -> bool:
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c):
		seen[c] = true
		if (_fields_by_class.get(c, {}) as Dictionary).has(fname):
			return true
		c = bases.get(c, "")
	return false


func _scan_effects(fd) -> bool:
	var locals: Dictionary = {}
	var params: Dictionary = {}
	var owner: String = _fx_owner.get(fd, "")
	if owner != "":
		locals["self"] = _named(owner)
	for i in fd.params.size():
		var pp: GateAST.GateParam = fd.params[i]
		params[pp.name] = i
		if pp.type != null:
			locals[pp.name] = pp.type
	var ctx: Dictionary = {"fx": _fx[fd], "cls": owner, "params": params,
		"locals": locals, "changed": false}
	_fx_stmts(fd.body, ctx)
	return ctx["changed"]


func _join_suffix(a: String, b: String) -> String:
	if a == "": return b
	if b == "": return a
	return a + "." + b

const MAX_REL_DEPTH := 24


func _rel(e, ctx: Dictionary, depth: int = 0) -> Array:
	if depth > MAX_REL_DEPTH:
		return ["", -1, ""]
	if e is GateAST.GateSelfExpr:
		return ["self", -1, ""]
	if e is GateAST.GateIdent:
		var n: String = (e as GateAST.GateIdent).name
		if n == "super":
			return ["self", -1, ""]
		if (ctx["params"] as Dictionary).has(n):
			return ["param", ctx["params"][n], ""]
		if _has_field(ctx["cls"], n):
			return ["self", -1, n]
		return ["", -1, ""]
	if e is GateAST.GateMember:
		var m: GateAST.GateMember = e
		var b: Array = _rel(m.target, ctx, depth + 1)
		if b[0] == "": return ["", -1, ""]
		return [b[0], b[1], _join_suffix(b[2], m.name)]
	if e is GateAST.GateIndex:
		var b2: Array = _rel((e as GateAST.GateIndex).target, ctx, depth + 1)
		if b2[0] == "": return ["", -1, ""]
		return [b2[0], b2[1], _join_suffix(b2[2], "*")]
	return ["", -1, ""]

const MAX_SUFFIX_DEPTH := 3
const MAX_SUFFIXES := 24


func _cap_suffix(sfx: String) -> String:
	if sfx == "":
		return ""
	var parts: PackedStringArray = sfx.split(".")
	var star: int = parts.find("*")
	if star >= 0:
		parts = parts.slice(0, star + 1)
	if parts.size() > MAX_SUFFIX_DEPTH:
		parts = parts.slice(0, MAX_SUFFIX_DEPTH)
		parts.append("*")
	return ".".join(parts)


func _fx_add(ctx: Dictionary, kind: String, idx: int, sfx: String) -> void:
	if kind == "" or sfx == "":
		return
	var fx: GateEffects = ctx["fx"]
	var bucket: Array = fx.self_paths if kind == "self" else fx.param_paths.get(idx, [])
	if bucket.has("*"):
		return
	var s: String = _cap_suffix(sfx)
	if s != "*" and bucket.size() >= MAX_SUFFIXES:
		s = "*"
	if s == "*":
		bucket.clear()
		if kind != "self":
			fx.param_paths[idx] = bucket
	var ch: bool = fx.add_self(s) if kind == "self" else fx.add_param(idx, s)
	if ch:
		ctx["changed"] = true


func _fx_stmts(body: Array, ctx: Dictionary) -> void:
	for s in body:
		if s is GateAST.GateAssignStmt:
			var a: GateAST.GateAssignStmt = s
			var r: Array = _rel(a.target, ctx)
			_fx_add(ctx, r[0], r[1], r[2])
			_fx_expr(a.target, ctx)
			_fx_expr(a.value, ctx)
		elif s is GateAST.GateVarDecl:
			var vd: GateAST.GateVarDecl = s
			_fx_expr(vd.value, ctx)
			if vd.type != null:
				ctx["locals"][vd.name] = vd.type
			else:
				var it: GateAST.GateTypeRef = type_of(vd.value, ctx["locals"])
				if it != null:
					ctx["locals"][vd.name] = it
		elif s is GateAST.GateExprStmt:
			_fx_expr((s as GateAST.GateExprStmt).expr, ctx)
		elif s is GateAST.GateReturnStmt:
			_fx_expr((s as GateAST.GateReturnStmt).value, ctx)
		elif s is GateAST.GateIfStmt:
			var i: GateAST.GateIfStmt = s
			_fx_expr(i.cond, ctx)
			_fx_stmts(i.then_body, ctx)
			for pair in i.elifs:
				_fx_expr(pair[0], ctx)
				_fx_stmts(pair[1], ctx)
			_fx_stmts(i.else_body, ctx)
		elif s is GateAST.GateForStmt:
			var fo: GateAST.GateForStmt = s
			_fx_expr(fo.iterable, ctx)
			if not fo.var_names.is_empty():
				var et: GateAST.GateTypeRef = fo.var_type
				if et == null:
					et = element_type(type_of(fo.iterable, ctx["locals"]))
				if et != null:
					ctx["locals"][fo.var_names[fo.var_names.size() - 1]] = et
			_fx_stmts(fo.body, ctx)
		elif s is GateAST.GateWhileStmt:
			_fx_expr((s as GateAST.GateWhileStmt).cond, ctx)
			_fx_stmts((s as GateAST.GateWhileStmt).body, ctx)
		elif s is GateAST.GateMatchStmt:
			_fx_expr((s as GateAST.GateMatchStmt).subject, ctx)
			for br in (s as GateAST.GateMatchStmt).branches:
				_fx_stmts(br[2], ctx)
		elif s is GateAST.GateMultiAssign:
			var ma: GateAST.GateMultiAssign = s
			for t in ma.targets:
				var r2: Array = _rel(t, ctx)
				_fx_add(ctx, r2[0], r2[1], r2[2])
			for v in ma.values:
				_fx_expr(v, ctx)


func _fx_expr(e, ctx: Dictionary) -> void:
	if e == null:
		return
	if e is GateAST.GateCall:
		var c: GateAST.GateCall = e
		_fx_expr(c.callee, ctx)
		for a in c.args:
			_fx_expr(a, ctx)
		_fx_call(c, ctx)
		return
	if e is GateAST.GateBinary:
		var spine: Array = []
		var cur = e
		while cur is GateAST.GateBinary:
			spine.append(cur)
			cur = (cur as GateAST.GateBinary).left
		_fx_expr(cur, ctx)
		for n in spine:
			_fx_expr((n as GateAST.GateBinary).right, ctx)
	elif e is GateAST.GateNullCoalesce:
		_fx_expr((e as GateAST.GateNullCoalesce).left, ctx)
		_fx_expr((e as GateAST.GateNullCoalesce).right, ctx)
	elif e is GateAST.GateTernary:
		var te: GateAST.GateTernary = e
		_fx_expr(te.cond, ctx); _fx_expr(te.if_true, ctx); _fx_expr(te.if_false, ctx)
	elif e is GateAST.GateMember or e is GateAST.GateIndex:
		var pspine: Array = []
		var pcur = e
		while pcur is GateAST.GateMember or pcur is GateAST.GateIndex:
			pspine.append(pcur)
			pcur = (pcur as GateAST.GateMember).target if pcur is GateAST.GateMember else (pcur as GateAST.GateIndex).target
		_fx_expr(pcur, ctx)
		for pn in pspine:
			if pn is GateAST.GateIndex:
				_fx_expr((pn as GateAST.GateIndex).index, ctx)
	elif e is GateAST.GateUnary:
		_fx_expr((e as GateAST.GateUnary).operand, ctx)
	elif e is GateAST.GateAwaitExpr:
		_fx_expr((e as GateAST.GateAwaitExpr).operand, ctx)
	elif e is GateAST.GateCastExpr:
		_fx_expr((e as GateAST.GateCastExpr).operand, ctx)
	elif e is GateAST.GateIsExpr:
		_fx_expr((e as GateAST.GateIsExpr).operand, ctx)
	elif e is GateAST.GateArrayLit:
		for el in (e as GateAST.GateArrayLit).elements: _fx_expr(el, ctx)
	elif e is GateAST.GateDictLit:
		for k in (e as GateAST.GateDictLit).keys: _fx_expr(k, ctx)
		for v in (e as GateAST.GateDictLit).values: _fx_expr(v, ctx)
	elif e is GateAST.GateObjectInit:
		for v2 in (e as GateAST.GateObjectInit).values: _fx_expr(v2, ctx)
	elif e is GateAST.GateFString:
		for part in (e as GateAST.GateFString).parts:
			if not (part is String): _fx_expr(part, ctx)
	elif e is GateAST.GateLambda:
		var lam: GateAST.GateLambda = e
		_fx_stmts(lam.body, ctx)
		_fx_expr(lam.expr_body, ctx)


func _fx_call(c: GateAST.GateCall, ctx: Dictionary) -> void:
	var recv: Array = ["", -1, ""]
	var callee_fd = null
	var uname: String = ""

	if c.callee is GateAST.GateIdent:
		var n: String = (c.callee as GateAST.GateIdent).name
		callee_fd = _pick(module_functions.get(n, []), c.args.size())
		if callee_fd != null:
			recv = ["self", -1, ""]
		if callee_fd == null and ctx["cls"] != "":
			callee_fd = _pick(method_candidates(ctx["cls"], n), c.args.size())
			if callee_fd != null:
				recv = ["self", -1, ""]
		if callee_fd == null:
			uname = n
			if not is_engine_method(engine_root(String(ctx["cls"])), n):
				recv = ["self", -1, ""]
	elif c.callee is GateAST.GateMember:
		var m: GateAST.GateMember = c.callee
		if m.name == "new":
			return
		recv = _rel(m.target, ctx)
		if m.target is GateAST.GateIdent and (m.target as GateAST.GateIdent).name == "super":
			callee_fd = _pick(
				method_candidates(String(bases.get(ctx["cls"], "")), m.name), c.args.size())
		var rt: GateAST.GateTypeRef = type_of(m.target, ctx["locals"])
		if callee_fd == null and rt != null and rt.array_depth == 0 and not rt.is_dict():
			callee_fd = _pick(method_candidates(rt.name, m.name), c.args.size())
		if callee_fd == null:
			uname = m.name
	else:
		return

	if callee_fd != null and _fx.has(callee_fd):
		var e2: GateEffects = _fx[callee_fd]
		for sfx in e2.self_paths:
			_fx_add(ctx, recv[0], recv[1], _join_suffix(recv[2], sfx))
		for j in e2.param_paths:
			if j >= c.args.size():
				continue
			var ar: Array = _rel(c.args[j], ctx)
			for sfx2 in e2.param_paths[j]:
				_fx_add(ctx, ar[0], ar[1], _join_suffix(ar[2], sfx2))
		return

	if PURE_GLOBALS.has(uname):
		return
	if uname in CALLABLE_INVOKERS or SYNC_HIGHER_ORDER.has(uname):
		_fx_add(ctx, "self", -1, "*")
	_fx_add(ctx, recv[0], recv[1], _join_suffix(recv[2], "*"))
	for a2 in c.args:
		var ar2: Array = _rel(a2, ctx)
		_fx_add(ctx, ar2[0], ar2[1], _join_suffix(ar2[2], "*"))

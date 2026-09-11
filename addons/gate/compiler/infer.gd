@tool
class_name GateInfer
extends "res://addons/gate/compiler/infer_core.gd"

## Interprocedural effect analysis on top of `infer_core.gd`.
##
## A function is summarised as the access paths it can write, relative to its
## receiver and each parameter, so the null analysis invalidates only those.


func build(mod: GateAST.Module, registry = null) -> void:
	fields.clear(); methods.clear(); bases.clear(); module_functions.clear()
	struct_names.clear(); open_types.clear(); untyped_fields.clear()
	member_names.clear(); signals.clear(); generic_params.clear(); implements.clear()
	accessor_fields.clear()
	_class_index.clear(); _ref_names.clear(); priv_members.clear()
	_names_built = false
	_names_mod = mod
	_names_registry = registry
	if registry != null:
		var own: Dictionary = {}
		_declared_classes(mod.members, own)
		if mod.class_name_decl != "":
			own[mod.class_name_decl] = true
		for k in registry.fields:
			if _from_registry(registry, k, own): fields[k] = registry.fields[k]
		for k in registry.methods:
			if _from_registry(registry, k, own):
				methods[k] = registry.methods[k].duplicate()
				_ref_names[String(k).substr(String(k).rfind(".") + 1)] = true
		for k in registry.bases:
			if _from_registry(registry, k + ".", own): bases[k] = registry.bases[k]
		var own_all: Dictionary = GateChecker.own_names(mod.members)
		for k in registry.structs:
			if not own_all.has(k): struct_names[k] = registry.structs[k]
		for k in registry.interfaces:
			if not own.has(k): open_types[k] = true
		for k in registry.traits:
			if not own.has(k): open_types[k] = true
		for k in registry.classes:
			if not own.has(k): _note_implements(registry.classes[k])
		for g in registry.generics:
			generic_params[g] = (registry.generics[g] as GateAST.ClassDecl).generic_params
		var scripts: Dictionary = registry.script_class_decls if "script_class_decls" in registry else {}
		var tables: Array = [registry.classes, registry.structs, registry.namespaces, registry.generics,
			scripts]
		for ti in tables.size():
			var table: Dictionary = tables[ti]
			for cname in table:
				if ti == 4 and own.has(cname):
					continue   # this file's own class_name
				_class_index[cname] = true
				if not own.has(cname):
					var rcd: GateAST.ClassDecl = table[cname]
					_index_signals(rcd.members, String(cname))
					_note_implements(rcd)
					for rm in rcd.members:
						if (rm is GateAST.FuncDecl or rm is GateAST.VarDecl) and rm.visibility == "priv" \
								and not String(rm.name).begins_with("_"):
							priv_members["%s.%s" % [cname, rm.name]] = true
		for iname in registry.interfaces:
			var icd: GateAST.ClassDecl = registry.interfaces[iname]
			if not own.has(iname):
				_note_implements(icd)
	_index(mod.members, MODULE_CLASS)
	if mod.extends_type != null:
		bases[MODULE_CLASS] = mod.extends_type.name
	if mod.class_name_decl != "":
		bases[mod.class_name_decl] = MODULE_CLASS
	for m in mod.members:
		if m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			if not module_functions.has(fd.name):
				module_functions[fd.name] = []
			module_functions[fd.name].append(fd)
	_accessor_names.clear()
	for ak in accessor_fields:
		_accessor_names[String(ak).substr(String(ak).rfind(".") + 1)] = true
	_method_names.clear()
	for mk in methods:
		_method_names[String(mk).substr(String(mk).rfind(".") + 1)] = true
	_fx_built = false


## The last part of every key in accessor_fields and methods. A lookup of a name
## missing here finds nothing whatever the receiver, so its type need not be worked out.
var _accessor_names: Dictionary = {}
var _method_names: Dictionary = {}


static func _declared_classes(members: Array, out: Dictionary) -> void:
	for m in members:
		if m is GateAST.ClassDecl:
			out[(m as GateAST.ClassDecl).name] = true
			_declared_classes((m as GateAST.ClassDecl).members, out)


## Whether a registry entry applies here. A class this file declares wins.
static func _from_registry(registry, key: String, own: Dictionary) -> bool:
	var cls: String = key.substr(0, key.rfind("."))
	return not own.has(cls) and (registry.top_level.has(cls)
		or ("script_class_decls" in registry and registry.script_class_decls.has(cls)))


class Effects extends RefCounted:
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


func effects_of(fd) -> Effects:
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
			_fx[f] = Effects.new()
	for n in module_functions:
		for f2 in module_functions[n]:
			if not _fx.has(f2):
				_fx_owner[f2] = ""
				_fx[f2] = Effects.new()

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
		var e: Effects = _fx[f]
		e.self_paths = ["*"]
		e.param_paths.clear()
		var fd: GateAST.FuncDecl = f
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
		var pp: GateAST.Param = fd.params[i]
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
	if e is GateAST.SelfExpr:
		return ["self", -1, ""]
	if e is GateAST.Ident:
		var n: String = (e as GateAST.Ident).name
		if n == "super":
			return ["self", -1, ""]
		if (ctx["params"] as Dictionary).has(n):
			return ["param", ctx["params"][n], ""]
		if _has_field(ctx["cls"], n):
			return ["self", -1, n]
		return ["", -1, ""]
	if e is GateAST.Member:
		var m: GateAST.Member = e
		var b: Array = _rel(m.target, ctx, depth + 1)
		if b[0] == "": return ["", -1, ""]
		return [b[0], b[1], _join_suffix(b[2], m.name)]
	if e is GateAST.Index:
		var b2: Array = _rel((e as GateAST.Index).target, ctx, depth + 1)
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
	var fx: Effects = ctx["fx"]
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
		if s is GateAST.AssignStmt:
			var a: GateAST.AssignStmt = s
			var r: Array = _rel(a.target, ctx)
			_fx_add(ctx, r[0], r[1], r[2])
			_fx_expr(a.target, ctx)
			_fx_expr(a.value, ctx)
		elif s is GateAST.VarDecl:
			var vd: GateAST.VarDecl = s
			_fx_expr(vd.value, ctx)
			if vd.type != null:
				ctx["locals"][vd.name] = vd.type
			else:
				var it: GateAST.TypeRef = type_of(vd.value, ctx["locals"])
				if it != null:
					ctx["locals"][vd.name] = it
		elif s is GateAST.ExprStmt:
			_fx_expr((s as GateAST.ExprStmt).expr, ctx)
		elif s is GateAST.ReturnStmt:
			_fx_expr((s as GateAST.ReturnStmt).value, ctx)
		elif s is GateAST.IfStmt:
			var i: GateAST.IfStmt = s
			_fx_expr(i.cond, ctx)
			_fx_stmts(i.then_body, ctx)
			for pair in i.elifs:
				_fx_expr(pair[0], ctx)
				_fx_stmts(pair[1], ctx)
			_fx_stmts(i.else_body, ctx)
		elif s is GateAST.ForStmt:
			var fo: GateAST.ForStmt = s
			_fx_expr(fo.iterable, ctx)
			if not fo.var_names.is_empty():
				var et: GateAST.TypeRef = fo.var_type
				if et == null:
					et = element_type(type_of(fo.iterable, ctx["locals"]))
				if et != null:
					ctx["locals"][fo.var_names[fo.var_names.size() - 1]] = et
			_fx_stmts(fo.body, ctx)
		elif s is GateAST.WhileStmt:
			_fx_expr((s as GateAST.WhileStmt).cond, ctx)
			_fx_stmts((s as GateAST.WhileStmt).body, ctx)
		elif s is GateAST.MatchStmt:
			_fx_expr((s as GateAST.MatchStmt).subject, ctx)
			for br in (s as GateAST.MatchStmt).branches:
				_fx_stmts(br[2], ctx)
		elif s is GateAST.MultiAssign:
			var ma: GateAST.MultiAssign = s
			for t in ma.targets:
				var r2: Array = _rel(t, ctx)
				_fx_add(ctx, r2[0], r2[1], r2[2])
			for v in ma.values:
				_fx_expr(v, ctx)


func _fx_expr(e, ctx: Dictionary) -> void:
	if e == null:
		return
	if e is GateAST.Call:
		var c: GateAST.Call = e
		_fx_expr(c.callee, ctx)
		for a in c.args:
			_fx_expr(a, ctx)
		_fx_call(c, ctx)
		return
	if e is GateAST.Binary:
		var spine: Array = []
		var cur = e
		while cur is GateAST.Binary:
			spine.append(cur)
			cur = (cur as GateAST.Binary).left
		_fx_expr(cur, ctx)
		for n in spine:
			_fx_expr((n as GateAST.Binary).right, ctx)
	elif e is GateAST.NullCoalesce:
		_fx_expr((e as GateAST.NullCoalesce).left, ctx)
		_fx_expr((e as GateAST.NullCoalesce).right, ctx)
	elif e is GateAST.Ternary:
		var te: GateAST.Ternary = e
		_fx_expr(te.cond, ctx); _fx_expr(te.if_true, ctx); _fx_expr(te.if_false, ctx)
	elif e is GateAST.Member or e is GateAST.Index:
		var pspine: Array = []
		var pcur = e
		while pcur is GateAST.Member or pcur is GateAST.Index:
			pspine.append(pcur)
			pcur = (pcur as GateAST.Member).target if pcur is GateAST.Member else (pcur as GateAST.Index).target
		_fx_expr(pcur, ctx)
		for pn in pspine:
			if pn is GateAST.Index:
				_fx_expr((pn as GateAST.Index).index, ctx)
	elif e is GateAST.Unary:
		_fx_expr((e as GateAST.Unary).operand, ctx)
	elif e is GateAST.AwaitExpr:
		_fx_expr((e as GateAST.AwaitExpr).operand, ctx)
	elif e is GateAST.CastExpr:
		_fx_expr((e as GateAST.CastExpr).operand, ctx)
	elif e is GateAST.IsExpr:
		_fx_expr((e as GateAST.IsExpr).operand, ctx)
	elif e is GateAST.ArrayLit:
		for el in (e as GateAST.ArrayLit).elements: _fx_expr(el, ctx)
	elif e is GateAST.DictLit:
		for k in (e as GateAST.DictLit).keys: _fx_expr(k, ctx)
		for v in (e as GateAST.DictLit).values: _fx_expr(v, ctx)
	elif e is GateAST.ObjectInit:
		for v2 in (e as GateAST.ObjectInit).values: _fx_expr(v2, ctx)
	elif e is GateAST.FString:
		for part in (e as GateAST.FString).parts:
			if not (part is String): _fx_expr(part, ctx)
	elif e is GateAST.Lambda:
		var lam: GateAST.Lambda = e
		_fx_stmts(lam.body, ctx)
		_fx_expr(lam.expr_body, ctx)


func _fx_call(c: GateAST.Call, ctx: Dictionary) -> void:
	var recv: Array = ["", -1, ""]
	var callee_fd = null
	var uname: String = ""

	if c.callee is GateAST.Ident:
		var n: String = (c.callee as GateAST.Ident).name
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
	elif c.callee is GateAST.Member:
		var m: GateAST.Member = c.callee
		if m.name == "new":
			return
		recv = _rel(m.target, ctx)
		if m.target is GateAST.Ident and (m.target as GateAST.Ident).name == "super":
			callee_fd = _pick(
				method_candidates(String(bases.get(ctx["cls"], "")), m.name), c.args.size())
		var rt: GateAST.TypeRef = type_of(m.target, ctx["locals"])
		if callee_fd == null and rt != null and rt.array_depth == 0 and not rt.is_dict():
			callee_fd = _pick(method_candidates(rt.name, m.name), c.args.size())
		if callee_fd == null:
			uname = m.name
	else:
		return

	if callee_fd != null and _fx.has(callee_fd):
		var e2: Effects = _fx[callee_fd]
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

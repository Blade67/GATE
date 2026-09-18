@tool
class_name GateInfer
extends "res://addons/gate/compiler/infer_core.gd"

## Interprocedural effect analysis on top of `infer_core.gd`.
##
## A function is summarised as the access paths it can write, relative to its
## receiver and each parameter, so the null analysis invalidates only those.


func build(mod: GateAST._Module, registry = null) -> void:
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
			generic_params[g] = (registry.generics[g] as GateAST._ClassDecl).generic_params
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
					var rcd: GateAST._ClassDecl = table[cname]
					_index_signals(rcd.members, String(cname))
					_note_implements(rcd)
					for rm in rcd.members:
						if (rm is GateAST._FuncDecl or rm is GateAST._VarDecl) and rm.visibility == "priv" \
								and not String(rm.name).begins_with("_"):
							priv_members["%s.%s" % [cname, rm.name]] = true
		for iname in registry.interfaces:
			var icd: GateAST._ClassDecl = registry.interfaces[iname]
			if not own.has(iname):
				_note_implements(icd)
	_index(mod.members, MODULE_CLASS)
	if mod.extends_type != null:
		bases[MODULE_CLASS] = mod.extends_type.name
	if mod.class_name_decl != "":
		bases[mod.class_name_decl] = MODULE_CLASS
	for m in mod.members:
		if m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
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
		if m is GateAST._ClassDecl:
			out[(m as GateAST._ClassDecl).name] = true
			_declared_classes((m as GateAST._ClassDecl).members, out)


## Whether a registry entry applies here. A class this file declares wins.
static func _from_registry(registry, key: String, own: Dictionary) -> bool:
	var cls: String = key.substr(0, key.rfind("."))
	return not own.has(cls) and (registry.top_level.has(cls)
		or ("script_class_decls" in registry and registry.script_class_decls.has(cls)))


class _Effects extends RefCounted:
	var self_paths: Array = []   ## suffixes relative to the receiver
	var param_paths: Dictionary = {}        ## param index -> Array of suffixes
	var statics: Array = []   ## "Class.field" paths of static fields written, reached any way
	var returns: Array = []
	var opaque: bool = false

	func add_return(r: Array) -> bool:
		if returns.has(r) or returns.has(["any", -1, ""]):
			return false
		if returns.size() >= 24:
			returns = [["any", -1, ""]]
			return true
		returns.append(r)
		return true

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

	func add_static(path: String) -> bool:
		if path == "" or statics.has(path): return false
		statics.append(path)
		return true

## GDScript's global built-ins. A bare call to one of these names always reaches the
## built-in, even where the class defines a function of the same name.
const GLOBAL_FUNCTIONS := {
	"Color8": true, "abs": true, "absf": true, "absi": true, "acos": true, "acosh": true,
	"angle_difference": true, "asin": true, "asinh": true, "assert": true, "atan": true,
	"atan2": true, "atanh": true, "bezier_derivative": true, "bezier_interpolate": true,
	"bytes_to_var": true, "bytes_to_var_with_objects": true, "ceil": true, "ceilf": true,
	"ceili": true, "char": true, "clamp": true, "clampf": true, "clampi": true, "convert": true,
	"cos": true, "cosh": true, "cubic_interpolate": true, "cubic_interpolate_angle": true,
	"cubic_interpolate_angle_in_time": true, "cubic_interpolate_in_time": true,
	"db_to_linear": true, "deg_to_rad": true, "dict_to_inst": true, "ease": true,
	"error_string": true, "exp": true, "floor": true, "floorf": true, "floori": true,
	"fmod": true, "fposmod": true, "get_stack": true, "hash": true, "inst_to_dict": true,
	"instance_from_id": true, "inverse_lerp": true, "is_equal_approx": true, "is_finite": true,
	"is_inf": true, "is_instance_id_valid": true, "is_instance_of": true,
	"is_instance_valid": true, "is_nan": true, "is_same": true, "is_zero_approx": true,
	"len": true, "lerp": true, "lerp_angle": true, "lerpf": true, "linear_to_db": true,
	"load": true, "log": true, "max": true, "maxf": true, "maxi": true, "min": true, "minf": true,
	"mini": true, "move_toward": true, "nearest_po2": true, "ord": true, "pingpong": true,
	"posmod": true, "pow": true, "preload": true, "print": true, "print_debug": true,
	"print_rich": true, "print_stack": true, "print_verbose": true, "printerr": true,
	"printraw": true, "prints": true, "printt": true, "push_error": true, "push_warning": true,
	"rad_to_deg": true, "rand_from_seed": true, "randf": true, "randf_range": true,
	"randfn": true, "randi": true, "randi_range": true, "randomize": true, "range": true,
	"remap": true, "rid_allocate_id": true, "rid_from_int64": true, "rotate_toward": true,
	"round": true, "roundf": true, "roundi": true, "seed": true, "sign": true, "signf": true,
	"signi": true, "sin": true, "sinh": true, "smoothstep": true, "snapped": true,
	"snappedf": true, "snappedi": true, "sqrt": true, "step_decimals": true, "str": true,
	"str_to_var": true, "tan": true, "tanh": true, "type_convert": true, "type_exists": true,
	"type_string": true, "typeof": true, "var_to_bytes": true, "var_to_bytes_with_objects": true,
	"var_to_str": true, "weakref": true, "wrap": true, "wrapf": true, "wrapi": true
}

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
var _fx_built: bool = false


func effects_of(fd) -> _Effects:
	ensure_effects()
	if fd != null and not _fx.has(fd) and _fx_every.has(fd) and not _fx_roots.has(fd):
		_fx_roots[fd] = true
		_build_effects()   # asked about a function the calls in this file did not reach
	return _fx.get(fd, null)


func summarise_all() -> Dictionary:
	var roots: Array = []
	for k in methods:
		roots.append_array(methods[k])
	for n in module_functions:
		roots.append_array(module_functions[n])
	return summarise(roots)


func summarise(roots: Array) -> Dictionary:
	_fx_built = true
	_fx_roots = {}
	for f in roots:
		_fx_roots[f] = true
	_build_effects()
	return _fx


func ensure_effects() -> void:
	if not _fx_built:
		_fx_built = true
		_build_effects()

const MAX_EFFECT_PASSES := 12


var _fx_roots: Dictionary = {}
var _fx_every: Dictionary = {}


## Summaries only for the functions this file can ask about, and the ones their
## summaries read: a summary reads another only through a call it resolves or an
## override it merges, so the functions left out cannot change the ones kept, and
## each comes out as summarising the whole project would make it, pass for pass.
## Summarising every function of every file for each file compiled was what made a
## large project slow.
func _build_effects() -> void:
	_fx.clear(); _fx_owner.clear(); _fields_by_class.clear()

	for k in fields.keys() + untyped_fields.keys():
		var fkey: String = String(k)
		var fdot: int = fkey.rfind(".")
		if fdot <= 0:
			continue
		var fcls: String = fkey.substr(0, fdot)
		if not _fields_by_class.has(fcls):
			_fields_by_class[fcls] = {}
		_fields_by_class[fcls][fkey.substr(fdot + 1)] = true

	var owner_of: Dictionary = {}
	for k1 in methods:
		var okey: String = String(k1)
		var odot: int = okey.rfind(".")
		if odot <= 0:
			continue
		for f0 in methods[k1]:
			owner_of[f0] = okey.substr(0, odot)
	for n0 in module_functions:
		for f1 in module_functions[n0]:
			if not owner_of.has(f1):
				owner_of[f1] = ""
	_fx_every = owner_of

	_subclasses.clear()
	for sub in bases:
		var base: String = String(bases[sub])
		if not _subclasses.has(base):
			_subclasses[base] = []
		_subclasses[base].append(String(sub))
	var chosen: Dictionary = _summary_closure(owner_of)

	for k2 in methods:
		var mkey: String = String(k2)
		var mdot: int = mkey.rfind(".")
		if mdot <= 0:
			continue
		var mcls: String = mkey.substr(0, mdot)
		for f in methods[k2]:
			if not chosen.has(f):
				continue
			_fx_owner[f] = mcls
			_fx[f] = _Effects.new()
	for n in module_functions:
		for f2 in module_functions[n]:
			if not _fx.has(f2) and chosen.has(f2):
				_fx_owner[f2] = ""
				_fx[f2] = _Effects.new()

	var limit: int = maxi(MAX_EFFECT_PASSES, owner_of.size() + 1)   # as if every function were summarised
	_fx_clock = 0
	_fx_moved_at.clear(); _fx_scan_at.clear(); _fx_scan_reads.clear()
	_fx_merge_at.clear(); _fx_merge_reads.clear()
	var still_moving: Dictionary = {}
	for _pass in limit:
		still_moving = {}
		for f3 in _fx:
			if _rescan(f3):
				still_moving[f3] = true
		for f4 in _fx:
			if _remerge(f4):
				still_moving[f4] = true
		if still_moving.is_empty():
			return
	_widen_effects(still_moving)


## A scan reads only its own summary and those of the functions it calls, so when
## none of them has grown since it last ran it would add nothing, and is skipped.
var _fx_clock: int = 0
var _fx_moved_at: Dictionary = {}
var _fx_scan_at: Dictionary = {}
var _fx_scan_reads: Dictionary = {}
var _fx_merge_at: Dictionary = {}
var _fx_merge_reads: Dictionary = {}
var _fx_reading: Dictionary = {}


func _rescan(fd) -> bool:
	if _fx_scan_at.has(fd) and not _moved_since(fd, _fx_scan_reads[fd], _fx_scan_at[fd]):
		return false
	_fx_clock += 1
	_fx_scan_at[fd] = _fx_clock
	_fx_reading = {}
	var changed: bool = _scan_effects(fd)
	_fx_scan_reads[fd] = _fx_reading
	_fx_reading = {}
	if changed:
		_fx_clock += 1
		_fx_moved_at[fd] = _fx_clock
	return changed


func _remerge(fd) -> bool:
	if _fx_merge_at.has(fd) and not _moved_since(fd, _fx_merge_reads[fd], _fx_merge_at[fd]):
		return false
	_fx_clock += 1
	_fx_merge_at[fd] = _fx_clock
	_fx_reading = {}
	var changed: bool = _merge_overrides(fd)
	_fx_merge_reads[fd] = _fx_reading
	_fx_reading = {}
	if changed:
		_fx_clock += 1
		_fx_moved_at[fd] = _fx_clock
	return changed


func _moved_since(fd, reads: Dictionary, at: int) -> bool:
	if int(_fx_moved_at.get(fd, 0)) > at:
		return true
	for r in reads:
		if int(_fx_moved_at.get(r, 0)) > at:
			return true
	return false


var _subclasses: Dictionary = {}


func _summary_closure(owner_of: Dictionary) -> Dictionary:
	var by_name: Dictionary = {}
	for f in owner_of:
		_file_by_name(by_name, f)
	var chosen: Dictionary = {}
	var todo: Array = []
	var asked: Dictionary = {}
	_calls_in(_names_mod.members if _names_mod != null else [], asked, asked, true)
	for an in asked:
		for af in by_name.get(an, []):
			_choose(af, chosen, todo)
	for rf in _fx_roots:
		if owner_of.has(rf):
			_choose(rf, chosen, todo)
	while not todo.is_empty():
		var fd: GateAST._FuncDecl = todo.pop_back()
		var owner: String = owner_of[fd]
		var bare: Dictionary = {}
		var dotted: Dictionary = {}
		_calls_in(fd.body, bare, dotted, false)
		for bn in bare:
			for mf in module_functions.get(bn, []):
				_choose(mf, chosen, todo)
			var seen: Dictionary = {}
			var c: String = owner
			while c != "" and not seen.has(c):
				seen[c] = true
				for cf in methods.get("%s.%s" % [c, bn], []):
					_choose(cf, chosen, todo)
				c = bases.get(c, "")
		for dn in dotted:
			for df in by_name.get(dn, []):
				_choose(df, chosen, todo)
		if owner != "":
			var sub_seen: Dictionary = {owner: true}
			var subs: Array = (_subclasses.get(owner, []) as Array).duplicate()
			while not subs.is_empty():
				var sub: String = subs.pop_back()
				if sub_seen.has(sub):
					continue
				sub_seen[sub] = true
				subs.append_array(_subclasses.get(sub, []))
				for of in methods.get("%s.%s" % [sub, fd.name], []):
					_choose(of, chosen, todo)
	return chosen


static func _choose(fd, chosen: Dictionary, todo: Array) -> void:
	if not chosen.has(fd):
		chosen[fd] = true
		todo.append(fd)


static func _file_by_name(by_name: Dictionary, fd) -> void:
	var n: String = (fd as GateAST._FuncDecl).name
	if not by_name.has(n):
		by_name[n] = []
	(by_name[n] as Array).append(fd)


## The names called under `root`: a bare `f()` into `bare`, `x.f()` into `dotted`.
## A scan resolves `X.new()` to nothing; the null analysis asks for `_init`, so for
## this file's own calls (`asked`) that name counts too.
static func _calls_in(root, bare: Dictionary, dotted: Dictionary, asked: bool) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is Array:
			stack.append_array(n)
			continue
		if not (n is GateAST._ASTNode) or n is GateAST._TypeRef:
			continue
		if n is GateAST._Call:
			var callee = (n as GateAST._Call).callee
			if callee is GateAST._Ident:
				bare[(callee as GateAST._Ident).name] = true
			elif callee is GateAST._Member:
				var mn: String = (callee as GateAST._Member).name
				if mn != "new":
					dotted[mn] = true
				elif asked:
					dotted["_init"] = true
		for pn in GateAST.child_names(n):
			var v = (n as Object).get(pn)
			if v is Array or v is Object:
				stack.append(v)


func _merge_overrides(fd) -> bool:
	var owner: String = _fx_owner.get(fd, "")
	var fdecl: GateAST._FuncDecl = fd
	if owner == "" or fdecl.is_static or fdecl.name in ["_init", "_static_init"]:
		return false   # constructors and static functions are not dispatched on the object
	var ctx: Dictionary = {"fx": _fx[fd], "changed": false}
	var seen: Dictionary = {owner: true}
	var todo: Array = (_subclasses.get(owner, []) as Array).duplicate()
	while not todo.is_empty():
		var sub: String = todo.pop_back()
		if seen.has(sub):
			continue
		seen[sub] = true
		todo.append_array(_subclasses.get(sub, []))
		var ofd: GateAST._FuncDecl = _pick(methods.get("%s.%s" % [sub, fdecl.name], []), fdecl.params.size())
		if ofd == null or ofd == fd or not _fx.has(ofd):
			continue
		_fx_reading[ofd] = true
		var src: _Effects = _fx[ofd]
		if src.opaque:
			_fx_opaque(ctx)
		for sfx in src.self_paths:
			_fx_add(ctx, "self", -1, sfx)
		for j in src.param_paths:
			for sfx2 in src.param_paths[j]:
				_fx_add(ctx, "param", j, sfx2)
		for sp in src.statics:
			_fx_add(ctx, "static", -1, sp)
		for r in src.returns:
			if (ctx["fx"] as _Effects).add_return(r):
				ctx["changed"] = true
	return ctx["changed"]


func _widen_effects(which: Dictionary) -> void:
	for f in which:
		var e: _Effects = _fx[f]
		e.self_paths = ["*"]
		e.statics = ["*"]
		e.param_paths.clear()
		e.returns = [["any", -1, ""]]
		var fd: GateAST._FuncDecl = f
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
		var pp: GateAST._Param = fd.params[i]
		params[pp.name] = i
		if pp.type != null:
			locals[pp.name] = pp.type
	var ctx: Dictionary = {"fx": _fx[fd], "cls": owner, "params": params,
		"locals": locals, "changed": false, "aliases": {}, "declared": {},
		"widen": false}
	var passes: int = 0
	while _collect_aliases(fd.body, ctx):
		passes += 1
		if passes >= maxi(MAX_ALIAS_PASSES, (ctx["declared"] as Dictionary).size() + 2):
			ctx["widen"] = true
			break
	_fx_stmts(fd.body, ctx)
	var bodiless: bool = (fd.is_virtual or fd.is_abstract) and fd.body.is_empty()
	if ctx["widen"] or bodiless:
		_fx_add(ctx, "self", -1, "*")
		for i in fd.params.size():
			_fx_add(ctx, "param", i, "*")
	if ctx["widen"]:
		_fx_add(ctx, "static", -1, "*")
		if (ctx["fx"] as _Effects).add_return(["any", -1, ""]):
			ctx["changed"] = true
	return ctx["changed"]


func _join_suffix(a: String, b: String) -> String:
	if a == "": return b
	if b == "": return a
	return a + "." + b

const MAX_REL_DEPTH := 24
const MAX_ALIAS_PASSES := 4
const MAX_ALIASES := 24


func _rel(e, ctx: Dictionary, depth: int = 0) -> Array:
	var all: Array = _rels(e, ctx, depth)
	return all[0] if not all.is_empty() else ["", -1, ""]


func _rels(e, ctx: Dictionary, depth: int = 0) -> Array:
	if depth > MAX_REL_DEPTH:
		return []
	if e is GateAST._SelfExpr:
		return [["self", -1, ""]]
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		if n == "super":
			return [["self", -1, ""]]
		if (ctx["params"] as Dictionary).has(n):
			return [["param", ctx["params"][n], ""]]
		var al = (ctx["aliases"] as Dictionary).get(n, null)
		if al != null:
			return (al as Array).duplicate()
		if _has_field(ctx["cls"], n):
			var so: String = static_owner(ctx["cls"], n)
			if so != "":
				return [["self", -1, n], ["static", -1, "%s.%s" % [so, n]]]
			return [["self", -1, n]]
		return []
	if e is GateAST._Member:
		var m: GateAST._Member = e
		var out: Array = []
		for b in _rels(m.target, ctx, depth + 1):
			out.append([b[0], b[1], _join_suffix(b[2], m.name)])
		if static_fields.is_empty():
			return out
		var holder: String = _class_named(m.target, ctx)
		if holder == "":
			var ht: GateAST._TypeRef = type_of(m.target, ctx["locals"])
			if ht != null and ht.array_depth == 0 and not ht.is_dict():
				holder = ht.name
		var owner: String = static_owner(holder, m.name) if holder != "" else ""
		if owner != "":
			out.append(["static", -1, "%s.%s" % [owner, m.name]])
		return out
	if e is GateAST._Index:
		var out2: Array = []
		for b2 in _rels((e as GateAST._Index).target, ctx, depth + 1):
			out2.append([b2[0], b2[1], _join_suffix(b2[2], "*")])
		return out2
	if e is GateAST._CastExpr:
		return _rels((e as GateAST._CastExpr).operand, ctx, depth + 1)
	if e is GateAST._NullCoalesce:
		var nc: GateAST._NullCoalesce = e
		return _rels(nc.left, ctx, depth + 1) + _rels(nc.right, ctx, depth + 1)
	if e is GateAST._Ternary:
		var te: GateAST._Ternary = e
		return _rels(te.if_true, ctx, depth + 1) + _rels(te.if_false, ctx, depth + 1)
	if e is GateAST._Call:
		return _call_rels(e, ctx, depth)
	return []


func _class_named(e, ctx: Dictionary) -> String:
	if not (e is GateAST._Ident):
		return ""
	var n: String = (e as GateAST._Ident).name
	if (ctx["params"] as Dictionary).has(n) or (ctx["declared"] as Dictionary).has(n) \
			or (ctx["aliases"] as Dictionary).has(n) or _has_field(ctx["cls"], n):
		return ""
	return n if has_class(n) else ""


func _note_alias(name: String, value, ctx: Dictionary, extra: String = "",
		held: GateAST._TypeRef = null) -> bool:
	if value == null or (ctx["params"] as Dictionary).has(name):
		return false
	var t: GateAST._TypeRef = held if extra != "" else type_of(value, ctx["locals"])
	if _holds_value(t):
		return false
	var al: Array = (ctx["aliases"] as Dictionary).get(name, [])
	var changed: bool = false
	for r in _rels(value, ctx):
		var one: Array = [r[0], r[1], _join_suffix(r[2], extra)]
		if one[0] == "" or al.has(one):
			continue
		if al.size() >= MAX_ALIASES:
			ctx["widen"] = true   # more than we keep: summarise conservatively
			continue
		al.append(one)
		changed = true
	if changed:
		ctx["aliases"][name] = al
	return changed


func _holds_value(t: GateAST._TypeRef) -> bool:
	if t == null or t.array_depth > 0 or t.is_dict():
		return false
	var n: String = GateTypes.canonical(t.name)
	if struct_names.has(n):
		return true
	return GateTypes.BUILTIN.has(n) and not n in ["Array", "Dictionary", "Variant"]


func _collect_aliases(body: Array, ctx: Dictionary) -> bool:
	var changed: bool = false
	for s in body:
		if s is GateAST._AnnotatedStmt:
			s = (s as GateAST._AnnotatedStmt).stmt
		if s is GateAST._VarDecl:
			var vd: GateAST._VarDecl = s
			ctx["declared"][vd.name] = true
			if _note_alias(vd.name, vd.value, ctx):
				changed = true
		elif s is GateAST._AssignStmt:
			var a: GateAST._AssignStmt = s
			if a.op == "=" and a.target is GateAST._Ident \
				and (ctx["declared"] as Dictionary).has((a.target as GateAST._Ident).name):
				if _note_alias((a.target as GateAST._Ident).name, a.value, ctx):
					changed = true
		elif s is GateAST._MultiAssign:
			var ma: GateAST._MultiAssign = s
			for t in ma.targets:
				if t is GateAST._Ident and ma.declares:
					ctx["declared"][(t as GateAST._Ident).name] = true
			for i in ma.targets.size():
				var tg = ma.targets[i]
				if not (tg is GateAST._Ident) \
					or not (ctx["declared"] as Dictionary).has((tg as GateAST._Ident).name):
					continue
				var tn: String = (tg as GateAST._Ident).name
				if not ma.destructure and ma.values.size() == ma.targets.size():
					if _note_alias(tn, ma.values[i], ctx):
						changed = true
				elif ma.values.size() == 1 and ma.values[0] is GateAST._ArrayLit \
					and (ma.values[0] as GateAST._ArrayLit).elements.size() == ma.targets.size():
					if _note_alias(tn, (ma.values[0] as GateAST._ArrayLit).elements[i], ctx):
						changed = true
				elif ma.values.size() == 1:
					if _note_alias(tn, ma.values[0], ctx, "*"):
						changed = true
		elif s is GateAST._IfStmt:
			var i: GateAST._IfStmt = s
			if _collect_aliases(i.then_body, ctx): changed = true
			for pair in i.elifs:
				if _collect_aliases(pair[1], ctx): changed = true
			if _collect_aliases(i.else_body, ctx): changed = true
		elif s is GateAST._ForStmt:
			var fo: GateAST._ForStmt = s
			if not fo.var_names.is_empty():
				var lv: String = fo.var_names[fo.var_names.size() - 1]
				ctx["declared"][lv] = true
				var et: GateAST._TypeRef = fo.var_type
				if et == null:
					et = element_type(type_of(fo.iterable, ctx["locals"]))
				if _note_alias(lv, fo.iterable, ctx, "*", et):
					changed = true
			if _collect_aliases(fo.body, ctx): changed = true
		elif s is GateAST._WhileStmt:
			if _collect_aliases((s as GateAST._WhileStmt).body, ctx): changed = true
		elif s is GateAST._MatchStmt:
			var mt: GateAST._MatchStmt = s
			for br in mt.branches:
				for p in br[0]:
					if not (p is GateAST._RawExpr):
						continue
					var text: String = (p as GateAST._RawExpr).text.strip_edges()
					for bn in _var_binds(text):
						ctx["declared"][bn] = true
						var whole: bool = text == "var " + bn
						if _note_alias(bn, mt.subject, ctx, "" if whole else "*"):
							changed = true
				if _collect_aliases(br[2], ctx): changed = true
	return changed


static func _var_binds(text: String) -> Array:
	var bare: String = ""
	var quote: String = ""
	var i: int = 0
	while i < text.length():
		var c: String = text[i]
		if quote != "":
			if c == "\\":
				bare += "  "
				i += 2
				continue
			if c == quote:
				quote = ""
			bare += " "
		elif c == "\"" or c == "'":
			quote = c
			bare += " "
		else:
			bare += c
		i += 1
	var out: Array = []
	var at: int = bare.find("var ")
	while at >= 0:
		if at == 0 or not _is_word_char(bare[at - 1]):
			var j: int = at + 4
			while j < bare.length() and bare[j] == " ":
				j += 1
			var name: String = ""
			while j < bare.length() and _is_word_char(bare[j]):
				name += bare[j]
				j += 1
			if name != "":
				out.append(name)
		at = bare.find("var ", at + 4)
	return out


static func _is_word_char(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
		or (c >= "0" and c <= "9") or c == "_" or c.unicode_at(0) >= 0x80

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
	var fx: _Effects = ctx["fx"]
	var bucket: Array = fx.self_paths if kind == "self" \
		else (fx.statics if kind == "static" else fx.param_paths.get(idx, []))
	if bucket.has("*"):
		return
	var s: String = _cap_suffix(sfx)
	if kind == "static" and sfx != "*":
		var head: int = sfx.find(".", sfx.find(".") + 1)   # "Class.field" stays whole
		s = sfx if head < 0 else sfx.substr(0, head + 1) + _cap_suffix(sfx.substr(head + 1))
	if s != "*" and bucket.size() >= MAX_SUFFIXES:
		s = "*"
	if s == "*":
		bucket.clear()
		if kind == "param":
			fx.param_paths[idx] = bucket
	var ch: bool = fx.add_self(s) if kind == "self" \
		else (fx.add_static(s) if kind == "static" else fx.add_param(idx, s))
	if ch:
		ctx["changed"] = true


func _fx_stmts(body: Array, ctx: Dictionary) -> void:
	for s in body:
		if s is GateAST._AssignStmt:
			var a: GateAST._AssignStmt = s
			for r in _rels(a.target, ctx):
				_fx_add(ctx, r[0], r[1], r[2])
			if not _fx_accessor(a.target, ctx).is_empty():
				_fx_opaque(ctx)   # a setter runs
			_fx_expr(a.target, ctx)
			_fx_expr(a.value, ctx)
		elif s is GateAST._VarDecl:
			var vd: GateAST._VarDecl = s
			_fx_expr(vd.value, ctx)
			_note_alias(vd.name, vd.value, ctx)
			if vd.type != null:
				ctx["locals"][vd.name] = vd.type
			else:
				var it: GateAST._TypeRef = type_of(vd.value, ctx["locals"])
				if it != null:
					ctx["locals"][vd.name] = it
		elif s is GateAST._ExprStmt:
			_fx_expr((s as GateAST._ExprStmt).expr, ctx)
		elif s is GateAST._ReturnStmt:
			var rv = (s as GateAST._ReturnStmt).value
			_fx_expr(rv, ctx)
			if int(ctx.get("lambda", 0)) == 0 and rv != null \
				and not _holds_value(type_of(rv, ctx["locals"])):
				for r in _rels(rv, ctx):
					if (ctx["fx"] as _Effects).add_return(r):
						ctx["changed"] = true
		elif s is GateAST._IfStmt:
			var i: GateAST._IfStmt = s
			_fx_expr(i.cond, ctx)
			_fx_stmts(i.then_body, ctx)
			for pair in i.elifs:
				_fx_expr(pair[0], ctx)
				_fx_stmts(pair[1], ctx)
			_fx_stmts(i.else_body, ctx)
		elif s is GateAST._ForStmt:
			var fo: GateAST._ForStmt = s
			_fx_expr(fo.iterable, ctx)
			if not fo.var_names.is_empty():
				var et: GateAST._TypeRef = fo.var_type
				if et == null:
					et = element_type(type_of(fo.iterable, ctx["locals"]))
				if et != null:
					ctx["locals"][fo.var_names[fo.var_names.size() - 1]] = et
				_note_alias(fo.var_names[fo.var_names.size() - 1], fo.iterable, ctx, "*", et)
			_fx_stmts(fo.body, ctx)
		elif s is GateAST._WhileStmt:
			_fx_expr((s as GateAST._WhileStmt).cond, ctx)
			_fx_stmts((s as GateAST._WhileStmt).body, ctx)
		elif s is GateAST._MatchStmt:
			_fx_expr((s as GateAST._MatchStmt).subject, ctx)
			for br in (s as GateAST._MatchStmt).branches:
				_fx_expr(br[1], ctx)   # a `when` guard can call things too
				_fx_stmts(br[2], ctx)
		elif s is GateAST._MultiAssign:
			var ma: GateAST._MultiAssign = s
			for t in ma.targets:
				for r2 in _rels(t, ctx):
					_fx_add(ctx, r2[0], r2[1], r2[2])
				if not _fx_accessor(t, ctx).is_empty():
					_fx_opaque(ctx)
			for v in ma.values:
				_fx_expr(v, ctx)


func _fx_accessor(e, ctx: Dictionary) -> Dictionary:
	if accessor_fields.is_empty():
		return {}
	if e is GateAST._Ident and not _accessor_names.has((e as GateAST._Ident).name):
		return {}
	if e is GateAST._Member and not _accessor_names.has((e as GateAST._Member).name):
		return {}
	var names: Dictionary = (ctx["declared"] as Dictionary).merged(ctx["params"])
	return accessor_at(e, String(ctx["cls"]), ctx["locals"], names)


func _fx_expr(e, ctx: Dictionary) -> void:
	if e == null:
		return
	if (e is GateAST._Ident or e is GateAST._Member) and _fx_accessor(e, ctx).get("get", false):
		_fx_opaque(ctx)
	if e is GateAST._Call:
		var c: GateAST._Call = e
		_fx_expr(c.callee, ctx)
		for a in c.args:
			_fx_expr(a, ctx)
		_fx_call(c, ctx)
		return
	if e is GateAST._Binary:
		var spine: Array = []
		var cur = e
		while cur is GateAST._Binary:
			spine.append(cur)
			cur = (cur as GateAST._Binary).left
		_fx_expr(cur, ctx)
		for n in spine:
			_fx_expr((n as GateAST._Binary).right, ctx)
	elif e is GateAST._NullCoalesce:
		_fx_expr((e as GateAST._NullCoalesce).left, ctx)
		_fx_expr((e as GateAST._NullCoalesce).right, ctx)
	elif e is GateAST._Ternary:
		var te: GateAST._Ternary = e
		_fx_expr(te.cond, ctx); _fx_expr(te.if_true, ctx); _fx_expr(te.if_false, ctx)
	elif e is GateAST._Member or e is GateAST._Index:
		var pspine: Array = []
		var pcur = e
		while pcur is GateAST._Member or pcur is GateAST._Index:
			pspine.append(pcur)
			pcur = (pcur as GateAST._Member).target if pcur is GateAST._Member else (pcur as GateAST._Index).target
		_fx_expr(pcur, ctx)
		for pn in pspine:
			if pn is GateAST._Index:
				_fx_expr((pn as GateAST._Index).index, ctx)
			elif pn != e and _fx_accessor(pn, ctx).get("get", false):
				_fx_opaque(ctx)
	elif e is GateAST._Unary:
		_fx_expr((e as GateAST._Unary).operand, ctx)
	elif e is GateAST._AwaitExpr:
		_fx_expr((e as GateAST._AwaitExpr).operand, ctx)
	elif e is GateAST._CastExpr:
		_fx_expr((e as GateAST._CastExpr).operand, ctx)
	elif e is GateAST._IsExpr:
		_fx_expr((e as GateAST._IsExpr).operand, ctx)
	elif e is GateAST._ArrayLit:
		for el in (e as GateAST._ArrayLit).elements: _fx_expr(el, ctx)
	elif e is GateAST._DictLit:
		for k in (e as GateAST._DictLit).keys: _fx_expr(k, ctx)
		for v in (e as GateAST._DictLit).values: _fx_expr(v, ctx)
	elif e is GateAST._ObjectInit:
		for v2 in (e as GateAST._ObjectInit).values: _fx_expr(v2, ctx)
	elif e is GateAST._FString:
		for part in (e as GateAST._FString).parts:
			if not (part is String): _fx_expr(part, ctx)
	elif e is GateAST._Lambda:
		var lam: GateAST._Lambda = e
		ctx["lambda"] = int(ctx.get("lambda", 0)) + 1
		_fx_stmts(lam.body, ctx)
		_fx_expr(lam.expr_body, ctx)
		ctx["lambda"] = int(ctx["lambda"]) - 1


func _callee_of(c: GateAST._Call, ctx: Dictionary):
	var recvs: Array = []
	var callee_fd = null
	var uname: String = ""

	if c.callee is GateAST._Ident:
		var n: String = (c.callee as GateAST._Ident).name
		callee_fd = _pick(module_functions.get(n, []), c.args.size())
		if callee_fd != null:
			recvs = [["self", -1, ""]]
		if callee_fd == null and ctx["cls"] != "":
			callee_fd = _pick(method_candidates(ctx["cls"], n), c.args.size())
			if callee_fd != null:
				recvs = [["self", -1, ""]]
		if callee_fd == null:
			uname = n
			if not is_engine_method(engine_root(String(ctx["cls"])), n):
				recvs = [["self", -1, ""]]
	elif c.callee is GateAST._Member:
		var m: GateAST._Member = c.callee
		if m.name == "new":
			return null
		recvs = _rels(m.target, ctx)
		if m.target is GateAST._Ident and (m.target as GateAST._Ident).name == "super":
			callee_fd = _pick(
				method_candidates(String(bases.get(ctx["cls"], "")), m.name), c.args.size())
		if callee_fd == null and not _method_names.has(m.name):
			uname = m.name   # no class declares a method of that name
			return [callee_fd, recvs, uname]
		var rt: GateAST._TypeRef = type_of(m.target, ctx["locals"])
		if callee_fd == null and rt != null and rt.array_depth == 0 and not rt.is_dict():
			callee_fd = _pick(method_candidates(rt.name, m.name), c.args.size())
		if callee_fd == null and rt == null:
			var holder: String = _class_named(m.target, ctx)
			if holder != "":
				var sfd: GateAST._FuncDecl = _pick(method_candidates(holder, m.name), c.args.size())
				if sfd != null and sfd.is_static:
					callee_fd = sfd   # `Class.f()`: its writes to statics reach every caller
		if callee_fd == null:
			uname = m.name
	else:
		return null
	return [callee_fd, recvs, uname]


const ELEMENT_GETTERS := {
	"back": true, "front": true, "pop_back": true, "pop_front": true, "pop_at": true,
	"get": true, "pick_random": true, "min": true, "max": true, "values": true,
}


func _call_rels(c: GateAST._Call, ctx: Dictionary, depth: int) -> Array:
	var r = _callee_of(c, ctx)
	if r == null:
		return []
	var callee_fd = r[0]
	var recvs: Array = r[1]
	var out: Array = []
	if callee_fd != null and _fx.has(callee_fd):
		_fx_reading[callee_fd] = true
		for ret in (_fx[callee_fd] as _Effects).returns:
			if ret[0] == "any":
				out.append(["self", -1, ""])
				for i in (ctx["params"] as Dictionary).size():
					out.append(["param", i, ""])
				return out
			if ret[0] == "self":
				for recv in recvs:
					out.append([recv[0], recv[1], _join_suffix(recv[2], ret[2])])
			elif ret[0] == "param" and int(ret[1]) < c.args.size():
				for ar in _rels(c.args[int(ret[1])], ctx, depth + 1):
					out.append([ar[0], ar[1], _join_suffix(ar[2], ret[2])])
			elif ret[0] == "static":
				out.append(ret)
		return out
	if c.callee is GateAST._Member and ELEMENT_GETTERS.get(r[2], false):
		for recv2 in recvs:
			out.append([recv2[0], recv2[1], _join_suffix(recv2[2], "*")])
	return out


const OPAQUE_CALLS := ["call", "callv", "emit", "emit_signal"]


func _fx_opaque(ctx: Dictionary) -> void:
	var fx: _Effects = ctx["fx"]
	if not fx.opaque:
		fx.opaque = true
		ctx["changed"] = true


func accessor_at(e, cls: String, locals: Dictionary, local_names: Dictionary) -> Dictionary:
	if accessor_fields.is_empty():
		return {}
	var owner: String = ""
	var name: String = ""
	if e is GateAST._Ident:
		name = (e as GateAST._Ident).name
		if local_names.has(name):
			return {}   # a local of that name hides the property
		owner = cls
	elif e is GateAST._Member and not (e as GateAST._Member).safe:
		var m: GateAST._Member = e
		name = m.name
		if not _accessor_names.has(name):
			return {}
		if m.target is GateAST._SelfExpr:
			owner = cls
		else:
			var t: GateAST._TypeRef = type_of(m.target, locals)
			if t == null or t.array_depth > 0 or t.is_dict():
				return {}
			owner = t.name
	else:
		return {}
	var found = _lookup(accessor_fields, owner, name)
	return found if found is Dictionary else {}


func _fx_call(c: GateAST._Call, ctx: Dictionary) -> void:
	var r = _callee_of(c, ctx)
	if r == null:
		return
	var callee_fd = r[0]
	var recvs: Array = r[1]
	var uname: String = r[2]

	if callee_fd != null and _fx.has(callee_fd):
		_fx_reading[callee_fd] = true
		var e2: _Effects = _fx[callee_fd]
		if e2.opaque:
			_fx_opaque(ctx)
		for sfx in e2.self_paths:
			for recv in recvs:
				_fx_add(ctx, recv[0], recv[1], _join_suffix(recv[2], sfx))
		for sp in e2.statics:
			_fx_add(ctx, "static", -1, sp)
		for j in e2.param_paths:
			if j >= c.args.size():
				continue
			for ar in _rels(c.args[j], ctx):
				for sfx2 in e2.param_paths[j]:
					_fx_add(ctx, ar[0], ar[1], _join_suffix(ar[2], sfx2))
		return

	if PURE_GLOBALS.has(uname):
		return
	if uname in OPAQUE_CALLS:
		_fx_opaque(ctx)
	if uname in CALLABLE_INVOKERS or SYNC_HIGHER_ORDER.has(uname):
		_fx_add(ctx, "self", -1, "*")
	for recv2 in recvs:
		_fx_add(ctx, recv2[0], recv2[1], _join_suffix(recv2[2], "*"))
	for a2 in c.args:
		for ar2 in _rels(a2, ctx):
			_fx_add(ctx, ar2[0], ar2[1], _join_suffix(ar2[2], "*"))

@tool
extends RefCounted

## The null analysis state: the abstract environment, access paths, and the rules
## for invalidating them.

enum S { NULL, NOTNULL, MAYBE }

var diagnostics: GateDiagnostics
var infer: GateInfer

var _env: Dictionary = {}
var _narrowed: Dictionary = {}
var _fresh: Dictionary = {}
var _inferred: Dictionary = {}
var _fixed: Dictionary = {}
var _locals: Dictionary = {}
var _local_names: Dictionary = {}
var _field_names: Dictionary = {}
var _cls: String = ""
var _ret: GateAST.TypeRef = null
var _quiet: int = 0

var _break_envs: Array = []
var _continue_envs: Array = []

var _in_static: bool = false

var _engine_base: String = ""

var _asserted: Dictionary = {}
var _opted_in: bool = false


func _err(msg: String, line: int, col: int, hint: String = "") -> void:
	if _quiet > 0:
		return
	if hint == "":
		diagnostics.error(msg, line, col)
	else:
		diagnostics.error(msg, line, col, hint)


func _warn(msg: String, line: int, col: int, hint: String = "") -> void:
	if _quiet > 0:
		return
	diagnostics.warn(msg, line, col, hint)

const MAX_PATH_DEPTH := 24


func _path_of(e, depth: int = 0) -> String:
	if depth > MAX_PATH_DEPTH:
		return ""
	return _path_of_inner(e, depth)


func _path_of_inner(e, depth: int) -> String:
	if e is GateAST.SelfExpr:
		return "self"
	if e is GateAST.Ident:
		var n: String = (e as GateAST.Ident).name
		if n == "super":
			return "self"
		if not _local_names.has(n) and _field_names.has(n) and not _in_static:
			return "self." + n
		return n
	if e is GateAST.Member:
		var m: GateAST.Member = e
		if m.safe:
			return ""
		if m.target is GateAST.Ident and (m.target as GateAST.Ident).name == _cls and _field_names.has(m.name):
			return m.name if _in_static else "self." + m.name
		var base: String = _path_of(m.target, depth + 1)
		if base == "":
			return ""
		return base + "." + m.name
	if e is GateAST.Index:
		var ix: GateAST.Index = e
		if ix.safe:
			return ""
		var b: String = _path_of(ix.target, depth + 1)
		if b == "":
			return ""
		var k: String = _index_key(ix.index)
		if k == "":
			return ""
		return "%s[%s]" % [b, k]
	return ""


func _index_key(e) -> String:
	if e is GateAST.Literal:
		var l: GateAST.Literal = e
		if l.kind == "number" or l.kind == "string":
			return l.raw
		return ""
	if e is GateAST.Ident:
		return (e as GateAST.Ident).name
	if e is GateAST.Unary:
		var u: GateAST.Unary = e
		if u.op == "-" and u.operand is GateAST.Literal \
			and (u.operand as GateAST.Literal).kind == "number":
			return "-" + (u.operand as GateAST.Literal).raw
	return ""


func _narrowed_type(path: String) -> GateAST.TypeRef:
	return _narrowed.get(path, null)


func _type_of(e) -> GateAST.TypeRef:
	if _narrowed.is_empty():
		return _static_type_of(e)
	return _narrowed_type_of(e, 0)


func _static_type_of(e) -> GateAST.TypeRef:
	if e is GateAST.Member and not infer.static_fields.is_empty():
		var m: GateAST.Member = e
		if not m.safe and m.target is GateAST.Ident:
			var cls: String = (m.target as GateAST.Ident).name
			var sf = infer.static_fields.get("%s.%s" % [cls, m.name])
			if sf != null:
				return sf
	return infer.type_of(e, _locals)


func _narrowed_type_of(e, depth: int) -> GateAST.TypeRef:
	if depth > MAX_PATH_DEPTH:
		return _static_type_of(e)
	var p: String = _path_of(e)
	if p != "" and _narrowed.has(p):
		return _narrowed[p]
	if e is GateAST.Member:
		var m: GateAST.Member = e
		if not m.safe and m.target is GateAST.Ident and not infer.static_fields.is_empty():
			var sf = infer.static_fields.get("%s.%s" % [(m.target as GateAST.Ident).name, m.name])
			if sf != null:
				return sf
		var base: GateAST.TypeRef = _narrowed_type_of(m.target, depth + 1)
		if base == null or base.array_depth > 0 or base.is_dict():
			return null
		return GateInfer.maybe_null(infer.field_type(base.name, m.name), m.safe and base.nullable)
	if e is GateAST.Index:
		var ie: GateAST.Index = e
		var it: GateAST.TypeRef = _narrowed_type_of(ie.target, depth + 1)
		return GateInfer.maybe_null(infer.element_type(it), ie.safe and it != null and it.nullable)
	if e is GateAST.NullCoalesce:
		var nc: GateAST.NullCoalesce = e
		return infer.coalesce_type(_narrowed_type_of(nc.left, depth + 1),
			_narrowed_type_of(nc.right, depth + 1))
	if e is GateAST.Binary:
		if infer.COMPARISONS.has((e as GateAST.Binary).op):
			return infer.binary_type((e as GateAST.Binary).op, null, null)
		var spine: Array = []
		var cur = e
		while cur is GateAST.Binary:
			spine.append(cur)   # top down: read back to front for left to right
			cur = (cur as GateAST.Binary).left
		var acc: GateAST.TypeRef = _narrowed_type_of(cur, depth + 1)
		for i in range(spine.size() - 1, -1, -1):
			var b: GateAST.Binary = spine[i]
			acc = infer.binary_type(b.op, acc,
				null if infer.COMPARISONS.has(b.op) else _narrowed_type_of(b.right, depth + 1))
		return acc
	if e is GateAST.Call and (e as GateAST.Call).callee is GateAST.Member:
		var c: GateAST.Call = e
		var cm: GateAST.Member = c.callee
		if cm.name == "new" and cm.target is GateAST.Ident:
			return _static_type_of(e)
		var recv: GateAST.TypeRef = _narrowed_type_of(cm.target, depth + 1)
		if recv != null and cm.name in ["call", "callv", "bind"] \
			and GateTypes.canonical(recv.name) == "Callable":
			return recv.callable_return
		if recv != null and recv.array_depth == 0 and not recv.is_dict():
			var fd: GateAST.FuncDecl = infer._pick(
				infer.method_candidates(recv.name, cm.name), c.args.size())
			if fd != null:
				return fd.return_type
		return null
	return _static_type_of(e)


func _is_subclass(sub: String, sup: String) -> bool:
	if sub == "" or sup == "":
		return false
	sub = GateTypes.canonical(sub)
	sup = GateTypes.canonical(sup)
	var seen: Dictionary = {}
	var c: String = sub
	while c != "" and not seen.has(c):
		if c == sup:
			return true
		seen[c] = true
		if not infer.bases.has(c):
			return ClassDB.class_exists(c) and ClassDB.class_exists(sup) \
				and ClassDB.is_parent_class(c, sup)
		c = String(infer.bases[c])
	return false


func _tracked(e) -> bool:
	var t: GateAST.TypeRef = _type_of(e)
	return t != null and t.nullable


func _state(path: String) -> int:
	return _env.get(path, S.MAYBE)


func _join_path(base: String, sfx: String) -> String:
	if base == "":
		return sfx
	if sfx == "":
		return base
	return base + "." + sfx


func _invalidate_under(path: String) -> void:
	if path == "":
		return
	for d in [_env, _narrowed]:
		var drop: Array = []
		for k in d:
			var key: String = String(k)
			if key.begins_with(path + ".") or key.begins_with(path + "["):
				drop.append(k)
		for k2 in drop:
			d.erase(k2)


func _invalidate_siblings(container: String) -> void:
	if container == "":
		return
	for d in [_env, _narrowed]:
		var drop: Array = []
		for k in d:
			if String(k).begins_with(container + "["):
				drop.append(k)
		for k2 in drop:
			d.erase(k2)


func _kill_index_var(name: String) -> void:
	for d in [_env, _narrowed]:
		var drop: Array = []
		for k in d:
			if String(k).contains("[" + name + "]"):
				drop.append(k)
		for k2 in drop:
			d.erase(k2)


func _kill_path(path: String) -> void:
	if path == "":
		return
	_env.erase(path)
	_narrowed.erase(path)
	_invalidate_under(path)


func _kill_suffix(base: String, sfx: String) -> void:
	if base == "":
		return
	var star: int = sfx.find("*")
	if star >= 0:
		var pre: String = sfx.substr(0, star)
		while pre.ends_with("."):
			pre = pre.substr(0, pre.length() - 1)
		_invalidate_under(_join_path(base, pre))
		return
	_kill_path(_join_path(base, sfx))


func _kill_self_suffix(recv: String, sfx: String) -> void:
	if recv != "self" or not _in_static:
		_kill_suffix(recv, sfx)
		return
	var star: int = sfx.find("*")
	if star < 0:
		_kill_path(sfx)
		return
	var pre: String = sfx.substr(0, star)
	while pre.ends_with("."):
		pre = pre.substr(0, pre.length() - 1)
	if pre != "":
		_kill_path(pre)
		_invalidate_under(pre)
		return
	var drop: Array = []
	for k in _env:
		var root: String = String(k).split(".")[0].split("[")[0]
		if not _local_names.has(root):
			drop.append(k)
	for k2 in drop:
		_env.erase(k2)


func _kill_target(target) -> void:
	if target is GateAST.Ident:
		_kill_index_var((target as GateAST.Ident).name)
	if target is GateAST.Index:
		var ix: GateAST.Index = target
		_invalidate_siblings(_path_of(ix.target))
	var p: String = _path_of(target)
	if p != "":
		_narrowed.erase(p)
		_invalidate_under(p)


func _invalidate_across_suspend() -> void:
	for d in [_env, _narrowed]:
		var drop: Array = []
		for k in d:
			var key: String = String(k)
			if key.contains(".") or key.contains("["):
				drop.append(k)
		for k2 in drop:
			d.erase(k2)


func _join(a: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var keys: Dictionary = {}
	for k in a: keys[k] = true
	for k in b: keys[k] = true
	for k in keys:
		var sa: int = a.get(k, S.MAYBE)
		var sb: int = b.get(k, S.MAYBE)
		out[k] = sa if sa == sb else S.MAYBE
	return out


func _join_types(a: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in a:
		if b.has(k) and _same_type(a[k], b[k]):
			out[k] = a[k]
	return out


func _types_diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in a:
		if not b.has(k) or not _same_type(a[k], b[k]):
			out[k] = true
	for k2 in b:
		if not a.has(k2):
			out[k2] = true
	return out


static func _same_type(a: GateAST.TypeRef, b: GateAST.TypeRef) -> bool:
	if a == b:
		return true
	if a == null or b == null:
		return false
	return a.describe() == b.describe()


func _env_eq(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k) or b[k] != a[k]:
			return false
	return true

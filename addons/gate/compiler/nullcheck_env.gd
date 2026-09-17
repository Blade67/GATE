@tool
extends RefCounted

## The null analysis state: the abstract environment, access paths, and the rules
## for invalidating them.

enum S { NULL, NOTNULL, MAYBE }

var diagnostics: GateDiagnostics
var infer: GateInfer

var _env: Dictionary = {}
var _locals: Dictionary = {}
var _local_names: Dictionary = {}
var _field_names: Dictionary = {}
var _cls: String = ""
var _ret: GateAST.GateTypeRef = null
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
	if e is GateAST.GateSelfExpr:
		return "self"
	if e is GateAST.GateIdent:
		var n: String = (e as GateAST.GateIdent).name
		if n == "super":
			return "self"
		if not _local_names.has(n) and _field_names.has(n) and not _in_static:
			return "self." + n
		return n
	if e is GateAST.GateMember:
		var m: GateAST.GateMember = e
		if m.safe:
			return ""
		if m.target is GateAST.GateIdent and (m.target as GateAST.GateIdent).name == _cls and _field_names.has(m.name):
			return m.name if _in_static else "self." + m.name
		var base: String = _path_of(m.target, depth + 1)
		if base == "":
			return ""
		return base + "." + m.name
	if e is GateAST.GateIndex:
		var ix: GateAST.GateIndex = e
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
	if e is GateAST.GateLiteral:
		var l: GateAST.GateLiteral = e
		if l.kind == "number" or l.kind == "string":
			return l.raw
		return ""
	if e is GateAST.GateIdent:
		return (e as GateAST.GateIdent).name
	if e is GateAST.GateUnary:
		var u: GateAST.GateUnary = e
		if u.op == "-" and u.operand is GateAST.GateLiteral \
			and (u.operand as GateAST.GateLiteral).kind == "number":
			return "-" + (u.operand as GateAST.GateLiteral).raw
	return ""


func _type_of(e) -> GateAST.GateTypeRef:
	if e is GateAST.GateMember:
		var m: GateAST.GateMember = e
		if not m.safe and m.target is GateAST.GateIdent:
			var cls: String = (m.target as GateAST.GateIdent).name
			var sf = infer.static_fields.get("%s.%s" % [cls, m.name])
			if sf != null:
				return sf
	return infer.type_of(e, _locals)


func _tracked(e) -> bool:
	var t: GateAST.GateTypeRef = _type_of(e)
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
	var drop: Array = []
	for k in _env:
		var key: String = String(k)
		if key.begins_with(path + ".") or key.begins_with(path + "["):
			drop.append(k)
	for k2 in drop:
		_env.erase(k2)


func _invalidate_siblings(container: String) -> void:
	if container == "":
		return
	var drop: Array = []
	for k in _env:
		if String(k).begins_with(container + "["):
			drop.append(k)
	for k2 in drop:
		_env.erase(k2)


func _kill_index_var(name: String) -> void:
	var drop: Array = []
	for k in _env:
		if String(k).contains("[" + name + "]"):
			drop.append(k)
	for k2 in drop:
		_env.erase(k2)


func _kill_path(path: String) -> void:
	if path == "":
		return
	_env.erase(path)
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
	if target is GateAST.GateIdent:
		_kill_index_var((target as GateAST.GateIdent).name)
	if target is GateAST.GateIndex:
		var ix: GateAST.GateIndex = target
		_invalidate_siblings(_path_of(ix.target))
	var p: String = _path_of(target)
	if p != "":
		_invalidate_under(p)


func _invalidate_across_suspend() -> void:
	var drop: Array = []
	for k in _env:
		var key: String = String(k)
		if key.contains(".") or key.contains("["):
			drop.append(k)
	for k2 in drop:
		_env.erase(k2)


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


func _env_eq(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k) or b[k] != a[k]:
			return false
	return true

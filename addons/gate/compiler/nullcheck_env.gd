@tool
extends RefCounted

## The null analysis state: the abstract environment, access paths, and the rules
## for invalidating them.

enum _S { NULL, NOTNULL, MAYBE }

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
var _ret: GateAST._TypeRef = null
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
	if e is GateAST._SelfExpr:
		return "self"
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		if n == "super":
			return "self"
		if not _local_names.has(n) and _field_names.has(n) and not _in_static:
			return "self." + n
		return n
	if e is GateAST._Member:
		var m: GateAST._Member = e
		if m.safe:
			return ""
		if m.target is GateAST._Ident and (m.target as GateAST._Ident).name == _cls and _field_names.has(m.name):
			return m.name if _in_static else "self." + m.name
		var base: String = _path_of(m.target, depth + 1)
		if base == "":
			return ""
		return base + "." + m.name
	if e is GateAST._Index:
		var ix: GateAST._Index = e
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
	if e is GateAST._Literal:
		var l: GateAST._Literal = e
		if l.kind == "number" or l.kind == "string":
			return l.raw
		return ""
	if e is GateAST._Ident:
		return (e as GateAST._Ident).name
	if e is GateAST._Unary:
		var u: GateAST._Unary = e
		if u.op == "-" and u.operand is GateAST._Literal \
			and (u.operand as GateAST._Literal).kind == "number":
			return "-" + (u.operand as GateAST._Literal).raw
	return ""


func _narrowed_type(path: String) -> GateAST._TypeRef:
	return _narrowed.get(path, null)


func _type_of(e) -> GateAST._TypeRef:
	if _narrowed.is_empty():
		return _static_type_of(e)
	return _narrowed_type_of(e, 0)


func _static_type_of(e) -> GateAST._TypeRef:
	if e is GateAST._Member and not infer.static_fields.is_empty():
		var m: GateAST._Member = e
		if not m.safe and m.target is GateAST._Ident:
			var cls: String = (m.target as GateAST._Ident).name
			var sf = infer.static_fields.get("%s.%s" % [cls, m.name])
			if sf != null:
				return sf
	return infer.type_of(e, _locals)


func _narrowed_type_of(e, depth: int) -> GateAST._TypeRef:
	if depth > MAX_PATH_DEPTH:
		return _static_type_of(e)
	var p: String = _path_of(e)
	if p != "" and _narrowed.has(p):
		return _narrowed[p]
	if e is GateAST._Member:
		var m: GateAST._Member = e
		if not m.safe and m.target is GateAST._Ident and not infer.static_fields.is_empty():
			var sf = infer.static_fields.get("%s.%s" % [(m.target as GateAST._Ident).name, m.name])
			if sf != null:
				return sf
		var base: GateAST._TypeRef = _narrowed_type_of(m.target, depth + 1)
		if base == null or base.array_depth > 0 or base.is_dict():
			return null
		return GateInfer.maybe_null(infer.field_type(base.name, m.name), m.safe and base.nullable)
	if e is GateAST._Index:
		var ie: GateAST._Index = e
		var it: GateAST._TypeRef = _narrowed_type_of(ie.target, depth + 1)
		return GateInfer.maybe_null(infer.element_type(it), ie.safe and it != null and it.nullable)
	if e is GateAST._NullCoalesce:
		var nc: GateAST._NullCoalesce = e
		return infer.coalesce_type(_narrowed_type_of(nc.left, depth + 1),
			_narrowed_type_of(nc.right, depth + 1))
	if e is GateAST._Binary:
		if infer.COMPARISONS.has((e as GateAST._Binary).op):
			return infer.binary_type((e as GateAST._Binary).op, null, null)
		var spine: Array = []
		var cur = e
		while cur is GateAST._Binary:
			spine.append(cur)   # top down: read back to front for left to right
			cur = (cur as GateAST._Binary).left
		var acc: GateAST._TypeRef = _narrowed_type_of(cur, depth + 1)
		for i in range(spine.size() - 1, -1, -1):
			var b: GateAST._Binary = spine[i]
			acc = infer.binary_type(b.op, acc,
				null if infer.COMPARISONS.has(b.op) else _narrowed_type_of(b.right, depth + 1))
		return acc
	if e is GateAST._Call and (e as GateAST._Call).callee is GateAST._Member:
		var c: GateAST._Call = e
		var cm: GateAST._Member = c.callee
		if cm.name == "new" and cm.target is GateAST._Ident:
			return _static_type_of(e)
		var recv: GateAST._TypeRef = _narrowed_type_of(cm.target, depth + 1)
		if recv != null and cm.name in ["call", "callv", "bind"] \
			and GateTypes.canonical(recv.name) == "Callable":
			return recv.callable_return
		if recv != null and recv.array_depth == 0 and not recv.is_dict():
			var fd: GateAST._FuncDecl = infer._pick(
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
	var t: GateAST._TypeRef = _type_of(e)
	return t != null and t.nullable


func _state(path: String) -> int:
	return _env.get(path, _S.MAYBE)


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


func _kill_suffix(base: String, sfx: String, bt: GateAST._TypeRef = null) -> void:
	_kill_suffix_aliases(base, sfx, bt)
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


func _kill_self_suffix(recv: String, sfx: String, recv_t: GateAST._TypeRef = null) -> void:
	if recv != "self" or not _in_static:
		_kill_suffix(recv, sfx, recv_t)
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
	for d in [_env, _narrowed]:
		var drop: Array = []
		for k in d:
			var root: String = String(k).split(".")[0].split("[")[0]
			if not _local_names.has(root):
				drop.append(k)
		for k2 in drop:
			d.erase(k2)


func _kill_static(key: String) -> void:
	var owner: String = ""
	var field: String = ""
	var sfx: String = ""
	if key != "*":
		var parts: PackedStringArray = key.split(".", true, 2)
		if parts.size() < 2:
			return
		owner = parts[0]
		field = parts[1]
		sfx = parts[2] if parts.size() > 2 else ""
	for h in _static_heads(owner, field):
		_kill_suffix(h, sfx)


func _static_heads(owner: String, field: String) -> Dictionary:
	var heads: Dictionary = {}
	for d in [_env, _narrowed]:
		for k in d:
			var h: String = _static_head(String(k), owner, field, [])
			if h != "":
				heads[h] = true
	return heads


func _static_head(path: String, owner: String, field: String, slot: Array) -> String:
	var seps: PackedInt32Array = _path_seps(path)
	var root: String = path.substr(0, seps[0]) if not seps.is_empty() else path
	var named: bool = not _local_names.has(root)   # not hidden by a local
	if named and _in_static and _is_static_of(_cls, root, owner, field):
		slot.append("%s.%s" % [infer.static_owner(_cls, root), root])
		return root
	var class_root: bool = named and not _field_names.has(root) and infer.has_class(root)
	for i in seps.size():
		if path[seps[i]] != ".":
			continue
		var end: int = seps[i + 1] if i + 1 < seps.size() else path.length()
		var f: String = path.substr(seps[i] + 1, end - seps[i] - 1)
		var holder: String = root if i == 0 and class_root else ""
		if holder == "":
			var ht: GateAST._TypeRef = _type_of_path(path.substr(0, seps[i]))
			if ht == null or ht.array_depth > 0 or ht.is_dict():
				continue
			holder = ht.name
		if _is_static_of(holder, f, owner, field):
			slot.append("%s.%s" % [infer.static_owner(holder, f), f])
			return path.substr(0, end)
	return ""


func _is_static_of(cls: String, f: String, owner: String, field: String) -> bool:
	var found: String = infer.static_owner(cls, f)
	return found != "" and (owner == "" or (found == owner and f == field))


func _kill_target(target, value_state: int = -1) -> void:
	if target is GateAST._Ident:
		_kill_index_var((target as GateAST._Ident).name)
		var fp: String = _path_of(target)
		if fp.begins_with("self."):
			_kill_aliases("self", _locals.get("self", null), fp.substr(5), value_state)
	if target is GateAST._Index:
		var ix: GateAST._Index = target
		var container: String = _path_of(ix.target)
		_invalidate_siblings(container)
		_kill_aliases(container, _type_of(ix.target), "", value_state)
	elif target is GateAST._Member:
		var m: GateAST._Member = target
		_kill_aliases(_path_of(m.target), _type_of(m.target), m.name, value_state)
	var p: String = _path_of(target)
	if p != "":
		_narrowed.erase(p)
		_invalidate_under(p)
		if not infer.static_fields.is_empty():
			_write_static_spellings(p, value_state)


func _write_static_spellings(path: String, value_state: int) -> void:
	var slot: Array = []
	if _static_head(path, "", "", slot) != path:
		return
	var parts: PackedStringArray = String(slot[0]).split(".")
	for h in _static_heads(parts[0], parts[1]):
		if h == path:
			continue
		_kill_path(h)
		if value_state >= 0:
			_env[h] = value_state


## A write to a slot clears that slot on every path that may be the same object.
func _kill_aliases(base: String, bt: GateAST._TypeRef, f: String, new_state: int = -1) -> void:
	if base != "" and _fresh.has(base):
		return
	var needle: String = ("." + f) if f != "" else "["
	var memo: Dictionary = {}
	for di in 2:
		var d: Dictionary = _env if di == 0 else _narrowed
		var drop: Array = []
		var joins: Dictionary = {}
		for k in d:
			var key: String = String(k)
			if not key.contains(needle):
				continue
			for pos in _slot_positions(key, f):
				var x: String = key.substr(0, pos)
				if x == base or _fresh.has(x):
					continue
				if not memo.has(x):
					memo[x] = _may_alias(x, _type_of_path(x), base, bt)
				if memo[x]:
					var seps: PackedInt32Array = _path_seps(key)
					if di == 0 and new_state >= 0 and seps[seps.size() - 1] == pos:
						joins[k] = d[k] if int(d[k]) == new_state else _S.MAYBE
					else:
						drop.append(k)
					break
		for k2 in drop:
			d.erase(k2)
		for k3 in joins:
			d[k3] = joins[k3]


func _kill_suffix_aliases(base: String, sfx: String, bt: GateAST._TypeRef) -> void:
	var star: int = sfx.find("*")
	var pre: String = sfx if star < 0 else sfx.substr(0, star)
	while pre.ends_with("."):
		pre = pre.substr(0, pre.length() - 1)
	if pre == "":
		return
	var segs: PackedStringArray = pre.split(".")
	var holder: String = base
	var ht: GateAST._TypeRef = bt if base == "" else _type_of_path(base)
	for i in segs.size() - 1:
		if holder != "":
			holder = holder + "." + segs[i]
		ht = _field_step(ht, segs[i])
	var last: String = segs[segs.size() - 1]
	if star < 0:
		_kill_aliases(holder, ht, last)
	else:
		var sub: String = holder + "." + last if holder != "" else ""
		_kill_alias_subtrees(sub, _field_step(ht, last))


func _field_step(t: GateAST._TypeRef, f: String) -> GateAST._TypeRef:
	if t == null or t.array_depth > 0 or t.is_dict():
		return null
	return infer.field_type(t.name, f)


func _kill_alias_subtrees(sub: String, st: GateAST._TypeRef) -> void:
	if sub != "" and _fresh.has(sub):
		return
	var memo: Dictionary = {}
	for d in [_env, _narrowed]:
		var drop: Array = []
		for k in d:
			var key: String = String(k)
			for pos in _path_seps(key):
				var x: String = key.substr(0, pos)
				if x == sub or _fresh.has(x):
					continue
				if not memo.has(x):
					memo[x] = _may_alias(x, _type_of_path(x), sub, st)
				if memo[x]:
					drop.append(k)
					break
		for k2 in drop:
			d.erase(k2)


func _slot_positions(key: String, f: String) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var seps: PackedInt32Array = _path_seps(key)
	for i in seps.size():
		var at: int = seps[i]
		if f == "":
			if key[at] == "[":
				out.append(at)
			continue
		if key[at] != ".":
			continue
		var end: int = seps[i + 1] if i + 1 < seps.size() else key.length()
		if key.substr(at + 1, end - at - 1) == f:
			out.append(at)
	return out


func _path_seps(path: String) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var depth: int = 0
	var quote: String = ""
	var i: int = 0
	while i < path.length():
		var c: String = path[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c == "[":
			if depth == 0:
				out.append(i)
			depth += 1
		elif c == "]":
			depth -= 1
		elif c == "." and depth == 0:
			out.append(i)
		i += 1
	return out


func _type_of_path(path: String, depth: int = 0) -> GateAST._TypeRef:
	if _narrowed.has(path):
		return _narrowed[path]
	if depth > MAX_PATH_DEPTH:
		return null
	var seps: PackedInt32Array = _path_seps(path)
	if seps.is_empty():
		return _locals.get(path, null)
	var cut: int = seps[seps.size() - 1]
	var bt: GateAST._TypeRef = _type_of_path(path.substr(0, cut), depth + 1)
	if bt == null:
		return null
	if path[cut] == "[":
		return infer.element_type(bt)
	if bt.array_depth > 0 or bt.is_dict():
		return null
	return infer.field_type(bt.name, path.substr(cut + 1))


## Whether two paths may name the same object. `b` is "" for an object reached
## through a call.
func _may_alias(x: String, xt: GateAST._TypeRef, b: String, bt: GateAST._TypeRef,
		depth: int = 0) -> bool:
	if _is_struct_type(xt) or _is_struct_type(bt):
		if b == "" or depth > MAX_PATH_DEPTH:
			return true
		var xs: PackedInt32Array = _path_seps(x)
		var bs: PackedInt32Array = _path_seps(b)
		if xs.is_empty() or bs.is_empty():
			return false
		var xc: int = xs[xs.size() - 1]
		var bc: int = bs[bs.size() - 1]
		if x[xc] != b[bc]:
			return false
		if x[xc] == "." and x.substr(xc + 1) != b.substr(bc + 1):
			return false
		var xp: String = x.substr(0, xc)
		var bp: String = b.substr(0, bc)
		if xp == bp:
			return true
		return _may_alias(xp, _type_of_path(xp), bp, _type_of_path(bp), depth + 1)
	if xt == null or bt == null:
		return true
	if xt.is_dict() or bt.is_dict():
		return (xt.is_dict() or _is_plain(xt, "Dictionary")) \
			and (bt.is_dict() or _is_plain(bt, "Dictionary"))
	if xt.array_depth > 0 or bt.array_depth > 0:
		if xt.array_depth == bt.array_depth:
			return _related(xt.name, bt.name)
		return _is_plain(xt, "Array") or _is_plain(bt, "Array")
	var xn: String = GateTypes.canonical(xt.name)
	var bn: String = GateTypes.canonical(bt.name)
	if xn in ["", "Variant", "Object"] or bn in ["", "Variant", "Object"]:
		return true
	if infer.open_types.has(xn) or infer.open_types.has(bn):
		return true
	return _related(xn, bn)


func _related(a: String, b: String) -> bool:
	return _is_subclass(a, b) or _is_subclass(b, a)


func _is_plain(t: GateAST._TypeRef, name: String) -> bool:
	return t.array_depth == 0 and not t.is_dict() and GateTypes.canonical(t.name) == name


func _is_struct_type(t: GateAST._TypeRef) -> bool:
	return t != null and t.array_depth == 0 and not t.is_dict() \
		and infer.struct_names.has(t.name)


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
		var sa: int = a.get(k, _S.MAYBE)
		var sb: int = b.get(k, _S.MAYBE)
		out[k] = sa if sa == sb else _S.MAYBE
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


static func _same_type(a: GateAST._TypeRef, b: GateAST._TypeRef) -> bool:
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

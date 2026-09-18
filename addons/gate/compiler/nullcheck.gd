@tool
class_name GateNullCheck
extends "res://addons/gate/compiler/nullcheck_env.gd"

## Flow-sensitive null analysis for values declared `T?`.
##
## Only nullable declared types participate, so ordinary GDScript cannot produce a
## false positive. Loops are analysed to a fixpoint.


func check(mod: GateAST._Module, diags: GateDiagnostics, registry = null) -> void:
	diagnostics = diags
	infer = GateInfer.new()
	infer.build(mod, registry)
	_opted_in = mod.uses_nullable
	_struct_names = {}
	_enum_names = {}
	if registry != null:
		var own: Dictionary = GateChecker.own_names(mod.members)
		for sn in registry.structs:
			if not own.has(sn):
				_struct_names[sn] = true
	_collect_struct_names(mod.members)
	_const_exprs = GateChecker.const_values(mod.members)
	_gate_types = mod.uses_gate_types or _registry_has_gate_types(registry)
	var runs: Array = [] if _instance_run else _instance_modules(mod, registry)
	_walk_members(mod.members, GateInfer.MODULE_CLASS)
	for r in runs:
		var found: GateDiagnostics = GateDiagnostics.new()
		found.file = diags.file
		var sub: GateNullCheck = GateNullCheck.new()
		sub._instance_run = true
		sub.check(r[1], found, registry)
		var only: Dictionary = {}
		GateChecker.positions_in(r[2], only, {})
		GateChecker.report_instance(diags, found, r[0], only)


var _gate_types: bool = false
var _instance_run: bool = false


static func _instance_modules(mod: GateAST._Module, registry) -> Array:
	var out: Array = []
	for inst in GateChecker.generic_instances(mod, registry):
		if inst[0] == null:
			continue   # the checker reports the ones it stopped at
		var memo: Dictionary = {}
		var copy: GateAST._Module = GateChecker.clone_ast(mod, memo)
		var tid: int = (inst[0] as Object).get_instance_id()
		var bound: GateAST._ClassDecl
		if memo.has(tid):
			bound = memo[tid]
		else:
			bound = GateChecker.clone_ast(inst[0], memo)
			copy.members.append(bound)
		GateChecker.bind_generic(bound, inst[1])
		out.append([inst, copy, bound])
	return out


static var _gate_types_of: Array = [null, false]


static func _registry_has_gate_types(registry) -> bool:
	if registry == null:
		return false
	var seen: WeakRef = _gate_types_of[0]
	if seen != null and seen.get_ref() == registry:
		return _gate_types_of[1]
	var found: bool = _registry_scan_gate_types(registry)
	_gate_types_of = [weakref(registry), found]
	return found


static func _registry_scan_gate_types(registry) -> bool:
	if "aliases" in registry and not registry.aliases.is_empty():
		return true
	for k in registry.fields:
		if GateChecker.is_gate_only_type(registry.fields[k]):
			return true
	for k2 in registry.methods:
		for fd in registry.methods[k2]:
			var f: GateAST._FuncDecl = fd
			if GateChecker.is_gate_only_type(f.return_type):
				return true
			for p in f.params:
				if GateChecker.is_gate_only_type((p as GateAST._Param).type):
					return true
	return false


var _const_exprs: Dictionary = {}
var _struct_names: Dictionary = {}
var _enum_names: Dictionary = {}


func _collect_struct_names(members: Array) -> void:
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			if cd.form == "struct":
				_struct_names[cd.name] = true
			_collect_struct_names(cd.members)
		elif m is GateAST._EnumDecl and (m as GateAST._EnumDecl).name != "":
			_enum_names[(m as GateAST._EnumDecl).name] = true


func _check_union_default(vd: GateAST._VarDecl) -> void:
	var t: GateAST._TypeRef = vd.type
	if t == null or t.nullable or t.array_depth > 0 or not (t.is_union() or t.is_tuple()):
		return
	if vd.value != null:
		return
	if t.is_union():
		var first: GateAST._TypeRef = t.union_members[0]
		if _has_default(first):
			return
		_err("'%s' has no initial value, and %s, the first type in %s, has no default"
				% [vd.name, first.describe(), t.describe()], vd.line, vd.col,
			"give it a value, put a type that has a default first, or declare it `%s?`"
				% t.describe())
		return
	for i in t.tuple_elems.size():
		var te: GateAST._TypeRef = t.tuple_elems[i]
		if not _has_default(te):
			_err("'%s' has no initial value, and element %d of %s, %s, has no default"
					% [vd.name, i, t.describe(), te.describe()], vd.line, vd.col,
				"give it a value, or declare that element `%s?`" % te.describe())
			return


func _has_default(t: GateAST._TypeRef) -> bool:
	var leaf: String = t.name.get_slice(".", t.name.get_slice_count(".") - 1)
	if t.nullable or t.array_depth > 0 or t.is_dict() or t.is_set() or _enum_names.has(t.name) \
			or _enum_names.has(leaf):
		return true
	if t.is_union():
		return _has_default(t.union_members[0])
	if t.is_tuple():
		for te in t.tuple_elems:
			if not _has_default(te):
				return false
		return true
	var n: String = GateTypes.canonical(t.name)
	return GateTypes.BUILTIN.has(n) or GateTypeCompat.PACKED_ARRAYS.has(n) \
		or GateTypes.PACKED.has(t.name) or _struct_names.has(t.name)


func _walk_members(members: Array, cls: String) -> void:
	var saved_cls: String = _cls
	var saved_fields: Dictionary = _field_names
	var saved_engine: String = _engine_base
	_cls = cls
	_field_names = _fields_of(cls)
	_engine_base = infer.engine_root(cls)
	for m in members:
		if m is GateAST._FuncDecl:
			_check_func(m, cls)
		elif m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			if cd.form in ["interface", "trait"]:
				continue
			_walk_members(cd.members, cd.name)
		elif m is GateAST._VarDecl:
			var vd: GateAST._VarDecl = m
			if vd.type != null and vd.value == null:
				_check_union_default(vd)
				if not infer.struct_names.has(cls):
					_require_struct_default(vd)
			var saved_locals: Dictionary = _locals
			_locals = _field_names.duplicate() if not vd.is_static else _static_field_names(cls)
			vd.value = _check_value_against(vd.type, vd.value, "'%s'" % vd.name, vd.line, vd.col, false)
			_locals = saved_locals
			_check_field_init_values(vd.value)
	_cls = saved_cls
	_field_names = saved_fields
	_engine_base = saved_engine


func _static_field_names(cls: String) -> Dictionary:
	var out: Dictionary = {}
	for k in infer.static_fields:
		var key: String = String(k)
		if key.begins_with(cls + "."):
			var f: String = key.substr(cls.length() + 1)
			if not f.contains("."):
				out[f] = infer.static_fields[k]
	return out


func _fields_of(cls: String) -> Dictionary:
	var out: Dictionary = {}
	if cls == "":
		return out
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c):
		seen[c] = true
		for k in infer.fields:
			var key: String = String(k)
			if key.begins_with(c + "."):
				var f: String = key.substr(c.length() + 1)
				if not f.contains("."):
					out[f] = infer.fields[k]
		c = infer.bases.get(c, "")
	return out


func _declare_local(name: String, t, inferred: bool = false) -> void:
	_local_names[name] = true
	_inferred.erase(JOINED + name)
	if t != null:
		_locals[name] = t
	else:
		_locals.erase(name)
	_env.erase(name)
	_narrowed.erase(name)
	if inferred:
		_fixed.erase(name)
		if t != null:
			_inferred[name] = t
		else:
			_inferred.erase(name)
	else:
		_inferred.erase(name)
		if t != null:
			_fixed[name] = true
		else:
			_fixed.erase(name)


func _retype_local(name: String, t: GateAST._TypeRef) -> void:
	_inferred.erase(JOINED + name)
	if t != null:
		_inferred[name] = t
		_locals[name] = t
	else:
		_inferred.erase(name)
		_locals.erase(name)


func _follows_assignments(name: String) -> bool:
	return _local_names.has(name) and not _fixed.has(name)


func _check_func(fd: GateAST._FuncDecl, cls: String) -> void:
	var saved_destructured: Dictionary = _destructured
	_destructured = {}
	var saved_env: Dictionary = _env
	var saved_narrowed: Dictionary = _narrowed
	var saved_fresh: Dictionary = _fresh
	var saved_inferred: Dictionary = _inferred
	var saved_fixed: Dictionary = _fixed
	var saved_locals: Dictionary = _locals
	var saved_names: Dictionary = _local_names
	var saved_ret: GateAST._TypeRef = _ret
	_env = {}
	_narrowed = {}
	_fresh = _scan_fresh(fd.body, null)
	_inferred = {}
	_fixed = {}
	_locals = {}
	_local_names = {}
	_asserted = {}
	_ret = fd.return_type
	var saved_static: bool = _in_static
	_in_static = fd.is_static

	if cls != "" and not fd.is_static:
		var self_t: GateAST._TypeRef = GateAST._TypeRef.new()
		self_t.name = cls
		_locals["self"] = self_t
		for f in _field_names:
			_locals[f] = _field_names[f]
	elif cls != "":
		var statics: Dictionary = _static_field_names(cls)
		for f in statics:
			_locals[f] = statics[f]

	for p in fd.params:
		var pp: GateAST._Param = p
		if pp.default != null:
			_check_param_default(pp, fd.name)
		_declare_local(pp.name, pp.type)
		_explicit[pp.name] = pp.type != null and not pp.inferred
		if pp.type != null and pp.type.nullable:
			_env[pp.name] = _S.MAYBE

	_walk_block(fd.body)

	_env = saved_env
	_narrowed = saved_narrowed
	_fresh = saved_fresh
	_inferred = saved_inferred
	_fixed = saved_fixed
	_locals = saved_locals
	_local_names = saved_names
	_ret = saved_ret
	_in_static = saved_static
	_destructured = saved_destructured


func _check_param_default(pp: GateAST._Param, owner: String) -> void:
	if pp.default == null or pp.type == null:
		return
	if not GateChecker.is_gate_only_type(pp.type):
		_check_known_plain(pp.type, pp.default,
			"the default of %s parameter '%s'" % [owner if owner == "the lambda" else "'%s'" % owner,
				pp.name], pp.line, pp.col)
		return
	pp.default = _check_gate_value(pp.type, pp.default,
		"the default of %s parameter '%s'" % [owner if owner == "the lambda" else "'%s'" % owner,
			pp.name], pp.line, pp.col)


func _walk_block(body: Array) -> bool:
	var exits: bool = false
	for s in body:
		if _walk_stmt(s):
			exits = true
	return exits


func _walk_stmt(s) -> bool:
	if s == null:
		return false

	if s is GateAST._AnnotatedStmt:
		if (s as GateAST._AnnotatedStmt).stmt == null:
			return false
		return _walk_stmt((s as GateAST._AnnotatedStmt).stmt)

	if s is GateAST._VarDecl:
		var vd: GateAST._VarDecl = s
		_adopt_callable_type(vd.type, vd.value)
		if vd.value != null:
			_check_expr(vd.value)
		if vd.type != null and vd.value == null:
			_check_union_default(vd)
			_require_struct_default(vd)
		vd.value = _check_value_against(vd.type, vd.value, "'%s'" % vd.name, vd.line, vd.col)
		var gate_t: GateAST._TypeRef = null
		if vd.inferred and vd.type == null and vd.value != null and _gate_types:
			gate_t = _colon_eq_type(vd)
		_explicit[vd.name] = vd.type != null or (vd.inferred and vd.value is GateAST._Literal
			and (vd.value as GateAST._Literal).kind != "null")
		var carried: GateAST._TypeRef = null
		if gate_t != null:
			_declare_local(vd.name, gate_t)
		elif vd.type != null:
			_declare_local(vd.name, vd.type)
		else:
			var static_t: GateAST._TypeRef = _static_type_of(vd.value)
			var narrow_t: GateAST._TypeRef = _type_of(vd.value)
			if narrow_t != null and not _same_type(narrow_t, static_t):
				carried = narrow_t
			_declare_local(vd.name, static_t, not vd.inferred)
			_note_joined(vd.name, vd.value)
		_kill_path(vd.name)
		_kill_index_var(vd.name)
		if carried != null:
			_narrowed[vd.name] = carried
		if vd.type != null and vd.type.nullable:
			_env[vd.name] = _state_of(vd.value)
		elif vd.type == null and vd.value != null and (
				(_locals.has(vd.name) and (_locals[vd.name] as GateAST._TypeRef).nullable)
				or (carried != null and carried.nullable)):
			_env[vd.name] = _state_of(vd.value)
		return false

	if s is GateAST._AssignStmt:
		var a: GateAST._AssignStmt = s
		if _gate_types and a.op == "=" and a.value is GateAST._Lambda:
			_adopt_callable_type(_type_of(a.target), a.value)
		_check_expr(a.value)
		_check_expr(a.target)
		if a.op != "=":
			_check_value_operand(a.target, a.op, a.line, a.col)
			if _gate_types:
				_check_union_operator(a.op.trim_suffix("="), a.target, a.value, a.line, a.col)
		var retype: bool = a.target is GateAST._Ident \
			and _follows_assignments((a.target as GateAST._Ident).name)
		var new_t: GateAST._TypeRef = null
		if retype and a.op == "=":
			new_t = _static_type_of(a.value)
		elif retype:
			var bin: GateAST._Binary = GateAST._Binary.new()
			bin.op = a.op.trim_suffix("=")
			bin.left = a.target
			bin.right = a.value
			new_t = _static_type_of(bin)
		var path: String = _path_of(a.target)
		var target_t: GateAST._TypeRef = _type_of(a.target) \
			if _gate_types and a.op == "=" and not retype else null
		_kill_target(a.target, _state_of(a.value) if a.op == "=" else -1)
		if retype:
			_retype_local((a.target as GateAST._Ident).name, new_t)
			if a.op == "=":
				_note_joined((a.target as GateAST._Ident).name, a.value)
		if target_t != null and GateChecker.is_gate_only_type(target_t) \
				and (_tracked(a.target) or path == ""):
			a.value = _check_gate_value(target_t, a.value,
				"'%s'" % (path if path != "" else "the target"), a.line, a.col)
		if a.target is GateAST._Index and a.op == "=":
			var kix: GateAST._Index = a.target
			var kt: GateAST._TypeRef = _decl_key(_type_of(kix.target))
			if kt != null and kix.index != null:
				_check_known_plain(kt, kix.index, "a key of '%s'" % _shown(kix.target),
					kix.index.line, kix.index.col)
		if _gate_types and a.target is GateAST._Index and a.op == "=":
			var elem_t: GateAST._TypeRef = _tuple_slot(a.target as GateAST._Index, false)
			if elem_t != null and _check_compat(elem_t, a.value, "'%s'" % _shown(a.target),
					a.line, a.col):
				a.value = _widen(elem_t, a.value, "'%s'" % _shown(a.target), a.line, a.col, true)
		if path != "":
			if _tracked(a.target):
				if a.op == "=" and not retype:
					var declared_t: GateAST._TypeRef = _static_type_of(a.target)
					if declared_t != null and not _is_untyped(declared_t):
						_check_known_plain(declared_t, a.value, "'%s'" % path, a.line, a.col)
				if a.op == "=":
					_env[path] = _state_of(a.value)
				elif _is_value_typed(a.target):
					_env[path] = _S.NOTNULL
				else:
					_env[path] = _S.MAYBE
			elif a.op == "=" and not retype and not (a.target is GateAST._Index
					and _tuple_slot(a.target as GateAST._Index, false) != null):
				a.value = _check_value_against(_type_of(a.target), a.value,
					"'%s'" % path, a.line, a.col)
		if not _accessor(a.target).is_empty():
			_opaque_call()   # the property's setter runs
		return false

	if s is GateAST._ExprStmt:
		_check_expr((s as GateAST._ExprStmt).expr)
		_note_assert((s as GateAST._ExprStmt).expr)
		return false

	if s is GateAST._ReturnStmt:
		var r: GateAST._ReturnStmt = s
		_check_expr(r.value)
		_check_return(r)
		return true

	if s is GateAST._SimpleStmt:
		var kw: String = (s as GateAST._SimpleStmt).keyword
		if kw == "break" and not _break_envs.is_empty():
			_break_envs[-1].append(_state_copy())
		elif kw == "continue" and not _continue_envs.is_empty():
			_continue_envs[-1].append(_state_copy())
		return kw in ["break", "continue"]

	if s is GateAST._IfStmt:
		return _walk_if(s)

	if s is GateAST._WhileStmt:
		_walk_while(s)
		return false

	if s is GateAST._ForStmt:
		_walk_for(s)
		return false

	if s is GateAST._MatchStmt:
		return _walk_match(s)

	if s is GateAST._MultiAssign:
		var ma: GateAST._MultiAssign = s
		for v in ma.values:
			_check_expr(v)
		if ma.declares and ma.destructure and ma.values.size() == 1:
			_walk_destructure(ma)
			return false
		var paired: bool = ma.targets.size() == ma.values.size()
		if paired and _gate_types and not ma.declares:
			for i in ma.targets.size():
				ma.values[i] = _gate_store(ma.targets[i], ma.values[i], ma.line, ma.col)
		var value_types: Array = []
		for j in ma.targets.size():
			value_types.append(_static_type_of(ma.values[j]) if paired else null)
		for i in ma.targets.size():
			var t = ma.targets[i]
			if t is GateAST._Ident and ma.declares:
				_declare_local((t as GateAST._Ident).name, value_types[i], true)
			_check_expr(t)
			var p: String = _path_of(t)
			_kill_target(t)
			if t is GateAST._Ident and not ma.declares \
				and _follows_assignments((t as GateAST._Ident).name):
				_retype_local((t as GateAST._Ident).name, value_types[i])
			if p != "" and _tracked(t):
				_env[p] = _state_of(ma.values[i]) if paired else _S.MAYBE
			if not _accessor(t).is_empty():
				_opaque_call()
		return false

	if s is GateAST._FuncDecl:
		_check_func(s, _cls)
		return false

	if s is GateAST._ClassDecl:
		_walk_members((s as GateAST._ClassDecl).members, (s as GateAST._ClassDecl).name)
		return false

	return false


func _gate_store(target, value, line: int, col: int) -> GateAST._Expr:
	var tt: GateAST._TypeRef = _type_of(target)
	var what: String = "'%s'" % _shown(target)
	if tt != null and GateChecker.is_gate_only_type(tt):
		return _check_gate_value(tt, value, what, line, col)
	if target is GateAST._Index:
		var elem_t: GateAST._TypeRef = _tuple_slot(target as GateAST._Index, false)
		if elem_t != null and _check_compat(elem_t, value, what, line, col):
			return _widen(elem_t, value, what, line, col, true)
	return value


func _colon_eq_type(vd: GateAST._VarDecl) -> GateAST._TypeRef:
	infer.ensure_effects()
	var gt: GateAST._TypeRef = _type_of(vd.value)
	if gt == null:
		return null
	if gt.is_union() or gt.is_tuple() or gt.nullable or gt.is_func_type:
		vd.inferred = false
		return gt
	if gt.name == "" or GateTypes.canonical(gt.name) == "Variant" \
			or infer.generic_params.has(gt.name) or _is_generic_param(gt.name):
		return null
	if _lowers_to_variant(vd.value, 0):
		vd.type = GateChecker.copy_type(gt)
		vd.type.at(vd.line, vd.col)
		vd.inferred = false
	return null


func _is_generic_param(n: String) -> bool:
	for k in infer.generic_params:
		if (infer.generic_params[k] as Array).has(n):
			return true
	return false


func _lowers_to_variant(e, depth: int) -> bool:
	if e == null or depth > MAX_PATH_DEPTH:
		return false
	if e is GateAST._NullCoalesce:
		return true
	if e is GateAST._Index:
		var tt: GateAST._TypeRef = _type_of((e as GateAST._Index).target)
		if tt != null and tt.is_tuple() and tt.array_depth == 0:
			return true
		return _lowers_to_variant((e as GateAST._Index).target, depth + 1)
	if e is GateAST._Call and (e as GateAST._Call).callee is GateAST._Member:
		var cm: GateAST._Member = (e as GateAST._Call).callee
		var rt: GateAST._TypeRef = _type_of(cm.target)
		if (cm.name == "call" or cm.name == "callv") and rt != null and rt.is_func_type:
			return true
		return _lowers_to_variant(cm.target, depth + 1)
	if e is GateAST._Member:
		if _declared_gate_shape(e):
			return true
		return _lowers_to_variant((e as GateAST._Member).target, depth + 1)
	if e is GateAST._Ident:
		return _declared_gate_shape(e) or _destructured.has((e as GateAST._Ident).name)
	if e is GateAST._Binary:
		return _lowers_to_variant((e as GateAST._Binary).left, depth + 1) \
			or _lowers_to_variant((e as GateAST._Binary).right, depth + 1)
	if e is GateAST._Unary:
		return _lowers_to_variant((e as GateAST._Unary).operand, depth + 1)
	if e is GateAST._Ternary:
		return _lowers_to_variant((e as GateAST._Ternary).if_true, depth + 1) \
			or _lowers_to_variant((e as GateAST._Ternary).if_false, depth + 1)
	return false


func _declared_gate_shape(e) -> bool:
	var st: GateAST._TypeRef = _static_type_of(e)
	return st != null and (st.is_union() or st.is_tuple() or st.nullable or st.is_func_type)


var _destructured: Dictionary = {}


func _adopt_callable_type(decl: GateAST._TypeRef, value) -> void:
	if decl == null or not (value is GateAST._Lambda) or not decl.is_func_type or decl.array_depth > 0:
		return
	var lam: GateAST._Lambda = value
	if lam.return_type == null and decl.callable_return != null \
			and GateChecker.is_gate_only_type(decl.callable_return):
		infer.ensure_effects()
		lam.return_type = GateChecker.copy_type(decl.callable_return)
		_param_hints[lam] = decl.callable_params


var _param_hints: Dictionary = {}


func _walk_destructure(ma: GateAST._MultiAssign) -> void:
	var src: GateAST._Expr = ma.values[0]
	var vt: GateAST._TypeRef = _type_of(src)
	var tuple: bool = vt != null and vt.is_tuple() and vt.array_depth == 0
	if tuple and vt.tuple_elems.size() != ma.targets.size():
		_err("this names %d value(s), but %s holds %d" % [ma.targets.size(), vt.describe(),
				vt.tuple_elems.size()], ma.line, ma.col,
			"destructure exactly as many names as the tuple has elements")
	if tuple and vt.nullable and _nullness(src) != _S.NOTNULL:
		var shown: String = _path_of(src)
		_err("%s may be null, and destructuring it reads its values"
				% ("'%s'" % shown if shown != "" else "the value"), ma.line, ma.col,
			"guard it with `if %s != null:` first" % (shown if shown != "" else "value"))
	for i in ma.targets.size():
		if not (ma.targets[i] is GateAST._Ident):
			continue
		var name: String = (ma.targets[i] as GateAST._Ident).name
		var et: GateAST._TypeRef = vt.tuple_elems[i] if tuple and i < vt.tuple_elems.size() else null
		_declare_local(name, et, true)
		_destructured[name] = true
		_kill_path(name)
		_kill_index_var(name)
		if et != null and et.nullable:
			_env[name] = _S.MAYBE


func _walk_if(st: GateAST._IfStmt) -> bool:
	_check_expr(st.cond)
	var before: Array = _state_copy()

	_set_state(_narrow_state(before, st.cond, true))
	var then_exits: bool = _walk_block(st.then_body)
	var branch_states: Array = []
	if not then_exits:
		branch_states.append(_state_copy())

	var else_state: Array = _narrow_state(before, st.cond, false)
	var all_exit: bool = then_exits

	for pair in st.elifs:
		_set_state(_copy_state(else_state))
		_check_expr(pair[0])
		var tested: Array = _state_copy()   # what the condition called has already run
		_set_state(_narrow_state(tested, pair[0], true))
		var e_exits: bool = _walk_block(pair[1])
		if not e_exits:
			branch_states.append(_state_copy())
		all_exit = all_exit and e_exits
		else_state = _narrow_state(tested, pair[0], false)

	if not st.else_body.is_empty():
		_set_state(_copy_state(else_state))
		var else_exits: bool = _walk_block(st.else_body)
		if not else_exits:
			branch_states.append(_state_copy())
		all_exit = all_exit and else_exits
	else:
		branch_states.append(else_state)
		all_exit = false

	if branch_states.is_empty():
		_set_state(before)
		return all_exit
	var joined: Array = branch_states[0]
	for i in range(1, branch_states.size()):
		joined = _join_state(joined, branch_states[i])
	_set_state(joined)
	return all_exit

const MAX_LOOP_PASSES := 6
const MAX_LOOP_PASSES_CAP := 24


## The loop-head state that holds on every pass. If it does not settle in time,
## every narrowing is dropped.
func _loop_fixpoint(entry: Array, cond, body: Array) -> Array:
	var cur: Array = _copy_state(entry)
	_quiet += 1
	_break_envs.append([])   # a break here leaves this loop, not the one around it
	_continue_envs.append([])
	var limit: int = mini(maxi(MAX_LOOP_PASSES, (entry[0] as Dictionary).size() + 1),
		MAX_LOOP_PASSES_CAP)
	var settled: bool = false
	var moving: Dictionary = {}
	var moving_t: Dictionary = {}
	var moving_i: Dictionary = {}
	for _pass in limit:
		if cond != null:
			_set_state(_copy_state(cur))
			_check_expr(cond)
			_set_state(_narrow_state(_state_copy(), cond, true))
		else:
			_set_state(_copy_state(cur))
		_walk_block(body)
		var nxt: Array = _join_state(cur, _state_copy())
		for ce in _continue_envs[-1]:
			nxt = _join_state(nxt, ce)
		_continue_envs[-1] = []
		moving = _env_diff(nxt[0], cur[0])
		moving_t = _types_diff(nxt[1], cur[1])
		moving_i = _types_diff(nxt[2], cur[2])
		if moving.is_empty() and moving_t.is_empty() and moving_i.is_empty():
			settled = true
			break
		cur = nxt
	_break_envs.pop_back()
	_continue_envs.pop_back()
	_quiet -= 1
	if not settled:
		for k in moving:
			cur[0][k] = _S.MAYBE
		for k2 in moving_t:
			(cur[1] as Dictionary).erase(k2)
		for k3 in moving_i:
			(cur[2] as Dictionary).erase(k3)
	return cur


func _env_diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in a:
		if b.get(k) != a[k]:
			out[k] = true
	for k2 in b:
		if not a.has(k2):
			out[k2] = true
	return out


func _walk_while(w: GateAST._WhileStmt) -> void:
	var entry: Array = _state_copy()
	var stable: Array = _loop_fixpoint(entry, w.cond, w.body)
	_set_state(_copy_state(stable))
	_check_expr(w.cond)
	var tested: Array = _state_copy()
	_set_state(_narrow_state(tested, w.cond, true))
	_break_envs.append([])
	_continue_envs.append([])
	_walk_block(w.body)
	var out: Array = _join_state(_state_copy(), _narrow_state(tested, w.cond, false))
	for be2 in _break_envs[-1]:
		out = _join_state(out, be2)
	_set_state(out)
	_break_envs.pop_back()
	_continue_envs.pop_back()


func _walk_key_type(tr: GateAST._TypeRef) -> GateAST._TypeRef:
	if tr == null or tr.array_depth != 0:
		return null
	if tr.is_dict():
		return tr.dict_key
	if GateTypes.canonical(tr.name) == "Dictionary" and tr.generic_args.size() == 2:
		return tr.generic_args[0]
	return null


func _walked_type(tr: GateAST._TypeRef, f: GateAST._ForStmt) -> GateAST._TypeRef:
	if f.var_names.size() == 1 and not f.is_enumerate:
		var key: GateAST._TypeRef = _walk_key_type(tr)
		if key != null:
			return key
	return infer.element_type(tr)


func _walk_for(f: GateAST._ForStmt) -> void:
	_check_expr(f.iterable)
	_check_iterable(f)
	if _gate_types:
		_check_union_elements(f.iterable, "iterating", f.line, f.col)
	var it: GateAST._TypeRef = _static_type_of(f.iterable)
	var it_n: GateAST._TypeRef = _type_of(f.iterable)
	var carried: Dictionary = {}
	var outer: Array = _open_scope(f.var_names)
	if f.var_names.size() == 2 and it != null and it.is_dict() and not f.is_enumerate:
		_declare_local(f.var_names[0], it.dict_key, true)
		_declare_local(f.var_names[1], it.dict_value, true)
	else:
		var et: GateAST._TypeRef = f.var_type
		if et == null:
			et = _walked_type(it, f)
			var et_n: GateAST._TypeRef = _walked_type(it_n, f)
			if et_n != null and not _same_type(et_n, et) \
				and not (it_n != null and it_n.is_dict() and f.var_names.size() == 2):
				carried[f.var_names[f.var_names.size() - 1]] = et_n
		for i in f.var_names.size():
			_declare_local(f.var_names[i],
				et if i == f.var_names.size() - 1 else null, f.var_type == null)
	for n in f.var_names:
		_local_names[n] = true
		_kill_path(n)
		_kill_index_var(n)
	for cn in carried:
		_narrowed[cn] = carried[cn]

	var entry: Array = _state_copy()
	var stable: Array = _loop_fixpoint(entry, null, f.body)
	_set_state(_copy_state(stable))
	_break_envs.append([])
	_continue_envs.append([])
	_walk_block(f.body)
	var out: Array = _join_state(_state_copy(), stable)
	for be in _break_envs[-1]:
		out = _join_state(out, be)
	_set_state(out)
	_break_envs.pop_back()
	_continue_envs.pop_back()
	_close_scope(f.var_names, outer)


func _open_scope(names: Array) -> Array:
	var out: Array = []
	for n in names:
		out.append([_local_names.has(n), _locals.get(n, null), _inferred.get(n, null),
			_inferred.get(JOINED + n, null), _fixed.has(n)])
	return out


func _close_scope(names: Array, outer: Array) -> void:
	for i in names.size():
		var n: String = names[i]
		var was: Array = outer[i]
		_kill_path(n)
		_kill_index_var(n)
		if was[0]:
			_local_names[n] = true
		else:
			_local_names.erase(n)
		for pair in [[_locals, n, was[1]], [_inferred, n, was[2]], [_inferred, JOINED + n, was[3]]]:
			if pair[2] != null:
				(pair[0] as Dictionary)[pair[1]] = pair[2]
			else:
				(pair[0] as Dictionary).erase(pair[1])
		if was[4]:
			_fixed[n] = true
		else:
			_fixed.erase(n)


func _check_iterable(f: GateAST._ForStmt) -> void:
	var st: int = _expr_nullness(f.iterable)
	if st == _S.NOTNULL:
		return
	var src: String = _path_of(f.iterable)
	var desc: String = "'%s'" % src if src != "" else "the value"
	if st == _S.NULL:
		_err("%s is null here, and a for loop cannot iterate null" % desc, f.line, f.col,
			"assign it before the loop")
	else:
		_err("%s may be null, and a for loop cannot iterate null" % desc, f.line, f.col,
			"guard it with `if %s != null:`, or iterate `%s ?? []`"
				% [src if src != "" else "value", src if src != "" else "value"])


func _walk_match(mt: GateAST._MatchStmt) -> bool:
	_check_expr(mt.subject)
	var before: Array = _state_copy()
	var joined = null
	var exhaustive: bool = false
	var has_null_arm: bool = false
	for br0 in mt.branches:
		if _is_null_pattern(br0[0]):
			has_null_arm = true
	var null_taken: bool = false   # an unguarded `null` arm came before this one
	for br in mt.branches:
		_set_state(_copy_state(before))
		var subj: String = _path_of(mt.subject)
		if subj != "" and _tracked(mt.subject) and has_null_arm:
			if _is_null_pattern(br[0]):
				_env[subj] = _S.NULL
			elif null_taken:
				_env[subj] = _S.NOTNULL
		if _is_null_pattern(br[0]) and br[1] == null:
			null_taken = true
		var bound: Array = _pattern_bindings(br[0])
		var saved_names: Dictionary = _local_names.duplicate()
		var outer: Array = _open_scope(bound)
		for bn in bound:
			_declare_local(bn, null, true)
			_kill_path(bn)
			_kill_index_var(bn)
		if br[1] != null:
			_check_expr(br[1])
			_apply_narrow(_env, br[1], true)
		if br[1] == null and _is_wildcard(br[0]):
			exhaustive = true
		var exits: bool = _walk_block(br[2])
		_close_scope(bound, outer)
		_local_names = saved_names
		if exits:
			continue
		joined = _state_copy() if joined == null else _join_state(joined, _state_copy())
	if joined == null:
		_set_state(before)
		return exhaustive and not mt.branches.is_empty()
	_set_state(joined if exhaustive else _join_state(joined, before))
	return false


func _pattern_bindings(patterns: Array) -> Array:
	var out: Array = []
	for p in patterns:
		var text: String = ""
		if p is GateAST._RawExpr:
			text = (p as GateAST._RawExpr).text
		elif p is GateAST._Ident:
			continue
		else:
			continue
		text = _outside_strings(text)
		var i: int = 0
		while true:
			i = text.find("var ", i)
			if i < 0:
				break
			if i > 0 and _is_name_char(text[i - 1]):
				i += 4
				continue
			var j: int = i + 4
			var name: String = ""
			while j < text.length() and _is_name_char(text[j]):
				name += text[j]
				j += 1
			if name != "":
				out.append(name)
			i = j
	return out


static func _outside_strings(text: String) -> String:
	var out: String = ""
	var i: int = 0
	var quote: String = ""
	while i < text.length():
		var c: String = text[i]
		if quote != "":
			if c == "\\" and i + 1 < text.length():
				out += "  "
				i += 2
				continue
			if c == quote:
				quote = ""
			out += " "
			i += 1
			continue
		if c == "\"" or c == "'":
			quote = c
			out += " "
			i += 1
			continue
		out += c
		i += 1
	return out


static func _is_name_char(c: String) -> bool:
	return ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
		or (c >= "0" and c <= "9") or c == "_" or c.unicode_at(0) >= 0x80)


func _is_null_pattern(patterns: Array) -> bool:
	for p in patterns:
		if p is GateAST._Literal and (p as GateAST._Literal).kind == "null":
			return true
		if p is GateAST._RawExpr and (p as GateAST._RawExpr).text.strip_edges() == "null":
			return true
	return false


func _is_wildcard(patterns: Array) -> bool:
	for p in patterns:
		if p is GateAST._RawExpr and (p as GateAST._RawExpr).text.strip_edges() == "_":
			return true
		if p is GateAST._Ident and (p as GateAST._Ident).name == "_":
			return true
	return false


func _state_copy() -> Array:
	return [_env.duplicate(), _narrowed.duplicate(), _inferred.duplicate()]


func _copy_state(st: Array) -> Array:
	return [(st[0] as Dictionary).duplicate(), (st[1] as Dictionary).duplicate(),
		(st[2] as Dictionary).duplicate()]


func _set_state(st: Array) -> void:
	_env = st[0]
	_narrowed = st[1]
	var nxt: Dictionary = st[2]
	for n in _inferred:
		if not nxt.has(n):
			_locals.erase(n)
	for n2 in nxt:
		_locals[n2] = nxt[n2]
	_inferred = nxt


func _join_state(a: Array, b: Array) -> Array:
	return [_join(a[0], b[0]), _join_types(a[1], b[1]), _join_inferred(a[2], b[2])]


func _drop_killed(into: Array, before: Array, after: Array) -> void:
	var env_b: Dictionary = before[0]
	var env_a: Dictionary = after[0]
	for k in env_b:
		if not env_a.has(k) or env_a[k] != env_b[k]:
			(into[0] as Dictionary).erase(k)
	var nar_b: Dictionary = before[1]
	var nar_a: Dictionary = after[1]
	for k2 in nar_b:
		if not nar_a.has(k2) or not _same_type(nar_a[k2], nar_b[k2]):
			(into[1] as Dictionary).erase(k2)


func _replay_kills(e) -> void:
	if (_env.is_empty() and _narrowed.is_empty()) or not _may_kill(e, 0):
		return
	var live: Array = [_env, _narrowed, _inferred]
	var before: Array = _state_copy()
	_set_state(_copy_state(before))
	_quiet += 1
	_check_expr(e)
	_quiet -= 1
	var after: Array = _state_copy()
	_set_state(live)
	_drop_killed(live, before, after)


func _may_kill(e, depth: int) -> bool:
	if e == null or e is GateAST._Literal or e is GateAST._SelfExpr:
		return false
	if depth > MAX_PATH_DEPTH:
		return true
	if e is GateAST._Ident:
		return not infer.accessor_fields.is_empty()
	if e is GateAST._Member:
		return not infer.accessor_fields.is_empty() or _may_kill((e as GateAST._Member).target, depth + 1)
	if e is GateAST._Index:
		return _may_kill((e as GateAST._Index).target, depth + 1) \
			or _may_kill((e as GateAST._Index).index, depth + 1)
	if e is GateAST._Binary:
		return _may_kill((e as GateAST._Binary).left, depth + 1) \
			or _may_kill((e as GateAST._Binary).right, depth + 1)
	if e is GateAST._Unary:
		return _may_kill((e as GateAST._Unary).operand, depth + 1)
	if e is GateAST._IsExpr:
		return _may_kill((e as GateAST._IsExpr).operand, depth + 1)
	return true


const JOINED := "?"


func _join_inferred(a: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in a:
		if not String(k).begins_with(JOINED) and b.has(k) and _same_type(a[k], b[k]):
			out[k] = a[k]
	var names: Dictionary = {}
	for side in [a, b]:
		for k2 in side:
			names[String(k2).trim_prefix(JOINED)] = true
	for n in names:
		if out.has(n):
			continue
		var types: Array = []
		if _types_on(a, n, types) and _types_on(b, n, types) and types.size() >= 2:
			out[JOINED + n] = _union_of(types)
	return out


func _types_on(side: Dictionary, n: String, types: Array) -> bool:
	if side.has(JOINED + n):
		for m in (side[JOINED + n] as GateAST._TypeRef).union_members:
			_add_type(types, m)
		return true
	if side.has(n):
		_add_type(types, side[n])
		return true
	return false


func _note_joined(name: String, value) -> void:
	var types: Array = []
	_branch_types(value, types)
	if types.size() >= 2:
		_inferred[JOINED + name] = _union_of(types)


func _branch_types(e, out: Array) -> void:
	if e is GateAST._Ternary:
		_branch_types((e as GateAST._Ternary).if_true, out)
		_branch_types((e as GateAST._Ternary).if_false, out)
		return
	var t: GateAST._TypeRef = _static_type_of(e)
	if t != null:
		_add_type(out, t)


func _add_type(types: Array, t: GateAST._TypeRef) -> void:
	if t == null:
		return
	for have in types:
		if _same_type(have, t):
			return
	types.append(t)


func _union_of(types: Array) -> GateAST._TypeRef:
	var u: GateAST._TypeRef = GateAST._TypeRef.new()
	u.union_members = types.duplicate()
	return u


func _narrow_state(st: Array, cond, truth: bool) -> Array:
	var saved: Array = [_env, _narrowed, _inferred]
	_set_state(_copy_state(st))
	_apply_narrow(_env, cond, truth)
	var out: Array = [_env, _narrowed, _inferred]
	_set_state(saved)
	return out


func _narrow_step(st: Array, term, truth: bool) -> Array:
	var saved: Array = [_env, _narrowed, _inferred]
	_set_state(_copy_state(st))
	_replay_kills(term)
	_apply_narrow(_env, term, truth)
	var out: Array = [_env, _narrowed, _inferred]
	_set_state(saved)
	return out


func _apply_narrow(env: Dictionary, cond, truth: bool) -> void:
	if cond == null:
		return

	if cond is GateAST._Unary and (cond as GateAST._Unary).op == "not":
		_apply_narrow(env, (cond as GateAST._Unary).operand, not truth)
		return

	if cond is GateAST._Binary:
		var b: GateAST._Binary = cond
		if b.op == "and":
			if truth:
				_apply_narrow(env, b.left, true)
				_replay_kills(b.right)
				_apply_narrow(env, b.right, true)
			return
		if b.op == "or":
			if not truth:
				_apply_narrow(env, b.left, false)
				_replay_kills(b.right)
				_apply_narrow(env, b.right, false)
			return
		if b.op == "!=" or b.op == "==":
			var operand = null
			if _is_null_literal(b.right):
				operand = b.left
			elif _is_null_literal(b.left):
				operand = b.right
			if operand != null:
				var path: String = _path_of(operand)
				if path != "" and _tracked(operand):
					env[path] = _S.NOTNULL if ((b.op == "!=") == truth) else _S.NULL
			return
		return

	if cond is GateAST._IsExpr:
		var ie: GateAST._IsExpr = cond
		var ip: String = _path_of(ie.operand)
		if ip != "" and (truth != ie.negated):
			if _tracked(ie.operand):
				env[ip] = _S.NOTNULL
			_narrow_to(ip, ie.operand, ie.type)
		elif ip != "" and _gate_types:
			_narrow_out(ip, ie.operand, ie.type)
		return

	if cond is GateAST._Call:
		var cc: GateAST._Call = cond
		if cc.callee is GateAST._Ident and (cc.callee as GateAST._Ident).name == "is_instance_valid" and cc.args.size() == 1:
			var ip2: String = _path_of(cc.args[0])
			if ip2 != "" and _tracked(cc.args[0]):
				env[ip2] = _S.NOTNULL if truth else _S.MAYBE
			return

	var p: String = _path_of(cond)
	if p != "" and _tracked(cond):
		env[p] = _S.NOTNULL if truth else _S.NULL


func _narrow_to(path: String, operand, t: GateAST._TypeRef) -> void:
	if t == null or t.name == "" or t.is_dict() or t.nullable:
		return
	if not _narrowable(path):
		return
	var cur: GateAST._TypeRef = _type_of(operand)
	if cur != null:
		if cur.array_depth > 0 or cur.is_dict():
			if t.array_depth == 0 and GateTypes.canonical(t.name) in ["Array", "Dictionary"]:
				return
		else:
			var cn: String = GateTypes.canonical(cur.name)
			var known_class: bool = cn != "" and cn != "Variant" \
				and not infer.open_types.has(cn)
			if known_class and not (t.array_depth == 0 and _is_subclass(t.name, cn)
					and GateTypes.canonical(t.name) != cn):
				return
	_narrowed[path] = t


func _narrow_out(path: String, operand, t: GateAST._TypeRef) -> void:
	if t == null or not _narrowable(path):
		return
	var cur: GateAST._TypeRef = _type_of(operand)
	if cur == null or not cur.is_union() or cur.array_depth > 0:
		return
	var members: Array = GateTypeCompat.flat_members(cur)
	var rest: Array = []
	for m in members:
		if GateTypeCompat.assignable(m, t, infer, false) != GateTypeCompat.YES:
			rest.append(m)
	if rest.is_empty() or rest.size() == members.size():
		return
	var out: GateAST._TypeRef
	if rest.size() == 1:
		out = GateChecker.copy_type(rest[0])
		out.nullable = out.nullable or cur.nullable
	else:
		out = GateChecker.copy_type(cur)
		out.shaped().union_members = rest
	_narrowed[path] = out


## Only a path whose every writer we can see may narrow. A static var can be
## written from any class.
func _narrowable(path: String) -> bool:
	var segs: PackedStringArray = path.split(".")
	var root: String = segs[0].split("[")[0]
	if root == "self":
		if segs.size() == 1:
			return true
		var f: String = segs[1].split("[")[0]
		return _field_names.has(f) and not _is_static_field(f)
	return _local_names.has(root)


func _is_static_field(name: String) -> bool:
	var seen: Dictionary = {}
	var c: String = _cls
	while c != "" and not seen.has(c):
		seen[c] = true
		if infer.static_fields.has("%s.%s" % [c, name]):
			return true
		c = String(infer.bases.get(c, ""))
	return false


func _note_assert(e) -> void:
	if not (e is GateAST._Call):
		return
	var c: GateAST._Call = e
	if not (c.callee is GateAST._Ident) or (c.callee as GateAST._Ident).name != "assert":
		return
	if c.args.is_empty():
		return
	var probe: Dictionary = {}
	var saved_t: Dictionary = _narrowed
	_narrowed = _narrowed.duplicate()
	_apply_narrow(probe, c.args[0], true)
	_narrowed = saved_t
	for k in probe:
		if probe[k] == _S.NOTNULL:
			_asserted[k] = true


func _is_null_literal(e) -> bool:
	return e is GateAST._Literal and (e as GateAST._Literal).kind == "null"


func _expr_nullness(e, opted: bool = false) -> int:
	if _is_null_literal(e):
		return _S.NULL if opted else _S.NOTNULL
	if e is GateAST._NullCoalesce:
		var nc: GateAST._NullCoalesce = e
		if _expr_nullness(nc.left) == _S.NOTNULL:
			return _S.NOTNULL
		return _expr_nullness(nc.right, true)   # `a ?? null` on a nullable `a`
	if e is GateAST._Ternary:
		var te: GateAST._Ternary = e
		var saved: Array = _state_copy()
		_set_state(_narrow_state(saved, te.cond, true))
		var a: int = _expr_nullness(te.if_true)
		_set_state(_narrow_state(saved, te.cond, false))
		var b: int = _expr_nullness(te.if_false)
		_set_state(saved)
		if a == _S.NOTNULL and b == _S.NOTNULL:
			return _S.NOTNULL
		if a == _S.NULL and b == _S.NULL:
			return _S.NULL
		return _S.MAYBE
	return _nullness(e)


func _safe_access_nullness(value) -> int:
	var target = null
	if value is GateAST._Member and (value as GateAST._Member).safe:
		target = (value as GateAST._Member).target
	elif value is GateAST._Index and (value as GateAST._Index).safe:
		target = (value as GateAST._Index).target
	else:
		return -1
	if _nullness(target) != _S.NOTNULL:
		return _S.MAYBE
	var own: GateAST._TypeRef = null
	if value is GateAST._Member:
		own = infer._member_type(value, _locals)
	else:
		own = infer.element_type(_type_of(target))
	return _S.MAYBE if own != null and own.nullable else _S.NOTNULL


func _state_of(value) -> int:
	if value == null or _is_null_literal(value):
		return _S.NULL
	var safe_st: int = _safe_access_nullness(value)
	if safe_st >= 0:
		return safe_st
	if value is GateAST._Literal:
		return _S.NOTNULL
	if value is GateAST._NullCoalesce:
		return _state_of((value as GateAST._NullCoalesce).right)
	if value is GateAST._Widen:
		return _state_of((value as GateAST._Widen).args[0])
	if value is GateAST._ArrayLit or value is GateAST._DictLit \
		or value is GateAST._ObjectInit or value is GateAST._FString \
		or value is GateAST._Lambda:
		return _S.NOTNULL
	if value is GateAST._CastExpr:
		var ct: GateAST._TypeRef = (value as GateAST._CastExpr).type
		return _S.MAYBE if (ct == null or ct.nullable) else _S.NOTNULL
	if value is GateAST._Call:
		var t: GateAST._TypeRef = _type_of(value)
		if t == null:
			return _S.MAYBE
		return _S.MAYBE if t.nullable else _S.NOTNULL
	var p: String = _path_of(value)
	if p != "":
		return _state(p) if _tracked(value) else _S.NOTNULL
	return _S.MAYBE


func _nullness(value) -> int:
	if value == null or _is_null_literal(value):
		return _S.NULL
	var safe_st: int = _safe_access_nullness(value)
	if safe_st >= 0:
		return safe_st
	var p: String = _path_of(value)
	if p != "" and _tracked(value):
		return _state(p)
	if value is GateAST._NullCoalesce:
		return _nullness((value as GateAST._NullCoalesce).right)
	if value is GateAST._Widen:
		return _nullness((value as GateAST._Widen).args[0])
	var vt: GateAST._TypeRef = _type_of(value)
	if vt != null and vt.nullable:
		return _S.MAYBE
	return _S.NOTNULL


func _is_untyped(t: GateAST._TypeRef) -> bool:
	return t == null or t.nullable or t.name == "" or t.name == "Variant" or t.name == "void"

## The superset rule: a hard error is only raised for something plain GDScript
## cannot express. `var x: Thing = null` is legal, so renaming a `.gd` to `.gate`
## must not reject it.
##
func _check_value_against(decl: GateAST._TypeRef, value, what: String, line: int, col: int,
		strict_casts: bool = true) -> GateAST._Expr:
	if decl == null or value == null:
		return value
	if _struct_mismatch(decl, value, what, line, col):
		return value
	if GateChecker.is_gate_only_type(decl):
		if decl.strict and strict_casts and not decl.nullable:
			_strict_casts_in(decl, value, what, line, col)
		return _check_gate_value(decl, value, what, line, col)
	_check_plain_value(decl, value, what, line, col, strict_casts)
	return value


const VECTOR_TYPES := {"Vector2": true, "Vector2i": true, "Vector3": true,
	"Vector3i": true, "Vector4": true, "Vector4i": true}


func _struct_mismatch(decl: GateAST._TypeRef, value, what: String, line: int, col: int) -> bool:
	if decl.is_dict() or decl.is_union() or decl.is_tuple() \
		or not infer.struct_names.has(decl.name):
		return false
	var vt: GateAST._TypeRef = _value_type(value)
	if vt == null or vt.is_dict() or vt.is_union() or vt.is_tuple() \
		or vt.array_depth != decl.array_depth:
		return false
	if VECTOR_TYPES.has(GateTypes.canonical(vt.name)):
		_err("the value is %s, but %s is the struct %s" % [vt.describe(), what, decl.name],
			line, col,
			"a %s is not a %s, whatever it is packed into; build one from its fields, "
				% [vt.describe(), decl.name]
			+ "as `%s(...)`, so each value lands on the field you name." % decl.name)
		return true
	if not infer.struct_names.has(vt.name) or vt.name == decl.name:
		return false
	_err("the value is %s, but %s is %s" % [vt.describe(), what, decl.describe()], line, col,
		"structs are distinct types even when their fields line up; build a %s from its fields"
			% decl.name)
	return true


func _check_plain_value(decl: GateAST._TypeRef, value, what: String, line: int, col: int,
		strict_casts: bool = true) -> void:
	_check_gate_source(decl, value, what, line, col)
	if decl != null and value != null and decl.is_dict() and not decl.nullable:
		_check_known_plain(decl, value, what, line, col)
	if _is_untyped(decl) or value == null:
		return
	if not decl.is_dict():
		_check_known_plain(decl, value, what, line, col)
	if decl.strict and strict_casts:
		_strict_casts_in(decl, value, what, line, col)
	if _is_null_literal(value):
		if decl.strict:
			_err("cannot assign null to %s, which is not nullable" % what, line, col,
				"declare it as `%s? ...` to allow null" % decl.describe())
		elif _opted_in:
			_warn("null assigned to %s, declared '%s'" % [what, decl.describe()],
				line, col,
				"GDScript allows this; write `%s?` to say so deliberately, and GATE "
				% decl.describe() + "will check every use of it")
		return
	var st: int = _nullness(value)
	if st == _S.NOTNULL:
		return
	var src: String = _path_of(value)
	var desc: String = "'%s'" % src if src != "" else "the value"
	if st == _S.NULL:
		_err("%s is null, but %s is not nullable" % [desc, what], line, col,
			"declare it `%s? ...` to allow null" % decl.describe())
	else:
		_err("%s may be null, but %s is not nullable" % [desc, what], line, col,
			"guard it with `if %s != null:` first, or declare the target `%s? ...`"
				% [src if src != "" else "value", decl.describe()])


func _strict_casts_in(decl: GateAST._TypeRef, value, what: String, line: int, col: int) -> void:
	if value is GateAST._CastExpr:
		_check_strict_cast(decl, value, what, line, col)
	elif value is GateAST._Ternary:
		var te: GateAST._Ternary = value
		var saved: Array = _state_copy()
		_set_state(_narrow_state(saved, te.cond, true))
		_strict_casts_in(decl, te.if_true, what, line, col)
		_set_state(_narrow_state(saved, te.cond, false))
		_strict_casts_in(decl, te.if_false, what, line, col)
		_set_state(saved)
	elif value is GateAST._NullCoalesce:
		_strict_casts_in(decl, (value as GateAST._NullCoalesce).right, what, line, col)
	elif value is GateAST._ArrayLit and decl.is_tuple() and decl.array_depth == 0:
		var elems: Array = (value as GateAST._ArrayLit).elements
		for i in mini(elems.size(), decl.tuple_elems.size()):
			var slot: GateAST._TypeRef = decl.tuple_elems[i]
			if slot != null and not slot.nullable:
				_strict_casts_in(slot, elems[i], "element %d of %s" % [i, what], line, col)


func _check_strict_cast(decl: GateAST._TypeRef, ce: GateAST._CastExpr, what: String,
		line: int, col: int) -> void:
	var ct: GateAST._TypeRef = ce.type
	if ct == null or ct.nullable or not _cast_can_yield_null(ct):
		return
	var ot: GateAST._TypeRef = _type_of(ce.operand)
	if ot != null and ot.array_depth == 0 and not ot.is_dict() \
		and (_is_subclass(ot.name, ct.name) or infer.implements_type(ot.name, ct.name)) \
		and _nullness(ce.operand) == _S.NOTNULL:
		return
	var src: String = _path_of(ce.operand)
	var hint: String
	if src != "" and not _narrowable(src):
		hint = ("GATE never narrows '%s' - a field any call may rebind - so an `is` check "
			% src + "on it does not count; copy it to a local first (`var v = %s`), "
			% src + "guard that with `is %s`, and cast it, or declare it `%s?`"
			% [ct.describe(), decl.describe()])
	elif src != "":
		hint = "guard it with `if %s is %s:`, or declare it `%s?`" \
			% [src, ct.describe(), decl.describe()]
	else:
		hint = "declare it `%s?` and check it for null, or cast a variable you have " \
			% decl.describe() + "guarded with `is %s`" % ct.describe()
	_err("'%s as %s' is null if the cast fails, but %s is not nullable"
			% [src if src != "" else "...", ct.describe(), what],
		line, col, hint)


## `as T` yields null only for object types. A builtin cast converts or fails.
func _cast_can_yield_null(ct: GateAST._TypeRef) -> bool:
	if ct.array_depth > 0 or ct.is_dict():
		return false
	var n: String = GateTypes.canonical(ct.name)
	if GateTypes.BUILTIN.has(n) or n.begins_with("Packed"):
		return false
	if infer.open_types.has(n):
		return true
	var sd = infer.struct_names.get(n, null)
	if sd is GateAST._ClassDecl and (sd as GateAST._ClassDecl).lowering == "vector":
		return false
	return ClassDB.class_exists(n) or infer.has_class(n)


func _check_return(r: GateAST._ReturnStmt) -> void:
	if _ret != null and r.value != null and _struct_mismatch(_ret, r.value, "the return type",
			r.line, r.col):
		return
	if _ret != null and r.value != null and GateChecker.is_gate_only_type(_ret):
		r.value = _check_gate_value(_ret, r.value, "the return type", r.line, r.col)
		return
	if r.value != null:
		_check_gate_source(_ret, r.value, "the return type", r.line, r.col)
	if _is_untyped(_ret):
		return
	if r.value != null:
		_check_known_plain(_ret, r.value, "the return type", r.line, r.col)
	if r.value == null:
		return
	if _is_null_literal(r.value):
		if _opted_in:
			_warn("returning null from a function declared '%s'" % _ret.describe(),
				r.line, r.col,
				"declare the return type `%s?` and GATE will check every caller"
					% _ret.describe())
		return
	var st: int = _nullness(r.value)
	if st == _S.NOTNULL:
		return
	var src: String = _path_of(r.value)
	var desc: String = "'%s'" % src if src != "" else "the returned value"
	_err("%s %s null, but the return type is '%s'"
			% [desc, "is" if st == _S.NULL else "may be", _ret.describe()],
		r.line, r.col,
		"guard it before returning, or declare the return type `%s?`" % _ret.describe())


func _check_known_plain(decl: GateAST._TypeRef, value, what: String, line: int, col: int) -> void:
	if decl.nullable or GateChecker.is_gate_only_type(decl):
		return
	var to: String = _godot_probe_type(decl)
	if to == "":
		return
	var container: bool = decl.array_depth > 0 or decl.is_dict() or not decl.generic_args.is_empty()
	if container and (value is GateAST._ArrayLit or value is GateAST._DictLit) \
			and (to == "Array") == (value is GateAST._ArrayLit) and to != "Object":
		_check_literal_elements(decl, value, what, line, col)
		return
	var lit: String = ""
	var vt: GateAST._TypeRef = null
	var from: String = ""
	if value is GateAST._Literal and (value as GateAST._Literal).kind != "null":
		lit = (value as GateAST._Literal).raw
		from = lit
	else:
		vt = _godot_known_type(value)
		from = _godot_value_probe(vt)
		if from == "":
			return
		if to == "Object" and ClassDB.class_exists(from):
			return   # an object into a class of the user's: Godot checks it when it runs
	if _godot_accepts(from, to, lit != ""):
		return
	var shown: String = lit if lit != "" else GateTypeCompat.describe(vt)
	var hint: String = "Godot refuses this when it loads the script"
	if GateTypes.BUILTIN.has(to) and not container:
		hint += "; convert it first, as in `%s(...)`" % to
	_err("%s is %s, and %s cannot be stored there" % [what, decl.describe(), shown], line, col, hint)


func _godot_value_probe(vt: GateAST._TypeRef) -> String:
	if vt == null or vt.nullable or GateChecker.is_gate_only_type(vt):
		return ""
	if vt.array_depth > 0:
		return "Array"
	if vt.is_dict():
		return "Dictionary"
	var c: String = GateTypes.canonical(vt.name)
	if not vt.generic_args.is_empty():
		return c if (c == "Array" or c == "Dictionary") else ""
	return c if _godot_type_name(vt.name) else ""


func _decl_element(decl: GateAST._TypeRef) -> GateAST._TypeRef:
	var et: GateAST._TypeRef = null
	if decl.array_depth > 0 or GateTypeCompat.PACKED_ARRAYS.has(GateTypes.canonical(decl.name)):
		et = infer.element_type(decl)
	elif decl.is_dict():
		et = decl.dict_value
	elif not decl.generic_args.is_empty():
		var c: String = GateTypes.canonical(decl.name)
		if c == "Array" and decl.generic_args.size() == 1:
			et = decl.generic_args[0]
		elif c == "Dictionary" and decl.generic_args.size() == 2:
			et = decl.generic_args[1]
	return null if et == null or GateChecker.is_gate_only_type(et) else et


func _decl_key(decl: GateAST._TypeRef) -> GateAST._TypeRef:
	if decl == null:
		return null
	var kt: GateAST._TypeRef = null
	if decl.is_dict():
		kt = decl.dict_key
	elif not decl.generic_args.is_empty() and decl.generic_args.size() == 2 \
			and GateTypes.canonical(decl.name) == "Dictionary":
		kt = decl.generic_args[0]
	return null if kt == null or GateChecker.is_gate_only_type(kt) else kt


func _check_literal_elements(decl: GateAST._TypeRef, value, what: String, line: int, col: int) -> void:
	var et: GateAST._TypeRef = _decl_element(decl)
	if value is GateAST._ArrayLit:
		if et == null:
			return
		for el in (value as GateAST._ArrayLit).elements:
			_check_known_plain(et, el, "an element of %s" % what, el.line, el.col)
		return
	var dl: GateAST._DictLit = value
	var kt: GateAST._TypeRef = _decl_key(decl)
	for i in dl.keys.size():
		var lua: bool = i < dl.lua_keys.size() and dl.lua_keys[i]
		if kt != null and not lua and dl.keys[i] != null:
			_check_known_plain(kt, dl.keys[i], "a key of %s" % what, dl.keys[i].line, dl.keys[i].col)
		if et != null and i < dl.values.size() and dl.values[i] != null:
			_check_known_plain(et, dl.values[i], "a value of %s" % what,
				dl.values[i].line, dl.values[i].col)


func _godot_probe_type(decl: GateAST._TypeRef) -> String:
	if decl.array_depth > 0:
		return "Array"
	if decl.is_dict():
		return "Dictionary"
	var n: String = decl.name
	var leaf: String = n.get_slice(".", n.get_slice_count(".") - 1)
	if not decl.generic_args.is_empty():
		var gc: String = GateTypes.canonical(n)
		if gc == "Array" or gc == "Dictionary":
			return gc
		return "Object" if infer.generic_params.has(n) else ""
	if _godot_type_name(n):
		return GateTypes.canonical(n)
	if _enum_names.has(leaf) or infer.open_types.has(leaf) or GateTypes.shadowed.has(n) \
			or _is_generic_param(n):
		return ""
	var sd = infer.struct_names.get(leaf, null)
	if sd is GateAST._ClassDecl:
		var scd: GateAST._ClassDecl = sd
		return scd.vector_type if scd.lowering == "vector" else "Object"
	if infer.has_class(leaf) or GateChecker._global_script(n, null) != "":
		return "Object"
	return ""


func _godot_type_name(n: String) -> bool:
	var c: String = GateTypes.canonical(n)
	if c == "" or c == "Variant" or GateTypes.shadowed.has(n) or _struct_names.has(n) \
			or _enum_names.has(n) or infer.has_class(n):
		return false
	return GateTypes.BUILTIN.has(c) or c == "Array" or c == "Dictionary" \
		or GateTypeCompat.PACKED_ARRAYS.has(c) or ClassDB.class_exists(c)


func _godot_known_type(e) -> GateAST._TypeRef:
	if e is GateAST._ArrayLit:
		return infer._shared("Array")
	if e is GateAST._DictLit:
		return infer._shared("Dictionary")
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		if _local_names.has(n):
			return _locals.get(n, null) if _fixed.has(n) and _explicit.get(n, false) else null
		return _field_names.get(n, null)
	if e is GateAST._Call:
		var c: GateAST._Call = e
		if c.callee is GateAST._Ident and infer.module_functions.has((c.callee as GateAST._Ident).name) \
				and (_cls == "" or _cls == GateInfer.MODULE_CLASS
					or infer.method_candidates(_cls, (c.callee as GateAST._Ident).name).is_empty()):
			return _static_type_of(e)
		if c.callee is GateAST._Ident and infer.CONSTRUCTED.has(GateTypes.canonical(
				(c.callee as GateAST._Ident).name)) and not _local_names.has((c.callee as GateAST._Ident).name):
			return _static_type_of(e)
	return null


var _explicit: Dictionary = {}


static var _accepts_cache: Dictionary = {}


static func _godot_accepts(from: String, to: String, literal: bool) -> bool:
	var key: String = "%s|%s|%s" % [from, to, literal]
	if not _accepts_cache.has(key):
		var g: GDScript = GDScript.new()
		if literal:
			g.source_code = "func f() -> void:\n\tvar t: %s = %s\n" % [to, from]
		else:
			g.source_code = "func f(v: %s) -> void:\n\tvar t: %s = v\n" % [from, to]
		var saved: bool = Engine.print_error_messages
		Engine.print_error_messages = false
		_accepts_cache[key] = g.reload() == OK
		Engine.print_error_messages = saved
	return _accepts_cache[key]


func _check_gate_source(decl: GateAST._TypeRef, value, what: String, line: int, col: int) -> void:
	if not _gate_types or decl == null or value == null or decl.name == "" \
			or GateTypes.canonical(decl.name) == "Variant":
		return
	var vt: GateAST._TypeRef = _value_type(value)
	if vt == null or not (vt.is_union() or vt.is_tuple()):
		return
	if GateTypeCompat.assignable(vt, decl, infer) == GateTypeCompat.NO:
		_report_mismatch(decl, vt, what, line, col)


func _check_gate_value(decl: GateAST._TypeRef, value, what: String, line: int, col: int) -> GateAST._Expr:
	if not _check_compat(decl, value, what, line, col):
		return value
	var st: int = _S.NOTNULL if decl.nullable or _is_null_literal(value) else _nullness(value)
	var src: String = _path_of(value)
	value = _widen(decl, value, what, line, col)
	if st == _S.NOTNULL:
		return value
	var desc: String = "'%s'" % src if src != "" else "the value"
	_err("%s %s null, but %s is %s, which is not nullable"
			% [desc, "is" if st == _S.NULL else "may be", what, decl.describe()], line, col,
		"guard it first, or declare it `%s?`" % decl.describe())
	return value


func _widen(decl: GateAST._TypeRef, value, what: String, line: int, col: int, slot: bool = false) -> GateAST._Expr:
	infer.ensure_effects()   # this may rewrite the tree the summaries are read from
	if decl == null or value == null:
		return value
	if value is GateAST._Ternary:
		var tv: GateAST._Ternary = value
		tv.if_true = _widen(decl, tv.if_true, what, line, col, slot)
		tv.if_false = _widen(decl, tv.if_false, what, line, col, slot)
		return value
	if value is GateAST._NullCoalesce:
		var nc: GateAST._NullCoalesce = value
		nc.left = _widen(decl, nc.left, what, line, col, slot)
		nc.right = _widen(decl, nc.right, what, line, col, slot)
		return value
	if value is GateAST._ArrayLit:
		return _widen_array(decl, value, what, line, col, slot)
	if value is GateAST._DictLit:
		if decl.is_dict() and decl.array_depth == 0 and decl.dict_value != null:
			var dl: GateAST._DictLit = value
			for i in dl.values.size():
				if dl.values[i] != null:
					dl.values[i] = _widen(decl.dict_value, dl.values[i], "a value of %s" % what,
						line, col)
			for k in dl.keys.size():
				if not (k < dl.lua_keys.size() and dl.lua_keys[k]):
					dl.keys[k] = _widen(decl.dict_key, dl.keys[k], "a key of %s" % what, line, col)
		return value
	if decl.array_depth > 0 or not (decl.is_union() or slot):
		return value
	var vt: GateAST._TypeRef = _value_type(value)
	if vt == null:
		return value
	var guards: Array = []
	if vt.is_union() and vt.array_depth == 0:
		guards = GateTypeCompat.member_widenings(vt, decl, infer)
		for g in guards:
			if String(g[1]) == "?":
				_err("%s is %s, and %s, one of the types of %s, widens to more than one of them"
						% [what, decl.describe(), g[0], vt.describe()], line, col,
					"narrow it with `is` and convert it yourself to the one you mean")
				return value
		if guards.is_empty():
			return value
	else:
		var to: String = GateTypeCompat.widening(vt, decl, infer)
		if to == "":
			return value
		if to == "?":
			_err("%s is %s, and %s widens to more than one of its types"
					% [what, decl.describe(), GateTypeCompat.describe(vt)], line, col,
				"convert it yourself to the one you mean, as in `StringName(x)`")
			return value
		if vt.nullable and _nullness(value) != _S.NOTNULL:
			guards = [["null", to]]
		elif _quiet == 0:
			return _conversion(GateAST._Call.new(), to, value)
	if _quiet > 0:
		return value
	var w: GateAST._Widen = GateAST._Widen.new()
	w.guards = guards
	return _conversion(w, String(guards[0][1]), value)


func _conversion(conv: GateAST._Call, to: String, value: GateAST._Expr) -> GateAST._Call:
	conv.at(value.line, value.col)
	var callee: GateAST._Ident = GateAST._Ident.new()
	callee.at(value.line, value.col)
	callee.name = to
	conv.callee = callee
	conv.args = [value]
	return conv


func _widen_array(decl: GateAST._TypeRef, al: GateAST._ArrayLit, what: String, line: int, col: int,
		slot: bool) -> GateAST._Expr:
	if decl.is_tuple() and decl.array_depth == 0 and al.elements.size() == decl.tuple_elems.size():
		for i in al.elements.size():
			al.elements[i] = _widen(decl.tuple_elems[i], al.elements[i],
				"element %d of %s" % [i, what], line, col, true)
		return al
	if decl.array_depth == 1 and (decl.is_union() or decl.is_tuple()):
		var elem_t: GateAST._TypeRef = GateTypeCompat._element(decl)
		for j in al.elements.size():
			al.elements[j] = _widen(elem_t, al.elements[j], "an element of %s" % what, line,
				col, true)
		return al
	var cands: Array = []
	if decl.is_union() and decl.array_depth == 0:
		cands = GateTypeCompat.flat_members(decl)
	elif slot and decl.array_depth > 0:
		cands = [decl]
	var lit_t: GateAST._TypeRef = _value_type(al)
	var fits: Array = []
	for m in cands:
		var mt: GateAST._TypeRef = m
		if not (mt.array_depth > 0 or mt.is_tuple() or GateTypeCompat._category(mt, infer) == "array"):
			continue
		if GateTypeCompat.assignable(lit_t, mt, infer) != GateTypeCompat.NO:
			fits.append(mt)
	if fits.size() > 1:
		var exact: Array = fits.filter(func(ft: GateAST._TypeRef) -> bool:
			return GateTypeCompat.assignable(lit_t, ft, infer, false) == GateTypeCompat.YES)
		if exact.size() == 1:
			fits = exact
	if fits.size() > 1:
		var all_typed: bool = true
		for ft2 in fits:
			if (ft2 as GateAST._TypeRef).array_depth == 0 or GateChecker.is_gate_only_type(ft2):
				all_typed = false
		if all_typed and decl.is_union():
			_err("%s is %s, and this array fits more than one of its types" % [what, decl.describe()],
				line, col, "say which, as in `[] as %s`" % (fits[0] as GateAST._TypeRef).describe())
		return al
	if fits.is_empty() or _quiet > 0:
		return al
	var typed: GateAST._TypeRef = fits[0]
	if typed.array_depth == 0 or GateChecker.is_gate_only_type(typed):
		return al
	var ce: GateAST._CastExpr = GateAST._CastExpr.new()
	ce.at(al.line, al.col)
	ce.operand = al
	ce.type = GateChecker.copy_type(typed)
	ce.type.nullable = false
	return ce


func _check_compat(decl: GateAST._TypeRef, value, what: String, line: int, col: int) -> bool:
	if value is GateAST._Ternary:
		var tv: GateAST._Ternary = value
		return _check_compat(decl, tv.if_true, what, line, col) \
			and _check_compat(decl, tv.if_false, what, line, col)
	if value is GateAST._NullCoalesce:
		var nc: GateAST._NullCoalesce = value
		return _check_compat(decl, nc.left, what, line, col) \
			and _check_compat(decl, nc.right, what, line, col)
	if value is GateAST._DictLit and decl.is_dict() and decl.array_depth == 0 \
			and decl.dict_value != null:
		var dl: GateAST._DictLit = value
		var ok: bool = true
		for i in dl.values.size():
			if dl.values[i] != null and not _check_compat(decl.dict_value, dl.values[i],
					"a value of %s" % what, line, col):
				ok = false
		return ok
	var vt: GateAST._TypeRef = _value_type(value)
	if GateTypeCompat.assignable(vt, decl, infer) != GateTypeCompat.NO:
		return true
	_report_mismatch(decl, vt, what, line, col)
	return false


func _value_type(value) -> GateAST._TypeRef:
	if _is_null_literal(value):
		return GateTypeCompat.null_type()
	if value is GateAST._ArrayLit:
		var elems: Array = []
		for el in (value as GateAST._ArrayLit).elements:
			elems.append(_value_type(el))
		if elems.is_empty():
			return _type_of(value)
		return GateTypeCompat.tuple_of(elems)
	return _type_of(value)


func _check_typed_call(c: GateAST._Call) -> void:
	if not _gate_types or not (c.callee is GateAST._Member) or (c.callee as GateAST._Member).name != "call":
		return
	var m: GateAST._Member = c.callee
	var t: GateAST._TypeRef = _type_of(m.target)
	if t == null or not t.is_func_type or t.array_depth > 0:
		return
	var shown: String = (m.target as GateAST._Ident).name if m.target is GateAST._Ident \
		else _path_of(m.target)
	var desc: String = "'%s'" % shown if shown != "" else "the callable"
	var want: int = t.callable_params.size()
	if c.args.size() != want:
		_err("%s is %s, which takes %d argument(s), but %d given" % [desc, t.describe(), want,
				c.args.size()], c.line, c.col)
		return
	for i in want:
		if _check_compat(t.callable_params[i], c.args[i],
				"argument %d of %s" % [i + 1, desc], c.line, c.col):
			c.args[i] = _widen(t.callable_params[i], c.args[i],
				"argument %d of %s" % [i + 1, desc], c.line, c.col, true)


func _check_union_operator(op: String, left, right, line: int, col: int) -> void:
	if not _gate_types or not GateTypeCompat.OPERATORS.has(op):
		return
	var lt: GateAST._TypeRef = _type_of(left)
	var rt: GateAST._TypeRef = _type_of(right) if right != null else null
	var lu: bool = lt != null and lt.is_union() and lt.array_depth == 0
	var ru: bool = rt != null and rt.is_union() and rt.array_depth == 0
	if not (lu or ru):
		return
	var bad: String = GateTypeCompat.operator_problem(op, lt, rt, right == null, infer)
	if bad == "":
		return
	var which: Variant = left if lu else right
	var wt: GateAST._TypeRef = lt if lu else rt
	_err("'%s' is %s, and %s is not defined" % [_shown(which), wt.describe(), bad], line, col,
		"an operator on a union must work for every type in it. Narrow it with `is` first")


func _tuple_slot(ix: GateAST._Index, report: bool = true) -> GateAST._TypeRef:
	if not _gate_types:
		return null
	var tt: GateAST._TypeRef = _type_of(ix.target)
	if tt == null or not tt.is_tuple() or tt.array_depth > 0:
		return null
	var k: Variant = _const_index(ix.index)
	if k == null:
		return null
	var n: int = tt.tuple_elems.size()
	var at: int = int(k) if int(k) >= 0 else n + int(k)
	if at < 0 or at >= n:
		if not report:
			return null
		_err("'%s' is %s, which has %d element(s); index %d is out of range"
				% [_shown(ix.target), tt.describe(), n, int(k)], ix.line, ix.col,
			"a tuple's length is part of its type")
		return null
	return tt.tuple_elems[at]


func _const_index(e) -> Variant:
	return GateChecker.fold_int(e, _const_exprs)


static func _const_index_literal(e) -> Variant:
	if e is GateAST._Literal and (e as GateAST._Literal).kind == "number" \
			and (e as GateAST._Literal).raw.is_valid_int():
		return int((e as GateAST._Literal).raw)
	if e is GateAST._Unary and (e as GateAST._Unary).op == "-" and (e as GateAST._Unary).operand is GateAST._Literal \
			and ((e as GateAST._Unary).operand as GateAST._Literal).raw.is_valid_int():
		return -int(((e as GateAST._Unary).operand as GateAST._Literal).raw)
	return null


func _shown(e) -> String:
	if e is GateAST._Ident:
		return (e as GateAST._Ident).name
	var p: String = _path_of(e)
	return p if p != "" else "the value"


const TUPLE_LENGTH_CHANGERS := {
	"append": true, "append_array": true, "push_back": true, "push_front": true,
	"insert": true, "clear": true, "resize": true, "erase": true, "remove_at": true,
	"pop_back": true, "pop_front": true, "pop_at": true,
}


func _check_tuple_call(c: GateAST._Call) -> void:
	if not _gate_types or not (c.callee is GateAST._Member):
		return
	var m: GateAST._Member = c.callee
	var reorders: bool = TUPLE_REORDERS.has(m.name)
	if not TUPLE_LENGTH_CHANGERS.has(m.name) and not reorders:
		return
	var tt: GateAST._TypeRef = _type_of(m.target)
	if tt == null or not tt.is_tuple() or tt.array_depth > 0:
		return
	if reorders:
		_err("'%s' is %s, and .%s() would move its values between slots" % [_shown(m.target),
				tt.describe(), m.name], c.line, c.col,
			"each slot of a tuple has its own type; copy it into an array (`T[]`) to reorder")
		return
	_err("'%s' is %s, and .%s() would change its length" % [_shown(m.target), tt.describe(), m.name],
		c.line, c.col, "a tuple's length is part of its type; use an array (`T[]`) to grow or shrink")


const TUPLE_REORDERS := {"reverse": true, "sort": true, "sort_custom": true, "shuffle": true}


const ARRAY_STORES := {"append": 0, "push_back": 0, "push_front": 0, "insert": 1, "fill": 0}


func _check_array_store_call(c: GateAST._Call) -> void:
	if not (c.callee is GateAST._Member):
		return
	var m: GateAST._Member = c.callee
	if not ARRAY_STORES.has(m.name) or c.args.size() <= int(ARRAY_STORES[m.name]):
		return
	var tt: GateAST._TypeRef = _type_of(m.target)
	if tt == null or tt.array_depth == 0 or tt.is_dict():
		return
	var et: GateAST._TypeRef = GateTypeCompat._element(tt)
	if not GateChecker.is_gate_only_type(et):
		return
	var at: int = ARRAY_STORES[m.name]
	c.args[at] = _check_gate_value(et, c.args[at], "an element of '%s'" % _shown(m.target),
		c.line, c.col)


func _check_signal_use(c: GateAST._Call) -> void:
	var sig: GateAST._TypeRef = null
	var shown: String = ""
	var verb: String = ""
	var args: Array = c.args
	var by_name_cls: String = ""
	if c.callee is GateAST._Member:
		var m: GateAST._Member = c.callee
		if m.name == "emit" or m.name == "connect":
			if m.target is GateAST._Ident and _local_names.has((m.target as GateAST._Ident).name):
				var lt: Variant = _locals.get((m.target as GateAST._Ident).name, null)
				if not (lt is GateAST._TypeRef and (lt as GateAST._TypeRef).sig_known):
					return
			var st: GateAST._TypeRef = _type_of(m.target)
			if st != null and st.sig_known and st.array_depth == 0 \
					and GateTypes.canonical(st.name) == "Signal":
				sig = st
				verb = m.name
				shown = (m.target as GateAST._Member).name if m.target is GateAST._Member \
					else (m.target as GateAST._Ident).name if m.target is GateAST._Ident else "the signal"
		elif m.name == "emit_signal":
			var rt: GateAST._TypeRef = _type_of(m.target)
			if rt != null and rt.array_depth == 0:
				by_name_cls = rt.name
	elif c.callee is GateAST._Ident and (c.callee as GateAST._Ident).name == "emit_signal":
		by_name_cls = _cls
	if by_name_cls != "" and not c.args.is_empty() and c.args[0] is GateAST._Literal \
			and (c.args[0] as GateAST._Literal).kind == "string":
		shown = (c.args[0] as GateAST._Literal).raw.lstrip("&^").replace("\"", "").replace("'", "")
		sig = infer.signal_type(by_name_cls, shown)
		verb = "emit"
		args = c.args.slice(1)
	if sig == null:
		return
	if sig.callable_params.is_empty():
		return
	for p in sig.callable_params:
		if p == null:
			return
	var params: PackedStringArray = PackedStringArray()
	for p2 in sig.callable_params:
		params.append((p2 as GateAST._TypeRef).describe())
	var declared: String = "%s(%s)" % [shown, ", ".join(params)]
	if verb == "emit":
		if args.size() != sig.callable_params.size():
			_warn("'%s' is declared %s, but %d argument(s) are emitted"
					% [shown, declared, args.size()], c.line, c.col,
				"GDScript does not check signal arguments; every connected method "
				+ "receives exactly these")
			return
		var offset: int = c.args.size() - args.size()
		for i in args.size():
			var vt: GateAST._TypeRef = _value_type(args[i])
			var pt: GateAST._TypeRef = sig.callable_params[i]
			if vt != null and vt.name == "null" and GateTypeCompat.holds_null(pt, infer):
				continue
			if GateTypeCompat.godot_converts(vt, pt):
				continue
			if GateTypeCompat.assignable(vt, pt, infer) == GateTypeCompat.NO:
				_warn("'%s' is declared %s, but argument %d is %s"
						% [shown, declared, i + 1, GateTypeCompat.describe(vt)], c.line, c.col,
					"GDScript does not check signal arguments, so connected methods "
					+ "would receive this as it is")
			elif GateChecker.is_gate_only_type(pt):
				c.args[i + offset] = _widen(pt, c.args[i + offset],
					"argument %d of '%s'" % [i + 1, shown], c.line, c.col)
		return
	if args.is_empty():
		return
	var ft: GateAST._TypeRef = _type_of(args[0])
	if ft == null or not (ft.sig_known or ft.is_func_type) or GateTypes.canonical(ft.name) != "Callable":
		return
	var want: GateAST._TypeRef = GateAST._TypeRef.new()
	want.name = "Callable"
	want.is_func_type = true
	want.callable_params = sig.callable_params
	var ret: GateAST._TypeRef = GateAST._TypeRef.new()
	ret.name = "void"
	want.callable_return = ret
	if GateTypeCompat.assignable(ft, want, infer) == GateTypeCompat.NO:
		var receiver: String = (args[0] as GateAST._Ident).name if args[0] is GateAST._Ident \
			else "this callable"
		_warn("'%s' cannot receive '%s', which is declared %s" % [receiver, shown, declared],
			c.line, c.col,
			"its parameters must take exactly what the signal passes. Godot reports this "
			+ "only when the signal is emitted")


func _check_union_elements(target, what: String, line: int, col: int) -> void:
	var t: GateAST._TypeRef = _type_of(target)
	if t == null or not t.is_union() or t.array_depth > 0:
		return
	var elem: String = ""
	var uniform: bool = true
	for m in GateTypeCompat.flat_members(t):
		var mt: GateAST._TypeRef = m
		var et: GateAST._TypeRef = infer.element_type(mt)
		if et == null and mt.array_depth == 0 and GateTypes.canonical(mt.name) == "String":
			et = infer._shared("String")
		var en: String = et.describe() if et != null else ""
		if en == "" or (elem != "" and en != elem):
			uniform = false
			break
		elem = en
	if uniform:
		return
	var shown: String = _shown(target)
	_err("'%s' is %s; narrow it with `is` before %s it" % [shown, t.describe(), what], line, col,
		"its types hold different elements, or none. Test first: `if %s is %s:`"
			% [shown, GateTypeCompat.describe(t.union_members[0])])


func _member_printed_differently(t: GateAST._TypeRef, name: String, m: GateAST._Member = null) -> GateAST._TypeRef:
	var first: String = ""
	var first_type: GateAST._TypeRef = null
	var renamer: String = ""
	for um in t.union_members:
		var cls: String = GateTypes.canonical((um as GateAST._TypeRef).name)
		var printed: String = infer.emitted_member(cls, name)
		if printed == "":
			return null   # one of them is beyond GATE's sight: say nothing
		if printed != name and renamer == "":
			renamer = cls
		if first == "":
			first = printed
			first_type = um
			continue
		if printed != first:
			return um if printed != name else first_type
	if m != null and renamer != "":
		m.member_class = renamer
	return null


func _check_joined_member(m: GateAST._Member) -> void:
	if not (m.target is GateAST._Ident) or _type_of(m.target) != null:
		return
	var n: String = (m.target as GateAST._Ident).name
	if not _inferred.has(JOINED + n):
		return
	var t: GateAST._TypeRef = _inferred[JOINED + n]
	var odd: GateAST._TypeRef = _member_printed_differently(t, m.name, m)
	if odd != null:
		_err("'%s' may hold %s here, and `.%s` is not the same member on each of those "
				% [n, GateTypeCompat.describe(t), m.name] + "types; narrow it with `is` first",
			m.line, m.col,
			"the paths that meet here leave different types in '%s'. On %s `.%s` is a "
				% [n, GateTypeCompat.describe(odd), m.name]
			+ "packed struct's field, a `priv` member or an overloaded method under a name "
			+ "the others do not use. Test first: `if %s is %s:`" % [n, GateTypeCompat.describe(odd)])


func _check_union_member(m: GateAST._Member) -> void:
	_check_joined_member(m)
	if not _gate_types:
		return
	var t: GateAST._TypeRef = _type_of(m.target)
	if t == null or not t.is_union() or t.array_depth > 0:
		return
	var shown: String = (m.target as GateAST._Ident).name if m.target is GateAST._Ident \
		else _path_of(m.target)
	var desc: String = "'%s'" % shown if shown != "" else "the value"
	if _every_member_has(t, m.name):
		var odd: GateAST._TypeRef = _member_printed_differently(t, m.name, m)
		if odd != null:
			_err("%s is %s, and `.%s` is not the same member on each of those types; "
					% [desc, t.describe(), m.name] + "narrow it with `is` first",
				m.line, m.col,
				"on %s it is a packed struct's field, a `priv` member or an overloaded "
					% GateTypeCompat.describe(odd)
				+ "method under a name the others do not use. Test first: `if %s is %s:`"
					% [shown if shown != "" else "x", GateTypeCompat.describe(odd)])
		return
	_err("%s is %s; narrow it with `is` before using its members" % [desc, t.describe()],
		m.line, m.col,
		"`.%s` is not on every type in the union. Test first: `if %s is %s:`"
			% [m.name, shown if shown != "" else "x",
				GateTypeCompat.describe(t.union_members[0])])


func _every_member_has(t: GateAST._TypeRef, name: String) -> bool:
	for um in t.union_members:
		var mt: GateAST._TypeRef = um
		if mt.is_union() or mt.is_tuple() or mt.array_depth > 0 or mt.is_dict():
			return false
		var cls: String = GateTypes.canonical(mt.name)
		if GateTypes.BUILTIN.has(cls) or GateTypeCompat.PACKED_ARRAYS.has(cls):
			return false
		if infer.has_member(cls, name) == 0:
			return false
	return true


func _report_mismatch(decl: GateAST._TypeRef, vt: GateAST._TypeRef, what: String, line: int, col: int) -> void:
	var dd: String = decl.describe()
	if vt.is_union() and vt.array_depth == 0:
		for m in GateTypeCompat.flat_members(vt):
			if GateTypeCompat.assignable(m, decl, infer) == GateTypeCompat.NO:
				_err("%s is %s, but the value is %s, and %s does not fit" % [what, dd, vt.describe(),
						GateTypeCompat.describe(m)], line, col,
					"a union fits only where every one of its types does. Narrow it with `is` first")
				return
	if vt.name == "null" and not vt.is_tuple():
		_err("%s is %s, which is not nullable, so it cannot hold null" % [what, dd], line, col,
			"declare it `%s?` to allow null" % dd)
		return
	if decl.is_tuple() and vt.is_tuple():
		var want: int = decl.tuple_elems.size()
		var got: int = vt.tuple_elems.size()
		if want != got:
			_err("%s is %s, which holds %d value(s), but this array has %d" % [what, dd, want, got],
				line, col, "a tuple's length is part of its type")
			return
		for i in want:
			if GateTypeCompat.assignable(vt.tuple_elems[i], decl.tuple_elems[i], infer) == GateTypeCompat.NO:
				_err("%s is %s, but element %d is %s, not %s" % [what, dd, i,
						GateTypeCompat.describe(vt.tuple_elems[i]),
						GateTypeCompat.describe(decl.tuple_elems[i])],
					line, col)
				return
	if decl.is_union():
		_err("%s is %s, and %s is not one of its types" % [what, dd, GateTypeCompat.describe(vt)],
			line, col, "store one of those types, or add this one to the union")
		return
	_err("%s is %s, and %s does not fit" % [what, dd, GateTypeCompat.describe(vt)], line, col)


func _check_expr(e) -> void:
	if e == null:
		return
	_note_flow_type(e)

	if e is GateAST._Member or e is GateAST._Index:
		var spine: Array = []
		var cur = e
		while cur is GateAST._Member or cur is GateAST._Index:
			spine.append(cur)
			cur = (cur as GateAST._Member).target if cur is GateAST._Member else (cur as GateAST._Index).target
		for node in spine:
			if node != e:
				_note_flow_type(node)   # `e` itself was noted above
			if node is GateAST._Member:
				var mm: GateAST._Member = node
				_check_union_member(mm)
				if not mm.safe:
					_report_deref(mm.target, mm.line, mm.col, ".%s" % mm.name)
			else:
				var ii: GateAST._Index = node
				if not ii.safe:
					_report_deref(ii.target, ii.line, ii.col, "[...]")
				_check_expr(ii.index)
				_check_value_operand(ii.index, "[...]", ii.line, ii.col)
				if _gate_types:
					_tuple_slot(ii)
					_check_union_elements(ii.target, "indexing", ii.line, ii.col)
		_check_expr(cur)
		for gi in range(spine.size() - 1, -1, -1):
			if spine[gi] is GateAST._Member and _accessor(spine[gi]).get("get", false):
				_opaque_call()
		return

	if e is GateAST._Ident and _accessor(e).get("get", false):
		_opaque_call()
		return

	if e is GateAST._Call:
		var c: GateAST._Call = e
		_check_expr(c.callee)
		for a in c.args:
			_check_expr(a)
		_check_call_site(c)
		_note_overload_receiver(c)
		_check_init_values(c)
		if _gate_types:
			_check_typed_call(c)
			_check_tuple_call(c)
			_check_array_store_call(c)
		var callee_name: String = (c.callee as GateAST._Member).name if c.callee is GateAST._Member \
			else ((c.callee as GateAST._Ident).name if c.callee is GateAST._Ident else "")
		if callee_name == "emit" or callee_name == "connect" or callee_name == "emit_signal":
			_check_signal_use(c)
		_apply_call_effects(c)
		return

	if e is GateAST._Binary:
		var b: GateAST._Binary = e
		if b.op == "and" or b.op == "or":
			var truth: bool = b.op == "and"
			var run: Array = []
			var below = b
			while below is GateAST._Binary and (below as GateAST._Binary).op == b.op:
				run.append(below)
				below = (below as GateAST._Binary).left
			run.reverse()
			for ri in range(run.size() - 1, 0, -1):
				_note_flow_type(run[ri - 1])   # `b` itself was noted above
			_check_expr(below)
			var saved: Array = _state_copy()
			var tested: Array = _narrow_state(saved, below, truth)
			for ri2 in run.size():
				var node: GateAST._Binary = run[ri2]
				_set_state(_copy_state(tested))
				_check_expr(node.right)
				var env_n: int = (saved[0] as Dictionary).size()
				var nar_n: int = (saved[1] as Dictionary).size()
				_drop_killed(saved, tested, _state_copy())   # the right side may have run
				_set_state(saved)
				if ri2 + 1 == run.size():
					break
				if (saved[0] as Dictionary).size() == env_n and (saved[1] as Dictionary).size() == nar_n:
					tested = _narrow_step(tested, node.right, truth)
				else:
					tested = _narrow_state(saved, node, truth)   # the base moved: narrow it afresh
			_set_state(saved)
			return
		var spine: Array = []
		var cur = b
		while cur is GateAST._Binary:
			var cb: GateAST._Binary = cur
			if cb.op == "and" or cb.op == "or":
				break
			spine.append(cb)
			cur = cb.left
		_check_expr(cur)
		for n in spine:
			var nb: GateAST._Binary = n
			_check_expr(nb.right)
			_check_value_operands(nb)
			if _gate_types:
				_check_union_operator(nb.op, nb.left, nb.right, nb.line, nb.col)
		return

	if e is GateAST._Ternary:
		var t: GateAST._Ternary = e
		_check_expr(t.cond)
		var saved3: Array = _state_copy()
		var yes: Array = _narrow_state(saved3, t.cond, true)
		_set_state(_copy_state(yes))
		_check_expr(t.if_true)
		var yes_after: Array = _state_copy()
		var no: Array = _narrow_state(saved3, t.cond, false)
		_set_state(_copy_state(no))
		_check_expr(t.if_false)
		_drop_killed(saved3, yes, yes_after)
		_drop_killed(saved3, no, _state_copy())
		_set_state(saved3)
		return

	if e is GateAST._NullCoalesce:
		var nc: GateAST._NullCoalesce = e
		if not (nc.left is GateAST._Member and (nc.left as GateAST._Member).safe) \
			and not (nc.left is GateAST._Index and (nc.left as GateAST._Index).safe):
			_check_expr(nc.left)
		_check_expr(nc.right)
		return

	if e is GateAST._Lambda:
		_check_lambda(e)
		return

	if e is GateAST._AwaitExpr:
		_check_expr((e as GateAST._AwaitExpr).operand)
		_invalidate_across_suspend()
		return

	if e is GateAST._Unary:
		var un: GateAST._Unary = e
		_check_expr(un.operand)
		if un.op == "-" or un.op == "~":
			_check_value_operand(un.operand, un.op, un.line, un.col)
		if _gate_types and (un.op == "-" or un.op == "~" or un.op == "+"):
			_check_union_operator(un.op, un.operand, null, un.line, un.col)
		return
	if e is GateAST._CastExpr:
		_check_expr((e as GateAST._CastExpr).operand); return
	if e is GateAST._IsExpr:
		_check_expr((e as GateAST._IsExpr).operand); return
	if e is GateAST._ArrayLit:
		for el in (e as GateAST._ArrayLit).elements: _check_expr(el)
		return
	if e is GateAST._DictLit:
		var d: GateAST._DictLit = e
		for k in d.keys: _check_expr(k)
		for v in d.values: _check_expr(v)
		return
	if e is GateAST._ObjectInit:
		var oi: GateAST._ObjectInit = e
		for v2 in oi.values: _check_expr(v2)
		return
		return
	if e is GateAST._FString:
		for part in (e as GateAST._FString).parts:
			if not (part is String): _check_expr(part)
		return


func _check_lambda(lam: GateAST._Lambda) -> void:
	var saved_env: Dictionary = _env
	var saved_narrowed: Dictionary = _narrowed
	var saved_locals: Dictionary = _locals.duplicate()
	var saved_names: Dictionary = _local_names.duplicate()
	var saved_ret: GateAST._TypeRef = _ret
	var carried: Dictionary = {}
	for k in _env:
		if _captured_by_value(String(k)):
			carried[k] = _env[k]
	var carried_t: Dictionary = {}
	for k2 in _narrowed:
		if _captured_by_value(String(k2)):
			carried_t[k2] = _narrowed[k2]
	_env = carried
	_narrowed = carried_t
	var saved_fresh: Dictionary = _fresh
	_fresh = _scan_fresh(lam.body, lam.expr_body)
	var saved_inferred: Dictionary = _inferred
	var saved_fixed: Dictionary = _fixed
	_inferred = _inferred.duplicate()
	_fixed = _fixed.duplicate()
	_ret = lam.return_type
	var hints: Array = _param_hints.get(lam, [])
	for pi in lam.params.size():
		var pp: GateAST._Param = lam.params[pi]
		if pp.default != null:
			_check_param_default(pp, "the lambda")
		var hint: GateAST._TypeRef = hints[pi] if pp.type == null and pi < hints.size() else null
		_declare_local(pp.name, pp.type if pp.type != null else hint)
		if pp.type != null and pp.type.nullable:
			_env[pp.name] = _S.MAYBE
	_walk_block(lam.body)
	if lam.expr_body != null:
		_check_expr(lam.expr_body)
	_env = saved_env
	_narrowed = saved_narrowed
	_fresh = saved_fresh
	_inferred = saved_inferred
	_fixed = saved_fixed
	_locals = saved_locals
	_local_names = saved_names
	_ret = saved_ret


func _captured_by_value(key: String) -> bool:
	if key == "self" or key.begins_with("self."):
		return false
	if key.contains(".") or key.contains("["):
		return false
	return _local_names.has(key)


func _is_numeric_expr(e) -> bool:
	if e is GateAST._Literal:
		var raw: String = (e as GateAST._Literal).raw
		return raw.length() > 0 and (raw[0] == "-" or raw[0] == "+" or raw[0] == "."
			or (raw[0] >= "0" and raw[0] <= "9"))
	var t: GateAST._TypeRef = _type_of(e)
	if t == null:
		return false
	return GateTypes.canonical(t.name) in ["int", "float"]


func _is_string_expr(e) -> bool:
	if e is GateAST._Literal:
		var raw: String = (e as GateAST._Literal).raw
		return raw.begins_with("\"") or raw.begins_with("'")
	if e is GateAST._FString:
		return true
	var t: GateAST._TypeRef = _type_of(e)
	if t == null:
		return false
	return GateTypes.canonical(t.name) in ["String", "StringName"]

const VALUE_OPS := ["+", "-", "*", "/", "%", "**", "<<", ">>", "&", "|", "^",
	"<", ">", "<=", ">="]


func _is_value_typed(e) -> bool:
	var t: GateAST._TypeRef = _type_of(e)
	return t != null and GateTypes.BUILTIN.has(GateTypes.canonical(t.name))


func _check_value_operand(side, op: String, line: int, col: int) -> void:
	var path: String = _path_of(side)
	if path == "" or not _tracked(side):
		return
	if _state(path) == _S.NOTNULL:
		return
	var t: GateAST._TypeRef = _type_of(side)
	if t == null or not t.nullable:
		return
	if not GateTypes.BUILTIN.has(GateTypes.canonical(t.name)):
		return
	_err("'%s' may be null, and '%s' has no null case" % [path, op], line, col,
		"guard it with `if %s != null:`, or supply a fallback with `%s ?? ...`"
			% [path, path])


func _check_value_operands(b: GateAST._Binary) -> void:
	if not VALUE_OPS.has(b.op):
		return
	if b.op == "%" and not _is_numeric_expr(b.left):
		return
	for side in [b.left, b.right]:
		var path: String = _path_of(side)
		if path == "" or not _tracked(side):
			continue
		if _state(path) == _S.NOTNULL:
			continue
		var t: GateAST._TypeRef = _type_of(side)
		if t == null or not t.nullable:
			continue
		if not GateTypes.BUILTIN.has(GateTypes.canonical(t.name)):
			continue
		_err("'%s' may be null, and '%s' has no null case" % [path, b.op],
			b.line, b.col,
			"guard it with `if %s != null:`, or supply a fallback with `%s ?? ...`"
				% [path, path])


func _report_deref(target, line: int, col: int, access: String) -> void:
	if (target is GateAST._Member and (target as GateAST._Member).safe) \
		or (target is GateAST._Index and (target as GateAST._Index).safe):
		var op: String = "?[...]"
		if target is GateAST._Member:
			op = "?." + (target as GateAST._Member).name
		var safe_access: String = "?" + access
		if access.begins_with("."):
			safe_access = "?" + access
		_err("'%s' yields null when its left side is null, so '%s' is unchecked"
				% [op, access],
			line, col,
			"keep the chain safe with `%s%s`, or use `??` to supply a fallback first"
				% [op, safe_access])
		return

	if target is GateAST._Call:
		var t: GateAST._TypeRef = _type_of(target)
		if t != null and t.nullable:
			var fname: String = "the call"
			var callee = (target as GateAST._Call).callee
			if callee is GateAST._Member:
				fname = "'%s()'" % (callee as GateAST._Member).name
			elif callee is GateAST._Ident:
				fname = "'%s()'" % (callee as GateAST._Ident).name
			_err("%s may return null; '%s' is unchecked" % [fname, access],
				line, col,
				"assign it to a variable and guard it, or use `?%s`" % access)
		return

	var path: String = _path_of(target)
	if path == "" and (target is GateAST._NullCoalesce or target is GateAST._Ternary):
		var vst: int = _expr_nullness(target)
		if vst == _S.NOTNULL:
			return
		var kind: String = ("the `??` expression" if target is GateAST._NullCoalesce
			else "the conditional expression")
		_err("%s may give null; '%s' is unchecked" % [kind, access.trim_prefix(".")],
			line, col, "give it a fallback that is not null, or guard the value first")
		return
	if path == "" or not _tracked(target):
		return
	var st: int = _state(path)
	if st == _S.NOTNULL:
		return
	if st == _S.NULL:
		_err("'%s' is null here; '%s%s' will fail" % [path, path, access],
			line, col, "assign a value before using it")
	elif _asserted.has(path):
		_err("'%s' may be null; '%s%s' is unchecked" % [path, path, access],
			line, col,
			"the `assert(%s != null)` above does not count: Godot strips assert() " % path
			+ "from release builds, so an exported game reaches this line with '%s' " % path
			+ "still null. Use `if %s == null: return`, or `%s?%s`." % [path, path, access])
	else:
		_err("'%s' may be null; '%s%s' is unchecked" % [path, path, access],
			line, col,
			"guard it with `if %s != null:`, or use `%s?%s`" % [path, path, access])

const CALLABLE_INVOKERS := GateInfer.CALLABLE_INVOKERS


func _opaque_call() -> void:
	_invalidate_across_suspend()


func _accessor(e) -> Dictionary:
	return infer.accessor_at(e, _cls, _locals, _local_names)


func _lambda_writes(lam: GateAST._Lambda) -> bool:
	var found: Array = [false]
	var probe: Callable = func(node) -> void:
		if node is GateAST._Call:
			found[0] = true
		elif node is GateAST._AssignStmt and not ((node as GateAST._AssignStmt).target is GateAST._Ident):
			found[0] = true
		elif node is GateAST._MultiAssign:
			found[0] = true
	_each_node(lam.body, probe)
	_each_node(lam.expr_body, probe)
	return found[0]


func _each_node(node, visit: Callable) -> void:
	if node == null:
		return
	if node is Array:
		for x in node:
			_each_node(x, visit)
		return
	if not (node is Object) or (node as Object).get_script() == null:
		return
	visit.call(node)
	for prop in (node as Object).get_property_list():
		var pn: String = prop["name"]
		if pn in ["script", "Built-in script", "RefCounted", "Object"]:
			continue
		var v = (node as Object).get(pn)
		if v is Array or (v is Object and v != null and (v as Object).get_script() != null):
			_each_node(v, visit)


func _apply_call_effects(c: GateAST._Call) -> void:
	if _env.is_empty() and _narrowed.is_empty():
		return   # nothing is tracked, so there is nothing a call could invalidate
	var r: Dictionary = _resolve_callee(c)
	var fd = r["fd"]
	if fd != null:
		var fx = infer.effects_of(fd)
		if fx != null and fx.opaque:
			_opaque_call()
		if fx != null:
			var fresh_recv: bool = c.callee is GateAST._Member \
				and (c.callee as GateAST._Member).name == "new"
			var recv_t: GateAST._TypeRef = null
			if r["recv"] == "" and c.callee is GateAST._Member and not fresh_recv:
				recv_t = _type_of((c.callee as GateAST._Member).target)
			if not fresh_recv:
				for sfx in fx.self_paths:
					_kill_self_suffix(r["recv"], sfx, recv_t)
			for sp in fx.statics:
				_kill_static(sp)
			for j in fx.param_paths:
				if j >= c.args.size():
					continue
				var ap: String = _path_of(c.args[j])
				if ap == "" and _is_fresh(c.args[j]):
					continue
				var at: GateAST._TypeRef = _type_of(c.args[j]) if ap == "" else null
				for sfx2 in fx.param_paths[j]:
					_kill_suffix(ap, sfx2, at)
			return
	if GateInfer.PURE_GLOBALS.has(r["name"]):
		return
	if r["name"] in GateInfer.OPAQUE_CALLS:
		_opaque_call()   # a Callable or a signal's handlers: any lambda may run
	elif GateInfer.SYNC_HIGHER_ORDER.has(r["name"]):
		for la in c.args:
			if la is GateAST._Lambda and _lambda_writes(la):
				_opaque_call()
				break
	if (r["name"] in CALLABLE_INVOKERS
			or (GateInfer.SYNC_HIGHER_ORDER.has(r["name"]) and _has_lambda_arg(c))):
		_invalidate_under("self")
		_kill_path("self")
		_kill_self_suffix(r["recv"], "*")
	elif r["recv"] == "self" and infer.is_engine_method(_engine_base, r["name"]):
		pass
	else:
		_kill_self_suffix(r["recv"], "*")
	for a in c.args:
		_kill_suffix(_path_of(a), "*")


## Locals holding an object built here that never leaves. One escaping use
## anywhere disqualifies it.
func _scan_fresh(body: Array, expr_body) -> Dictionary:
	var decls: Dictionary = {}
	_fresh_decls(body, decls)
	var cands: Dictionary = {}
	for n in decls:
		if decls[n] is GateAST._VarDecl and _is_fresh((decls[n] as GateAST._VarDecl).value) \
			and not ((decls[n] as GateAST._VarDecl).value is GateAST._Literal):
			cands[n] = true
	if cands.is_empty():
		return cands
	_fresh_stmts(body, cands)
	_fresh_expr(expr_body, cands)
	return cands


func _fresh_decls(body: Array, out: Dictionary) -> void:
	for s in body:
		if s is GateAST._AnnotatedStmt:
			s = (s as GateAST._AnnotatedStmt).stmt
		if s is GateAST._VarDecl:
			var vd: GateAST._VarDecl = s
			out[vd.name] = false if out.has(vd.name) else vd
		elif s is GateAST._MultiAssign:
			for t in (s as GateAST._MultiAssign).targets:
				if t is GateAST._Ident:
					out[(t as GateAST._Ident).name] = false
		elif s is GateAST._ForStmt:
			for vn in (s as GateAST._ForStmt).var_names:
				out[String(vn)] = false
			_fresh_decls((s as GateAST._ForStmt).body, out)
		elif s is GateAST._IfStmt:
			var i: GateAST._IfStmt = s
			_fresh_decls(i.then_body, out)
			for pair in i.elifs:
				_fresh_decls(pair[1], out)
			_fresh_decls(i.else_body, out)
		elif s is GateAST._WhileStmt:
			_fresh_decls((s as GateAST._WhileStmt).body, out)
		elif s is GateAST._MatchStmt:
			for br in (s as GateAST._MatchStmt).branches:
				for bn in _pattern_bindings(br[0]):
					out[bn] = false
				_fresh_decls(br[2], out)


func _fresh_stmts(body: Array, cands: Dictionary) -> void:
	for s in body:
		if cands.is_empty():
			return
		if s is GateAST._AnnotatedStmt:
			s = (s as GateAST._AnnotatedStmt).stmt
		if s is GateAST._VarDecl:
			_fresh_expr((s as GateAST._VarDecl).value, cands)
		elif s is GateAST._AssignStmt:
			var a: GateAST._AssignStmt = s
			if a.target is GateAST._Ident:
				cands.erase((a.target as GateAST._Ident).name)   # rebound
			else:
				_fresh_place(a.target, cands)
			_fresh_expr(a.value, cands)
		elif s is GateAST._MultiAssign:
			var ma: GateAST._MultiAssign = s
			for t in ma.targets:
				if t is GateAST._Ident:
					cands.erase((t as GateAST._Ident).name)
				else:
					_fresh_place(t, cands)
			for v in ma.values:
				_fresh_expr(v, cands)
		elif s is GateAST._ExprStmt:
			_fresh_expr((s as GateAST._ExprStmt).expr, cands)
		elif s is GateAST._ReturnStmt:
			_fresh_expr((s as GateAST._ReturnStmt).value, cands)
		elif s is GateAST._IfStmt:
			var i: GateAST._IfStmt = s
			_fresh_test(i.cond, cands)
			_fresh_stmts(i.then_body, cands)
			for pair in i.elifs:
				_fresh_test(pair[0], cands)
				_fresh_stmts(pair[1], cands)
			_fresh_stmts(i.else_body, cands)
		elif s is GateAST._WhileStmt:
			_fresh_test((s as GateAST._WhileStmt).cond, cands)
			_fresh_stmts((s as GateAST._WhileStmt).body, cands)
		elif s is GateAST._ForStmt:
			_fresh_expr((s as GateAST._ForStmt).iterable, cands)
			_fresh_stmts((s as GateAST._ForStmt).body, cands)
		elif s is GateAST._MatchStmt:
			var mt: GateAST._MatchStmt = s
			_fresh_expr(mt.subject, cands)
			for br in mt.branches:
				_fresh_test(br[1], cands)
				_fresh_stmts(br[2], cands)
		elif s is GateAST._FuncDecl:
			cands.clear()


func _fresh_place(e, cands: Dictionary) -> void:
	while e is GateAST._Member or e is GateAST._Index:
		if e is GateAST._Index:
			_fresh_expr((e as GateAST._Index).index, cands)
			e = (e as GateAST._Index).target
		else:
			e = (e as GateAST._Member).target
	if not (e is GateAST._Ident):
		_fresh_expr(e, cands)


func _fresh_test(e, cands: Dictionary) -> void:
	if e is GateAST._Ident:
		return
	if e is GateAST._Unary and (e as GateAST._Unary).op == "not":
		_fresh_test((e as GateAST._Unary).operand, cands)
		return
	if e is GateAST._IsExpr:
		_fresh_test((e as GateAST._IsExpr).operand, cands)
		return
	if e is GateAST._Binary and (e as GateAST._Binary).op in ["==", "!=", "<", ">", "<=", ">=",
			"in", "not in", "and", "or"]:
		_fresh_test((e as GateAST._Binary).left, cands)
		_fresh_test((e as GateAST._Binary).right, cands)
		return
	_fresh_expr(e, cands)


func _fresh_expr(e, cands: Dictionary) -> void:
	if e == null or cands.is_empty():
		return
	if e is GateAST._Ident:
		cands.erase((e as GateAST._Ident).name)
	elif e is GateAST._Member or e is GateAST._Index:
		_fresh_place(e, cands)
	elif e is GateAST._Call:
		var c: GateAST._Call = e
		if c.callee is GateAST._Member:
			_fresh_expr((c.callee as GateAST._Member).target, cands)   # a method may keep self
		else:
			_fresh_expr(c.callee, cands)
		for a in c.args:
			_fresh_expr(a, cands)
	elif e is GateAST._Binary:
		var b: GateAST._Binary = e
		if b.op in ["==", "!=", "<", ">", "<=", ">=", "in", "not in", "and", "or"]:
			_fresh_test(e, cands)
		else:
			var cur = b
			while cur is GateAST._Binary:
				_fresh_expr((cur as GateAST._Binary).right, cands)
				cur = (cur as GateAST._Binary).left
			_fresh_expr(cur, cands)
	elif e is GateAST._IsExpr or (e is GateAST._Unary and (e as GateAST._Unary).op == "not"):
		_fresh_test(e, cands)
	elif e is GateAST._Unary:
		_fresh_expr((e as GateAST._Unary).operand, cands)
	elif e is GateAST._CastExpr:
		_fresh_expr((e as GateAST._CastExpr).operand, cands)
	elif e is GateAST._Ternary:
		_fresh_test((e as GateAST._Ternary).cond, cands)
		_fresh_expr((e as GateAST._Ternary).if_true, cands)
		_fresh_expr((e as GateAST._Ternary).if_false, cands)
	elif e is GateAST._NullCoalesce:
		_fresh_expr((e as GateAST._NullCoalesce).left, cands)
		_fresh_expr((e as GateAST._NullCoalesce).right, cands)
	elif e is GateAST._ArrayLit:
		for el in (e as GateAST._ArrayLit).elements:
			_fresh_expr(el, cands)
	elif e is GateAST._DictLit:
		for k in (e as GateAST._DictLit).keys:
			_fresh_expr(k, cands)
		for v in (e as GateAST._DictLit).values:
			_fresh_expr(v, cands)
	elif e is GateAST._ObjectInit:
		for v2 in (e as GateAST._ObjectInit).values:
			_fresh_expr(v2, cands)
	elif e is GateAST._FString:
		for part in (e as GateAST._FString).parts:
			if not (part is String):
				_fresh_expr(part, cands)
	elif e is GateAST._AwaitExpr:
		_fresh_expr((e as GateAST._AwaitExpr).operand, cands)
	elif e is GateAST._Lambda:
		cands.clear()


func _is_fresh(e) -> bool:
	if e is GateAST._Literal or e is GateAST._ArrayLit or e is GateAST._DictLit \
		or e is GateAST._ObjectInit or e is GateAST._FString or e is GateAST._Lambda:
		return true
	if e is GateAST._Call:
		var callee = (e as GateAST._Call).callee
		if callee is GateAST._Member and (callee as GateAST._Member).name == "new":
			return true
		if callee is GateAST._Ident and infer.struct_names.has((callee as GateAST._Ident).name):
			return true
	return false


func _has_lambda_arg(c: GateAST._Call) -> bool:
	for a in c.args:
		if a is GateAST._Lambda:
			return true
	return false


func _resolve_callee(c: GateAST._Call) -> Dictionary:
	var out: Dictionary = {"fd": null, "recv": "", "name": ""}

	if c.callee is GateAST._Ident:
		var n: String = (c.callee as GateAST._Ident).name
		out["name"] = n
		if GateInfer.GLOBAL_FUNCTIONS.has(n):
			return out
		if _cls != "":
			var own2 = _pick_arity(infer.method_candidates(_cls, n), c.args.size())
			if own2 != null:
				out["fd"] = own2
				out["recv"] = "self"
				return out
		var fd = _pick_arity(infer.module_functions.get(n, []), c.args.size())
		if fd != null:
			out["fd"] = fd
			out["recv"] = "self"
			return out
		if _cls != "":
			fd = _pick_arity(infer.method_candidates(_cls, n), c.args.size())
			if fd != null:
				out["fd"] = fd
				out["recv"] = "self"
				return out
		out["recv"] = "self"
		return out

	if c.callee is GateAST._Member:
		var m: GateAST._Member = c.callee
		out["name"] = m.name
		if m.target is GateAST._Ident and (m.target as GateAST._Ident).name == "super":
			out["recv"] = "self"
			out["fd"] = _pick_arity(
				infer.method_candidates(String(infer.bases.get(_cls, "")), m.name),
				c.args.size())
			return out
		if m.name == "new":
			if m.target is GateAST._Ident:
				out["fd"] = _pick_arity(
					infer.method_candidates((m.target as GateAST._Ident).name, "_init"),
					c.args.size())
			return out
		out["recv"] = _path_of(m.target)
		var rt: GateAST._TypeRef = _type_of(m.target)
		if rt != null and rt.array_depth == 0 and not rt.is_dict():
			out["fd"] = _pick_arity(infer.method_candidates(rt.name, m.name), c.args.size())
		elif rt == null and m.target is GateAST._Ident:
			var holder: String = (m.target as GateAST._Ident).name
			if not _local_names.has(holder) and not _field_names.has(holder) and infer.has_class(holder):
				var sfd: GateAST._FuncDecl = _pick_arity(infer.method_candidates(holder, m.name), c.args.size())
				if sfd != null and sfd.is_static:
					out["fd"] = sfd
		return out

	return out


func _pick_arity(cands: Array, given: int):
	for f in cands:
		if _accepts(f, given):
			return f
	return null


func _candidates(c: GateAST._Call, narrowed: bool = false) -> Array:
	if c.callee is GateAST._Ident:
		var n: String = (c.callee as GateAST._Ident).name
		if GateInfer.GLOBAL_FUNCTIONS.has(n):
			return []
		if _cls != "":
			var own: Array = infer.method_candidates(_cls, n)
			if not own.is_empty():
				return own
		var mf: Array = infer.module_functions.get(n, [])
		if not mf.is_empty():
			return mf
		return []
	if c.callee is GateAST._Member:
		var m: GateAST._Member = c.callee
		if m.name == "new":
			return []
		var recv: GateAST._TypeRef = _type_of(m.target) if narrowed \
			else infer.type_of(m.target, _locals)
		if recv != null and recv.array_depth == 0 and not recv.is_dict():
			return infer.method_candidates(recv.name, m.name)
	return []


func _check_store_call(c: GateAST._Call) -> void:
	var fd: GateAST._FuncDecl = null
	if c.callee is GateAST._Member:
		var m: GateAST._Member = c.callee
		if m.safe or not (m.target is GateAST._Ident):
			return
		var n: String = (m.target as GateAST._Ident).name
		if n == "super":
			fd = _pick_arity(infer.method_candidates(String(infer.bases.get(_cls, "")), m.name),
				c.args.size())
		elif _local_names.has(n) or _field_names.has(n) or not infer.has_class(n):
			return
		elif m.name != "new":
			fd = _pick_arity(infer.method_candidates(n, m.name), c.args.size())
		else:
			fd = _pick_arity(infer.method_candidates(n, "_init"), c.args.size())
			if fd == null:
				_check_field_init(c, n, infer.struct_names.get(n, null))
				return
	elif c.callee is GateAST._Ident:
		var sn: String = (c.callee as GateAST._Ident).name
		var sd = infer.struct_names.get(sn, null)
		if sd == null or _local_names.has(sn):
			return
		if not _check_field_init(c, sn, sd):
			_check_struct_args(c, sd)
		return
	if fd == null:
		return
	for i in mini(c.args.size(), fd.params.size()):
		var param: GateAST._Param = fd.params[i]
		if param.type != null and GateChecker.is_gate_only_type(param.type):
			c.args[i] = _check_gate_value(param.type, c.args[i],
				"'%s' parameter '%s'" % [fd.name, param.name], c.line, c.col)


func _check_struct_args(c: GateAST._Call, sd: GateAST._ClassDecl) -> void:
	var at: int = 0
	for f in sd.members:
		if not (f is GateAST._VarDecl) or (f as GateAST._VarDecl).is_const or (f as GateAST._VarDecl).is_static:
			continue
		var vd: GateAST._VarDecl = f
		var what: String = "'%s.%s'" % [sd.name, vd.name]
		if at >= c.args.size():
			_require_default(vd, what, c.line, c.col)
		elif vd.type != null and GateChecker.is_gate_only_type(vd.type):
			c.args[at] = _check_gate_value(vd.type, c.args[at], what, c.line, c.col)
		elif vd.type != null and vd.type.strict:
			_check_plain_value(vd.type, c.args[at], what, c.line, c.col)
		at += 1


## A field left out takes its default; with none written, an object's is null.
func _require_struct_default(vd: GateAST._VarDecl) -> void:
	if vd.type == null or vd.type.nullable or vd.type.array_depth != 0:
		return
	var n: String = GateTypes.canonical(vd.type.name)
	if infer.struct_names.has(n.get_slice(".", n.get_slice_count(".") - 1)):
		_require_default(vd, "'%s'" % vd.name, vd.line, vd.col)


func _require_default(vd: GateAST._VarDecl, what: String, line: int, col: int, depth: int = 0) -> void:
	if vd.value != null or vd.type == null or vd.type.nullable or not vd.type.strict:
		return
	var t: GateAST._TypeRef = vd.type
	if t.array_depth != 0 or t.is_dict() or t.is_set() or GateChecker.is_gate_only_type(t):
		return
	var n: String = GateTypes.canonical(t.name)
	var sd = infer.struct_names.get(n.get_slice(".", n.get_slice_count(".") - 1), null)
	if sd is GateAST._ClassDecl:
		if depth < 8:
			for f in GateChecker.struct_fields(sd):
				_require_default(f, "'%s.%s'" % [(sd as GateAST._ClassDecl).name, (f as GateAST._VarDecl).name],
					line, col, depth + 1)
		return
	if GateTypes.BUILTIN.has(n):
		return
	if not (ClassDB.class_exists(n) or infer.has_class(n)):
		return
	_err("%s has no default, and a %s is never null" % [what, t.describe()], line, col,
		"pass a value for it, give the field a default, or declare it `%s?`" % t.describe())


func _check_field_init(c: GateAST._Call, cls: String, sd) -> bool:
	if c.args.size() != 1 or not (c.args[0] is GateAST._DictLit):
		return false
	var dl: GateAST._DictLit = c.args[0]
	var types: Dictionary = {}
	var holds_dict: bool = false
	if sd is GateAST._ClassDecl:
		var first: bool = true
		for f in (sd as GateAST._ClassDecl).members:
			if f is GateAST._VarDecl and not (f as GateAST._VarDecl).is_const \
					and not (f as GateAST._VarDecl).is_static:
				var vd: GateAST._VarDecl = f
				if first:
					holds_dict = vd.type == null or vd.type.is_dict() \
						or GateTypes.canonical(vd.type.name) in ["Variant", "Dictionary"]
				first = false
				types[vd.name] = vd.type
	for i in dl.keys.size():
		if not (dl.keys[i] is GateAST._Ident) or i >= dl.values.size() or dl.values[i] == null \
				or (i < dl.lua_keys.size() and dl.lua_keys[i]):
			return false
		if holds_dict and not types.has((dl.keys[i] as GateAST._Ident).name):
			return false
	return not (holds_dict and dl.keys.is_empty())


func _accepts(fd: GateAST._FuncDecl, given: int) -> bool:
	var required: int = 0
	var has_rest: bool = false
	for p in fd.params:
		var pp: GateAST._Param = p
		if pp.is_rest: has_rest = true
		elif pp.default == null: required += 1
	return given >= required and (has_rest or given <= fd.params.size())


func _check_call_site(c: GateAST._Call) -> void:
	var cands: Array = _candidates(c)
	var via_narrowing: bool = false
	if cands.is_empty() and not _narrowed.is_empty():
		cands = _candidates(c, true)
		via_narrowing = true
	if cands.is_empty():
		if _gate_types:
			_check_store_call(c)
		elif c.callee is GateAST._Ident:
			var sn: String = (c.callee as GateAST._Ident).name
			var sd = infer.struct_names.get(sn, null)
			if sd is GateAST._ClassDecl and not _local_names.has(sn) and not _check_field_init(c, sn, sd):
				_check_struct_args(c, sd)
		return
	var given: int = c.args.size()
	var fd: GateAST._FuncDecl = null
	for f in cands:
		if _accepts(f, given):
			fd = f
			break

	if fd == null and via_narrowing:
		return
	if fd == null:
		var counts: PackedStringArray = PackedStringArray()
		for f2 in cands:
			var d: GateAST._FuncDecl = f2
			var req: int = 0
			for p in d.params:
				if (p as GateAST._Param).default == null and not (p as GateAST._Param).is_rest:
					req += 1
			counts.append(str(req) if req == d.params.size() else "%d-%d" % [req, d.params.size()])
		_err("'%s' takes %s argument(s) but %d given"
			% [(cands[0] as GateAST._FuncDecl).name, " or ".join(counts), given],
			c.line, c.col)
		return

	var recv_t: GateAST._TypeRef = null
	if _gate_types and c.callee is GateAST._Member:
		recv_t = infer.type_of((c.callee as GateAST._Member).target, _locals)
	for i in mini(c.args.size(), fd.params.size()):
		var param: GateAST._Param = fd.params[i]
		if param.is_rest:
			break   # the rest collects every argument from here into one array
		var ptype: GateAST._TypeRef = infer.subst_generic(param.type, recv_t)
		if ptype != null and _struct_mismatch(ptype, c.args[i],
				"'%s' parameter '%s'" % [fd.name, param.name], c.line, c.col):
			continue
		if ptype != null and GateChecker.is_gate_only_type(ptype):
			c.args[i] = _check_gate_value(ptype, c.args[i], "'%s' parameter '%s'" % [fd.name, param.name],
				c.line, c.col)
			continue
		_check_gate_source(ptype, c.args[i], "'%s' parameter '%s'" % [fd.name, param.name],
			c.line, c.col)
		if ptype != null and not _is_untyped(ptype):
			_check_known_plain(ptype, c.args[i], "'%s' parameter '%s'" % [fd.name, param.name],
				c.line, c.col)
		if param.type == null or param.type.nullable:
			continue
		if not param.type.strict and _is_null_literal(c.args[i]):
			continue
		var st: int = _nullness(c.args[i])
		if st == _S.NOTNULL:
			continue
		var argp: String = _path_of(c.args[i])
		var what: String = "'%s'" % argp if argp != "" else "argument %d" % (i + 1)
		if st == _S.NULL:
			_err("%s is null, but '%s' parameter '%s' is not nullable"
					% [what, fd.name, param.name],
				c.line, c.col,
				"declare it `%s? %s` to accept null" % [param.type.describe(), param.name])
		else:
			_err("%s may be null, but '%s' parameter '%s' is not nullable"
					% [what, fd.name, param.name],
				c.line, c.col,
				"guard it first, or declare the parameter `%s? %s`"
					% [param.type.describe(), param.name])


var _overloads_seen: Dictionary = {}


func _overloaded_names() -> Dictionary:
	if _overloads_seen.is_empty():
		_overloads_seen["#built"] = true
		for key in infer.methods:
			for f in infer.methods[key]:
				if (f as GateAST._FuncDecl).mangled_name != "":
					_overloads_seen[(f as GateAST._FuncDecl).name] = true
	return _overloads_seen


func _note_overload_receiver(c: GateAST._Call) -> void:
	if _quiet > 0 or not (c.callee is GateAST._Member) or (c.callee as GateAST._Member).safe:
		return
	var m: GateAST._Member = c.callee
	if not (m.target is GateAST._Expr):
		return
	var rt: GateAST._TypeRef = _type_of(m.target)
	if rt == null or rt.array_depth > 0 or rt.is_dict() or rt.is_union() or rt.is_tuple() \
			or rt.is_func_type or rt.name == "":
		return
	if _overloaded_names().has(m.name):
		(m.target as GateAST._Expr).flow_type = rt


func _note_flow_type(e) -> void:
	if not (e is GateAST._Expr) or _quiet > 0:
		return
	var node: GateAST._Expr = e
	var ft: GateAST._TypeRef = _type_of(e)
	node.flow_type = ft if _flow_informative(ft) and _flow_worth_noting(e, ft) else null
	node.narrowed_vector = ""
	var p: String = _path_of(e)
	if node.flow_type == null and ft != null and p != "" and _narrowed.has(p) and ft.array_depth == 0 \
			and not ft.is_union() and not ft.nullable \
			and GateTypes.canonical(ft.name) in ["Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i"]:
		node.narrowed_vector = GateTypes.canonical(ft.name)


func _flow_informative(t: GateAST._TypeRef) -> bool:
	if t == null:
		return false
	if t.is_union() or t.is_tuple() or t.is_func_type:
		return true
	return t.name != "" and not (GateTypes.canonical(t.name) in ["Variant", "void"])


func _flow_worth_noting(e, ft: GateAST._TypeRef) -> bool:
	var p: String = "" if _narrowed.is_empty() else _path_of(e)
	if p != "" and _narrowed.has(p):
		var st: GateAST._TypeRef = _static_type_of(e)
		if _same_type(ft, st):
			return false
		return not (_flow_plain_reachable(ft) and not _flow_gate_shaped(st))
	if _flow_gate_shaped(ft):
		return true
	var src: GateAST._TypeRef = null
	if e is GateAST._Index:
		src = _type_of((e as GateAST._Index).target)
	elif e is GateAST._Member:
		src = _type_of((e as GateAST._Member).target)
	elif e is GateAST._Call and (e as GateAST._Call).callee is GateAST._Member:
		src = _type_of(((e as GateAST._Call).callee as GateAST._Member).target)
	return _flow_gate_shaped(src)


func _flow_gate_shaped(t: GateAST._TypeRef) -> bool:
	if t == null:
		return false
	if GateChecker.is_gate_only_type(t) or t.nullable or _struct_names.has(t.name):
		return true
	return not t.generic_args.is_empty() \
		and not (GateTypes.canonical(t.name) in ["Array", "Dictionary"])


func _flow_plain_reachable(t: GateAST._TypeRef) -> bool:
	if t == null or t.array_depth > 0 or t.is_dict() or _struct_names.has(t.name):
		return false
	var n: String = GateTypes.canonical(t.name)
	return GateTypes.BUILTIN.has(n) or ClassDB.class_exists(n)


func _check_init_values(c: GateAST._Call) -> void:
	if c.args.size() != 1 or not (c.args[0] is GateAST._DictLit):
		return
	var dl: GateAST._DictLit = c.args[0]
	for i in dl.keys.size():
		if not (dl.keys[i] is GateAST._Ident) or i >= dl.values.size() or dl.values[i] == null \
				or (i < dl.lua_keys.size() and dl.lua_keys[i]):
			return
	var owner: String = _init_owner(c)
	if owner == "":
		return
	var sd = infer.struct_names.get(owner, null)
	if sd is GateAST._ClassDecl:
		var given: Dictionary = {}
		for k in dl.keys:
			given[(k as GateAST._Ident).name] = true
		for f in (sd as GateAST._ClassDecl).members:
			if f is GateAST._VarDecl and not (f as GateAST._VarDecl).is_const \
					and not (f as GateAST._VarDecl).is_static and not given.has((f as GateAST._VarDecl).name):
				_require_default(f, "'%s.%s'" % [owner, (f as GateAST._VarDecl).name], c.line, c.col)
	for i in dl.keys.size():
		var key: String = (dl.keys[i] as GateAST._Ident).name
		var pt: GateAST._TypeRef = infer.field_type(owner, key)
		if pt == null:
			pt = _engine_prop_type(owner, key)
		if pt == null:
			continue
		var v = dl.values[i]
		var what: String = "'%s.%s'" % [owner, key]
		if GateChecker.is_gate_only_type(pt):
			dl.values[i] = _check_value_against(pt, v, what, v.line, v.col)
		elif _check_compat(pt, v, what, v.line, v.col):
			_check_plain_value(pt, v, what, v.line, v.col)


func _check_field_init_values(value) -> void:
	if not (value is GateAST._Call):
		return
	var saved_names: Dictionary = _local_names
	_local_names = {}
	_check_init_values(value)
	_local_names = saved_names


func _init_owner(c: GateAST._Call) -> String:
	if c.callee is GateAST._Ident:
		var sn: String = (c.callee as GateAST._Ident).name
		return sn if _struct_names.has(sn) and not _local_names.has(sn) else ""
	if not (c.callee is GateAST._Member) or (c.callee as GateAST._Member).safe:
		return ""
	var cm: GateAST._Member = c.callee
	if cm.name == "instantiate":
		var rt: GateAST._TypeRef = _type_of(cm.target)
		if rt == null or rt.array_depth != 0 or rt.generic_args.size() != 1 \
				or GateTypes.canonical(rt.name) != "PackedScene":
			return ""
		return (rt.generic_args[0] as GateAST._TypeRef).name
	if cm.name != "new" or not (cm.target is GateAST._Ident):
		return ""
	var ref: String = (cm.target as GateAST._Ident).name
	if (cm.target as GateAST._Ident).generic_base != "":
		ref = (cm.target as GateAST._Ident).generic_base
	if _local_names.has(ref) or _struct_names.has(ref):
		return ""
	return ref if _init_takes_nothing(ref) else ""


func _init_takes_nothing(ref: String) -> bool:
	var seen: Dictionary = {}
	var c: String = ref
	while c != "" and not seen.has(c):
		seen[c] = true
		if ClassDB.class_exists(c):
			return true
		for f in infer.methods.get("%s._init" % c, []):
			if not (f as GateAST._FuncDecl).params.is_empty():
				return false
		if not infer.bases.has(c):
			return infer.fields.has(c) or infer.methods.has("%s._init" % c) \
				or _known_class(c)
		c = String(infer.bases[c])
		if c.begins_with("res://") or c.contains("\""):
			return false
	return false


func _known_class(c: String) -> bool:
	for k in infer.fields:
		if String(k).begins_with(c + "."):
			return true
	return false


func _engine_prop_type(cls: String, key: String) -> GateAST._TypeRef:
	var c: String = cls
	var seen: Dictionary = {}
	while c != "" and not seen.has(c) and not ClassDB.class_exists(c):
		seen[c] = true
		c = String(infer.bases.get(c, ""))
	if c == "" or not ClassDB.class_exists(c):
		return null
	for p in ClassDB.class_get_property_list(c):
		if String(p["name"]) != key:
			continue
		var ty: int = int(p.get("type", TYPE_NIL))
		var t: GateAST._TypeRef = GateAST._TypeRef.new()
		if ty == TYPE_OBJECT:
			t.name = String(p.get("class_name", ""))
			t.nullable = true
		else:
			t.name = String(_INIT_VALUE_TYPES.get(ty, ""))
		return t if t.name != "" else null
	return null


const _INIT_VALUE_TYPES := {
	TYPE_BOOL: "bool", TYPE_INT: "int", TYPE_FLOAT: "float", TYPE_STRING: "String",
	TYPE_STRING_NAME: "StringName", TYPE_NODE_PATH: "NodePath", TYPE_VECTOR2: "Vector2",
	TYPE_VECTOR2I: "Vector2i", TYPE_VECTOR3: "Vector3", TYPE_VECTOR3I: "Vector3i",
	TYPE_VECTOR4: "Vector4", TYPE_VECTOR4I: "Vector4i", TYPE_COLOR: "Color",
}


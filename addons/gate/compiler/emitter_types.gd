@tool
extends "res://addons/gate/compiler/emitter_out.gd"

## Emitter layer 2: naming, GATE -> GDScript type mapping, and precedence.


func _index_structs(members: Array, key: String = ".") -> void:
	for m in members:
		if not (m is GateAST._ClassDecl):
			continue
		var cd: GateAST._ClassDecl = m
		if cd.form == "struct":
			_index_struct(cd.name, cd, key)
			if key != "." and key != "":
				_structs[_qjoin(key, cd.name)] = _structs[cd.name].duplicate()
				_structs[_qjoin(key, cd.name)]["name"] = cd.name
		_index_structs(cd.members, _qjoin(key, cd.name))


func _index_struct(name: String, cd: GateAST._ClassDecl, scope: String = "") -> void:
	var names: Array = []
	var types: Array = []
	var defaults: Array = []
	var typerefs: Array = []
	for f in GateChecker.struct_fields(cd):
		var vd: GateAST._VarDecl = f
		names.append(vd.name)
		types.append(vd.type.name if vd.type != null else "Variant")
		typerefs.append(vd.type)
		defaults.append(vd.value)
	var methods: Dictionary = {}
	var consts: Dictionary = {}
	for mm in cd.members:
		if mm is GateAST._FuncDecl:
			methods[(mm as GateAST._FuncDecl).name] = (mm as GateAST._FuncDecl).is_static
		elif mm is GateAST._VarDecl and not names.has((mm as GateAST._VarDecl).name):
			consts[(mm as GateAST._VarDecl).name] = true
	_structs[name] = {
		"name": name,
		"lowering": cd.lowering,
		"vector": cd.vector_type,
		"fields": names,
		"types": types,
		"typerefs": typerefs,
		"defaults": defaults,
		"methods": methods,
		"consts": consts,
		"decl": cd,
		"scope": scope,
	}
	var ops: Dictionary = {}
	for f2 in cd.members:
		if f2 is GateAST._FuncDecl and (f2 as GateAST._FuncDecl).is_operator:
			var ofd: GateAST._FuncDecl = f2
			ops[ofd.operator_symbol] = ofd.name
	if not ops.is_empty():
		_struct_ops[name] = ops


func _index_class_ops(members: Array) -> void:
	var decls: Dictionary = {}
	var bases: Dictionary = {}
	_collect_classes(members, decls, bases)
	for rn in _reg_classes:
		if not decls.has(rn) and not _local_types.has(rn) and _reg_classes[rn] is GateAST._ClassDecl:
			decls[rn] = _reg_classes[rn]
			bases[rn] = String(_reg_bases.get(rn, ""))
	for cname in decls:
		if _struct_ops.has(cname):
			continue
		var ops: Dictionary = {}
		var fds: Dictionary = {}
		var c: String = String(cname)
		var seen: Dictionary = {}
		while decls.has(c) and not seen.has(c):
			seen[c] = true
			for f in (decls[c] as GateAST._ClassDecl).members:
				if f is GateAST._FuncDecl and (f as GateAST._FuncDecl).is_operator \
						and not ops.has((f as GateAST._FuncDecl).operator_symbol):
					ops[(f as GateAST._FuncDecl).operator_symbol] = (f as GateAST._FuncDecl).name
					fds[(f as GateAST._FuncDecl).operator_symbol] = f
			c = String(bases.get(c, ""))
		if not ops.is_empty():
			_struct_ops[cname] = ops
			_class_op_fds[cname] = fds


static func _collect_classes(members: Array, decls: Dictionary, bases: Dictionary) -> void:
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			if cd.form == "class" and cd.generic_params.is_empty() and not decls.has(cd.name):
				decls[cd.name] = cd
				bases[cd.name] = cd.extends_type.name if cd.extends_type != null else ""
			_collect_classes(cd.members, decls, bases)


func set_registry(reg, self_path: String) -> void:
	_self_path = self_path
	if reg == null:
		return
	_reg_classes = reg.classes
	_reg_whole = reg
	_reg_bases = reg.bases
	# another file's class_name script builds like its classes: `Enemy.new({ hp: 1 })`
	if "script_class_decls" in reg and not reg.script_class_decls.is_empty():
		_reg_classes = reg.classes.duplicate()
		_reg_bases = reg.bases.duplicate()
		for cn in reg.script_class_decls:
			if not _reg_classes.has(cn) and String(reg.script_class_names.get(cn, "")) != self_path:
				var scd: GateAST._ClassDecl = reg.script_class_decls[cn]
				_reg_classes[cn] = scd
				if scd.extends_type != null and not _reg_bases.has(cn):
					_reg_bases[cn] = scd.extends_type.name
	_reg_script_classes = reg.script_class_names
	_reg_origin = reg.origin
	_reg_namespaces = reg.namespaces
	if "module_names" in reg:
		_reg_module_names = reg.module_names
	for table in [reg.classes, reg.namespaces, reg.structs]:
		for name in table:
			if not reg.top_level.has(name):
				continue
			var origin: String = reg.origin.get(name, "")
			if origin != "" and origin != self_path:
				_extern_origin[name] = origin
	for fk in reg.fields:
		if not _field_types.has(fk):
			_field_types[fk] = reg.fields[fk]
	_project_generic_uses = reg.generic_uses
	for gname in reg.generics:
		if not reg.top_level.has(gname):
			continue
		var gorigin: String = reg.origin.get(gname, "")
		if gorigin != "" and gorigin != self_path:
			_extern_generics[gname] = gorigin


func set_base_chain(chain: Dictionary) -> void:
	_base_chain = chain


func _apply_base_chain() -> void:
	if _base_chain.is_empty():
		return
	for n in _base_chain["names"]:
		_base_names[n] = true
	for f in _base_chain["funcs"]:
		_declared_funcs[f] = true
	_base_via_gate = _base_chain["gate"]


func _extern_alias(name: String) -> String:
	if not _extern_origin.has(name):
		return ""
	if _local_types.has(name) or _base_names.has(name) or _value_shadows(name):
		return ""
	return _origin_alias(_extern_origin[name])


func _value_shadows(n: String) -> bool:
	if not _bound_names.has(n):
		return false
	if _fn_locals.has(n) or _declares_value(_scope_class, n):
		return true
	var q: String = _scope_class
	var seen: Dictionary = {}
	while not seen.has(q):
		seen[q] = true
		if _names_of_scope(q).has(n):
			return true
		q = String(_class_parent.get(q, "."))
	return false


func _extern_generic_alias(name: String) -> String:
	if not _extern_generics.has(name):
		return ""
	if _local_types.has(name) or _base_names.has(name):
		return ""
	return _origin_alias(_extern_generics[name])


func _origin_alias(origin: String) -> String:
	if _used_origins.has(origin):
		return _used_origins[origin]
	var mine: String = _user_preload_const(origin)
	if mine != "":
		return mine   # the file already preloads it, under a name of its own
	var base: String = ""
	for ch in String(origin).get_file().get_basename():
		base += ch if _is_ident_char(ch) else "_"
	var alias: String = "__gate_dep_%s_%d" % [base, _used_origins.size()]
	if _base_via_gate:
		alias = "%s_%s" % [alias, _file_tag()]
	while _bound_names.has(alias) or _local_types.has(alias) or _base_names.has(alias):
		alias = "_" + alias
	_used_origins[origin] = alias
	return alias


func _both_arms(a: String, b: String) -> String:
	if a != "" and a == b:
		return a
	if a == "" or b == "":
		return ""
	var ka: String = _struct_key(a)
	return a if ka != "" and ka == _struct_key(b) else ""


static func _is_null_lit(e) -> bool:
	return e is GateAST._Literal and (e as GateAST._Literal).kind == "null"


static func _last_part(n: String) -> String:
	return n.get_slice(".", n.get_slice_count(".") - 1)


static func _is_ident_char(c: String) -> bool:
	return ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
		or (c >= "0" and c <= "9") or c == "_" or c.unicode_at(0) >= 0x80)


func _index_local_names(members: Array) -> void:
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			_local_types[cd.name] = true
			if cd.extends_type != null:
				_class_bases[cd.name] = cd.extends_type.name
			for f in cd.members:
				if f is GateAST._VarDecl and (f as GateAST._VarDecl).type != null:
					var fv: GateAST._VarDecl = f
					_field_types["%s.%s" % [cd.name, fv.name]] = fv.type
			_index_local_names(cd.members)
		elif m is GateAST._VarDecl:
			_bound_names[(m as GateAST._VarDecl).name] = true
			if (m as GateAST._VarDecl).is_const and (m as GateAST._VarDecl).value != null:
				_const_exprs[(m as GateAST._VarDecl).name] = (m as GateAST._VarDecl).value
			_index_expr_names((m as GateAST._VarDecl).value)
		elif m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
			_bound_names[fd.name] = true
			for pp in fd.params:
				_bound_names[(pp as GateAST._Param).name] = true
				_index_expr_names((pp as GateAST._Param).default)
			_index_local_names(fd.body)
		elif m is GateAST._AnnotatedStmt:
			_index_local_names([(m as GateAST._AnnotatedStmt).stmt])
		elif m is GateAST._ExprStmt:
			_index_expr_names((m as GateAST._ExprStmt).expr)
		elif m is GateAST._ReturnStmt:
			_index_expr_names((m as GateAST._ReturnStmt).value)
		elif m is GateAST._AssignStmt:
			_index_expr_names((m as GateAST._AssignStmt).value)
		elif m is GateAST._MultiAssign:
			var ma: GateAST._MultiAssign = m
			if ma.declares:
				for t in ma.targets:
					if t is GateAST._Ident:
						_bound_names[(t as GateAST._Ident).name] = true
			for v in ma.values:
				_index_expr_names(v)
		elif m is GateAST._SignalDecl:
			_bound_names[(m as GateAST._SignalDecl).name] = true
		elif m is GateAST._EnumDecl:
			var ed: GateAST._EnumDecl = m
			if ed.name != "":
				_bound_names[ed.name] = true
				_enum_names[ed.name] = true
			else:
				for k in ed.keys:
					_bound_names[String(k)] = true
		elif m is GateAST._ForStmt:
			var fs: GateAST._ForStmt = m
			for vn in fs.var_names:
				_bound_names[String(vn)] = true
			_index_expr_names(fs.iterable)
			_index_local_names(fs.body)
		elif m is GateAST._IfStmt:
			var ifs: GateAST._IfStmt = m
			_index_expr_names(ifs.cond)
			_index_local_names(ifs.then_body)
			for pair in ifs.elifs:
				_index_expr_names(pair[0])
				_index_local_names(pair[1])
			_index_local_names(ifs.else_body)
		elif m is GateAST._WhileStmt:
			_index_expr_names((m as GateAST._WhileStmt).cond)
			_index_local_names((m as GateAST._WhileStmt).body)
		elif m is GateAST._MatchStmt:
			_index_expr_names((m as GateAST._MatchStmt).subject)
			for br in (m as GateAST._MatchStmt).branches:
				for bn in GateChecker.pattern_bindings(br[0]):
					_bound_names[bn] = true
				_index_expr_names(br[1])
				_index_local_names(br[2])


func _index_expr_names(e) -> void:
	if e == null:
		return
	if e is GateAST._Lambda:
		var lam: GateAST._Lambda = e
		for p in lam.params:
			_bound_names[(p as GateAST._Param).name] = true
			_index_expr_names((p as GateAST._Param).default)
		_index_local_names(lam.body)
		_index_expr_names(lam.expr_body)
	elif e is GateAST._Call:
		_index_expr_names((e as GateAST._Call).callee)
		for a in (e as GateAST._Call).args:
			_index_expr_names(a)
	elif e is GateAST._Binary:
		_index_expr_names((e as GateAST._Binary).left)
		_index_expr_names((e as GateAST._Binary).right)
	elif e is GateAST._Unary:
		_index_expr_names((e as GateAST._Unary).operand)
	elif e is GateAST._Ternary:
		_index_expr_names((e as GateAST._Ternary).cond)
		_index_expr_names((e as GateAST._Ternary).if_true)
		_index_expr_names((e as GateAST._Ternary).if_false)
	elif e is GateAST._NullCoalesce:
		_index_expr_names((e as GateAST._NullCoalesce).left)
		_index_expr_names((e as GateAST._NullCoalesce).right)
	elif e is GateAST._Member:
		_index_expr_names((e as GateAST._Member).target)
	elif e is GateAST._Index:
		_index_expr_names((e as GateAST._Index).target)
		_index_expr_names((e as GateAST._Index).index)
	elif e is GateAST._ArrayLit:
		for el in (e as GateAST._ArrayLit).elements:
			_index_expr_names(el)
	elif e is GateAST._DictLit:
		for v in (e as GateAST._DictLit).values:
			_index_expr_names(v)
	elif e is GateAST._AwaitExpr:
		_index_expr_names((e as GateAST._AwaitExpr).operand)
	elif e is GateAST._CastExpr:
		_index_expr_names((e as GateAST._CastExpr).operand)
	elif e is GateAST._IsExpr:
		_index_expr_names((e as GateAST._IsExpr).operand)


func _preload_lines() -> Array:
	var out: Array = []
	var origins: Array = _used_origins.keys()
	origins.sort()
	for o in origins:
		var target: String = String(o).get_basename() + ".gd"
		_preload_targets[target] = true
		out.append("const %s = preload(\"%s\")" % [_used_origins[o], target])
	return out


func set_external_structs(structs_by_name: Dictionary) -> void:
	_external_structs = structs_by_name


func _index_external_structs(own: Dictionary) -> void:
	for name in _external_structs:
		if _structs.has(name) or own.has(name):
			continue
		_index_struct(name, _external_structs[name])


func _index_generics(members: Array) -> void:
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			if not cd.generic_params.is_empty():
				_generics[cd.name] = cd
			_index_generics(cd.members)


func _collect_instantiations(members: Array) -> void:
	for m in members:
		if m is GateAST._VarDecl:
			_note_type((m as GateAST._VarDecl).type)
			_note_expr((m as GateAST._VarDecl).value)
		elif m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
			_note_type(fd.return_type)
			for p in fd.params:
				_note_type((p as GateAST._Param).type)
			_collect_instantiations(fd.body)
		elif m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			_note_type(cd.extends_type)
			_collect_instantiations(cd.members)
		elif m is GateAST._ExprStmt:
			_note_expr((m as GateAST._ExprStmt).expr)
		elif m is GateAST._AssignStmt:
			_note_expr((m as GateAST._AssignStmt).value)
		elif m is GateAST._ReturnStmt:
			_note_expr((m as GateAST._ReturnStmt).value)
		elif m is GateAST._IfStmt:
			var ifs: GateAST._IfStmt = m
			_note_expr(ifs.cond)
			_collect_instantiations(ifs.then_body)
			for pair in ifs.elifs:
				_note_expr(pair[0])
				_collect_instantiations(pair[1])
			_collect_instantiations(ifs.else_body)
		elif m is GateAST._ForStmt:
			_note_expr((m as GateAST._ForStmt).iterable)
			_collect_instantiations((m as GateAST._ForStmt).body)
		elif m is GateAST._WhileStmt:
			_note_expr((m as GateAST._WhileStmt).cond)
			_collect_instantiations((m as GateAST._WhileStmt).body)
		elif m is GateAST._MatchStmt:
			for br in (m as GateAST._MatchStmt).branches:
				_collect_instantiations(br[2])
		elif m is GateAST._MultiAssign:
			for v in (m as GateAST._MultiAssign).values:
				_note_expr(v)
		elif m is GateAST._AnnotatedStmt:
			_collect_instantiations([(m as GateAST._AnnotatedStmt).stmt])


func _note_expr(e) -> void:
	if e == null or _subst.is_empty():
		return
	if e is GateAST._Ident:
		var gt: GateAST._TypeRef = (e as GateAST._Ident).generic_type
		if gt != null and not _subst.is_empty():
			_note_type(gt)
	elif e is GateAST._Call:
		_note_expr((e as GateAST._Call).callee)
		for a in (e as GateAST._Call).args:
			_note_expr(a)
	elif e is GateAST._Member:
		_note_expr((e as GateAST._Member).target)
	elif e is GateAST._Index:
		_note_expr((e as GateAST._Index).target)
		_note_expr((e as GateAST._Index).index)
	elif e is GateAST._Binary:
		_note_expr((e as GateAST._Binary).left)
		_note_expr((e as GateAST._Binary).right)
	elif e is GateAST._Unary:
		_note_expr((e as GateAST._Unary).operand)
	elif e is GateAST._Ternary:
		_note_expr((e as GateAST._Ternary).cond)
		_note_expr((e as GateAST._Ternary).if_true)
		_note_expr((e as GateAST._Ternary).if_false)
	elif e is GateAST._NullCoalesce:
		_note_expr((e as GateAST._NullCoalesce).left)
		_note_expr((e as GateAST._NullCoalesce).right)
	elif e is GateAST._CastExpr:
		_note_expr((e as GateAST._CastExpr).operand)
	elif e is GateAST._AwaitExpr:
		_note_expr((e as GateAST._AwaitExpr).operand)
	elif e is GateAST._ArrayLit:
		for el in (e as GateAST._ArrayLit).elements:
			_note_expr(el)
	elif e is GateAST._DictLit:
		for v in (e as GateAST._DictLit).values:
			_note_expr(v)
	elif e is GateAST._Lambda:
		_collect_instantiations((e as GateAST._Lambda).body)


func _substituted(t: GateAST._TypeRef) -> GateAST._TypeRef:
	if _subst.is_empty():
		return t
	var out: GateAST._TypeRef = GateAST._TypeRef.new()
	out.name = t.name
	out.array_depth = t.array_depth
	out.nullable = t.nullable
	for g in t.generic_args:
		out.generic_args.append(_substituted_arg(g))
	return out


func _substituted_arg(g: GateAST._TypeRef) -> GateAST._TypeRef:
	var shaped: GateAST._TypeRef = _param_shape(g)
	if shaped != null:
		return shaped
	var g2: GateAST._TypeRef = GateAST._TypeRef.new()
	g2.name = _subst.get(g.name, g.name)
	g2.array_depth = g.array_depth
	g2.nullable = g.nullable
	for gg in g.generic_args:
		g2.generic_args.append(_substituted_arg(gg))
	return g2


static func _arrayed(n: String, depth: int) -> String:
	if depth <= 0:
		return n
	return "Array[%s]" % n if depth == 1 else "Array[Array]"


static func _normalized(t: GateAST._TypeRef) -> GateAST._TypeRef:
	if t == null:
		return null
	if t.is_union():
		var by_part: Dictionary = {}
		_collect_union_members(t, by_part)
		var keys: Array = by_part.keys()
		keys.sort()
		var members: Array = []
		for k in keys:
			members.append(_normalized(by_part[k]))
		t.union_members = members
	for i in t.tuple_elems.size():
		t.tuple_elems[i] = _normalized(t.tuple_elems[i])
	for j in t.callable_params.size():
		t.callable_params[j] = _normalized(t.callable_params[j])
	t.callable_return = _normalized(t.callable_return)
	for g in t.generic_args.size():
		t.generic_args[g] = _normalized(t.generic_args[g])
	return t


static func _collect_union_members(t: GateAST._TypeRef, out: Dictionary) -> void:
	for m in t.union_members:
		var mt: GateAST._TypeRef = m
		if mt.is_union() and mt.array_depth == 0 and not mt.nullable:
			_collect_union_members(mt, out)
		else:
			var key: String = GateParser._mangle_part(mt)
			if not out.has(key):
				out[key] = mt


static func _is_shape(t: GateAST._TypeRef) -> bool:
	return t != null and (t.is_union() or t.is_tuple() or t.is_func_type or t.is_dict() or t.is_set())


func _param_shape(t: GateAST._TypeRef) -> GateAST._TypeRef:
	if t == null or not _subst_types.has(t.name):
		return null
	var c: GateAST._TypeRef = GateChecker.copy_type(_subst_types[t.name])
	c.at(t.line, t.col)
	if t.array_depth > 0:
		if c.array_depth == 0 and (c.nullable or t.elem_nullable):
			c.elem_nullable = true
		c.nullable = t.nullable
		c.array_depth += t.array_depth
	else:
		c.nullable = c.nullable or t.nullable
	return c


func _subst_value(arg: GateAST._TypeRef) -> String:
	if not arg.generic_args.is_empty() and (_generics.has(arg.name) or _extern_generics.has(arg.name)):
		var bare: GateAST._TypeRef = GateAST._TypeRef.new()
		bare.name = arg.name
		bare.generic_args = arg.generic_args
		return _map_type_core(bare, false)
	return arg.name if GateTypes.PACKED.has(arg.name) else GateTypes.canonical(arg.name)


func _close_instantiations() -> void:
	for _pass in 8:
		var before: int = _instantiations.size()
		for key in _instantiations.keys():
			var entry: Array = _instantiations[key]
			var saved: Dictionary = _subst
			var saved_depth: Dictionary = _subst_depth
			var saved_types: Dictionary = _subst_types
			_subst = entry[1]
			_subst_depth = entry[2] if entry.size() > 2 else {}
			_subst_types = entry[3] if entry.size() > 3 else {}
			_collect_instantiations((entry[0] as GateAST._ClassDecl).members)
			_subst = saved
			_subst_depth = saved_depth
			_subst_types = saved_types
		if _instantiations.size() == before:
			return


func _note_type(t: GateAST._TypeRef) -> void:
	if t == null:
		return
	for g in t.generic_args:
		_note_type(g)
	if t.dict_key: _note_type(t.dict_key)
	if t.dict_value: _note_type(t.dict_value)
	if not t.generic_args.is_empty() and _generics.has(t.name):
		var st: GateAST._TypeRef = _substituted(t)
		var mangled: String = _generic_name(st)
		if not _instantiations.has(mangled):
			var cd: GateAST._ClassDecl = _generics[t.name]
			var sub: Dictionary = {}
			var depths: Dictionary = {}
			var full: Dictionary = {}
			for i in cd.generic_params.size():
				if i < st.generic_args.size():
					var ga: GateAST._TypeRef = st.generic_args[i]
					sub[cd.generic_params[i]] = _subst_value(ga)
					depths[cd.generic_params[i]] = ga.array_depth
					if _is_shape(ga):
						full[cd.generic_params[i]] = _normalized(GateChecker.copy_type(ga))
			if not _names_template_param(st):
				_instantiations[mangled] = [cd, sub, depths, full]
		else:
			var prev: Array = _instantiations[mangled]
			var prev_sub: Dictionary = prev[1]
			var same: bool = true
			var cd2: GateAST._ClassDecl = _generics[t.name]
			for i2 in cd2.generic_params.size():
				if i2 >= st.generic_args.size():
					continue
				var key: String = cd2.generic_params[i2]
				if GateTypes.canonical(prev_sub.get(key, "")) != GateTypes.canonical(_subst_value(st.generic_args[i2])):
					same = false
			if not same and prev[0] == cd2:
				diagnostics.error(
					"two different instantiations of '%s' both mangle to '%s'"
						% [t.name, mangled], t.line, t.col,
					"the generated class name joins the type arguments with '_', so "
					+ "argument names that already contain '_' can collide. Rename one "
					+ "of the types involved.")


func _names_template_param(t: GateAST._TypeRef) -> bool:
	for g in t.generic_args:
		var ga: GateAST._TypeRef = g
		if _is_template_param(ga.name) or _names_template_param(ga):
			return true
	return false


func _is_template_param(n: String) -> bool:
	if _local_types.has(n) or _structs.has(n) or _extern_origin.has(n) \
			or GateTypes.BUILTIN.has(GateTypes.canonical(n)) or ClassDB.class_exists(n):
		return false
	for tname in _generics:
		if (_generics[tname] as GateAST._ClassDecl).generic_params.has(n):
			return true
	return false


func _generic_name(t: GateAST._TypeRef) -> String:
	var base: String = GateParser.mangle_generic(t)
	if _generic_renames.has(base):
		return _generic_renames[base]
	var n: String = base
	while _local_types.has(n) or _bound_names.has(n):
		n = "_" + n
	_generic_renames[base] = n
	return n


func _is_known_type_name(n: String) -> bool:
	if n == "":
		return false
	if GateTypes.BUILTIN.has(n) or GateTypes.is_shorthand(n):
		return true
	if not _struct_of(n).is_empty():
		return true
	if _local_types.has(n):
		return true
	if _extern_origin.has(n) or _extern_generics.has(n):
		return true
	return ClassDB.class_exists(n)


func _struct_of(type_name: String) -> Dictionary:
	if not _subst.is_empty() and _subst.has(type_name):
		type_name = String(_subst[type_name])
	if _structs.has(type_name):
		return _structs[type_name]
	if not type_name.contains("."):
		return {}
	var parts: PackedStringArray = type_name.split(".")
	for i in range(1, parts.size()):
		var tail: String = ".".join(parts.slice(i))
		var st: Dictionary = _structs.get(tail, {})
		if st.is_empty():
			continue
		var prefix: String = ".".join(parts.slice(0, i))
		if String(st.get("scope", "")) == prefix or _qualifier_reaches(prefix, st):
			return st
	return {}


func _qualifier_reaches(prefix: String, st: Dictionary) -> bool:
	if _extern_origin.has(prefix.get_slice(".", 0)):
		return true
	var own: bool = String(st.get("scope", "")) != ""
	if own:
		return prefix == _self_class_name and _self_class_name != ""
	var origin: String = String(_reg_origin.get(String(st.get("name", "")), ""))
	if origin == "":
		return false
	if String(_reg_script_classes.get(prefix, "")) == origin:
		return true
	if String(_used_origins.get(origin, "")) == prefix:
		return true
	return _preload_const_of(prefix) == origin.get_basename() + ".gd"


func _user_preload_const(origin: String) -> String:
	var target: String = String(origin).get_basename() + ".gd"
	for m in _module_members:
		if not (m is GateAST._VarDecl) or not (m as GateAST._VarDecl).is_const:
			continue
		var n: String = (m as GateAST._VarDecl).name
		if n.lstrip("_").begins_with("gate_dep_"):
			continue   # one GATE wrote on an earlier build
		if _preload_const_of(n) == target:
			return n
	return ""


func _preload_const_of(name: String) -> String:
	for m in _module_members:
		if not (m is GateAST._VarDecl) or (m as GateAST._VarDecl).name != name \
				or not (m as GateAST._VarDecl).is_const:
			continue
		var v = (m as GateAST._VarDecl).value
		if v is GateAST._Call and (v as GateAST._Call).callee is GateAST._Ident \
				and ((v as GateAST._Call).callee as GateAST._Ident).name == "preload" \
				and (v as GateAST._Call).args.size() == 1 \
				and (v as GateAST._Call).args[0] is GateAST._Literal:
			var raw: String = ((v as GateAST._Call).args[0] as GateAST._Literal).raw
			var path: String = raw.substr(1, raw.length() - 2)
			if path.begins_with("res://") or _self_path == "":
				return path
			return _self_path.get_base_dir().path_join(path).simplify_path()
	return ""


func _struct_key(type_name: String) -> String:
	var st: Dictionary = _struct_of(type_name)
	return String(st.get("name", "")) if not st.is_empty() else ""


func _ops_of(type_name: String) -> Dictionary:
	if type_name == "":
		return {}
	if _struct_ops.has(type_name):
		return _struct_ops[type_name]
	var key: String = _struct_key(type_name)
	if key != "" and _struct_ops.has(key):
		return _struct_ops[key]
	if type_name.contains("."):
		var last: String = type_name.get_slice(".", type_name.get_slice_count(".") - 1)
		if _struct_ops.has(last) and _struct_key(type_name) == "":
			return _struct_ops[last]   # another file's class, through its own name
	return {}


func _ctor_struct_of(n: String) -> Dictionary:
	var st: Dictionary = _struct_of(n)
	if st.is_empty() or _local_types.has(n) or not _external_structs.has(n):
		return st
	var key: String = "%s|%s" % [_scope_class, n]
	if not _func_reach.has(key):
		_func_reach[key] = _class_reaches_func(_scope_class, n)
	return {} if _func_reach[key] else st


func _shorthand_taken(n: String) -> bool:
	var key: String = "%s|%s" % [_scope_class, n]
	if not _func_reach.has(key):
		_func_reach[key] = _class_reaches_func(_scope_class, n)
	return bool(_func_reach[key])


func _class_reaches_func(scope: String, n: String) -> bool:
	var q: String = scope
	var seen: Dictionary = {}
	for _guard in 64:
		if seen.has(q):
			return false
		seen[q] = true
		if (_class_funcs.get(q, {}) as Dictionary).has(n):
			return true
		var b: Dictionary = _base_of(q)
		match String(b["kind"]):
			"local":
				q = String(b["key"])
			"ext":
				return _named_class_has_func(String(b["name"]), n, 0)
			"path":
				return _script_has_func((_class_base[q] as GateAST._TypeRef).name, source_path, n, 0)
			_:
				return false
	return false


func _named_class_has_func(cls: String, n: String, depth: int) -> bool:
	if depth > 32:
		return false
	if _reg_classes.has(cls):
		for m in (_reg_classes[cls] as GateAST._ClassDecl).members:
			if m is GateAST._FuncDecl and (m as GateAST._FuncDecl).name == n:
				return true
		var rb: String = String(_reg_bases.get(cls, ""))
		if rb.begins_with("\"") or rb.begins_with("'") or rb.begins_with("res://"):
			return _script_has_func(rb, String(_extern_origin.get(cls, source_path)), n, depth + 1)
		return rb != "" and _named_class_has_func(rb, n, depth + 1)
	if _reg_script_classes.has(cls):
		return _script_has_func(String(_reg_script_classes[cls]), "", n, depth + 1)
	for c in ProjectSettings.get_global_class_list():
		if String(c["class"]) == cls:
			return _script_has_func(String(c["path"]), "", n, depth + 1)
	return ClassDB.class_exists(cls) and ClassDB.class_has_method(cls, n)


func _script_has_func(ref: String, from: String, n: String, depth: int) -> bool:
	if depth > 32:
		return false
	var path: String = ref.strip_edges()
	if path.begins_with("\"") or path.begins_with("'"):
		path = path.substr(1, path.length() - 2)
	if not path.begins_with("res://") and from != "":
		path = from.get_base_dir().path_join(path).simplify_path()
	if path.get_extension() == "gd" and FileAccess.file_exists(path.get_basename() + ".gate"):
		path = path.get_basename() + ".gate"
	if not FileAccess.file_exists(path) or not GateProject.is_utf8(path):
		return false
	var text: String = FileAccess.get_file_as_string(path)
	var fn: RegEx = RegEx.create_from_string("(?m)^(?:static\\s+)?func\\s+%s\\s*\\(" % n)
	if fn.search(text) != null:
		return true
	var ext: RegEx = RegEx.create_from_string(
		"(?m)^(?:class_name\\s+\\w+\\s+)?extends\\s+(\"[^\"]*\"|'[^']*'|[^\\s#:]+)")
	var m: RegExMatch = ext.search(text)
	if m == null:
		return false
	var base: String = m.get_string(1)
	if base.begins_with("\"") or base.begins_with("'"):
		return _script_has_func(base, path, n, depth + 1)
	return _named_class_has_func(base, n, depth + 1)


func _is_class_struct(t: GateAST._TypeRef) -> bool:
	if t == null or t.nullable or t.array_depth != 0 or t.is_dict():
		return false
	var s: Dictionary = _struct_of(t.name)
	return not s.is_empty() and s["lowering"] != "vector"


func _map_type(t: GateAST._TypeRef, packed_hint := false) -> String:
	var mapped: String = _map_type_core(t, packed_hint)
	if not _warned_packed and t != null:
		if (mapped.contains("PackedInt32Array") and _names_elem(t, "int")) \
				or (mapped.contains("PackedFloat32Array") and _names_elem(t, "float")):
			_warn_packed(mapped, t.line, t.col)
	if t != null and t.nullable and not GateTypes.is_gd_nullable(mapped):
		return "Variant"
	return mapped


## Whether `elem` is written as an array's element anywhere in `t`. `i32` and `f32`
## ask for 32 bits by name, so only `int` and `float` count.
static func _names_elem(t: GateAST._TypeRef, elem: String) -> bool:
	if t == null:
		return false
	if t.array_depth > 0 and t.name == elem:
		return true
	for sub in [t.dict_key, t.dict_value]:
		if _names_elem(sub, elem):
			return true
	for g in t.generic_args:
		if _names_elem(g, elem):
			return true
	return false


func _warn_packed(mapped: String, line: int, col: int) -> void:
	_warned_packed = true
	diagnostics.warn(
		"stored as %s, which holds 32-bit values" % mapped, line, col,
		"GDScript's int and float are 64-bit, so a value past 2^31, or `1e300`, does not "
		+ "read back. Write `i64` / `f64` to keep the full width. Reported once per file.")


func _map_type_core(t: GateAST._TypeRef, packed_hint: bool) -> String:
	if t == null:
		return ""
	if t.is_path_literal:
		return t.name
	var shaped: GateAST._TypeRef = _param_shape(t)
	if shaped != null:
		return _map_type(shaped, packed_hint)
	if _subst.has(t.name) and _subst[t.name] != t.name:
		var concrete: GateAST._TypeRef = GateAST._TypeRef.new()
		concrete.name = _subst[t.name]
		concrete.array_depth = t.array_depth + int(_subst_depth.get(t.name, 0))
		concrete.nullable = t.nullable
		return _map_type(concrete, packed_hint)
	if not t.generic_args.is_empty() and _extern_generics.has(t.name):
		var ga: String = _extern_generic_alias(t.name)
		return _arrayed("%s.%s" % [ga, _generic_name(_substituted(t))], t.array_depth)
	if not t.generic_args.is_empty() and _generics.has(t.name):
		return _arrayed(_generic_name(_substituted(t)), t.array_depth)
	if t.is_dict():
		if t.dict_key != null and t.dict_key.array_depth == 0 and not t.dict_key.nullable:
			var ks: Dictionary = _struct_of(t.dict_key.name)
			if not ks.is_empty() and ks["lowering"] != "vector":
				_struct_key_error(t.dict_key)
		return "Dictionary[%s, %s]" % [_map_type(t.dict_key), _map_dict_value(t.dict_value)]
	if t.generic_args.is_empty() and _is_erased_type(t.name):
		return "Array" if t.array_depth > 0 else "Variant"
	if (t.generic_args.is_empty() and t.name.contains(".") and not t.name.begins_with("res://")
			and _extern_alias(t.name.get_slice(".", 0)) != ""):
		var qn: String = "%s.%s" % [_extern_alias(t.name.get_slice(".", 0)), t.name]
		return "Array[%s]" % qn if t.array_depth > 0 else qn
	if t.generic_args.is_empty() and not _structs.has(t.name):
		var xa: String = _extern_alias(t.name)
		if xa != "":
			var qualified: String = "%s.%s" % [xa, t.name]
			return "Array[%s]" % qualified if t.array_depth > 0 else qualified
	var s: Dictionary = _struct_of(t.name)
	if not s.is_empty() and s["lowering"] != "vector":
		var sa: String = _extern_alias(t.name)
		if sa != "":
			var q: String = "%s.%s" % [sa, t.name]
			return "Array[%s]" % q if t.array_depth > 0 else q
	if not s.is_empty() and s["lowering"] == "vector":
		var base: String = s["vector"]
		if t.array_depth == 0:
			return base
		var packed: bool = GateTypes.has_packed(base)
		var out: String = GateTypes.packed_for(base) if packed else "Array[%s]" % base
		if t.array_depth > 1 and not packed:
			out = "Array"
		for _d in range(1, t.array_depth):
			out = "Array[%s]" % out
		return out
	return GateTypes.resolve(t, diagnostics, packed_hint)


func _map_dict_value(t: GateAST._TypeRef) -> String:
	if t == null:
		return "Variant"
	if t.is_dict() or t.is_set():
		diagnostics.warn(
			"nested dictionary value has no Packed equivalent; inner type left unenforced",
			t.line, t.col,
			"GDScript cannot express Dictionary[K, Dictionary[K, V]] (proposal #12224). "
			+ "Emitting Dictionary[K, Dictionary].")
		return "Dictionary"
	if t.array_depth > 0:
		var elem_t: GateAST._TypeRef = GateAST._TypeRef.new()
		elem_t.name = t.name
		elem_t.generic_args = t.generic_args
		var elem: String = _map_type(elem_t)
		if t.array_depth == 1 and GateTypes.has_packed(t.name):
			return GateTypes.packed_for(t.name)
		if t.array_depth == 1 and GateTypes.has_packed(elem):
			return GateTypes.packed_for(elem)
		diagnostics.warn(
			"nested array of '%s' has no Packed equivalent; inner type left unenforced" % elem,
			t.line, t.col,
			"GDScript cannot express Dictionary[K, Array[T]] (proposal #12224). "
			+ "Emitting Dictionary[K, Array].")
		return "Array"
	return _map_type(t)


func _struct_key_error(_at) -> void:
	push_error("[GATE] internal: _struct_key_error not overridden")


func _is_namespace_ref(_e) -> bool:
	push_error("[GATE] internal: _is_namespace_ref not overridden")
	return false


func _names_of_scope(_key: String) -> Dictionary:
	push_error("[GATE] internal: _names_of_scope not overridden")
	return {}


func _declares_value(_key: String, _n: String) -> bool:
	push_error("[GATE] internal: _declares_value not overridden")
	return false


func _build_struct(_st: Dictionary, _ctor: String, _keys: Array, _values: Array, _at_node) -> String:
	push_error("[GATE] internal: _build_struct not overridden")
	return "null"


func _default_for(t: GateAST._TypeRef, packed_hint: bool) -> String:
	var shaped: GateAST._TypeRef = _param_shape(t)
	if shaped != null:
		t = shaped
	if t != null and not t.nullable and t.array_depth == 0 and (_enum_names.has(t.name)
			or _enum_names.has(t.name.get_slice(".", t.name.get_slice_count(".") - 1))):
		return "0"   # `Meta.Kind` is an enum of this file too
	if t != null and not t.nullable and t.array_depth == 0 and t.is_union():
		return _default_for(t.union_members[0], false)
	if t != null and not t.nullable and t.array_depth == 0 and t.is_tuple():
		var elems: PackedStringArray = PackedStringArray()
		for te in t.tuple_elems:
			elems.append(_default_for(te, false))
		return "[%s]" % ", ".join(elems)
	var mapped: String = _map_type(t, packed_hint)
	if mapped.begins_with("Packed") and mapped.ends_with("Array"):
		return mapped + "()"
	if t != null and not t.nullable and t.array_depth == 0 and not t.is_dict():
		var vs: Dictionary = _struct_of(t.name)
		if not vs.is_empty() and vs["lowering"] == "vector" and (vs["defaults"] as Array).any(
				func(d) -> bool: return d != null):
			return _build_struct(vs, "", [], [], t)
	if t != null and not t.nullable and t.array_depth == 0 and not t.is_dict():
		var sd: Dictionary = _struct_of(t.name)
		if not sd.is_empty() and sd["lowering"] != "vector" and mapped != "":
			return "%s.new()" % mapped
	if t != null and not t.nullable and t.array_depth == 0 and not t.is_dict() and mapped != "" and mapped != t.name:
		var lowered: GateAST._TypeRef = GateAST._TypeRef.new()
		lowered.name = mapped
		return GateTypes.default_value(lowered)
	return GateTypes.default_value(t)

## GDScript's own precedence ladder. Re-printing an AST without consulting it
## changes meaning: `"%s" % (i + 1)` comes back out as `"%s" % i + 1`.
const PREC := {
	"or": 1, "and": 2,
	"in": 4, "not in": 4,
	"==": 5, "!=": 5, "<": 5, ">": 5, "<=": 5, ">=": 5,
	"|": 6, "^": 7, "&": 8,
	"<<": 9, ">>": 9,
	"+": 10, "-": 10,
	"*": 11, "/": 11, "%": 11,
	"**": 13,
}

const PREC_NOT := 3

const PREC_UNARY := 12

const PREC_TYPE_TEST := 14

const PREC_AWAIT := 15

const PREC_ATOM := 100

const PREC_TERNARY := 0


func _prec_of(e) -> int:
	if e is GateAST._Ident and _rename_prec.has((e as GateAST._Ident).name) \
			and _ident_renames.has((e as GateAST._Ident).name):
		return int(_rename_prec[(e as GateAST._Ident).name])
	if e is GateAST._Binary:
		var low: String = _binary_lowering(e)
		if low == "call":
			return PREC_ATOM
		if low == "not":
			return PREC_NOT
		if (e as GateAST._Binary).op == "not in":
			return PREC_NOT   # printed as `not (a in b)`
		return PREC.get((e as GateAST._Binary).op, PREC_ATOM)
	if e is GateAST._Unary:
		return PREC_NOT if (e as GateAST._Unary).op == "not" else PREC_UNARY
	if e is GateAST._IsExpr:
		# Lowered to a call, it binds like one. Keeping `not (x is T)`'s parentheses
		if (e as GateAST._IsExpr).negated:
			return PREC_NOT
		return PREC_ATOM if _is_lowers_to_call(e) else PREC_TYPE_TEST
	if e is GateAST._AwaitExpr:
		return PREC_AWAIT
	if e is GateAST._Lambda:
		return 0
	if e is GateAST._Ternary:
		return PREC_TERNARY if (e as GateAST._Ternary).if_false is GateAST._Ternary else PREC_ATOM
	if e is GateAST._CastExpr and (e as GateAST._CastExpr).operand is GateAST._CastExpr:
		return PREC_TYPE_TEST   # `a as A as B` is printed without parentheses
	return PREC_ATOM


func _text_prec(e, text: String) -> int:
	if _bare_ternary(text):
		return PREC_TERNARY
	return _prec_of(e)


static func _bare_ternary(text: String) -> bool:
	if not text.contains(" if "):
		return false   # the scan below can only answer yes through one
	var depth: int = 0
	var quote: String = ""
	var saw_if: bool = false
	var i: int = 0
	while i < text.length():
		var ch: String = text[i]
		if quote != "":
			if ch == "\\":
				i += 2
				continue
			if text.substr(i, quote.length()) == quote:
				i += quote.length()
				quote = ""
				continue
		elif ch == "\"" or ch == "'":
			quote = ch.repeat(3) if text.substr(i, 3) == ch.repeat(3) else ch
			i += quote.length()
			continue
		elif ch == "(" or ch == "[" or ch == "{":
			depth += 1
		elif ch == ")" or ch == "]" or ch == "}":
			depth -= 1
		elif depth == 0 and text.substr(i, 4) == " if ":
			saw_if = true
		elif depth == 0 and saw_if and text.substr(i, 6) == " else ":
			return true
		i += 1
	return false


static func _wrapped(text: String) -> bool:
	if not text.begins_with("(") or not text.ends_with(")"):
		return false
	var depth: int = 0
	var quote: String = ""
	var i: int = 0
	while i < text.length():
		var ch: String = text[i]
		if quote != "":
			if ch == "\\":
				i += 2
				continue
			if ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "(" or ch == "[" or ch == "{":
			depth += 1
		elif ch == ")" or ch == "]" or ch == "}":
			depth -= 1
			if depth == 0 and i != text.length() - 1:
				return false
		i += 1
	return true


func _binary_lowering(b: GateAST._Binary) -> String:
	if (b.op == "==" or b.op == "!=") and _against_null(b):
		return ""   # against null, identity is equality
	var lt: String = _static_type_of(b.left)
	if lt != "":
		var ops: Dictionary = _ops_of(lt)
		if ops.has(b.op):
			return "call"
		if b.op == "!=" and ops.has("=="):
			return "not"
	if (b.op == "==" or b.op == "!=") and _eqv_text(b) != "":
		return "call" if b.op == "==" else "not"
	if (b.op == "in" or b.op == "not in") and _in_struct_text(b) != "":
		return "call" if b.op == "in" else "not"
	return ""


func _eqv_text(_b: GateAST._Binary) -> String:
	push_error("[GATE] internal: _eqv_text not overridden")
	return ""


func _in_struct_text(_b: GateAST._Binary) -> String:
	push_error("[GATE] internal: _in_struct_text not overridden")
	return ""


static func _against_null(b: GateAST._Binary) -> bool:
	for lit in [b.left, b.right]:
		if lit is GateAST._Literal and (lit as GateAST._Literal).kind == "null":
			return true
	return false


func _eq_struct(b: GateAST._Binary) -> String:
	if _against_null(b):
		return ""   # against null, identity is equality
	for side in [b.left, b.right]:
		var t: String = _static_type_of(side)
		var st: Dictionary = _struct_of(t)
		if not st.is_empty() and st["lowering"] != "vector":
			if (_ops_of(t) as Dictionary).has("=="):
				return ""
			return t
	return ""


func _is_lowers_to_call(ie: GateAST._IsExpr) -> bool:
	var tname: String = ie.type.name
	if not _is_known_native(tname) and _looks_like_interface(tname):
		return true
	return _packed_twin(ie.type, _map_type(ie.type)) != ""


func _packed_twin(t: GateAST._TypeRef, mapped: String) -> String:
	if t.array_depth != 1 or not t.generic_args.is_empty() or t.is_dict() or t.is_set():
		return ""
	if not mapped.begins_with("Array["):
		return ""
	return GateTypes.packed_for(t.name)
func _not_text(node, text: String) -> String:
	if _text_prec(node, text) < PREC_ATOM and not _is_bare_ident(text):
		return "not (%s)" % text
	return "not %s" % text

const CTOR_SHORTHAND := {
	"vec2": "Vector2", "vec2i": "Vector2i",
	"vec3": "Vector3", "vec3i": "Vector3i",
	"vec4": "Vector4", "vec4i": "Vector4i",
	"rect2": "Rect2", "rect2i": "Rect2i",
	"quat": "Quaternion",
	"xform2d": "Transform2D", "xform3d": "Transform3D",
	"color": "Color", "aabb": "AABB", "plane": "Plane",
	"basis": "Basis", "proj": "Projection",
	"nodepath": "NodePath", "rid": "RID", "sname": "StringName",
}


func _index_declared_funcs(members: Array) -> void:
	for m in members:
		if m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
			_declared_funcs[fd.name] = true
			if fd.return_type != null and fd.return_type.array_depth == 0:
				_func_returns[fd.name] = fd.return_type.name
		elif m is GateAST._ClassDecl:
			_index_declared_funcs((m as GateAST._ClassDecl).members)


func _flow_name(e) -> String:
	if not (e is GateAST._Expr) or (e as GateAST._Expr).flow_type == null:
		return ""
	var t: GateAST._TypeRef = (e as GateAST._Expr).flow_type
	if (t.array_depth != 0 or t.is_dict() or t.is_set() or t.is_union() or t.is_tuple()
			or t.is_func_type):
		return ""
	if not t.generic_args.is_empty():
		if _generics.has(t.name):
			return _generic_name(_substituted(t))
		return t.name if GateTypes.canonical(t.name) == "PackedScene" else ""
	return t.name


func _left_spine_types(b: GateAST._Binary) -> Dictionary:
	var spine: Array = []
	var cur: GateAST._Binary = b
	while true:
		spine.append(cur)
		if not (cur.left is GateAST._Binary):
			break
		cur = cur.left
	var out: Dictionary = {}
	var t: String = _static_type_of((spine[spine.size() - 1] as GateAST._Binary).left)
	for i in range(spine.size() - 1, -1, -1):
		var node: GateAST._Binary = spine[i]
		out[node] = t
		var fn: String = _flow_name(node)
		t = fn if fn != "" else ("" if t == "" else _struct_op_type(t, node.op))
	return out


func _static_type_of(e) -> String:
	var fn: String = "" if (e is GateAST._NullCoalesce or e is GateAST._Ternary) else _flow_name(e)
	if fn != "":
		return fn
	if e is GateAST._Ident:
		var inm: String = (e as GateAST._Ident).name
		if _var_depths.get(inm, 0) > 0:
			return ""
		return _var_types.get(inm, "")
	if e is GateAST._Member:
		var m: GateAST._Member = e
		if m.target is GateAST._SelfExpr:
			if _var_depths.get(m.name, 0) > 0:
				return ""
			return _var_types.get(m.name, "")
		var owner: String = _static_type_of(m.target)
		if owner != "":
			var ft = _field_types.get("%s.%s" % [owner, m.name])
			if ft == null and owner.contains("."):
				ft = _field_types.get("%s.%s" % [owner.get_slice(".", owner.get_slice_count(".") - 1), m.name])
			if ft == null:
				ft = _struct_field_tref(owner, m.name)
			if ft == null:
				ft = _generic_field_tref(owner.get_slice(".", owner.get_slice_count(".") - 1), m.name)
			if ft == null and _mono_template.has(owner):
				ft = _field_types.get("%s.%s" % [_mono_template[owner], m.name])
				if ft != null:
					ft = _instance_tref(ft, owner)
			if ft != null and (ft as GateAST._TypeRef).array_depth == 0:
				return (ft as GateAST._TypeRef).name
		return ""
	if e is GateAST._Ternary:
		var tt: GateAST._Ternary = e
		if _is_null_lit(tt.if_false):
			return _static_type_of(tt.if_true)
		if _is_null_lit(tt.if_true):
			return _static_type_of(tt.if_false)
		return _both_arms(_static_type_of(tt.if_true), _static_type_of(tt.if_false))
	if e is GateAST._NullCoalesce:
		return _both_arms(_static_type_of((e as GateAST._NullCoalesce).left),
			_static_type_of((e as GateAST._NullCoalesce).right))
	if e is GateAST._Binary:
		var lb: GateAST._Binary = e
		return _struct_op_type(String(_left_spine_types(lb)[lb]), lb.op)
	if e is GateAST._CastExpr:
		var ct: GateAST._TypeRef = (e as GateAST._CastExpr).type
		return ct.name if (ct.array_depth == 0 and not ct.is_union() and not ct.is_tuple()
			and not ct.is_dict()) else ""
	if e is GateAST._Index:
		var ix: GateAST._Index = e
		if ix.target is GateAST._Ident:
			var slot: Variant = GateChecker.fold_int(ix.index, _const_exprs)
			var tup: GateAST._TypeRef = _tuple_tref(_declared_tref(ix.target)) if slot != null else null
			if tup != null:
				var at: int = int(slot) if int(slot) >= 0 else tup.tuple_elems.size() + int(slot)
				var et: GateAST._TypeRef = _elem_tref_of(ix.target, at)
				return et.name if et != null and et.array_depth == 0 and not et.is_union() else ""
		if ix.target is GateAST._Ident:
			var an: String = (ix.target as GateAST._Ident).name
			if _var_dict_values.has(an):
				return _var_dict_values[an]
			if _var_depths.get(an, 0) == 1:
				return _var_types.get(an, "")
		return ""
	if e is GateAST._Call:
		var c: GateAST._Call = e
		if _is_scene_preload(c):
			return "PackedScene"
		if c.callee is GateAST._Ident:
			var cn: String = (c.callee as GateAST._Ident).name
			if not _ctor_struct_of(cn).is_empty():
				return cn
			if _func_returns.has(cn):
				return _func_returns[cn]
			var ctor: String = cn if GateTypes.shadowed.has(cn) else String(CTOR_SHORTHAND.get(cn, cn))
			if VECTOR_CTORS.has(ctor) and not _shorthand_taken(cn):
				return ctor   # `Vector2i(5, 10)`, a Vector struct on a recompile
		if c.callee is GateAST._Member:
			var cm: GateAST._Member = c.callee
			if cm.name == "new" and cm.target is GateAST._Ident:
				return (cm.target as GateAST._Ident).name
			if cm.name == "_gate_copy" and c.args.is_empty():
				return _static_type_of(cm.target)   # GATE's own copy, on a recompile
			if cm.name.begins_with("_gate_value") and c.args.size() == 1:
				return _static_type_of(c.args[0])   # the guard hands back what it was given
			if _is_namespace_ref(cm.target) and not _struct_of(cm.name).is_empty():
				return _class_ref_text(cm)   # `RcLib.Pt(1, 2)`, a struct through a qualifier
			var recv_t: String = _static_type_of(cm.target)
			var rst: Dictionary = _struct_of(recv_t) if recv_t != "" else {}
			if rst.has("decl"):
				var mrt: GateAST._TypeRef = _struct_method_return(rst, cm.name)
				if mrt != null:
					return mrt.name
			if cm.name == "new" and cm.target is GateAST._Member:
				var root = cm.target
				while root is GateAST._Member:
					root = (root as GateAST._Member).target
				if root is GateAST._Ident and (root as GateAST._Ident).name.contains("gate_dep_"):
					return (cm.target as GateAST._Member).name   # another file's class, through its preload
				var qpath: String = _class_ref_text(cm.target)
				if qpath != "" and not _struct_of(qpath).is_empty():
					return qpath   # `RcLib.Pt.new(...)`, this struct through a qualifier
			if cm.name != "new" and recv_t != "":
				var mrt2: GateAST._TypeRef = _member_tref(_name_key(_scope_class, recv_t), cm.name, true)
				if mrt2 != null and mrt2.array_depth == 0 and not mrt2.is_union() and not mrt2.is_tuple():
					return mrt2.name   # a class's own method, `__op_add` on a recompile included
	return ""


func _generic_field_tref(inst: String, field: String) -> GateAST._TypeRef:
	if _demangled.is_empty():
		_demangled["."] = null
		for gt in _project_generic_uses:
			_demangled[GateParser.mangle_generic(gt)] = gt
	var use = _demangled.get(inst, null)
	if use == null or _reg_whole == null or not ("generics" in _reg_whole):
		return null
	var cd = (_reg_whole.generics as Dictionary).get((use as GateAST._TypeRef).name, null)
	if not (cd is GateAST._ClassDecl):
		return null
	for m in (cd as GateAST._ClassDecl).members:
		if m is GateAST._VarDecl and (m as GateAST._VarDecl).name == field and (m as GateAST._VarDecl).type != null:
			var ft: GateAST._TypeRef = (m as GateAST._VarDecl).type
			var gi: int = (cd as GateAST._ClassDecl).generic_params.find(ft.name)
			if gi < 0:
				return ft
			if ft.array_depth == 0 and gi < (use as GateAST._TypeRef).generic_args.size():
				return (use as GateAST._TypeRef).generic_args[gi]
			return null
	return null


func _struct_op_type(lt: String, op: String) -> String:
	if lt == "" or not (_ops_of(lt) as Dictionary).has(op):
		return ""
	var ops_owner: String = lt if _class_op_fds.has(lt) else _last_part(lt)
	if _class_op_fds.has(ops_owner):
		var ort: GateAST._TypeRef = ((_class_op_fds[ops_owner] as Dictionary)[op] as GateAST._FuncDecl).return_type
		return ort.name if (ort != null and ort.array_depth == 0 and not ort.is_union()
			and not ort.is_tuple()) else ""
	var st: Dictionary = _struct_of(lt)
	if st.is_empty() or not st.has("decl"):
		return ""
	var fname: String = String((_ops_of(lt) as Dictionary)[op])
	for m in (st["decl"] as GateAST._ClassDecl).members:
		if m is GateAST._FuncDecl and (m as GateAST._FuncDecl).name == fname:
			var rt: GateAST._TypeRef = (m as GateAST._FuncDecl).return_type
			if rt != null and rt.array_depth == 0 and not rt.is_union() and not rt.is_tuple():
				return rt.name
	return ""


func _struct_method_return(st: Dictionary, method: String) -> GateAST._TypeRef:
	for m in (st["decl"] as GateAST._ClassDecl).members:
		if m is GateAST._FuncDecl and (m as GateAST._FuncDecl).name == method:
			var rt: GateAST._TypeRef = (m as GateAST._FuncDecl).return_type
			if rt != null and rt.array_depth == 0 and not rt.is_union() and not rt.is_tuple():
				return rt
			return null
	return null


func _vec_component(st: Dictionary, i: int) -> String:
	var fields: Array = st["fields"]
	if not _vec_named_fields(st):
		return GateTypes.VECTOR_COMPONENTS[i]
	return String(fields[i])


func _vec_named_fields(st: Dictionary) -> bool:
	var fields: Array = st["fields"]
	var seen: Dictionary = {}
	for f in fields:
		var at: int = GateTypes.VECTOR_COMPONENTS.find(String(f))
		if at < 0 or at >= fields.size() or seen.has(f):
			return false
		seen[f] = true
	return true


func _vec_args(st: Dictionary, parts: PackedStringArray) -> PackedStringArray:
	if not _vec_named_fields(st) or parts.size() != (st["fields"] as Array).size():
		return parts
	var out: PackedStringArray = parts.duplicate()
	for i in parts.size():
		out[GateTypes.VECTOR_COMPONENTS.find(_vec_component(st, i))] = parts[i]
	return out


func _vector_struct_of(e) -> Dictionary:
	var tn: String = _static_type_of(e)
	if tn == "":
		return {}
	var st: Dictionary = _struct_of(tn)
	if st.is_empty() or st["lowering"] != "vector":
		return {}
	return st


func set_interfaces(names: Array) -> void:
	for n in names:
		_interface_names[n] = true


func _looks_like_interface(name: String) -> bool:
	return _interface_names.has(name)


func _is_known_native(name: String) -> bool:
	return GateTypes.BUILTIN.has(GateTypes.canonical(name))


func set_erased_types(names: Array) -> void:
	for n in names:
		_erased_types[n] = true


func _is_erased_type(name: String) -> bool:
	return _erased_types.has(name)


func set_overloads(map: Dictionary) -> void:
	_overloads = map


func set_overload_owners(owners: Dictionary) -> void:
	_overload_owners = owners


func _overload_declared_by(name: String, owner: String) -> bool:
	return _overload_owners.has(name) and (_overload_owners[name] as Dictionary).has(owner)


func _overload_declared_by_chain(name: String, owner: String) -> bool:
	var seen: Dictionary = {}
	var c: String = owner
	while not seen.has(c):
		seen[c] = true
		if _overload_declared_by(name, c):
			return true
		if _class_bases.has(c):
			c = String(_class_bases[c])
		elif _reg_bases.has(c):
			c = String(_reg_bases[c])   # another file's class
		else:
			break
	return false


func _resolve_overload(name: String, arity: int) -> String:
	if not _overloads.has(name):
		return ""
	var by_arity: Dictionary = _overloads[name]
	if by_arity.has(arity):
		return by_arity[arity]
	return by_arity.get(GateChecker.REST_ARITY, "")


func _soa_name(e) -> String:
	if e is GateAST._Ident and _soa.has((e as GateAST._Ident).name):
		return (e as GateAST._Ident).name
	if (e is GateAST._Member and (e as GateAST._Member).target is GateAST._SelfExpr
			and not (e as GateAST._Member).safe and _soa.has((e as GateAST._Member).name)):
		return (e as GateAST._Member).name
	return ""


func _soa_field_array(info: Dictionary, field: String) -> String:
	var idx: int = info["fields"].find(field)
	if idx < 0:
		return ""
	return info["arrays"][idx]


func _is_bare_ident(rendered: String) -> bool:
	if rendered.is_empty():
		return false
	for i in rendered.length():
		var c: String = rendered[i]
		var ok: bool = (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" \
			or (i > 0 and c >= "0" and c <= "9")
		if not ok:
			return false
	return true


func _repeatable(e, rendered: String) -> bool:
	if e is GateAST._Literal or e is GateAST._SelfExpr:
		return true
	if e is GateAST._Member and not (e as GateAST._Member).safe:
		var fm: GateAST._Member = e
		if fm.target is GateAST._SelfExpr:
			if (rendered == "self." + fm.name
					and _plain_fields.has("%s#%s" % [_scope_class, fm.name])):
				return true
		elif fm.target is GateAST._Ident:
			var tn: String = (fm.target as GateAST._Ident).name
			if rendered == "%s.%s" % [tn, fm.name] and _repeatable(fm.target, tn):
				var owner: String = _declared_type_of(fm.target)
				if owner != "" and _plain_fields.has("%s#%s" % [owner, fm.name]):
					return true
	if not _is_bare_ident(rendered):
		return false
	if _fn_locals.has(rendered) or _tmp_names.has(rendered):
		return true
	return _plain_fields.has("%s#%s" % [_scope_class, rendered])


func _stable(e, text: String) -> bool:
	if _tmp_names.has(text):
		return true
	if text.ends_with("._gate_copy()") or text.contains("._gate_copy() if "):
		return false
	return _stable_node(e)


func _stable_node(e) -> bool:
	if e is GateAST._Literal or e is GateAST._SelfExpr or e is GateAST._Lambda:
		return true   # (a lambda expression only builds a Callable)
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		return (_fn_locals.has(n) and not _soa.has(n) and not _soa_cursors.has(n)
			and _extern_alias(n) == "")
	if e is GateAST._Unary:
		return _stable_node((e as GateAST._Unary).operand) and _plain_value(
			(e as GateAST._Unary).operand)
	if e is GateAST._Binary:
		var b: GateAST._Binary = e
		if _binary_lowering(b) != "":
			return false   # an overloaded operator is a method call
		return (_stable_node(b.left) and _stable_node(b.right)
			and _plain_value(b.left) and _plain_value(b.right))
	return false


const CONTAINER_BUILTINS := ["Array", "Dictionary", "Variant", "Callable", "Signal"]


func _plain_value(e) -> bool:
	if e is GateAST._Literal:
		return true
	if e is GateAST._Unary:
		return _plain_value((e as GateAST._Unary).operand)
	if e is GateAST._Binary:
		return _plain_value((e as GateAST._Binary).left) and _plain_value((e as GateAST._Binary).right)
	if e is GateAST._Ident and _fn_locals.has((e as GateAST._Ident).name):
		var c: String = GateTypes.canonical(_declared_type_of(e))
		return GateTypes.BUILTIN.has(c) and not CONTAINER_BUILTINS.has(c)
	return false


func _render_once(e, rendered: String) -> String:
	if _repeatable(e, rendered):
		return rendered
	var ctx: String = _no_hoist_ctx()
	if ctx == "const" or (ctx != "" and _dev_simple(e)):
		return rendered
	if ctx == "param" or ctx == "annotation":
		diagnostics.error("this needs a temporary, and %s has nowhere to put one"
				% ("a default parameter value" if ctx == "param" else "an annotation argument"),
			e.line, e.col,
			"`??`, `?.` and `?[` after a call evaluate it into a temporary first. "
			+ "Compute the value in the function body instead.")
		return rendered
	var t: String = _new_tmp()
	var text: String = rendered
	if _text_prec(e, rendered) < PREC_ATOM and _wrapped(rendered) and not (e is GateAST._Lambda):
		text = rendered.substr(1, rendered.length() - 2)
	_hoist("var %s = %s" % [t, text])
	return t


static func _has_safe_step(e) -> bool:
	var node = e
	while node is GateAST._Member or node is GateAST._Index:
		if node.safe:
			return true
		node = node.target
	return false


static func _has_null_ops(e) -> bool:
	if e == null or not (e is GateAST._Expr):
		return false
	if e is GateAST._NullCoalesce:
		return true
	if (e is GateAST._Member or e is GateAST._Index) and e.safe:
		return true
	if e is GateAST._Lambda:
		return false
	for part in _sub_exprs(e):
		if _has_null_ops(part):
			return true
	return false


static func _sub_exprs(e) -> Array:
	if e is GateAST._Unary:
		return [(e as GateAST._Unary).operand]
	if e is GateAST._Binary:
		return [(e as GateAST._Binary).left, (e as GateAST._Binary).right]
	if e is GateAST._NullCoalesce:
		return [(e as GateAST._NullCoalesce).left, (e as GateAST._NullCoalesce).right]
	if e is GateAST._Ternary:
		return [(e as GateAST._Ternary).cond, (e as GateAST._Ternary).if_true, (e as GateAST._Ternary).if_false]
	if e is GateAST._Member:
		return [(e as GateAST._Member).target]
	if e is GateAST._Index:
		return [(e as GateAST._Index).target, (e as GateAST._Index).index]
	if e is GateAST._Call:
		return [(e as GateAST._Call).callee] + (e as GateAST._Call).args
	if e is GateAST._ArrayLit:
		return (e as GateAST._ArrayLit).elements
	if e is GateAST._DictLit:
		return (e as GateAST._DictLit).keys + (e as GateAST._DictLit).values
	if e is GateAST._CastExpr:
		return [(e as GateAST._CastExpr).operand]
	if e is GateAST._IsExpr:
		return [(e as GateAST._IsExpr).operand]
	if e is GateAST._AwaitExpr:
		return [(e as GateAST._AwaitExpr).operand]
	if e is GateAST._Widen:
		return (e as GateAST._Widen).args
	return []


func _may_be_null(e) -> bool:
	if (e is GateAST._Member or e is GateAST._Index) and _has_safe_step(e):
		return true
	if e is GateAST._Call and _has_safe_step((e as GateAST._Call).callee):
		return true
	if e is GateAST._Expr and (e as GateAST._Expr).flow_type != null:
		return (e as GateAST._Expr).flow_type.nullable
	if e is GateAST._Literal:
		return (e as GateAST._Literal).kind == "null"
	if e is GateAST._NullCoalesce:
		return _may_be_null((e as GateAST._NullCoalesce).right)
	if e is GateAST._Ternary:
		return _may_be_null((e as GateAST._Ternary).if_true) or _may_be_null((e as GateAST._Ternary).if_false)
	if e is GateAST._Binary or e is GateAST._Unary or e is GateAST._IsExpr or e is GateAST._ArrayLit \
			or e is GateAST._DictLit or e is GateAST._FString or e is GateAST._Lambda:
		return false
	var tr: GateAST._TypeRef = _value_tref(e)
	if tr != null:
		return tr.nullable
	var key: String = _declared_type_of(e)
	if key == "":
		return true
	if e is GateAST._Call:
		var dc: String = GateTypes.canonical(key)
		return not (GateTypes.BUILTIN.has(dc) and dc != "Variant") \
			and not ((e as GateAST._Call).callee is GateAST._Member
				and ((e as GateAST._Call).callee as GateAST._Member).name == "new") \
			and _ctor_struct_of(String(key)).is_empty()
	var c: String = GateTypes.canonical(key)
	return not (GateTypes.BUILTIN.has(c) and c != "Variant")


func _type_text_of_key(key: String) -> String:
	if key == "" or key == "." or key == "Variant":
		return ""
	if GateTypes.BUILTIN.has(key) or ClassDB.class_exists(key) or _instantiations.has(key):
		return key
	if _class_decls.has(key):
		var cd: GateAST._ClassDecl = _class_decls[key]
		if cd.form == "struct":
			var st: Dictionary = _struct_of(cd.name)
			if not st.is_empty() and st["lowering"] == "vector":
				return String(st["vector"])
		return key if cd.form in ["class", "struct"] and cd.generic_params.is_empty() else ""
	return ""


## Renders operands left to right. When one has to be hoisted, everything to its left
## that could run code is hoisted first, so the order Godot would use is kept.
func _ordered(nodes: Array, render_at: Callable) -> PackedStringArray:
	var out: Array = []   # an Array, not a Packed one: _spill_before edits it in place
	for i in nodes.size():
		var before: int = _pending.size()
		var txt: String = render_at.call(i)
		if _pending.size() > before and _no_hoist_ctx() == "" and _in_lvalue == 0:
			_spill_before(nodes, out, i, before)
		out.append(txt)
	return PackedStringArray(out)


func _spill_before(nodes: Array, out: Array, upto: int, at: int) -> void:
	var ins: int = at
	for j in upto:
		if _stable(nodes[j], out[j]):
			continue
		var t: String = _new_tmp()
		_hoist_at(ins, "var %s = %s" % [t, out[j]])
		ins += 1
		out[j] = t


func _no_hoist_ctx() -> String:
	if _no_hoist != "":
		return _no_hoist
	return "" if _in_func_body else "field"


func _keeps_inplace(e) -> bool:
	var ctx: String = _no_hoist_ctx()
	return ctx == "const" or (ctx == "annotation" and _dev_simple(e))


func _dev_simple(e) -> bool:
	if e is GateAST._Ident or e is GateAST._Literal or e is GateAST._SelfExpr:
		return true
	if e is GateAST._Member:
		return not (e as GateAST._Member).safe and _dev_simple((e as GateAST._Member).target)
	return false


func _index_plain_fields(members: Array, key: String) -> void:
	if not _class_fields.has(key):
		_class_fields[key] = {}
	if not _class_funcs.has(key):
		_class_funcs[key] = {}
	_class_inits[key] = _init_param_count(members)
	if not _class_priv.has(key):
		_class_priv[key] = {}
	for m in members:
		if (m is GateAST._VarDecl or m is GateAST._FuncDecl) and m.visibility == "priv" \
				and not String(m.name).begins_with("_"):
			_class_priv[key][String(m.name)] = true
		if m is GateAST._VarDecl:
			var vd: GateAST._VarDecl = m
			if (vd.setter == "" and vd.inline_accessors == "" and vd.getter == ""
					and not _has_annotation(vd, "observable")):
				_plain_fields["%s#%s" % [key, vd.name]] = true
			elif _has_annotation(vd, "observable") and vd.type != null and vd.type.array_depth == 0:
				_observable_fields["%s#%s" % [key, vd.name]] = vd.type.name
			if vd.type != null:
				_class_field_types["%s#%s" % [key, vd.name]] = vd.type
			elif vd.is_const and _is_scene_preload(vd.value):
				var scene_t: GateAST._TypeRef = GateAST._TypeRef.new()
				scene_t.name = "PackedScene"
				_class_field_types["%s#%s" % [key, vd.name]] = scene_t
			if not vd.is_const:
				_class_fields[key][vd.name] = true
			for sa in vd.annotations:
				if (sa as GateAST._Annotation).name == "soa":
					_soa_fields["%s#%s" % [key, vd.name]] = true
		elif m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
			if not (_class_funcs[key] as Dictionary).has(fd.name):
				_class_funcs[key][fd.name] = []
			_class_funcs[key][fd.name].append(fd)
		elif m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			var ck: String = _qjoin(key, cd.name)
			_class_decls[ck] = cd
			_class_parent[ck] = key
			_class_base[ck] = cd.extends_type
			_index_plain_fields(cd.members, ck)


func _index_const_vectors(members: Array, key: String) -> void:
	var saved: String = _scope_class
	_scope_class = key
	for m in members:
		if m is GateAST._VarDecl:
			var vd: GateAST._VarDecl = m
			var fk: String = "%s#%s" % [key, vd.name]
			if not vd.is_const or vd.type != null or vd.value == null or _class_field_types.has(fk):
				continue
			var vk: String = GateTypes.canonical(_declared_type_of(vd.value))
			if SWIZZLE_SIZES.has(vk):
				var tr: GateAST._TypeRef = GateAST._TypeRef.new()
				tr.name = vk
				_class_field_types[fk] = tr
		elif m is GateAST._ClassDecl:
			_index_const_vectors((m as GateAST._ClassDecl).members, _qjoin(key, (m as GateAST._ClassDecl).name))
	_scope_class = saved


static func _qjoin(parent: String, name: String) -> String:
	return name if parent == "." else "%s.%s" % [parent, name]


func _method_emit_name(target, name: String, arity: int, owner: String = "") -> String:
	var mangled: String = _resolve_overload(name, arity)
	if mangled != "":
		var owner_t: String = owner
		if owner_t == "":
			owner_t = _cur_class if target is GateAST._SelfExpr else _static_type_of(target)
		if owner_t != "" and _overload_declared_by_chain(name, owner_t):
			return mangled
	return _member_name(owner if owner != "" else _owner_key(target), name)


func _owner_key(target) -> String:
	if target is GateAST._SelfExpr:
		return _scope_class
	return _declared_type_of(target)


func _member_name(owner: String, name: String) -> String:
	var q: String = owner if (owner == "." or _class_decls.has(owner)) else ""
	var ext: String = owner if q == "" else ""
	var seen: Dictionary = {}
	while q != "" and not seen.has(q):
		seen[q] = true
		if (_class_priv.get(q, {}) as Dictionary).has(name):
			return "_" + name
		if ((_class_fields.get(q, {}) as Dictionary).has(name)
				or (_class_funcs.get(q, {}) as Dictionary).has(name)):
			return name
		var b: Dictionary = _base_of(q)
		q = String(b["key"]) if String(b["kind"]) == "local" else ""
		if String(b["kind"]) == "ext":
			ext = String(b["name"])
	for _guard in 64:
		if ext == "" or seen.has(ext) or not _reg_classes.has(ext):
			break
		seen[ext] = true
		for m in (_reg_classes[ext] as GateAST._ClassDecl).members:
			if (m is GateAST._VarDecl or m is GateAST._FuncDecl) and m.name == name:
				return "_" + name if m.visibility == "priv" and not name.begins_with("_") else name
		ext = String(_reg_bases.get(ext, ""))
	return name


## Resolves a class name the way Godot does, from the inside out.
func _resolve_class(scope: String, ref: String) -> String:
	if ref == "" or ref.begins_with("res://") or ref.contains("\"") or ref.contains("'"):
		return ""
	var parts: PackedStringArray = ref.split(".")
	var q: String = ""
	var s: String = scope
	for _guard in 64:
		var cand: String = _qjoin(s, parts[0])
		if _class_decls.has(cand):
			q = cand
			break
		if s == "." or not _class_parent.has(s):
			break
		s = String(_class_parent[s])
	if q == "":
		if parts[0] != _self_class_name or _self_class_name == "":
			return ""
		q = "."
	for i in range(1, parts.size()):
		var nxt: String = _qjoin(q, parts[i])
		if not _class_decls.has(nxt):
			return ""
		q = nxt
	return q


func _base_of(key: String) -> Dictionary:
	var tr = _class_base.get(key)
	if tr == null:
		return {"kind": "none"}
	var t: GateAST._TypeRef = tr
	if t.is_path_literal or t.name.begins_with("res://") or t.name.contains("\""):
		return {"kind": "path"}
	var q: String = _resolve_class(String(_class_parent.get(key, ".")), t.name)
	if q != "" and q != key:
		return {"kind": "local", "key": q}
	return {"kind": "ext", "name": t.name}


func _name_key(scope: String, n: String) -> String:
	if n == "":
		return ""
	if _subst.has(n) and String(_subst[n]) != n:
		n = String(_subst[n])   # a generic parameter, inside one instantiation
	var q: String = _resolve_class(scope, n)
	return q if q != "" else GateTypes.canonical(n)


func _decl_info(scope: String, tr) -> Dictionary:
	if tr == null:
		return {}
	return {"t": _name_key(scope, _scalar_type_name(tr)),
		"e": _name_key(scope, _element_type_name(tr)),
		"k": _name_key(scope, _key_type_name(tr)),
		"g": _name_key(scope, _scene_root_name(tr)),
		"tr": tr, "scope": scope}


static func _scene_root_name(tr) -> String:
	if tr == null:
		return ""
	var t: GateAST._TypeRef = tr
	if t.array_depth != 0 or t.generic_args.size() != 1 or GateTypes.canonical(t.name) != "PackedScene":
		return ""
	return _scalar_type_name(t.generic_args[0])


static func _key_type_name(tr) -> String:
	if tr == null:
		return ""
	var t: GateAST._TypeRef = tr
	if t.is_dict():
		return _scalar_type_name(t.dict_key)
	if t.array_depth == 0 and t.generic_args.size() == 2 and GateTypes.canonical(t.name) == "Dictionary":
		return _scalar_type_name(t.generic_args[0])
	return ""


func _declared_tref(e) -> GateAST._TypeRef:
	if not (e is GateAST._Ident):
		return null
	var n: String = (e as GateAST._Ident).name
	if _fn_locals.has(n):
		return (_fn_locals[n] as Dictionary).get("tr", null)
	return _class_field_types.get("%s#%s" % [_scope_class, n], null)


func _value_tref(e) -> GateAST._TypeRef:
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		if _fn_locals.has(n):
			return (_fn_locals[n] as Dictionary).get("tr", null)
		return _member_tref(_scope_class, n, false)
	if e is GateAST._Member and not (e as GateAST._Member).safe:
		var m: GateAST._Member = e
		if m.target is GateAST._SelfExpr:
			return _member_tref(_scope_class, m.name, false)
		var owner: String = _declared_type_of(m.target)
		if owner == "" and _static_type_of(m.target) != "":
			owner = _name_key(_scope_class, _static_type_of(m.target))
		return _member_tref(owner, m.name, false) if owner != "" else null
	if e is GateAST._Call:
		var c: GateAST._Call = e
		if c.callee is GateAST._Ident:
			return _member_tref(_scope_class, (c.callee as GateAST._Ident).name, true)
		if c.callee is GateAST._Member and not (c.callee as GateAST._Member).safe:
			var cm: GateAST._Member = c.callee
			if cm.target is GateAST._SelfExpr:
				return _member_tref(_scope_class, cm.name, true)
			var cowner: String = _declared_type_of(cm.target)
			return _member_tref(cowner, cm.name, true) if cowner != "" else null
	return null


func _container_tref(e) -> GateAST._TypeRef:
	if e is GateAST._Call and (e as GateAST._Call).callee is GateAST._Member \
			and not ((e as GateAST._Call).callee as GateAST._Member).safe:
		var cm: GateAST._Member = (e as GateAST._Call).callee
		var rt: GateAST._TypeRef = _container_tref(cm.target)
		if rt != null:
			var parts: Array = _dict_parts(rt)
			if not parts.is_empty():
				if cm.name == "duplicate":
					return rt
				if cm.name == "values" or cm.name == "keys":
					var el: GateAST._TypeRef = parts[1] if cm.name == "values" else parts[0]
					if el == null:
						return null
					var arr: GateAST._TypeRef = GateChecker.copy_type(el)
					arr.array_depth += 1
					if el.nullable:
						arr.nullable = false
						arr.elem_nullable = true
					return arr
			elif _is_array_tref(rt) and cm.name in ["duplicate", "slice", "filter"]:
				return rt
	if e is GateAST._Ternary:
		var tt: GateAST._Ternary = e
		var a: GateAST._TypeRef = _container_tref(tt.if_true)
		var b: GateAST._TypeRef = _container_tref(tt.if_false)
		if a != null and b != null and a.name == b.name and a.array_depth == b.array_depth:
			return a
		return null
	if e is GateAST._Binary and (e as GateAST._Binary).op == "+":
		var lt: GateAST._TypeRef = _container_tref((e as GateAST._Binary).left)
		return lt if _is_array_tref(lt) else null
	return _value_tref(e)


static func _array_elem(t: GateAST._TypeRef) -> GateAST._TypeRef:
	if t.array_depth > 0:
		var el: GateAST._TypeRef = GateChecker.copy_type(t)
		el.array_depth -= 1
		el.nullable = t.elem_nullable if el.array_depth == 0 else false
		if el.array_depth == 0:
			el.elem_nullable = false
		return el
	return t.generic_args[0] if t.generic_args.size() == 1 else null


static func _is_array_tref(t: GateAST._TypeRef) -> bool:
	return t != null and (t.array_depth > 0 or (GateTypes.canonical(t.name) == "Array"
		and t.generic_args.size() == 1 and not t.is_tuple()))


func _struct_field_tref(owner: String, field: String) -> GateAST._TypeRef:
	var st: Dictionary = _struct_of(owner)
	if st.is_empty() and owner.contains("."):
		st = _struct_of(owner.get_slice(".", owner.get_slice_count(".") - 1))
	if st.is_empty():
		return null
	var fi: int = (st["fields"] as Array).find(field)
	return (st["typerefs"] as Array)[fi] if fi >= 0 else null


func _instance_tref(t: GateAST._TypeRef, mangled: String) -> GateAST._TypeRef:
	var entry: Array = _instantiations.get(mangled, [])
	if t == null or entry.size() < 2 or not (entry[1] as Dictionary).has(t.name):
		return t
	var c: GateAST._TypeRef = GateChecker.copy_type(t)
	c.name = String(entry[1][t.name])
	if entry.size() > 2:
		c.array_depth += int((entry[2] as Dictionary).get(t.name, 0))
	return c


func _member_tref(owner: String, name: String, fn: bool) -> GateAST._TypeRef:
	if _mono_template.has(owner):
		return _instance_tref(_member_tref(String(_mono_template[owner]), name, fn), owner)
	var q: String = owner
	var seen: Dictionary = {}
	while q != "" and not seen.has(q):
		seen[q] = true
		if fn:
			var fns: Array = (_class_funcs.get(q, {}) as Dictionary).get(name, [])
			if fns.size() == 1:
				return (fns[0] as GateAST._FuncDecl).return_type
			if fns.size() > 1:
				return null
		else:
			var ft = _class_field_types.get("%s#%s" % [q, name])
			if ft != null:
				return ft
			if (_class_fields.get(q, {}) as Dictionary).has(name):
				return null
		if not (q == "." or _class_decls.has(q)):
			return null
		var b: Dictionary = _base_of(q)
		q = String(b["key"]) if String(b["kind"]) == "local" else ""
	return null


func _loop_elem_tref(it) -> GateAST._TypeRef:
	if it is GateAST._Call and (it as GateAST._Call).args.is_empty() \
			and (it as GateAST._Call).callee is GateAST._Member:
		var cm: GateAST._Member = (it as GateAST._Call).callee
		if not cm.safe and (cm.name == "values" or cm.name == "keys"):
			var parts: Array = _dict_parts(_container_tref(cm.target))
			if not parts.is_empty():
				return parts[1] if cm.name == "values" else parts[0]
	var parts2: Array = _dict_parts(_container_tref(it))
	if not parts2.is_empty():
		return parts2[0]
	return _elem_tref_of(it)


func _tuple_tref(tr: GateAST._TypeRef) -> GateAST._TypeRef:
	if tr == null or tr.array_depth != 0:
		return null
	if tr.is_tuple():
		return tr
	if not tr.is_union():
		return null
	var found: GateAST._TypeRef = null
	for m in tr.union_members:
		var mt: GateAST._TypeRef = m
		if mt.array_depth != 0 or not mt.is_tuple():
			continue
		if found != null:
			return null
		found = mt
	return found


func _dict_parts(tr: GateAST._TypeRef) -> Array:
	if tr == null or tr.array_depth != 0:
		return []
	if tr.is_dict():
		return [tr.dict_key, tr.dict_value]
	if GateTypes.canonical(tr.name) == "Dictionary" and tr.generic_args.size() == 2:
		return [tr.generic_args[0], tr.generic_args[1]]
	return []


func _elem_tref_of(e, i: int = -1) -> GateAST._TypeRef:
	var tr: GateAST._TypeRef = _container_tref(e)
	var tup: GateAST._TypeRef = _tuple_tref(tr)
	if tup != null:
		return tup.tuple_elems[i] if i >= 0 and i < tup.tuple_elems.size() else null
	var n: String = ""
	if tr != null:
		if not _dict_parts(tr).is_empty():
			return _dict_parts(tr)[1]
		if tr.array_depth == 0 and GateTypes.canonical(tr.name) == "Array" and tr.generic_args.size() == 1:
			return tr.generic_args[0]
		if tr.array_depth == 1 and tr.generic_args.is_empty():
			var el: GateAST._TypeRef = GateChecker.copy_type(tr)
			el.array_depth = 0
			el.nullable = tr.elem_nullable
			el.elem_nullable = false
			return el
		n = _element_type_name(tr)
	elif e is GateAST._Ident:
		var an: String = (e as GateAST._Ident).name
		if _var_dict_values.has(an):
			n = _var_dict_values[an]
		elif int(_var_depths.get(an, 0)) == 1:
			n = String(_var_types.get(an, ""))
		elif not _fn_locals.has(an):
			n = _field_key(_scope_class, an, true)
	if n == "":
		return null
	var out: GateAST._TypeRef = GateAST._TypeRef.new()
	out.name = n
	return out


static func _is_scene_preload(e) -> bool:
	if not (e is GateAST._Call):
		return false
	var c: GateAST._Call = e
	if not (c.callee is GateAST._Ident) or (c.callee as GateAST._Ident).name != "preload":
		return false
	if c.args.size() != 1 or not (c.args[0] is GateAST._Literal):
		return false
	var lit: GateAST._Literal = c.args[0]
	if lit.kind != "string":
		return false
	var path: String = lit.raw.rstrip("\"'")
	return path.ends_with(".tscn") or path.ends_with(".scn")


static func _init_param_count(members: Array) -> int:
	for m in members:
		if m is GateAST._FuncDecl and (m as GateAST._FuncDecl).name == "_init":
			return (m as GateAST._FuncDecl).params.size()
	return -1


func _ctor_takes_params(scope: String, ref: String, instantiated: bool = false) -> int:
	var q: String = _resolve_class(scope, ref)
	var ext: String = ref if q == "" else ""
	var seen: Dictionary = {}
	for _guard in 64:
		if q != "":
			if seen.has(q):
				return -1
			seen[q] = true
			var cd = _class_decls.get(q)
			if cd != null and ((cd as GateAST._ClassDecl).form != "class"
					or (not (cd as GateAST._ClassDecl).generic_params.is_empty() and not instantiated)):
				return -1
			instantiated = false
			var n: int = int(_class_inits.get(q, -1))
			if n >= 0:
				return 1 if n > 0 else 0
			var b: Dictionary = _base_of(q)
			match String(b["kind"]):
				"none":
					return 0   # no extends: RefCounted, whose constructor takes nothing
				"path":
					return -1  # a base GATE cannot see may take parameters
				"local":
					q = String(b["key"])
				_:
					q = ""
					ext = String(b["name"])
			continue
		if (ext == "" or not _struct_of(ext).is_empty() or _generics.has(ext)
				or _interface_names.has(ext) or _erased_types.has(ext) or seen.has(ext)):
			return -1
		seen[ext] = true
		if _reg_classes.has(ext):
			var rcd: GateAST._ClassDecl = _reg_classes[ext]
			if not rcd.generic_params.is_empty():
				return -1
			var rn: int = _init_param_count(rcd.members)
			if rn >= 0:
				return 1 if rn > 0 else 0
			var rb: String = String(_reg_bases.get(ext, ""))
			if rb == "":
				return 0
			if rb.begins_with("res://") or rb.contains("\""):
				return -1
			ext = rb
			continue
		return 0 if ClassDB.class_exists(ext) else -1
	return -1


func _class_has_property(scope: String, ref: String, key: String) -> int:
	var q: String = _resolve_class(scope, ref)
	var ext: String = ref if q == "" else ""
	var seen: Dictionary = {}
	for _guard in 64:
		if q != "":
			if seen.has(q):
				return -1
			seen[q] = true
			if (_class_fields.get(q, {}) as Dictionary).has(key):
				return 1
			var b: Dictionary = _base_of(q)
			match String(b["kind"]):
				"none":
					return 1 if _engine_properties("RefCounted").has(key) else 0
				"path":
					return -1
				"local":
					q = String(b["key"])
				_:
					q = ""
					ext = String(b["name"])
			continue
		if ext == "" or seen.has(ext):
			return -1
		seen[ext] = true
		if _reg_classes.has(ext):
			for mm in (_reg_classes[ext] as GateAST._ClassDecl).members:
				if mm is GateAST._VarDecl and not (mm as GateAST._VarDecl).is_const \
						and (mm as GateAST._VarDecl).name == key:
					return 1
			var rb: String = String(_reg_bases.get(ext, ""))
			if rb == "":
				return 1 if _engine_properties("RefCounted").has(key) else 0
			if rb.begins_with("res://") or rb.contains("\""):
				return -1
			ext = rb
			continue
		if ClassDB.class_exists(ext):
			return 1 if _engine_properties(ext).has(key) else 0
		var script: String = GateChecker._global_script(ext, _reg_whole)
		return _script_has_property(script, key) if script != "" else -1
	return -1


func _script_has_property(path: String, key: String) -> int:
	var p: String = path
	var seen: Dictionary = {}
	for _guard in 32:
		if seen.has(p):
			return -1
		seen[p] = true
		var smod: GateAST._Module = GateChecker.read_script(p)
		if smod == null:
			return -1
		for m in smod.members:
			if m is GateAST._VarDecl and not (m as GateAST._VarDecl).is_const \
					and (m as GateAST._VarDecl).name == key:
				return 1
		var ext: String = smod.extends_type.name if smod.extends_type != null else "RefCounted"
		if ext.begins_with("\"") or ext.begins_with("'"):
			var split: Array = GateChecker.split_extends_path(ext)
			if String(split[1]) != "":
				return -1
			p = String(split[0])
			if not p.begins_with("res://"):
				p = smod.path.get_base_dir().path_join(p).simplify_path()
			continue
		if ClassDB.class_exists(ext):
			return 1 if _engine_properties(ext).has(key) else 0
		p = GateChecker._global_script(ext, _reg_whole)
		if p == "":
			return -1
	return -1


func _engine_properties(cls: String) -> Dictionary:
	if not _engine_props.has(cls):
		var names: Dictionary = {}
		for p in ClassDB.class_get_property_list(cls):
			var usage: int = int(p.get("usage", 0))
			if usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
				continue
			names[String(p["name"])] = true
		_engine_props[cls] = names
	return _engine_props[cls]


func _shadow_name(n: String) -> void:
	_var_types.erase(n)
	_var_depths.erase(n)
	_var_dict_values.erase(n)


const SWIZZLE_SIZES := {
	"Vector2": 2, "Vector2i": 2, "Vector3": 3, "Vector3i": 3, "Vector4": 4, "Vector4i": 4,
}


func _field_key(owner: String, name: String, elem: bool = false, key: bool = false) -> String:
	var info: Dictionary = _field_info(owner, name)
	return String(info.get("k" if key else ("e" if elem else "t"), ""))


func _field_info(owner: String, name: String) -> Dictionary:
	var q: String = owner if (owner == "." or _class_decls.has(owner)) else ""
	var ext: String = owner if q == "" else ""
	var seen: Dictionary = {}
	for _guard in 64:
		if q != "":
			if seen.has(q):
				return {}
			seen[q] = true
			var tr = _class_field_types.get("%s#%s" % [q, name])
			if tr != null:
				return _decl_info(q, tr)
			if (_class_fields.get(q, {}) as Dictionary).has(name):
				return {}   # declared here, without a type
			var b: Dictionary = _base_of(q)
			if String(b["kind"]) == "local":
				q = String(b["key"])
				continue
			if String(b["kind"]) != "ext":
				return {}
			q = ""
			ext = String(b["name"])
			continue
		if ext == "" or seen.has(ext):
			return {}
		if ClassDB.class_exists(ext):
			return _engine_prop_info(ext, name)
		if not _reg_classes.has(ext):
			return {}
		seen[ext] = true
		for mm in (_reg_classes[ext] as GateAST._ClassDecl).members:
			if mm is GateAST._VarDecl and (mm as GateAST._VarDecl).name == name:
				var rinfo: Dictionary = {}
				var rtr = (mm as GateAST._VarDecl).type
				for part in [["t", _scalar_type_name(rtr)], ["e", _element_type_name(rtr)],
						["k", _key_type_name(rtr)]]:
					var rt: String = GateTypes.canonical(String(part[1]))
					rinfo[part[0]] = rt if GateTypes.BUILTIN.has(rt) or ClassDB.class_exists(rt) else ""
				return rinfo
		ext = String(_reg_bases.get(ext, ""))
	return {}


func _engine_prop_info(cls: String, name: String) -> Dictionary:
	var cache_key: String = "%s#%s" % [cls, name]
	if _engine_prop_cache.has(cache_key):
		return _engine_prop_cache[cache_key]
	var info: Dictionary = {}
	for p in ClassDB.class_get_property_list(cls):
		if String(p["name"]) != name:
			continue
		var usage: int = int(p.get("usage", 0))
		if usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
			continue
		var ty: int = int(p.get("type", TYPE_NIL))
		var tn: String = String(ENGINE_TYPE_NAMES.get(ty, ""))
		if ty == TYPE_OBJECT and ClassDB.class_exists(String(p.get("class_name", ""))):
			tn = String(p["class_name"])
		info = {"t": tn, "e": String(PACKED_ELEMENTS.get(tn, "")), "k": ""}
		break
	_engine_prop_cache[cache_key] = info
	return info


const ENGINE_TYPE_NAMES := {
	TYPE_VECTOR2: "Vector2", TYPE_VECTOR2I: "Vector2i", TYPE_VECTOR3: "Vector3",
	TYPE_VECTOR3I: "Vector3i", TYPE_VECTOR4: "Vector4", TYPE_VECTOR4I: "Vector4i",
	TYPE_PACKED_VECTOR2_ARRAY: "PackedVector2Array", TYPE_PACKED_VECTOR3_ARRAY: "PackedVector3Array",
	TYPE_PACKED_VECTOR4_ARRAY: "PackedVector4Array",
}

const PACKED_ELEMENTS := {
	"PackedVector2Array": "Vector2", "PackedVector3Array": "Vector3",
	"PackedVector4Array": "Vector4",
}

const VECTOR_CONSTANTS := {
	"Vector2": ["ZERO", "ONE", "INF", "LEFT", "RIGHT", "UP", "DOWN"],
	"Vector2i": ["ZERO", "ONE", "MIN", "MAX", "LEFT", "RIGHT", "UP", "DOWN"],
	"Vector3": ["ZERO", "ONE", "INF", "LEFT", "RIGHT", "UP", "DOWN", "FORWARD", "BACK",
		"MODEL_LEFT", "MODEL_RIGHT", "MODEL_TOP", "MODEL_BOTTOM", "MODEL_FRONT", "MODEL_REAR"],
	"Vector3i": ["ZERO", "ONE", "MIN", "MAX", "LEFT", "RIGHT", "UP", "DOWN", "FORWARD", "BACK"],
	"Vector4": ["ZERO", "ONE", "INF"],
	"Vector4i": ["ZERO", "ONE", "MIN", "MAX"],
}

const VECTOR_SELF_METHODS := {
	"abs": true, "ceil": true, "floor": true, "round": true, "sign": true, "clamp": true,
	"clampf": true, "clampi": true, "snapped": true, "snappedf": true, "snappedi": true,
	"min": true, "minf": true, "mini": true, "max": true, "maxf": true, "maxi": true,
	"posmod": true, "posmodv": true, "lerp": true, "slerp": true, "move_toward": true,
	"normalized": true, "limit_length": true, "direction_to": true, "bounce": true,
	"reflect": true, "slide": true, "project": true, "cubic_interpolate": true,
	"cubic_interpolate_in_time": true, "bezier_interpolate": true, "bezier_derivative": true,
	"inverse": true, "rotated": true, "orthogonal": true,
}


func _method_key(owner: String, name: String) -> String:
	var q: String = owner if (owner == "." or _class_decls.has(owner)) else ""
	var seen: Dictionary = {}
	while q != "" and not seen.has(q):
		seen[q] = true
		var fns: Array = (_class_funcs.get(q, {}) as Dictionary).get(name, [])
		if fns.size() > 1:
			return ""
		if fns.size() == 1:
			var fd: GateAST._FuncDecl = fns[0]
			if fd.return_type == null or GateTypes.canonical(fd.return_type.name) == "void":
				return ""
			return String(_decl_info(q, fd.return_type)["t"])
		var b: Dictionary = _base_of(q)
		q = String(b["key"]) if String(b["kind"]) == "local" else ""
	return ""


static func _scalar_type_name(tr) -> String:
	if tr == null:
		return ""
	var t: GateAST._TypeRef = tr
	if t.array_depth != 0 or t.is_dict() or t.is_set():
		return ""
	if not t.generic_args.is_empty():
		return t.name if GateTypes.canonical(t.name) == "PackedScene" else ""
	return t.name


static func _element_type_name(tr) -> String:
	if tr == null:
		return ""
	var t: GateAST._TypeRef = tr
	if t.is_dict():
		return _scalar_type_name(t.dict_value)
	if t.array_depth == 1 and t.generic_args.is_empty():
		return t.name
	if t.array_depth == 0 and t.generic_args.is_empty() and PACKED_ELEMENTS.has(t.name):
		return PACKED_ELEMENTS[t.name]
	if t.array_depth == 0 and t.generic_args.size() == 1 and GateTypes.canonical(t.name) == "Array":
		return _scalar_type_name(t.generic_args[0])
	if t.array_depth == 0 and t.generic_args.size() == 2 and GateTypes.canonical(t.name) == "Dictionary":
		return _scalar_type_name(t.generic_args[1])
	return ""


const VECTOR_CTORS := {
	"Vector2": true, "Vector2i": true, "Vector3": true, "Vector3i": true,
	"Vector4": true, "Vector4i": true,
}


func _declared_type_of(e) -> String:
	if _is_scene_preload(e):
		return "PackedScene"
	var fn: String = _flow_name(e)
	if fn != "":
		return _name_key(_scope_class, fn)
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		if _soa_cursors.has(n) or _soa.has(n):
			return ""
		if _fn_locals.has(n):
			return String((_fn_locals[n] as Dictionary).get("t", ""))
		return _field_key(_scope_class, n)
	if e is GateAST._Member:
		var m: GateAST._Member = e
		if m.safe:
			return ""
		var sw: Dictionary = _swizzle_of(m)
		if not sw.is_empty():
			return _swizzle_result(sw, m.name.length())
		if m.target is GateAST._SelfExpr:
			return _field_key(_scope_class, m.name)
		var soa_field: String = _soa_field_key(m)
		if soa_field != "":
			return soa_field
		if m.target is GateAST._Ident:
			var rn: String = (m.target as GateAST._Ident).name
			if (VECTOR_CONSTANTS.has(rn) and not _fn_locals.has(rn) and _field_key(_scope_class, rn) == ""
					and not GateTypes.shadowed.has(rn) and (VECTOR_CONSTANTS[rn] as Array).has(m.name)):
				return rn
			if _scalar_names.has("%s.%s" % [rn, m.name]) and _scalar_repl.has(rn):
				var rst: Dictionary = _struct_of(String(_scalar_repl[rn]))
				var fi: int = (rst.get("fields", []) as Array).find(m.name)
				var rtr: Array = rst.get("typerefs", [])
				if fi >= 0 and fi < rtr.size():
					return _name_key(_scope_class, _scalar_type_name(rtr[fi]))
				return ""
		var owner: String = _declared_type_of(m.target)
		return _field_key(owner, m.name) if owner != "" else ""
	if e is GateAST._Index:
		return _declared_index_type(e)
	if e is GateAST._Literal:
		var lit: GateAST._Literal = e
		if lit.kind == "number":
			return "float" if lit.raw.contains(".") or (lit.raw.contains("e") \
				and not lit.raw.begins_with("0x")) else "int"
		if lit.kind == "string" and (lit.raw.begins_with("\"") or lit.raw.begins_with("'")):
			return "String"
		return "bool" if lit.kind == "bool" else ""
	if e is GateAST._NullCoalesce:
		var nl: String = _declared_type_of((e as GateAST._NullCoalesce).left)
		return nl if nl != "" and nl == _declared_type_of((e as GateAST._NullCoalesce).right) else ""
	if e is GateAST._Unary:
		var u: GateAST._Unary = e
		var ut: String = _declared_type_of(u.operand) if u.op == "-" or u.op == "+" else ""
		return ut if SWIZZLE_SIZES.has(ut) else ""
	if e is GateAST._Binary:
		return _declared_arith_type(e)
	if e is GateAST._Ternary:
		var tt: GateAST._Ternary = e
		var a: String = _declared_type_of(tt.if_true)
		if a != "" and a == _declared_type_of(tt.if_false):
			return a
		return ""
	if e is GateAST._Call:
		return _declared_call_type(e)
	return ""


func _declared_index_type(ix: GateAST._Index) -> String:
	if not ix.safe and ix.target is GateAST._Ident:
		var slot: Variant = GateChecker.fold_int(ix.index, _const_exprs)
		var tup: GateAST._TypeRef = _declared_tref(ix.target) if slot != null else null
		if tup != null and tup.array_depth == 0 and tup.is_tuple():
			var at: int = int(slot) if int(slot) >= 0 else tup.tuple_elems.size() + int(slot)
			var et: GateAST._TypeRef = _elem_tref_of(ix.target, at)
			if et != null and et.array_depth == 0 and not et.is_union():
				return _name_key(_scope_class, et.name)
			return ""
	var depth: int = 0
	var node = ix
	while node is GateAST._Index:
		if (node as GateAST._Index).safe:
			return ""
		depth += 1
		node = (node as GateAST._Index).target
	var info: Dictionary = {}
	if node is GateAST._Ident:
		var an: String = (node as GateAST._Ident).name
		if _soa.has(an) or _soa_cursors.has(an):
			return ""
		info = (_fn_locals[an] as Dictionary) if _fn_locals.has(an) else _field_info(_scope_class, an)
	elif node is GateAST._Member and not (node as GateAST._Member).safe:
		var nm: GateAST._Member = node
		var owner: String = _scope_class if nm.target is GateAST._SelfExpr else _declared_type_of(nm.target)
		if owner != "":
			info = _field_info(owner, nm.name)
	if info.is_empty():
		return ""
	if depth == 1:
		return String(info.get("e", ""))
	var tr = info.get("tr")
	if tr == null or (tr as GateAST._TypeRef).array_depth != depth \
			or not (tr as GateAST._TypeRef).generic_args.is_empty():
		return ""
	return _name_key(String(info.get("scope", _scope_class)), (tr as GateAST._TypeRef).name)


func _declared_arith_type(b: GateAST._Binary) -> String:
	if not (b.op in ["+", "-", "*", "/", "%"]):
		return ""
	var lt: String = GateTypes.canonical(_declared_type_of(b.left))
	var rt: String = GateTypes.canonical(_declared_type_of(b.right))
	if lt == rt and SWIZZLE_SIZES.has(lt):
		return lt
	if b.op != "*" and b.op != "/":
		return ""
	for pair in [[lt, rt], [rt, lt]]:
		var vec: String = pair[0]
		var num: String = pair[1]
		if b.op == "/" and vec == rt:
			continue   # a number divided by a vector
		if SWIZZLE_SIZES.has(vec) and (num == "int" or (num == "float" and not vec.ends_with("i"))):
			return vec
	return ""


func _soa_field_key(m: GateAST._Member) -> String:
	var sname: String = ""
	if m.target is GateAST._Ident and _soa_cursors.has((m.target as GateAST._Ident).name):
		sname = String(_soa_cursors[(m.target as GateAST._Ident).name]["soa"])
	elif m.target is GateAST._Index:
		sname = _soa_name((m.target as GateAST._Index).target)
	if sname == "":
		return ""
	var st: Dictionary = _struct_of(String(_soa[sname]["struct"]))
	var fi: int = (st.get("fields", []) as Array).find(m.name)
	var trefs: Array = st.get("typerefs", [])
	if fi < 0 or fi >= trefs.size():
		return ""
	return _name_key(_scope_class, _scalar_type_name(trefs[fi]))


func _declared_call_type(c: GateAST._Call) -> String:
	if c.callee is GateAST._Ident:
		var cn: String = (c.callee as GateAST._Ident).name
		if _fn_locals.has(cn):
			return ""
		var ctor: String = cn if GateTypes.shadowed.has(cn) else String(CTOR_SHORTHAND.get(cn, cn))
		if VECTOR_CTORS.has(ctor) and not _shorthand_taken(cn):
			return ctor
		if not _ctor_struct_of(cn).is_empty():
			return _name_key(_scope_class, cn)   # a struct constructor
		return _method_key(_scope_class, cn)
	if not (c.callee is GateAST._Member) or (c.callee as GateAST._Member).safe:
		return ""
	var cm: GateAST._Member = c.callee
	if not _struct_of(cm.name).is_empty() and cm.target is GateAST._Ident \
			and not _var_types.has((cm.target as GateAST._Ident).name) \
			and not _fn_locals.has((cm.target as GateAST._Ident).name):
		return _name_key(_scope_class, cm.name)
	if cm.name == "new":
		var ref: String = _class_ref_text(cm.target)
		if ref == "" or (cm.target is GateAST._Ident and _fn_locals.has(ref)):
			return ""
		var q: String = _resolve_class(_scope_class, ref)
		if q != "":
			return q
		return ref if ClassDB.class_exists(ref) or _reg_classes.has(ref) else ""
	if cm.target is GateAST._SelfExpr:
		return _method_key(_scope_class, cm.name)
	var owner: String = _declared_type_of(cm.target)
	if owner == "":
		return ""
	var co: String = GateTypes.canonical(owner)
	if SWIZZLE_SIZES.has(co) and (VECTOR_SELF_METHODS.has(cm.name)
			or (cm.name == "cross" and co == "Vector3")):
		return co
	return _method_key(owner, cm.name)


static func _class_ref_text(e) -> String:
	if e is GateAST._Ident:
		return (e as GateAST._Ident).name
	if e is GateAST._Member and not (e as GateAST._Member).safe:
		var head: String = _class_ref_text((e as GateAST._Member).target)
		return "" if head == "" else "%s.%s" % [head, (e as GateAST._Member).name]
	return ""


## Only on a statically typed vector: an untyped `v.xy` may be a property of your own.
func _swizzle_of(m: GateAST._Member) -> Dictionary:
	if m.safe or m == _swizzle_exempt:
		return {}
	var n: String = m.name
	if n.length() < 2 or n.length() > 4:
		return {}
	for i in n.length():
		if not "xyzw".contains(n[i]):
			return {}
	var vt: String = GateTypes.canonical(_declared_type_of(m.target))
	if not SWIZZLE_SIZES.has(vt) and m.target is GateAST._Expr:
		vt = (m.target as GateAST._Expr).narrowed_vector   # `if p is Vector3:` on an untyped p
	if not SWIZZLE_SIZES.has(vt):
		return {}
	return {"vector": vt, "size": int(SWIZZLE_SIZES[vt]), "int": vt.ends_with("i")}


func _swizzle_in_range(m: GateAST._Member, sw: Dictionary) -> bool:
	for i in m.name.length():
		var ch: String = m.name[i]
		if GateTypes.VECTOR_COMPONENTS.find(ch) >= int(sw["size"]):
			diagnostics.error("%s has no component '%s'" % [sw["vector"], ch], m.line, m.col,
				"a %s has %s." % [sw["vector"], ", ".join(PackedStringArray(
					GateTypes.VECTOR_COMPONENTS.slice(0, int(sw["size"]))))])
			return false
	return true


static func _swizzle_result(sw: Dictionary, length: int) -> String:
	return GateTypes.VECTOR_INT[length] if sw["int"] else GateTypes.VECTOR_FLOAT[length]


static func _pattern_binds(text: String) -> Array:
	var out: Array = []
	var i: int = text.find("var")
	while i >= 0:
		var before_ok: bool = i == 0 or not _is_ident_char(text[i - 1])
		var j: int = i + 3
		if before_ok and j < text.length() and (text[j] == " " or text[j] == "\t"):
			while j < text.length() and (text[j] == " " or text[j] == "\t"):
				j += 1
			var k: int = j
			while k < text.length() and _is_ident_char(text[k]):
				k += 1
			if k > j:
				out.append(text.substr(j, k - j))
		i = text.find("var", i + 3)
	return out


func _annotated_with(annotations: Array, name: String) -> bool:
	for a in annotations:
		if (a as GateAST._Annotation).name == name:
			return true
	return false


func _has_annotation(vd: GateAST._VarDecl, name: String) -> bool:
	for a in vd.annotations:
		if (a as GateAST._Annotation).name == name:
			return true
	return false

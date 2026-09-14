@tool
extends "res://addons/gate/compiler/emitter_out.gd"

## Emitter layer 2: naming, GATE -> GDScript type mapping, and precedence.


func _index_structs(members: Array, key: String = ".") -> void:
	for m in members:
		if not (m is GateAST.ClassDecl):
			continue
		var cd: GateAST.ClassDecl = m
		if cd.form == "struct":
			_index_struct(cd.name, cd, key)
			if key != "." and key != "":
				_structs[_qjoin(key, cd.name)] = _structs[cd.name].duplicate()
				_structs[_qjoin(key, cd.name)]["name"] = cd.name
		_index_structs(cd.members, _qjoin(key, cd.name))


func _index_struct(name: String, cd: GateAST.ClassDecl, scope: String = "") -> void:
	var names: Array = []
	var types: Array = []
	var defaults: Array = []
	var typerefs: Array = []
	for f in GateChecker.struct_fields(cd):
		var vd: GateAST.VarDecl = f
		names.append(vd.name)
		types.append(vd.type.name if vd.type != null else "Variant")
		typerefs.append(vd.type)
		defaults.append(vd.value)
	var methods: Dictionary = {}
	var consts: Dictionary = {}
	for mm in cd.members:
		if mm is GateAST.FuncDecl:
			methods[(mm as GateAST.FuncDecl).name] = (mm as GateAST.FuncDecl).is_static
		elif mm is GateAST.VarDecl and not names.has((mm as GateAST.VarDecl).name):
			consts[(mm as GateAST.VarDecl).name] = true
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
		if f2 is GateAST.FuncDecl and (f2 as GateAST.FuncDecl).is_operator:
			var ofd: GateAST.FuncDecl = f2
			ops[ofd.operator_symbol] = ofd.name
	if not ops.is_empty():
		_struct_ops[name] = ops


func _index_class_ops(members: Array) -> void:
	var decls: Dictionary = {}
	var bases: Dictionary = {}
	_collect_classes(members, decls, bases)
	for rn in _reg_classes:
		if not decls.has(rn) and not _local_types.has(rn) and _reg_classes[rn] is GateAST.ClassDecl:
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
			for f in (decls[c] as GateAST.ClassDecl).members:
				if f is GateAST.FuncDecl and (f as GateAST.FuncDecl).is_operator \
						and not ops.has((f as GateAST.FuncDecl).operator_symbol):
					ops[(f as GateAST.FuncDecl).operator_symbol] = (f as GateAST.FuncDecl).name
					fds[(f as GateAST.FuncDecl).operator_symbol] = f
			c = String(bases.get(c, ""))
		if not ops.is_empty():
			_struct_ops[cname] = ops
			_class_op_fds[cname] = fds


static func _collect_classes(members: Array, decls: Dictionary, bases: Dictionary) -> void:
	for m in members:
		if m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
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
				var scd: GateAST.ClassDecl = reg.script_class_decls[cn]
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


func _extern_alias(name: String) -> String:
	if not _extern_origin.has(name):
		return ""
	if _local_types.has(name):
		return ""
	if _bound_names.has(name):
		return ""
	return _origin_alias(_extern_origin[name])


func _extern_generic_alias(name: String) -> String:
	if not _extern_generics.has(name):
		return ""
	if _local_types.has(name):
		return ""
	return _origin_alias(_extern_generics[name])


func _origin_alias(origin: String) -> String:
	if _used_origins.has(origin):
		return _used_origins[origin]
	var base: String = ""
	for ch in String(origin).get_file().get_basename():
		base += ch if _is_ident_char(ch) else "_"
	var alias: String = "__gate_dep_%s_%d" % [base, _used_origins.size()]
	while _bound_names.has(alias) or _local_types.has(alias):
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
	return e is GateAST.Literal and (e as GateAST.Literal).kind == "null"


static func _last_part(n: String) -> String:
	return n.get_slice(".", n.get_slice_count(".") - 1)


static func _is_ident_char(c: String) -> bool:
	return ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
		or (c >= "0" and c <= "9") or c == "_" or c.unicode_at(0) >= 0x80)


func _index_local_names(members: Array) -> void:
	for m in members:
		if m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
			_local_types[cd.name] = true
			if cd.extends_type != null:
				_class_bases[cd.name] = cd.extends_type.name
			for f in cd.members:
				if f is GateAST.VarDecl and (f as GateAST.VarDecl).type != null:
					var fv: GateAST.VarDecl = f
					_field_types["%s.%s" % [cd.name, fv.name]] = fv.type
			_index_local_names(cd.members)
		elif m is GateAST.VarDecl:
			_bound_names[(m as GateAST.VarDecl).name] = true
			if (m as GateAST.VarDecl).is_const and (m as GateAST.VarDecl).value != null:
				_const_exprs[(m as GateAST.VarDecl).name] = (m as GateAST.VarDecl).value
			_index_expr_names((m as GateAST.VarDecl).value)
		elif m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			_bound_names[fd.name] = true
			for pp in fd.params:
				_bound_names[(pp as GateAST.Param).name] = true
			_index_local_names(fd.body)
		elif m is GateAST.SignalDecl:
			_bound_names[(m as GateAST.SignalDecl).name] = true
		elif m is GateAST.EnumDecl:
			var ed: GateAST.EnumDecl = m
			if ed.name != "":
				_bound_names[ed.name] = true
			else:
				for k in ed.keys:
					_bound_names[String(k)] = true
		elif m is GateAST.ForStmt:
			var fs: GateAST.ForStmt = m
			for vn in fs.var_names:
				_bound_names[String(vn)] = true
			_index_local_names(fs.body)
		elif m is GateAST.IfStmt:
			var ifs: GateAST.IfStmt = m
			_index_local_names(ifs.then_body)
			for pair in ifs.elifs:
				_index_local_names(pair[1])
			_index_local_names(ifs.else_body)
		elif m is GateAST.WhileStmt:
			_index_local_names((m as GateAST.WhileStmt).body)
		elif m is GateAST.MatchStmt:
			for br in (m as GateAST.MatchStmt).branches:
				_index_local_names(br[2])


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
		if m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
			if not cd.generic_params.is_empty():
				_generics[cd.name] = cd
			_index_generics(cd.members)


func _collect_instantiations(members: Array) -> void:
	for m in members:
		if m is GateAST.VarDecl:
			_note_type((m as GateAST.VarDecl).type)
			_note_expr((m as GateAST.VarDecl).value)
		elif m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			_note_type(fd.return_type)
			for p in fd.params:
				_note_type((p as GateAST.Param).type)
			_collect_instantiations(fd.body)
		elif m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
			_note_type(cd.extends_type)
			_collect_instantiations(cd.members)
		elif m is GateAST.ExprStmt:
			_note_expr((m as GateAST.ExprStmt).expr)
		elif m is GateAST.AssignStmt:
			_note_expr((m as GateAST.AssignStmt).value)
		elif m is GateAST.ReturnStmt:
			_note_expr((m as GateAST.ReturnStmt).value)
		elif m is GateAST.IfStmt:
			var ifs: GateAST.IfStmt = m
			_note_expr(ifs.cond)
			_collect_instantiations(ifs.then_body)
			for pair in ifs.elifs:
				_note_expr(pair[0])
				_collect_instantiations(pair[1])
			_collect_instantiations(ifs.else_body)
		elif m is GateAST.ForStmt:
			_note_expr((m as GateAST.ForStmt).iterable)
			_collect_instantiations((m as GateAST.ForStmt).body)
		elif m is GateAST.WhileStmt:
			_note_expr((m as GateAST.WhileStmt).cond)
			_collect_instantiations((m as GateAST.WhileStmt).body)
		elif m is GateAST.MatchStmt:
			for br in (m as GateAST.MatchStmt).branches:
				_collect_instantiations(br[2])
		elif m is GateAST.MultiAssign:
			for v in (m as GateAST.MultiAssign).values:
				_note_expr(v)
		elif m is GateAST.AnnotatedStmt:
			_collect_instantiations([(m as GateAST.AnnotatedStmt).stmt])


func _note_expr(e) -> void:
	if e == null or _subst.is_empty():
		return
	if e is GateAST.Ident:
		var gt: GateAST.TypeRef = (e as GateAST.Ident).generic_type
		if gt != null and not _subst.is_empty():
			_note_type(gt)
	elif e is GateAST.Call:
		_note_expr((e as GateAST.Call).callee)
		for a in (e as GateAST.Call).args:
			_note_expr(a)
	elif e is GateAST.Member:
		_note_expr((e as GateAST.Member).target)
	elif e is GateAST.Index:
		_note_expr((e as GateAST.Index).target)
		_note_expr((e as GateAST.Index).index)
	elif e is GateAST.Binary:
		_note_expr((e as GateAST.Binary).left)
		_note_expr((e as GateAST.Binary).right)
	elif e is GateAST.Unary:
		_note_expr((e as GateAST.Unary).operand)
	elif e is GateAST.Ternary:
		_note_expr((e as GateAST.Ternary).cond)
		_note_expr((e as GateAST.Ternary).if_true)
		_note_expr((e as GateAST.Ternary).if_false)
	elif e is GateAST.NullCoalesce:
		_note_expr((e as GateAST.NullCoalesce).left)
		_note_expr((e as GateAST.NullCoalesce).right)
	elif e is GateAST.CastExpr:
		_note_expr((e as GateAST.CastExpr).operand)
	elif e is GateAST.AwaitExpr:
		_note_expr((e as GateAST.AwaitExpr).operand)
	elif e is GateAST.ArrayLit:
		for el in (e as GateAST.ArrayLit).elements:
			_note_expr(el)
	elif e is GateAST.DictLit:
		for v in (e as GateAST.DictLit).values:
			_note_expr(v)
	elif e is GateAST.Lambda:
		_collect_instantiations((e as GateAST.Lambda).body)


func _substituted(t: GateAST.TypeRef) -> GateAST.TypeRef:
	if _subst.is_empty():
		return t
	var out: GateAST.TypeRef = GateAST.TypeRef.new()
	out.name = t.name
	out.array_depth = t.array_depth
	out.nullable = t.nullable
	for g in t.generic_args:
		out.generic_args.append(_substituted_arg(g))
	return out


func _substituted_arg(g: GateAST.TypeRef) -> GateAST.TypeRef:
	var shaped: GateAST.TypeRef = _param_shape(g)
	if shaped != null:
		return shaped
	var g2: GateAST.TypeRef = GateAST.TypeRef.new()
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


static func _normalized(t: GateAST.TypeRef) -> GateAST.TypeRef:
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


static func _collect_union_members(t: GateAST.TypeRef, out: Dictionary) -> void:
	for m in t.union_members:
		var mt: GateAST.TypeRef = m
		if mt.is_union() and mt.array_depth == 0 and not mt.nullable:
			_collect_union_members(mt, out)
		else:
			var key: String = GateParser._mangle_part(mt)
			if not out.has(key):
				out[key] = mt


static func _is_shape(t: GateAST.TypeRef) -> bool:
	return t != null and (t.is_union() or t.is_tuple() or t.is_func_type or t.is_dict() or t.is_set())


func _param_shape(t: GateAST.TypeRef) -> GateAST.TypeRef:
	if t == null or not _subst_types.has(t.name):
		return null
	var c: GateAST.TypeRef = GateChecker.copy_type(_subst_types[t.name])
	c.at(t.line, t.col)
	if t.array_depth > 0:
		if c.array_depth == 0 and (c.nullable or t.elem_nullable):
			c.elem_nullable = true
		c.nullable = t.nullable
		c.array_depth += t.array_depth
	else:
		c.nullable = c.nullable or t.nullable
	return c


func _subst_value(arg: GateAST.TypeRef) -> String:
	if not arg.generic_args.is_empty() and (_generics.has(arg.name) or _extern_generics.has(arg.name)):
		var bare: GateAST.TypeRef = GateAST.TypeRef.new()
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
			_collect_instantiations((entry[0] as GateAST.ClassDecl).members)
			_subst = saved
			_subst_depth = saved_depth
			_subst_types = saved_types
		if _instantiations.size() == before:
			return


func _note_type(t: GateAST.TypeRef) -> void:
	if t == null:
		return
	for g in t.generic_args:
		_note_type(g)
	if t.dict_key: _note_type(t.dict_key)
	if t.dict_value: _note_type(t.dict_value)
	if not t.generic_args.is_empty() and _generics.has(t.name):
		var st: GateAST.TypeRef = _substituted(t)
		var mangled: String = _generic_name(st)
		if not _instantiations.has(mangled):
			var cd: GateAST.ClassDecl = _generics[t.name]
			var sub: Dictionary = {}
			var depths: Dictionary = {}
			var full: Dictionary = {}
			for i in cd.generic_params.size():
				if i < st.generic_args.size():
					var ga: GateAST.TypeRef = st.generic_args[i]
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
			var cd2: GateAST.ClassDecl = _generics[t.name]
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


func _names_template_param(t: GateAST.TypeRef) -> bool:
	for g in t.generic_args:
		var ga: GateAST.TypeRef = g
		if _is_template_param(ga.name) or _names_template_param(ga):
			return true
	return false


func _is_template_param(n: String) -> bool:
	if _local_types.has(n) or _structs.has(n) or _extern_origin.has(n) \
			or GateTypes.BUILTIN.has(GateTypes.canonical(n)) or ClassDB.class_exists(n):
		return false
	for tname in _generics:
		if (_generics[tname] as GateAST.ClassDecl).generic_params.has(n):
			return true
	return false


func _generic_name(t: GateAST.TypeRef) -> String:
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
	if GateTypes.BUILTIN.has(n) or GateTypes.SHORTHAND.has(n):
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
		if not (m is GateAST.VarDecl) or not (m as GateAST.VarDecl).is_const:
			continue
		var n: String = (m as GateAST.VarDecl).name
		if n.lstrip("_").begins_with("gate_dep_"):
			continue   # one GATE wrote on an earlier build
		if _preload_const_of(n) == target:
			return n
	return ""


func _preload_const_of(name: String) -> String:
	for m in _module_members:
		if not (m is GateAST.VarDecl) or (m as GateAST.VarDecl).name != name \
				or not (m as GateAST.VarDecl).is_const:
			continue
		var v = (m as GateAST.VarDecl).value
		if v is GateAST.Call and (v as GateAST.Call).callee is GateAST.Ident \
				and ((v as GateAST.Call).callee as GateAST.Ident).name == "preload" \
				and (v as GateAST.Call).args.size() == 1 \
				and (v as GateAST.Call).args[0] is GateAST.Literal:
			var raw: String = ((v as GateAST.Call).args[0] as GateAST.Literal).raw
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
				return _script_has_func((_class_base[q] as GateAST.TypeRef).name, source_path, n, 0)
			_:
				return false
	return false


func _named_class_has_func(cls: String, n: String, depth: int) -> bool:
	if depth > 32:
		return false
	if _reg_classes.has(cls):
		for m in (_reg_classes[cls] as GateAST.ClassDecl).members:
			if m is GateAST.FuncDecl and (m as GateAST.FuncDecl).name == n:
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


func _is_class_struct(t: GateAST.TypeRef) -> bool:
	if t == null or t.nullable or t.array_depth != 0 or t.is_dict():
		return false
	var s: Dictionary = _struct_of(t.name)
	return not s.is_empty() and s["lowering"] != "vector"


func _map_type(t: GateAST.TypeRef, packed_hint := false) -> String:
	var mapped: String = _map_type_core(t, packed_hint)
	if t != null and t.nullable and not GateTypes.is_gd_nullable(mapped):
		return "Variant"
	return mapped


func _map_type_core(t: GateAST.TypeRef, packed_hint: bool) -> String:
	if t == null:
		return ""
	if t.is_path_literal:
		return t.name
	var shaped: GateAST.TypeRef = _param_shape(t)
	if shaped != null:
		return _map_type(shaped, packed_hint)
	if _subst.has(t.name) and _subst[t.name] != t.name:
		var concrete: GateAST.TypeRef = GateAST.TypeRef.new()
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


func _map_dict_value(t: GateAST.TypeRef) -> String:
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
		var elem_t: GateAST.TypeRef = GateAST.TypeRef.new()
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


func _default_for(t: GateAST.TypeRef, packed_hint: bool) -> String:
	var shaped: GateAST.TypeRef = _param_shape(t)
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
		var lowered: GateAST.TypeRef = GateAST.TypeRef.new()
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


func _prec_of(e) -> int:
	if e is GateAST.Ident and _rename_prec.has((e as GateAST.Ident).name) \
			and _ident_renames.has((e as GateAST.Ident).name):
		return int(_rename_prec[(e as GateAST.Ident).name])
	if e is GateAST.Binary:
		var low: String = _binary_lowering(e)
		if low == "call":
			return PREC_ATOM
		if low == "not":
			return PREC_NOT
		if (e as GateAST.Binary).op == "not in":
			return PREC_NOT   # printed as `not (a in b)`
		return PREC.get((e as GateAST.Binary).op, PREC_ATOM)
	if e is GateAST.Unary:
		return PREC_NOT if (e as GateAST.Unary).op == "not" else PREC_UNARY
	if e is GateAST.IsExpr:
		return PREC_TYPE_TEST
	if e is GateAST.AwaitExpr:
		return PREC_AWAIT
	if e is GateAST.Lambda:
		return 0
	return PREC_ATOM

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
		if m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			_declared_funcs[fd.name] = true
			if fd.return_type != null and fd.return_type.array_depth == 0:
				_func_returns[fd.name] = fd.return_type.name
		elif m is GateAST.ClassDecl:
			_index_declared_funcs((m as GateAST.ClassDecl).members)


func _flow_name(e) -> String:
	if not (e is GateAST.Expr) or (e as GateAST.Expr).flow_type == null:
		return ""
	var t: GateAST.TypeRef = (e as GateAST.Expr).flow_type
	if (t.array_depth != 0 or t.is_dict() or t.is_set() or t.is_union() or t.is_tuple()
			or t.is_func_type):
		return ""
	if not t.generic_args.is_empty():
		if _generics.has(t.name):
			return _generic_name(_substituted(t))
		return t.name if GateTypes.canonical(t.name) == "PackedScene" else ""
	return t.name


func _left_spine_types(b: GateAST.Binary) -> Dictionary:
	var spine: Array = []
	var cur: GateAST.Binary = b
	while true:
		spine.append(cur)
		if not (cur.left is GateAST.Binary):
			break
		cur = cur.left
	var out: Dictionary = {}
	var t: String = _static_type_of((spine[spine.size() - 1] as GateAST.Binary).left)
	for i in range(spine.size() - 1, -1, -1):
		var node: GateAST.Binary = spine[i]
		out[node] = t
		var fn: String = _flow_name(node)
		t = fn if fn != "" else ("" if t == "" else _struct_op_type(t, node.op))
	return out


func _static_type_of(e) -> String:
	var fn: String = "" if (e is GateAST.NullCoalesce or e is GateAST.Ternary) else _flow_name(e)
	if fn != "":
		return fn
	if e is GateAST.Ident:
		var inm: String = (e as GateAST.Ident).name
		if _var_depths.get(inm, 0) > 0:
			return ""
		return _var_types.get(inm, "")
	if e is GateAST.Member:
		var m: GateAST.Member = e
		if m.target is GateAST.SelfExpr:
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
			if ft != null and (ft as GateAST.TypeRef).array_depth == 0:
				return (ft as GateAST.TypeRef).name
		return ""
	if e is GateAST.Ternary:
		var tt: GateAST.Ternary = e
		if _is_null_lit(tt.if_false):
			return _static_type_of(tt.if_true)
		if _is_null_lit(tt.if_true):
			return _static_type_of(tt.if_false)
		return _both_arms(_static_type_of(tt.if_true), _static_type_of(tt.if_false))
	if e is GateAST.NullCoalesce:
		return _both_arms(_static_type_of((e as GateAST.NullCoalesce).left),
			_static_type_of((e as GateAST.NullCoalesce).right))
	if e is GateAST.Binary:
		var lb: GateAST.Binary = e
		return _struct_op_type(String(_left_spine_types(lb)[lb]), lb.op)
	if e is GateAST.CastExpr:
		var ct: GateAST.TypeRef = (e as GateAST.CastExpr).type
		return ct.name if (ct.array_depth == 0 and not ct.is_union() and not ct.is_tuple()
			and not ct.is_dict()) else ""
	if e is GateAST.Index:
		var ix: GateAST.Index = e
		if ix.target is GateAST.Ident:
			var slot: Variant = GateChecker.fold_int(ix.index, _const_exprs)
			var tup: GateAST.TypeRef = _tuple_tref(_declared_tref(ix.target)) if slot != null else null
			if tup != null:
				var at: int = int(slot) if int(slot) >= 0 else tup.tuple_elems.size() + int(slot)
				var et: GateAST.TypeRef = _elem_tref_of(ix.target, at)
				return et.name if et != null and et.array_depth == 0 and not et.is_union() else ""
		if ix.target is GateAST.Ident:
			var an: String = (ix.target as GateAST.Ident).name
			if _var_dict_values.has(an):
				return _var_dict_values[an]
			if _var_depths.get(an, 0) == 1:
				return _var_types.get(an, "")
		return ""
	if e is GateAST.Call:
		var c: GateAST.Call = e
		if _is_scene_preload(c):
			return "PackedScene"
		if c.callee is GateAST.Ident:
			var cn: String = (c.callee as GateAST.Ident).name
			if not _struct_of(cn).is_empty():
				return cn
			if _func_returns.has(cn):
				return _func_returns[cn]
			var ctor: String = cn if GateTypes.shadowed.has(cn) else String(CTOR_SHORTHAND.get(cn, cn))
			if VECTOR_CTORS.has(ctor) and not _shorthand_taken(cn):
				return ctor   # `Vector2i(5, 10)`, a Vector struct on a recompile
		if c.callee is GateAST.Member:
			var cm: GateAST.Member = c.callee
			if cm.name == "new" and cm.target is GateAST.Ident:
				return (cm.target as GateAST.Ident).name
			if cm.name == "_gate_copy" and c.args.is_empty():
				return _static_type_of(cm.target)   # GATE's own copy, on a recompile
			if cm.name.begins_with("_gate_value") and c.args.size() == 1:
				return _static_type_of(c.args[0])   # the guard hands back what it was given
			if _is_namespace_ref(cm.target) and not _struct_of(cm.name).is_empty():
				return _class_ref_text(cm)   # `RcLib.Pt(1, 2)`, a struct through a qualifier
			var recv_t: String = _static_type_of(cm.target)
			var rst: Dictionary = _struct_of(recv_t) if recv_t != "" else {}
			if rst.has("decl"):
				var mrt: GateAST.TypeRef = _struct_method_return(rst, cm.name)
				if mrt != null:
					return mrt.name
			if cm.name == "new" and cm.target is GateAST.Member:
				var root = cm.target
				while root is GateAST.Member:
					root = (root as GateAST.Member).target
				if root is GateAST.Ident and (root as GateAST.Ident).name.contains("gate_dep_"):
					return (cm.target as GateAST.Member).name   # another file's class, through its preload
				var qpath: String = _class_ref_text(cm.target)
				if qpath != "" and not _struct_of(qpath).is_empty():
					return qpath   # `RcLib.Pt.new(...)`, this struct through a qualifier
			if cm.name != "new" and recv_t != "":
				var mrt2: GateAST.TypeRef = _member_tref(_name_key(_scope_class, recv_t), cm.name, true)
				if mrt2 != null and mrt2.array_depth == 0 and not mrt2.is_union() and not mrt2.is_tuple():
					return mrt2.name   # a class's own method, `__op_add` on a recompile included
	return ""


func _generic_field_tref(inst: String, field: String) -> GateAST.TypeRef:
	if _demangled.is_empty():
		_demangled["."] = null
		for gt in _project_generic_uses:
			_demangled[GateParser.mangle_generic(gt)] = gt
	var use = _demangled.get(inst, null)
	if use == null or _reg_whole == null or not ("generics" in _reg_whole):
		return null
	var cd = (_reg_whole.generics as Dictionary).get((use as GateAST.TypeRef).name, null)
	if not (cd is GateAST.ClassDecl):
		return null
	for m in (cd as GateAST.ClassDecl).members:
		if m is GateAST.VarDecl and (m as GateAST.VarDecl).name == field and (m as GateAST.VarDecl).type != null:
			var ft: GateAST.TypeRef = (m as GateAST.VarDecl).type
			var gi: int = (cd as GateAST.ClassDecl).generic_params.find(ft.name)
			if gi < 0:
				return ft
			if ft.array_depth == 0 and gi < (use as GateAST.TypeRef).generic_args.size():
				return (use as GateAST.TypeRef).generic_args[gi]
			return null
	return null


func _struct_op_type(lt: String, op: String) -> String:
	if lt == "" or not (_ops_of(lt) as Dictionary).has(op):
		return ""
	var ops_owner: String = lt if _class_op_fds.has(lt) else _last_part(lt)
	if _class_op_fds.has(ops_owner):
		var ort: GateAST.TypeRef = ((_class_op_fds[ops_owner] as Dictionary)[op] as GateAST.FuncDecl).return_type
		return ort.name if (ort != null and ort.array_depth == 0 and not ort.is_union()
			and not ort.is_tuple()) else ""
	var st: Dictionary = _struct_of(lt)
	if st.is_empty() or not st.has("decl"):
		return ""
	var fname: String = String((_ops_of(lt) as Dictionary)[op])
	for m in (st["decl"] as GateAST.ClassDecl).members:
		if m is GateAST.FuncDecl and (m as GateAST.FuncDecl).name == fname:
			var rt: GateAST.TypeRef = (m as GateAST.FuncDecl).return_type
			if rt != null and rt.array_depth == 0 and not rt.is_union() and not rt.is_tuple():
				return rt.name
	return ""


func _struct_method_return(st: Dictionary, method: String) -> GateAST.TypeRef:
	for m in (st["decl"] as GateAST.ClassDecl).members:
		if m is GateAST.FuncDecl and (m as GateAST.FuncDecl).name == method:
			var rt: GateAST.TypeRef = (m as GateAST.FuncDecl).return_type
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
		if not _class_bases.has(c):
			break
		c = String(_class_bases[c])
	return false


func _resolve_overload(name: String, arity: int) -> String:
	if not _overloads.has(name):
		return ""
	var by_arity: Dictionary = _overloads[name]
	if by_arity.has(arity):
		return by_arity[arity]
	return by_arity.get(GateChecker.REST_ARITY, "")


func _soa_name(e) -> String:
	if e is GateAST.Ident and _soa.has((e as GateAST.Ident).name):
		return (e as GateAST.Ident).name
	if (e is GateAST.Member and (e as GateAST.Member).target is GateAST.SelfExpr
			and not (e as GateAST.Member).safe and _soa.has((e as GateAST.Member).name)):
		return (e as GateAST.Member).name
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


func _is_simple(e) -> bool:
	if e is GateAST.Ident or e is GateAST.Literal or e is GateAST.SelfExpr:
		return true
	if e is GateAST.Member:
		return not (e as GateAST.Member).safe and _is_simple((e as GateAST.Member).target)
	return false


func _annotated_with(annotations: Array, name: String) -> bool:
	for a in annotations:
		if (a as GateAST.Annotation).name == name:
			return true
	return false


func _has_annotation(vd: GateAST.VarDecl, name: String) -> bool:
	for a in vd.annotations:
		if (a as GateAST.Annotation).name == name:
			return true
	return false

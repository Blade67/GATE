@tool
extends "res://addons/gate/compiler/emitter_out.gd"

## Emitter layer 2: naming, GATE -> GDScript type mapping, and precedence.


func _index_structs(members: Array) -> void:
	for m in members:
		if not (m is GateAST.ClassDecl):
			continue
		var cd: GateAST.ClassDecl = m
		if cd.form == "struct":
			var names: Array = []
			var types: Array = []
			var defaults: Array = []
			var typerefs: Array = []
			for f in cd.members:
				if f is GateAST.VarDecl:
					names.append((f as GateAST.VarDecl).name)
					var vt: GateAST.VarDecl = f
					types.append(vt.type.name if vt.type != null else "Variant")
					typerefs.append(vt.type)
					defaults.append(vt.value)
			_structs[cd.name] = {
				"name": cd.name,
				"lowering": cd.lowering,
				"vector": cd.vector_type,
				"fields": names,
				"types": types,
				"typerefs": typerefs,
				"defaults": defaults,
			}
			var ops: Dictionary = {}
			for f2 in cd.members:
				if f2 is GateAST.FuncDecl and (f2 as GateAST.FuncDecl).is_operator:
					var ofd: GateAST.FuncDecl = f2
					ops[ofd.operator_symbol] = ofd.name
			if not ops.is_empty():
				_struct_ops[cd.name] = ops
		_index_structs(cd.members)


func set_registry(reg, self_path: String) -> void:
	_self_path = self_path
	if reg == null:
		return
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


func _index_external_structs() -> void:
	for name in _external_structs:
		if _structs.has(name):
			continue
		var cd: GateAST.ClassDecl = _external_structs[name]
		var names: Array = []
		var types: Array = []
		var defaults: Array = []
		var typerefs: Array = []
		for f in cd.members:
			if f is GateAST.VarDecl:
				var vd: GateAST.VarDecl = f
				names.append(vd.name)
				types.append(vd.type.name if vd.type != null else "Variant")
				typerefs.append(vd.type)
				defaults.append(vd.value)
		_structs[name] = {
			"name": name,
			"lowering": cd.lowering,
			"vector": cd.vector_type,
			"fields": names,
			"types": types,
			"typerefs": typerefs,
			"defaults": defaults,
		}
		var xops: Dictionary = {}
		for f2 in cd.members:
			if f2 is GateAST.FuncDecl and (f2 as GateAST.FuncDecl).is_operator:
				var ofd: GateAST.FuncDecl = f2
				xops[ofd.operator_symbol] = ofd.name
		if not xops.is_empty():
			_struct_ops[name] = xops


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
			_collect_instantiations(ifs.then_body)
			for pair in ifs.elifs:
				_collect_instantiations(pair[1])
			_collect_instantiations(ifs.else_body)
		elif m is GateAST.ForStmt:
			_collect_instantiations((m as GateAST.ForStmt).body)
		elif m is GateAST.WhileStmt:
			_collect_instantiations((m as GateAST.WhileStmt).body)


func _note_expr(e) -> void:
	if e == null:
		return
	if e is GateAST.Ident:
		var n: String = (e as GateAST.Ident).name
		if n.begins_with("__") and _pending_generic.has(n):
			pass
	elif e is GateAST.Call:
		_note_expr((e as GateAST.Call).callee)
		for a in (e as GateAST.Call).args:
			_note_expr(a)
	elif e is GateAST.Member:
		_note_expr((e as GateAST.Member).target)


func _substituted(t: GateAST.TypeRef) -> GateAST.TypeRef:
	if _subst.is_empty():
		return t
	var out: GateAST.TypeRef = GateAST.TypeRef.new()
	out.name = t.name
	out.array_depth = t.array_depth
	out.nullable = t.nullable
	for g in t.generic_args:
		var g2: GateAST.TypeRef = GateAST.TypeRef.new()
		g2.name = _subst.get(g.name, g.name)
		g2.array_depth = g.array_depth
		g2.nullable = g.nullable
		for gg in g.generic_args:
			g2.generic_args.append(gg)
		out.generic_args.append(g2)
	return out


func _close_instantiations() -> void:
	for _pass in 8:
		var before: int = _instantiations.size()
		for key in _instantiations.keys():
			var entry: Array = _instantiations[key]
			var saved: Dictionary = _subst
			var saved_depth: Dictionary = _subst_depth
			_subst = entry[1]
			_subst_depth = entry[2] if entry.size() > 2 else {}
			_collect_instantiations((entry[0] as GateAST.ClassDecl).members)
			_subst = saved
			_subst_depth = saved_depth
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
			for i in cd.generic_params.size():
				if i < st.generic_args.size():
					var garg: String = st.generic_args[i].name
					sub[cd.generic_params[i]] = (garg if GateTypes.PACKED.has(garg)
						else GateTypes.canonical(garg))
					depths[cd.generic_params[i]] = st.generic_args[i].array_depth
			var identity: bool = false
			for k in sub:
				if sub[k] == k:
					identity = true
			if not identity:
				_instantiations[mangled] = [cd, sub, depths]
		else:
			var prev: Array = _instantiations[mangled]
			var prev_sub: Dictionary = prev[1]
			var same: bool = true
			var cd2: GateAST.ClassDecl = _generics[t.name]
			for i2 in cd2.generic_params.size():
				if i2 >= st.generic_args.size():
					continue
				var key: String = cd2.generic_params[i2]
				if prev_sub.get(key, "") != GateTypes.canonical(st.generic_args[i2].name):
					same = false
			if not same and prev[0] == cd2:
				diagnostics.error(
					"two different instantiations of '%s' both mangle to '%s'"
						% [t.name, mangled], t.line, t.col,
					"the generated class name joins the type arguments with '_', so "
					+ "argument names that already contain '_' can collide. Rename one "
					+ "of the types involved.")


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
	return _structs.get(type_name, {})


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
	if _subst.has(t.name) and _subst[t.name] != t.name:
		var concrete: GateAST.TypeRef = GateAST.TypeRef.new()
		concrete.name = _subst[t.name]
		concrete.array_depth = t.array_depth + int(_subst_depth.get(t.name, 0))
		concrete.nullable = t.nullable
		return _map_type(concrete, packed_hint)
	if not t.generic_args.is_empty() and _extern_generics.has(t.name):
		var ga: String = _extern_generic_alias(t.name)
		return "%s.%s" % [ga, _generic_name(_substituted(t))]
	if not t.generic_args.is_empty() and _generics.has(t.name):
		return _generic_name(_substituted(t))
	if t.is_dict():
		return "Dictionary[%s, %s]" % [_map_type(t.dict_key), _map_dict_value(t.dict_value)]
	if t.generic_args.is_empty() and _is_erased_type(t.name):
		return "Array" if t.array_depth > 0 else "Variant"
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
		if t.array_depth == 1 and GateTypes.has_packed(base):
			return GateTypes.packed_for(base)
		if t.array_depth > 0:
			return "Array[%s]" % base
		return base
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
	if t != null and not t.nullable and t.array_depth == 0 and not t.is_dict() and mapped != "" and mapped != t.name:
		var lowered: GateAST.TypeRef = GateAST.TypeRef.new()
		lowered.name = mapped
		return GateTypes.default_value(lowered)
	if t != null and not t.nullable and t.array_depth == 0 and not t.is_dict():
		var sd: Dictionary = _struct_of(t.name)
		if not sd.is_empty() and sd["lowering"] != "vector" and mapped != "":
			return "%s.new()" % mapped
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
	if e is GateAST.Binary:
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


func _static_type_of(e) -> String:
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
			if ft != null and (ft as GateAST.TypeRef).array_depth == 0:
				return (ft as GateAST.TypeRef).name
		return ""
	if e is GateAST.Ternary:
		var tt: GateAST.Ternary = e
		var a: String = _static_type_of(tt.if_true)
		return a if a != "" and a == _static_type_of(tt.if_false) else ""
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
		if c.callee is GateAST.Member:
			var cm: GateAST.Member = c.callee
			if cm.name == "new" and cm.target is GateAST.Ident:
				return (cm.target as GateAST.Ident).name
	return ""


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

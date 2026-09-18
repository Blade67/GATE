@tool
class_name GateEmitter
extends "res://addons/gate/compiler/emitter_expr.gd"

## Emitter layer 4: statements, declarations, and the module.
##
## Comments are dropped on re-read - don't emit them. Same for anything else this
## can't read back: it breaks the fixed point.


func emit(mod: GateAST._Module, diags: GateDiagnostics, path: String) -> Dictionary:
	diagnostics = diags
	source_path = path
	_out = []
	_map = []
	_indent = 0
	_tmp = 0
	_structs.clear()
	_var_types.clear()
	_var_depths.clear()
	_struct_ops.clear()
	_class_op_fds.clear()
	_soa.clear()
	_soa_cursors.clear()
	_soa_fields.clear()
	_needs_iface_helper = false
	_iface_scopes = []
	_preload_targets.clear()
	_pending_line_src = []
	_generic_renames.clear()
	_enum_names.clear()
	_in_namespace = false
	_warned_narrow = false
	_warned_packed = false

	_declared_funcs.clear()
	_func_returns.clear()
	_field_types.clear()
	_class_bases.clear()
	_var_dict_values.clear()
	_fn_locals.clear()
	_tmp_names.clear()
	_plain_fields.clear()
	_class_field_types.clear()
	_class_decls.clear()
	_class_parent.clear()
	_class_base.clear()
	_class_funcs.clear()
	_class_inits.clear()
	_class_fields.clear()
	_class_priv.clear()
	_observable_fields.clear()
	_mutators.clear()
	_key_errors.clear()
	_init_helper_scopes.clear()
	_scope_class = "."
	_swizzle_exempt = null
	_assigned_names = null
	_no_hoist = ""
	_cur_base = mod.extends_type.name if mod.extends_type != null else ""
	_cur_class = ""
	_self_class_name = mod.class_name_decl
	_class_base["."] = mod.extends_type
	_index_plain_fields(mod.members, ".")
	_index_declared_funcs(mod.members)
	_module_members = mod.members
	_scope_names.clear()
	_index_structs(mod.members)
	_index_external_structs(GateChecker.own_names(mod.members))
	_index_generics(mod.members)
	_index_local_names(mod.members)
	_index_const_vectors(mod.members, ".")
	_index_class_ops(mod.members)
	_struct_user = _file_uses_struct(mod)
	_fn_params = {}
	_demangled.clear()
	_apply_base_chain()
	_collect_instantiations(mod.members)
	for gt in mod.generic_uses:
		_note_type(gt)
	for pgt in _project_generic_uses:
		if _generics.has(pgt.name):
			_note_type(pgt)
	_close_instantiations()
	_mono_template.clear()
	for mg in _instantiations:
		_mono_template[mg] = ((_instantiations[mg] as Array)[0] as GateAST._ClassDecl).name

	for hl in HEADER_LINES:
		_line((hl as String) % path if (hl as String).contains("%s") else hl, 1)
	for ha in mod.header_annotations:
		_emit_annotation(ha)
	if mod.class_name_decl != "":
		var cn: String = "class_name " + mod.class_name_decl
		_line(cn, mod.class_name_line)
	if mod.extends_type != null:
		var ext: String = GateTypes.resolve(mod.extends_type, diagnostics)
		var xa: String = "" if (mod.extends_type.is_path_literal
			or not mod.extends_type.generic_args.is_empty()) else _extern_alias(mod.extends_type.name)
		if xa != "":
			ext = "%s.%s" % [xa, mod.extends_type.name]
		_line("extends " + ext, mod.extends_line)
	if mod.class_name_decl != "" or mod.extends_type != null:
		_blank_line(mod.extends_line)

	var preload_at: int = _out.size()

	for m in mod.members:
		_emit_member(m)

	_emit_monomorphised()

	if _needs_iface_helper:
		_emit_iface_helper()

	if _init_helper_scopes.has("."):
		_emit_init_helper()

	var pl: Array = _preload_lines()
	if not pl.is_empty():
		pl.append("")
		for i in range(pl.size() - 1, -1, -1):
			_out.insert(preload_at, pl[i])
			_map.insert(preload_at, 1)

	while _out.size() > 0 and String(_out[_out.size() - 1]).strip_edges() == "":
		_out.remove_at(_out.size() - 1)
		if _map.size() > _out.size():
			_map.remove_at(_map.size() - 1)

	return {
		"source": "\n".join(_out) + "\n",
		"map": _map,
		"deps": _preload_targets.keys(),
	}


func _file_uses_struct(mod: GateAST._Module) -> bool:
	var names: Dictionary = {}
	for sn in _structs:
		var st: Dictionary = _structs[sn]
		if st.get("lowering", "") == "vector":
			continue
		if String(st.get("scope", "")) != "":
			return true
		var short: String = String(sn).get_slice(".", String(sn).get_slice_count(".") - 1)
		if _src_text == "" or _src_text.contains(short):
			names[short] = true
	if names.is_empty():
		return false
	if _src_text != "":
		var word: RegEx = RegEx.create_from_string("(?<![A-Za-z0-9_])(%s)(?![A-Za-z0-9_])" % "|".join(names.keys()))
		if word != null and word.search(_src_text) == null:
			return false
	return _names_struct(mod.members, names, GateChecker.block_names(mod.members))


func _names_struct(node, names: Dictionary, hidden: Dictionary) -> bool:
	if node is Array:
		for x in node:
			if _names_struct(x, names, hidden):
				return true
		return false
	if not (node is Object) or node == null or (node as Object).get_script() == null:
		return false
	if node is GateAST._TypeRef:
		var tn: String = (node as GateAST._TypeRef).name
		if names.has(tn.get_slice(".", tn.get_slice_count(".") - 1)):
			return true
	elif node is GateAST._Ident:
		var iname: String = (node as GateAST._Ident).name
		if names.has(iname) and not hidden.has(iname):
			return true
	elif node is GateAST._Member and names.has((node as GateAST._Member).name) \
			and (node as GateAST._Member).target is GateAST._Ident:
		return true
	elif node is GateAST._ClassDecl:
		hidden = hidden.merged(GateChecker.block_names((node as GateAST._ClassDecl).members))
	elif node is GateAST._FuncDecl or node is GateAST._Lambda:
		var inner: Dictionary = {}
		_bound_in(node, inner)
		hidden = hidden.merged(inner)
	for prop in (node as Object).get_property_list():
		var pn: String = prop["name"]
		if pn in ["script", "Built-in script", "RefCounted", "Object", "flow_type"]:
			continue
		var v = (node as Object).get(pn)
		if (v is Array or (v is Object and v != null)) and _names_struct(v, names, hidden):
			return true
	return false


static func _bound_in(node, out: Dictionary) -> void:
	if node is Array:
		for x in node:
			_bound_in(x, out)
		return
	if not (node is Object) or node == null or (node as Object).get_script() == null:
		return
	if node is GateAST._VarDecl:
		out[(node as GateAST._VarDecl).name] = true
	elif node is GateAST._Param:
		out[(node as GateAST._Param).name] = true
	elif node is GateAST._ForStmt:
		for vn in (node as GateAST._ForStmt).var_names:
			out[String(vn)] = true
	elif node is GateAST._MultiAssign and (node as GateAST._MultiAssign).declares:
		for t in (node as GateAST._MultiAssign).targets:
			if t is GateAST._Ident:
				out[(t as GateAST._Ident).name] = true
	elif node is GateAST._MatchStmt:
		for br in (node as GateAST._MatchStmt).branches:
			out.merge(GateChecker.pattern_bindings(br[0]))
	for prop in (node as Object).get_property_list():
		var pn: String = prop["name"]
		if pn in ["script", "Built-in script", "RefCounted", "Object", "flow_type"]:
			continue
		var v = (node as Object).get(pn)
		if v is Array or (v is Object and v != null):
			_bound_in(v, out)


func _emit_monomorphised() -> void:
	for mangled in _instantiations:
		var pair: Array = _instantiations[mangled]
		var cd: GateAST._ClassDecl = pair[0]
		_subst = pair[1]
		_subst_depth = pair[2] if pair.size() > 2 else {}
		_subst_types = pair[3] if pair.size() > 3 else {}
		var saved_name: String = cd.name
		_mono_scope = ""
		for k in _class_decls:
			if _class_decls[k] == cd:
				_mono_scope = String(k)
				break
		cd.name = mangled
		var saved_params: Array = cd.generic_params
		cd.generic_params = []
		_emit_class(cd)
		cd.name = saved_name
		cd.generic_params = saved_params
		_subst = {}
		_subst_depth = {}
		_subst_types = {}


func _emit_member(m) -> void:
	if m is GateAST._TypeAliasDecl:
		return   # substituted away by the checker; nothing to emit
	if m is GateAST._Stmt and (m as GateAST._Stmt).injected:
		_blank_line(m.line)
	elif m != null and "line" in m:
		_blank_gap(m.line)
	if m is GateAST._CommentStmt:
		_line((m as GateAST._CommentStmt).text, m.line)
	elif m is GateAST._ClassDecl:
		_emit_class(m)
	elif m is GateAST._FuncDecl:
		_emit_func(m)
	elif m is GateAST._VarDecl:
		_emit_var(m)
	elif m is GateAST._SignalDecl:
		_emit_signal(m)
	elif m is GateAST._EnumDecl:
		_emit_enum(m)
	elif m is GateAST._RawStmt:
		_emit_raw(m)
	else:
		_emit_statement(m)


func _emit_raw(r: GateAST._RawStmt) -> void:
	var lines: PackedStringArray = r.text.split("\n")
	var i: int = 0
	for l in lines:
		var stripped: String = l.strip_edges(true, false)
		if stripped == "":
			_line("", r.line + i)
		else:
			_out.append(l)
			_map.append(r.line + i)
		i += 1


func _emit_signal(s: GateAST._SignalDecl) -> void:
	for a in s.annotations:
		_emit_annotation(a)
	var parts: PackedStringArray = PackedStringArray()
	for p in s.params:
		var pp: GateAST._Param = p
		if pp.type != null:
			parts.append("%s: %s" % [pp.name, _map_type(pp.type)])
		else:
			parts.append(pp.name)
	if s.params.is_empty():
		_line("signal %s" % s.name, s.line)
	else:
		_line("signal %s(%s)" % [s.name, ", ".join(parts)], s.line)


func _emit_enum(e: GateAST._EnumDecl) -> void:
	for a in e.annotations:
		_emit_annotation(a)
	var parts: PackedStringArray = PackedStringArray()
	for i in e.keys.size():
		if i < e.values.size() and e.values[i] != null:
			parts.append("%s = %s" % [e.keys[i], _expr(e.values[i])])
		else:
			parts.append(e.keys[i])
	_line("enum %s { %s }" % [e.name, ", ".join(parts)], e.line)


static func _gate_written(cd: GateAST._ClassDecl) -> bool:
	for m in cd.members:
		if m is GateAST._FuncDecl and (m as GateAST._FuncDecl).name == "_gate_copy":
			return true
	return false


func _emit_class(cd: GateAST._ClassDecl) -> void:
	match cd.form:
		"interface":
			_emit_interface_doc(cd)
			return
		"trait":
			return
		"struct":
			_emit_struct(cd)
			return
		"namespace":
			_emit_namespace(cd)
			return
		_:
			pass

	if not cd.generic_params.is_empty() and _subst.is_empty():
		return

	var head: String = "class %s" % cd.name
	if cd.extends_type != null:
		head += " extends " + _map_type(cd.extends_type)
	for ca in cd.annotations:
		_emit_annotation(ca)
	_line(head + ":", cd.line)
	_indent += 1
	var saved_class: String = _cur_class
	var saved_base: String = _cur_base
	var saved_scope: String = _scope_class
	_cur_class = cd.name
	_cur_base = cd.extends_type.name if cd.extends_type != null else ""
	_scope_class = _mono_scope if _mono_scope != "" else _qjoin(saved_scope, cd.name)
	_mono_scope = ""
	var saved_types: Dictionary = _var_types.duplicate()
	var saved_depths: Dictionary = _var_depths.duplicate()
	var saved_dicts: Dictionary = _var_dict_values.duplicate()
	var saved_gen: bool = _in_gate_helper
	_in_gate_helper = saved_gen or _gate_written(cd)
	_emit_interface_marker(cd)
	_iface_scopes.append(false)
	var before: int = _out.size()
	for m in cd.members:
		_emit_member(m)
	_close_class_scope()
	if _init_helper_scopes.has(_scope_class):
		_emit_init_helper(_indent)
	if not _emitted_code_since(before):
		_line("pass", cd.line)
	_var_types = saved_types
	_var_depths = saved_depths
	_var_dict_values = saved_dicts
	_in_gate_helper = saved_gen
	_cur_base = saved_base
	_cur_class = saved_class
	_scope_class = saved_scope
	_indent -= 1
	_blank_line(cd.line)


func _warn_narrowed(what: String, types: Array, line: int, col: int) -> void:
	if _warned_narrow:
		return
	var narrowed: PackedStringArray = PackedStringArray()
	for t in types:
		if GateTypes.narrows_width(String(t)) and not narrowed.has(String(t)):
			narrowed.append(String(t))
	if narrowed.is_empty():
		return
	_warned_narrow = true
	diagnostics.warn(
		"%s stores its %s field(s) as 32-bit" % [what, " and ".join(narrowed)],
		line, col,
		"that is what makes the packing worth doing, and it is what an engine "
		+ "stores a position in - but GDScript's own float and int are 64-bit, so "
		+ "`1e300` reads back as `inf`. Write `f64` / `i64` instead to keep the "
		+ "full width (the struct is then emitted as a class). Reported once per file.")


func _emit_interface_doc(_cd: GateAST._ClassDecl) -> void:
	pass


func _emit_interface_marker(cd: GateAST._ClassDecl) -> void:
	if cd.interface_names.is_empty():
		return
	var quoted: PackedStringArray = PackedStringArray()
	for n in cd.interface_names:
		quoted.append("\"%s\"" % n)
	_line("const __gate_impl := [%s]" % ", ".join(quoted), cd.line)


func _emit_namespace(cd: GateAST._ClassDecl) -> void:
	_line("class %s:" % cd.name, cd.line)
	_indent += 1
	var saved_ns: bool = _in_namespace
	_iface_scopes.append(false)
	var saved_scope: String = _scope_class
	_scope_class = _qjoin(saved_scope, cd.name)
	var before: int = _out.size()
	for m in cd.members:
		# The namespace's own members are static so `Ns.f()` reaches them. A type
		# declared inside it is a real type, and its members are not.
		_in_namespace = not (m is GateAST._ClassDecl)
		_emit_member(m)
	_in_namespace = saved_ns
	_close_class_scope()
	if _init_helper_scopes.has(_scope_class):
		_emit_init_helper(_indent)
	_scope_class = saved_scope
	if not _emitted_code_since(before):
		_line("pass", cd.line)
	_indent -= 1
	_blank_line(cd.line)


func _emit_code_marker() -> void:
	pass


func _emitted_code_since(mark: int) -> bool:
	for i in range(mark, _out.size()):
		var t: String = String(_out[i]).strip_edges()
		if t != "" and not t.begins_with("#"):
			return true
	return false


func _emit_struct(cd: GateAST._ClassDecl) -> void:
	if cd.lowering == "vector":
		var ftypes: Array = []
		for f in cd.members:
			if f is GateAST._VarDecl and (f as GateAST._VarDecl).type != null:
				ftypes.append((f as GateAST._VarDecl).type.name)
		_warn_narrowed("struct '%s' lowers to %s, which" % [cd.name, cd.vector_type],
			ftypes, cd.line, cd.col)
		return

	_line("class %s extends RefCounted:" % cd.name, cd.line)
	_indent += 1
	_emit_interface_marker(cd)
	_iface_scopes.append(false)
	var fields: Array = GateChecker.struct_fields(cd)
	var saved_scope: String = _scope_class
	var saved_types: Dictionary = _var_types.duplicate()
	var saved_depths: Dictionary = _var_depths.duplicate()
	var saved_dicts: Dictionary = _var_dict_values.duplicate()
	_scope_class = _qjoin(saved_scope, cd.name)
	for m in cd.members:
		_bare_fields = fields.has(m)
		_emit_member(m)
		_bare_fields = false
	if not fields.is_empty():
		_emit_struct_init(cd, fields)
	if _init_helper_scopes.has(_scope_class):
		_emit_init_helper(_indent)
	_scope_class = saved_scope
	_var_types = saved_types
	_var_depths = saved_depths
	_var_dict_values = saved_dicts
	_close_class_scope()
	_indent -= 1
	_blank_line(cd.line)


func _emit_struct_init(cd: GateAST._ClassDecl, fields: Array) -> void:
	var st: Dictionary = _struct_of(cd.name)
	var member_names: Array = []
	for m in cd.members:
		if "name" in m:
			member_names.append(String(m.name))
	var pre: String = _free_prefix(member_names, "p_")
	var renames: Dictionary = {}
	var ps: PackedStringArray = PackedStringArray()
	for f in fields:
		var fv: GateAST._VarDecl = f
		var ft: String = _map_type(fv.type) if fv.type != null else "Variant"
		var dv: String = "null"
		if fv.value != null:
			dv = _render_in_struct(fv.value, renames)
		elif fv.type != null:
			dv = _default_for(fv.type, false)
		ps.append("%s%s: %s = %s" % [pre, fv.name, ft, dv])
		renames[fv.name] = pre + fv.name
	_blank_line(cd.line)
	_line("func _init(%s) -> void:" % ", ".join(ps), cd.line)
	_indent += 1
	for f2 in fields:
		_line("%s = %s%s" % [(f2 as GateAST._VarDecl).name, pre, (f2 as GateAST._VarDecl).name], cd.line)
	_indent -= 1

	for i in fields.size():
		if st.is_empty() or _default_kind(st, i) != "helper":
			continue
		var hv: GateAST._VarDecl = fields[i]
		var hp: PackedStringArray = PackedStringArray()
		var hr: Dictionary = {}
		for r in _default_refs(st, i):
			var rv: GateAST._VarDecl = fields[(st["fields"] as Array).find(r)]
			hp.append("%s%s%s" % [pre, r, ": " + _map_type(rv.type) if rv.type != null else ""])
			hr[r] = pre + r
		var head: String = "static func %s(%s)" % [_default_helper(st, i), ", ".join(hp)]
		if hv.type != null:
			head += " -> " + _map_type(hv.type)
		_blank_line(cd.line)
		_line(head + ":", hv.line)
		_indent += 1
		_line("return " + _render_in_struct(hv.value, hr), hv.line)
		_indent -= 1

	if not st.is_empty() and _has_instance_default(st):
		_emit_keyed_builder(cd, fields, st, member_names, pre)

	var deep: String = _deep_helper(st) if not st.is_empty() else _free_name(member_names, "_gate_deep")
	var copies: PackedStringArray = PackedStringArray()
	for f3 in fields:
		var cv: GateAST._VarDecl = f3
		var cst: Dictionary = _struct_of(cv.type.name) if cv.type != null and cv.type.array_depth == 0 \
			and not cv.type.is_dict() else {}
		if _holds_containers(cv.type):
			copies.append("%s(%s)" % [deep, cv.name])
		elif cst.is_empty() or cst["lowering"] == "vector":
			copies.append(cv.name)
		elif cv.type.nullable:
			copies.append("(%s._gate_copy() if %s != null else null)" % [cv.name, cv.name])
		else:
			copies.append("%s._gate_copy()" % cv.name)
	_blank_line(cd.line)
	_line("func _gate_copy() -> %s:" % cd.name, cd.line)
	_indent += 1
	_line("return %s.new(%s)" % [cd.name, ", ".join(copies)], cd.line)
	_indent -= 1
	_emit_deep_copy(deep, cd.line)   # also copies containers of this struct that engine calls hand out
	_emit_equality(cd, fields, st, member_names)


func _emit_keyed_builder(cd: GateAST._ClassDecl, fields: Array, st: Dictionary,
		member_names: Array, pre: String) -> void:
	for i in fields.size():
		if _default_kind(st, i) != "instance":
			continue
		var hv: GateAST._VarDecl = fields[i]
		var hp: PackedStringArray = PackedStringArray()
		var hr: Dictionary = {}
		for r in _default_refs(st, i):
			var rv: GateAST._VarDecl = fields[(st["fields"] as Array).find(r)]
			hp.append("%s%s%s" % [pre, r, ": " + _map_type(rv.type) if rv.type != null else ""])
			hr[r] = pre + r
		var head: String = "func %s(%s)" % [_default_helper(st, i), ", ".join(hp)]
		if hv.type != null:
			head += " -> " + _map_type(hv.type)
		_blank_line(cd.line)
		_line(head + ":", hv.line)
		_indent += 1
		_line("return " + _render_in_struct(hv.value, hr), hv.line)
		_indent -= 1
	var taken: Array = member_names.duplicate()
	for f in fields:
		taken.append(pre + (f as GateAST._VarDecl).name)
	var given: String = _free_name(taken, "__gate_given")
	var made: String = _free_name(taken, "__gate_made")
	var ps: PackedStringArray = PackedStringArray(["%s: int" % given])
	var args: PackedStringArray = PackedStringArray()
	for f in fields:
		var fv: GateAST._VarDecl = f
		ps.append("%s%s: %s" % [pre, fv.name, _map_type(fv.type) if fv.type != null else "Variant"])
		args.append(pre + fv.name)
	_blank_line(cd.line)
	_line("static func %s(%s) -> %s:" % [_keyed_builder(st), ", ".join(ps), cd.name], cd.line)
	_indent += 1
	_line("var %s: %s = %s.new(%s)" % [made, cd.name, cd.name, ", ".join(args)], cd.line)
	var comps: Dictionary = {}
	for i in fields.size():
		var fname: String = (fields[i] as GateAST._VarDecl).name
		var fill: String = ""
		if _default_kind(st, i) == "instance":
			var refs: PackedStringArray = PackedStringArray()
			for r in _default_refs(st, i):
				refs.append(String(comps[r]))
			fill = "%s.%s(%s)" % [made, _default_helper(st, i), ", ".join(refs)]
		else:
			fill = _render_default(st, i, comps, cd.name, fields[i])
		_line("if %s & %d == 0:" % [given, 1 << i], cd.line)
		_indent += 1
		_line("%s.%s = %s" % [made, fname, fill], cd.line)
		_indent -= 1
		comps[fname] = "%s.%s" % [made, fname]
	_line("return %s" % made, cd.line)
	_indent -= 1


func _holds_containers(t: GateAST._TypeRef) -> bool:
	if t == null or t.array_depth > 0 or t.is_dict() or t.is_set() or t.is_union() or t.is_tuple():
		return true
	var mapped: String = _map_type(t)
	return (mapped == "Variant" or mapped.begins_with("Array") or mapped.begins_with("Dictionary")
		or mapped.begins_with("Packed"))


func _emit_equality(cd: GateAST._ClassDecl, fields: Array, st: Dictionary, member_names: Array) -> void:
	var names: Dictionary = {}
	for w in ["_gate_eq", "_gate_eqv", "_gate_index", "_gate_count", "_gate_erase", "_gate_value"]:
		names[w] = _eq_helper(st, w) if not st.is_empty() else _free_name(member_names, w)
	var eqv: String = names["_gate_eqv"]
	var terms: PackedStringArray = PackedStringArray()
	for f in fields:
		var fv: GateAST._VarDecl = f
		var fst: Dictionary = _struct_of(fv.type.name) if fv.type != null and fv.type.array_depth == 0 \
			and not fv.type.is_dict() else {}
		if _holds_containers(fv.type) or (not fst.is_empty() and fst["lowering"] != "vector"):
			terms.append("%s(%s, o.%s)" % [eqv, fv.name, fv.name])
		else:
			terms.append("%s == o.%s" % [fv.name, fv.name])
	var user_eq: String = String((_ops_of(cd.name) as Dictionary).get("==", ""))
	var lines: Array = [
		"func %s(o: Variant) -> bool:" % names["_gate_eq"],
		"\tif not (o is %s):" % cd.name,
		"\t\treturn false",
		"\treturn %s" % (("%s(o)" % user_eq) if user_eq != "" else " and ".join(terms)),
		"",
		"static func %s(a: Variant, b: Variant) -> bool:" % eqv,
		"\tif is_instance_valid(a) and a.has_method(\"_gate_eq\"):",
		"\t\treturn a._gate_eq(b)",
		"\tif is_instance_valid(b) and b.has_method(\"_gate_eq\"):",
		"\t\treturn b._gate_eq(a)",
		"\tif a is Array and b is Array:",
		"\t\tif a.size() != b.size():",
		"\t\t\treturn false",
		"\t\tfor i in a.size():",
		"\t\t\tif not %s(a[i], b[i]):" % eqv,
		"\t\t\t\treturn false",
		"\t\treturn true",
		"\tif a is Dictionary and b is Dictionary:",
		"\t\tif a.size() != b.size():",
		"\t\t\treturn false",
		"\t\tfor k in a:",
		"\t\t\tif not b.has(k) or not %s(a[k], b[k]):" % eqv,
		"\t\t\t\treturn false",
		"\t\treturn true",
		"\treturn a == b",
		"",
		"static func %s(arr: Array, v: Variant, from: int, step: int) -> int:" % names["_gate_index"],
		"\tvar i: int = from",
		"\tif i < 0:",
		"\t\ti += arr.size()",
		"\twhile i >= 0 and i < arr.size():",
		"\t\tif %s(arr[i], v):" % eqv,
		"\t\t\treturn i",
		"\t\ti += step",
		"\treturn -1",
		"",
		"static func %s(arr: Array, v: Variant) -> int:" % names["_gate_count"],
		"\tvar n: int = 0",
		"\tfor e in arr:",
		"\t\tif %s(e, v):" % eqv,
		"\t\t\tn += 1",
		"\treturn n",
		"",
		"static func %s(arr: Array, v: Variant) -> void:" % names["_gate_erase"],
		"\tvar i: int = %s(arr, v, 0, 1)" % names["_gate_index"],
		"\tif i >= 0:",
		"\t\tarr.remove_at(i)",
		"",
		"static func %s(v: Variant) -> Variant:" % names["_gate_value"],
		"\tif is_instance_valid(v) and v.has_method(\"_gate_copy\"):",
		"\t\treturn v._gate_copy()",
		"\treturn v",
	]
	_blank_line(cd.line)
	for l in lines:
		if String(l) == "":
			_blank_line(cd.line)
		else:
			_line(String(l), cd.line)


func _emit_deep_copy(name: String, line: int) -> void:
	var lines: Array = [
		"static func %s(v: Variant) -> Variant:" % name,
		"\tif v is Array:",
		"\t\tvar a: Array = v.duplicate()",
		"\t\tfor i in a.size():",
		"\t\t\ta[i] = %s(a[i])" % name,
		"\t\treturn a",
		"\tif v is Dictionary:",
		"\t\tvar d: Dictionary = v.duplicate()",
		"\t\tfor k in d:",
		"\t\t\td[k] = %s(d[k])" % name,
		"\t\treturn d",
		"\tif is_instance_valid(v) and v.has_method(\"_gate_copy\"):",
		"\t\treturn v._gate_copy()",
		"\tif typeof(v) >= TYPE_PACKED_BYTE_ARRAY and typeof(v) < TYPE_MAX:",
		"\t\treturn v.duplicate()",
		"\treturn v",
	]
	_blank_line(line)
	for l in lines:
		_line(String(l), line)


func _render_in_struct(e, renames: Dictionary) -> String:
	var saved: Dictionary = _ident_renames
	_ident_renames = renames.duplicate()
	var text: String = _copy_value(e)
	_ident_renames = saved
	return text


func _free_prefix(names: Array, want: String) -> String:
	var pre: String = want
	while true:
		var clash: bool = false
		for n in names:
			if names.has(pre + n):
				clash = true
				break
		if not clash:
			return pre
		pre = "_" + pre
	return pre


func _free_name(names: Array, want: String) -> String:
	var n: String = want
	while names.has(n):
		n = "_" + n
	return n


func _emit_func(fd: GateAST._FuncDecl) -> void:
	if fd.accessor:
		return   # printed inside its property, by _emit_accessor_tail
	for a in fd.annotations:
		_emit_annotation(a)

	var name: String = fd.mangled_name if fd.mangled_name != "" else fd.name
	if fd.visibility == "priv" and not name.begins_with("_"):
		name = "_" + name

	var head: String = ""
	var is_static: bool = fd.is_static or (_in_namespace and not fd.name.begins_with("_"))
	if is_static:
		head += "static "
	var helpers: Array = []
	head += "func %s(%s)" % [name, _params(fd.params, name, helpers)]
	if fd.return_type != null:
		head += " -> " + _map_type(fd.return_type)
	elif fd.is_operator:
		pass
	if _annotated_with(fd.annotations, "abstract"):
		_line(head, fd.line)
		_blank_line(fd.line)
		_emit_default_helpers(helpers, is_static, fd.line)
		return

	_line(head + ":", fd.line)
	_indent += 1
	var saved_helper: bool = _in_gate_helper
	_in_gate_helper = saved_helper or fd.name.begins_with("_gate_") or fd.name.begins_with("__gate_")
	_emit_fn_body(fd)
	_in_gate_helper = saved_helper
	_indent -= 1
	_blank_line(fd.line)
	_emit_default_helpers(helpers, is_static, fd.line)


func _emit_fn_body(fd: GateAST._FuncDecl) -> void:
	var saved: Dictionary = _var_types.duplicate()
	var saved_depths: Dictionary = _var_depths.duplicate()
	var saved_locals: Dictionary = _fn_locals
	var saved_dict_values: Dictionary = _var_dict_values.duplicate()
	var saved_assigned = _assigned_names
	var saved_fn_body = _cur_fn_body
	var saved_no_hoist: String = _no_hoist
	_no_hoist = ""
	_assigned_names = null
	_cur_fn_body = fd.body
	_fn_locals = {}
	var saved_params: Dictionary = _fn_params
	_fn_params = {}
	var saved_null: Dictionary = _null_locals
	_null_locals = {}
	for p in fd.params:
		var pp: GateAST._Param = p
		_fn_locals[pp.name] = _decl_info(_scope_class, pp.type)
		_fn_params[pp.name] = true
		_shadow_name(pp.name)
		if pp.type != null:
			_var_types[pp.name] = pp.type.name
			_var_depths[pp.name] = pp.type.array_depth

	if fd.body.is_empty():
		if fd.is_virtual or fd.is_abstract:
			_line("push_error(\"%s: not implemented\")" % fd.name, fd.line)
			if fd.return_type != null and GateTypes.canonical(fd.return_type.name) != "void":
				_line("return " + _default_for(fd.return_type, false), fd.line)
		else:
			_line("pass", fd.line)
	else:
		var saved_in_body: bool = _in_func_body
		var saved_repl: Dictionary = _scalar_repl
		var saved_names: Dictionary = _scalar_names
		var ea = load("res://addons/gate/compiler/escape.gd").new()
		_scalar_repl = ea.analyse(fd.body, self, fd.params)
		_scalar_names = {}
		var taken: Dictionary = {}
		for rn in _scalar_repl:
			var rst: Dictionary = _struct_of(String(_scalar_repl[rn]))
			for fname in rst["fields"]:
				var local: String = "%s__%s" % [rn, fname]
				while _bound_names.has(local) or taken.has(local):
					local = "_" + local
				taken[local] = true
				_scalar_names["%s.%s" % [rn, fname]] = local
		_in_func_body = true
		for p2 in fd.params:
			if _would_copy(p2) and not _copies_first(fd.body, (p2 as GateAST._Param).name):
				_line(_entry_copy(p2), fd.line)
		for s in fd.body:
			_emit_statement(s)
		_in_func_body = saved_in_body
		_scalar_repl = saved_repl
		_scalar_names = saved_names
	_var_types = saved
	_var_depths = saved_depths
	_var_dict_values = saved_dict_values
	_fn_locals = saved_locals
	_assigned_names = saved_assigned
	_cur_fn_body = saved_fn_body
	_fn_params = saved_params
	_null_locals = saved_null
	_no_hoist = saved_no_hoist


func _emit_default_helpers(helpers: Array, is_static: bool, line: int) -> void:
	for h in helpers:
		_line("%sfunc %s(%s)%s:" % ["static " if is_static else "", h[0],
			", ".join(PackedStringArray(h[1])), (" -> " + String(h[4])) if String(h[4]) != "" else ""], line)
		_indent += 1
		for hl in (h[2] as PackedStringArray):
			_line(_deeper(hl, 1), line)   # rendered at the function's own depth
		_line(_deeper("return " + String(h[3]), 1), line)
		_indent -= 1
		_blank_line(line)


func _emit_annotation(a: GateAST._Annotation) -> void:
	if a.name in ["observable", "required", "export_if"]:
		return  # handled by _emit_var and GateInject; Godot rejects all three
	_line(_annotation_text(a), a.line)


func _export_if_prefix(vd: GateAST._VarDecl) -> String:
	if not _has_annotation(vd, "export_if"):
		return ""
	for a in vd.annotations:
		var n: String = (a as GateAST._Annotation).name
		if n != "export_if" and GateInject.is_export(n):
			return ""
	return "@export "


func _annotation_text(a: GateAST._Annotation) -> String:
	if a.args.is_empty():
		return "@" + a.name
	var parts: PackedStringArray = PackedStringArray()
	var saved_no_hoist: String = _no_hoist
	_no_hoist = "annotation"
	for arg in a.args:
		parts.append(_expr(arg))
	_no_hoist = saved_no_hoist
	return "@%s(%s)" % [a.name, ", ".join(parts)]


func _inline_annotation_prefix(node) -> String:
	var out: String = ""
	for a in node.annotations:
		var an: GateAST._Annotation = a
		if an.name in ["observable", "packed", "soa", "required", "export_if"]:
			continue
		if an.line != node.line:
			continue
		out += _annotation_text(an) + " "
	return out


func _emit_scalar_replaced(vd: GateAST._VarDecl) -> void:
	var sname: String = _scalar_repl[vd.name]
	var st: Dictionary = _struct_of(sname)
	var fields: Array = st["fields"]
	var ftypes: Array = st["types"]
	var args: Array = (vd.value as GateAST._Call).args
	_check_struct_arity(sname, st, vd.value)   # positional, and never reaching _emit_call
	var ctor: String = sname
	for hi in range(args.size(), fields.size()):
		if _default_kind(st, hi) == "helper":
			var salias: String = _extern_alias(sname)
			ctor = "%s.%s" % [salias, sname] if salias != "" else sname
			break
	var comps: Dictionary = {}
	_flush_pending(vd.line)
	for i in fields.size():
		var trefs: Array = st.get("typerefs", [])
		var tr = trefs[i] if i < trefs.size() and trefs[i] != null else null
		if tr == null:
			tr = GateAST._TypeRef.new()
			tr.name = String(ftypes[i]) if i < ftypes.size() else "Variant"
		var mapped: String = _map_type(tr)
		var value: String = ""
		if i < args.size():
			value = _copy_value(args[i])
		else:
			value = _render_default(st, i, comps, ctor, vd)
		_flush_pending(vd.line)
		var local: String = _scalar_names["%s.%s" % [vd.name, fields[i]]]
		comps[fields[i]] = local
		_fn_locals[local] = {}
		if mapped != "" and mapped != "Variant":
			_line("var %s: %s = %s" % [local, mapped, value], vd.line)
		else:
			_line("var %s = %s" % [local, value], vd.line)


func _infers_gate_shape(e) -> bool:
	if _subst_types.is_empty() or not (e is GateAST._Ident):
		return false
	var n: String = (e as GateAST._Ident).name
	var tname: String = ""
	if _fn_locals.has(n):
		tname = String((_fn_locals[n] as Dictionary).get("t", ""))
	else:
		var ft: Variant = _class_field_types.get("%s#%s" % [_scope_class, n], null)
		if ft is GateAST._TypeRef and (ft as GateAST._TypeRef).array_depth == 0:
			tname = (ft as GateAST._TypeRef).name
	if tname == "" or not _subst_types.has(tname):
		return false
	var st: GateAST._TypeRef = _subst_types[tname]
	return st.is_union() or st.is_tuple() or st.nullable or st.is_func_type


func _local_info(vd: GateAST._VarDecl) -> Dictionary:
	if vd.type != null:
		return _decl_info(_scope_class, vd.type)
	if vd.value == null:
		return {}
	if vd.inferred or vd.is_const:
		var t: String = _declared_type_of(vd.value)
		return {"t": t, "e": ""} if t != "" else {}
	if _is_scene_preload(vd.value) and not _is_assigned(vd.name):
		return {"t": "PackedScene", "e": ""}
	if vd.value is GateAST._ArrayLit and not _is_assigned(vd.name):
		var en: String = _vector_elem_name(vd.value)
		if en != "":
			var et: GateAST._TypeRef = GateAST._TypeRef.new()
			et.at(vd.line, vd.col)
			et.name = en
			et.array_depth = 1
			return _decl_info(_scope_class, et)
	return {}


func _vector_elem_name(lit) -> String:
	var items: Array = (lit as GateAST._DictLit).values if lit is GateAST._DictLit else (lit as GateAST._ArrayLit).elements
	if items.is_empty():
		return ""
	var name: String = ""
	for el in items:
		var t: String = _static_type_of(el)
		if t == "" or (name != "" and t != name):
			return ""
		name = t
	return name if not _struct_of(name).is_empty() else ""


func _is_assigned(n: String) -> bool:
	if _cur_fn_body == null:
		return true
	if _assigned_names == null:
		_assigned_names = {}
		_collect_assigned(_cur_fn_body)
	return (_assigned_names as Dictionary).has(n)


func _assignments_agree(n: String, t: String) -> bool:
	if _cur_fn_body == null:
		return false
	if _struct_of(t).is_empty() and (_ops_of(t) as Dictionary).is_empty():
		return false
	var vals: Array = []
	_values_stored(_cur_fn_body, n, vals)
	if vals.is_empty():
		return false
	var saved_t = _var_types.get(n)
	var saved_d = _var_depths.get(n)
	_var_types[n] = t   # `c = c + d` asks what `c` is, and this is the answer on trial
	_var_depths[n] = 0
	var ok: bool = true
	for v in vals:
		if v == null or _both_arms(t, _static_type_of(v)) == "":
			ok = false
			break
	if not ok:
		if saved_t == null:
			_var_types.erase(n)
			_var_depths.erase(n)
		else:
			_var_types[n] = saved_t
			_var_depths[n] = saved_d
	return ok


func _never_holds_struct(n: String, seen: Dictionary) -> bool:
	if _cur_fn_body == null or seen.has(n):
		return seen.get(n, false)
	if _fn_params.has(n):
		return false   # it arrives holding whatever the caller passed
	seen[n] = true   # a cycle through locals adds no struct of its own
	var vals: Array = []
	_values_stored(_cur_fn_body, n, vals)
	if vals.is_empty():
		seen[n] = false
		return false
	for v in vals:
		if not _surely_not_struct(v, seen):
			seen[n] = false
			return false
	return true


func _values_stored(node, n: String, out: Array) -> void:
	if node == null:
		return
	if node is Array:
		for x in node:
			_values_stored(x, n, out)
		return
	if not (node is Object) or (node as Object).get_script() == null:
		return
	if node is GateAST._VarDecl and (node as GateAST._VarDecl).name == n:
		out.append((node as GateAST._VarDecl).value)
	elif node is GateAST._ForStmt and (node as GateAST._ForStmt).var_names.has(n):
		out.append(null)
	elif node is GateAST._Lambda:
		for lp in (node as GateAST._Lambda).params:
			if (lp as GateAST._Param).name == n:
				out.append(null)
	elif node is GateAST._AssignStmt:
		var a: GateAST._AssignStmt = node
		if a.op == "=" and a.target is GateAST._Ident and (a.target as GateAST._Ident).name == n:
			out.append(a.value)
	elif node is GateAST._MultiAssign:
		var ma: GateAST._MultiAssign = node
		var lit: Array = []
		if ma.values.size() == 1 and ma.values[0] is GateAST._ArrayLit:
			lit = (ma.values[0] as GateAST._ArrayLit).elements
		for i in ma.targets.size():
			if ma.targets[i] is GateAST._Ident and (ma.targets[i] as GateAST._Ident).name == n:
				if ma.values.size() == ma.targets.size():
					out.append(ma.values[i])
				elif lit.size() == ma.targets.size():
					out.append(lit[i])   # `var [p, q] = [10, 20]`, position by position
				else:
					out.append(null)
	for prop in (node as Object).get_property_list():
		var pn: String = prop["name"]
		if pn in ["script", "Built-in script", "RefCounted", "Object"]:
			continue
		var v = (node as Object).get(pn)
		if v is Array or (v is Object and v != null and (v as Object).get_script() != null):
			_values_stored(v, n, out)


func _surely_not_struct(v, seen: Dictionary = {}) -> bool:
	if v == null:
		return false
	if v is GateAST._Ident:
		var vn: String = (v as GateAST._Ident).name
		if _var_types.has(vn):
			return _struct_of(String(_var_types[vn])).is_empty()
		if _fn_locals.has(vn) and (_fn_locals[vn] as Dictionary).is_empty():
			return _never_holds_struct(vn, seen)
		return false
	if v is GateAST._Literal or v is GateAST._ArrayLit or v is GateAST._DictLit \
		or v is GateAST._FString or v is GateAST._Lambda or v is GateAST._IsExpr:
		return true
	if v is GateAST._Unary and (v as GateAST._Unary).op == "not":
		return true
	if v is GateAST._Binary and (v as GateAST._Binary).op in ["==", "!=", "<", ">", "<=", ">=",
			"and", "or", "in", "not in"]:
		return true
	if v is GateAST._Call and (v as GateAST._Call).callee is GateAST._Member:
		var cm: GateAST._Member = (v as GateAST._Call).callee
		if cm.name in ["_gate_eq", "_gate_eqv", "_gate_index", "_gate_count", "_gate_erase"]:
			return true   # a bool, an index or nothing, on a recompile
		if _builtin_scalar_method(cm):
			return true   # `arr.find(...)`, a size or a flag
		if cm.name == "new" and cm.target is GateAST._Ident:
			return _struct_of((cm.target as GateAST._Ident).name).is_empty()
	return false


func _collect_assigned(node) -> void:
	if node == null:
		return
	if node is Array:
		for x in node:
			_collect_assigned(x)
		return
	if not (node is Object) or (node as Object).get_script() == null:
		return
	if node is GateAST._AssignStmt:
		var at = (node as GateAST._AssignStmt).target
		if at is GateAST._Ident:
			_assigned_names[(at as GateAST._Ident).name] = true
	elif node is GateAST._MultiAssign:
		for mt in (node as GateAST._MultiAssign).targets:
			if mt is GateAST._Ident:
				_assigned_names[(mt as GateAST._Ident).name] = true
	for pn in GateAST.walk_names(node):
		var v = (node as Object).get(pn)
		if v is Array or (v is Object and v != null and (v as Object).get_script() != null):
			_collect_assigned(v)


func _emit_var(vd: GateAST._VarDecl) -> void:
	var bare: bool = _bare_fields
	_bare_fields = false
	var observable: bool = _has_annotation(vd, "observable")
	var packed: bool = _has_annotation(vd, "packed")

	if _has_annotation(vd, "soa"):
		_emit_soa_decl(vd)
		return

	var name: String = vd.name
	if vd.visibility == "priv" and not name.begins_with("_"):
		name = "_" + name

	if _in_func_body:
		_shadow_name(name)
	if vd.type != null and vd.type.is_dict() and vd.type.dict_value != null:
		_var_dict_values[name] = vd.type.dict_value.name
	if vd.type != null and vd.type.name != "":
		_var_types[name] = vd.type.name
		_var_depths[name] = vd.type.array_depth
		if GateTypes.canonical(vd.type.name) == "Dictionary" and vd.type.generic_args.size() == 2:
			_var_dict_values[name] = (vd.type.generic_args[1] as GateAST._TypeRef).name
		if GateTypes.canonical(vd.type.name) == "Array" and vd.type.generic_args.size() == 1:
			var elem_t: GateAST._TypeRef = vd.type.generic_args[0] as GateAST._TypeRef
			if elem_t != null and elem_t.name != "":
				_var_types[name] = elem_t.name
				_var_depths[name] = elem_t.array_depth + 1
	elif vd.value != null:
		var inferred: String = _static_type_of(vd.value)
		if inferred != "" and (vd.inferred or not _in_func_body or not _is_assigned(vd.name)
				or _assignments_agree(vd.name, inferred)):
			_var_types[name] = inferred
			_var_depths[name] = 0
		elif vd.value is GateAST._ArrayLit and not _is_assigned(vd.name):
			var elem_name: String = _vector_elem_name(vd.value)
			if elem_name != "":
				_var_types[name] = elem_name
				_var_depths[name] = 1
		elif vd.value is GateAST._DictLit and not _is_assigned(vd.name):
			var value_name: String = _vector_elem_name(vd.value)
			if value_name != "":
				_var_dict_values[name] = value_name
	if _in_func_body:
		if (vd.type == null and vd.value != null and _is_value_class(String(_var_types.get(name, "")))
				and _value_may_be_null(vd.value)):
			_null_locals[name] = true
		else:
			_null_locals.erase(name)

	if packed and vd.type != null and vd.type.array_depth == 0:
		diagnostics.warn("@packed only applies to array declarations", vd.line, vd.col)
	elif packed and vd.type != null and not _map_type(vd.type, true).contains("Packed"):
		diagnostics.warn("'%s' has no Packed equivalent; @packed left unenforced"
				% vd.type.describe(), vd.line, vd.col,
			"GDScript packs byte, int, float, String, Vector2/3/4 and Color arrays. "
			+ "Emitting %s." % _map_type(vd.type, true))

	var infer_this: bool = vd.inferred and not _infers_gate_shape(vd.value)
	var infer_as: String = ""
	var infer_untyped: bool = false
	if (infer_this and vd.type == null and not vd.is_const and vd.value != null
			and _has_null_ops(vd.value)):
		infer_as = _type_text_of_key(_declared_type_of(vd.value))
		if infer_as == "" or _may_be_null(vd.value):
			infer_as = ""
			infer_untyped = true
		infer_this = false

	var saved_no_hoist: String = _no_hoist
	if vd.is_const:
		_no_hoist = "const"
	elif not _in_func_body:
		_no_hoist = "field"
	var value_src: String = ""
	if bare or (_in_func_body and _scalar_repl.has(vd.name)):
		pass   # _emit_scalar_replaced renders the arguments itself
	elif vd.value != null:
		value_src = _expr(vd.value) if _gate_temp_name(name) else _copy_value(vd.value)
	elif vd.type != null and vd.setter == "" and not _in_gate_helper and (vd.type.strict or _is_class_struct(vd.type)
			or vd.type.is_union() or vd.type.is_tuple()):
		value_src = _default_for(vd.type, packed)
	elif vd.type != null and (vd.type.is_union() or vd.type.is_tuple()) and vd.type.array_depth == 0:
		value_src = _default_for(vd.type, packed)
	_no_hoist = saved_no_hoist

	if _in_func_body:
		_fn_locals[name] = {} if infer_untyped else _local_info(vd)

	if not _in_func_body:
		var prefix: String = ""
		if vd.is_static or _in_namespace:
			prefix = "static "
		elif vd.is_onready or _has_annotation(vd, "onready"):
			prefix = "@onready "
		if prefix != "":
			for pi in _pending.size():
				if _pending[pi].begins_with("var "):
					_pending[pi] = prefix + _pending[pi]

	_flush_pending(vd.line)
	for a in vd.annotations:
		var va: GateAST._Annotation = a
		if va.name in ["observable", "packed", "required", "export_if"]:
			continue
		if va.line == vd.line or observable:
			continue   # an @observable's go on the property it generates
		_emit_annotation(va)

	if observable:
		_emit_observable(vd, name, value_src)
		return

	if _in_func_body and _scalar_repl.has(vd.name):
		_emit_scalar_replaced(vd)
		return

	var decl: String = _inline_annotation_prefix(vd) + _export_if_prefix(vd)
	if vd.is_const:
		decl += "const %s" % name
	else:
		decl += "%svar %s" % [
			"static " if (vd.is_static or _in_namespace) else "", name]

	if vd.type != null:
		decl += ": " + _map_type(vd.type, packed)
	elif infer_as != "":
		decl += ": " + infer_as
	elif infer_this:
		decl += " :="
		if value_src != "":
			_line(decl + " " + value_src + _accessor_head(vd), vd.line)
			_emit_accessor_tail(vd)
			return

	var tail: String = _accessor_head(vd)
	if value_src != "":
		if infer_this and vd.type == null:
			_line("%s := %s%s" % [decl.trim_suffix(" :="), value_src, tail], vd.line)
		else:
			_line(decl + " = " + value_src + tail, vd.line)
	else:
		_line(decl + tail, vd.line)
	_emit_accessor_tail(vd)


func _emit_soa_decl(vd: GateAST._VarDecl) -> void:
	if vd.type == null or vd.type.array_depth != 1:
		diagnostics.error("@soa requires an array declaration such as `@soa Particle[] swarm`",
			vd.line, vd.col)
		return
	var st: Dictionary = _struct_of(vd.type.name)
	if st.is_empty():
		diagnostics.error("@soa requires a struct element type; '%s' is not a struct" % vd.type.name,
			vd.line, vd.col,
			"declare it with `struct %s:`" % vd.type.name)
		return
	if vd.value != null:
		diagnostics.error("@soa arrays cannot have an initialiser", vd.line, vd.col,
			"they are emitted as several parallel arrays, so there is nothing to assign to")
		return

	var fields: Array = st["fields"]
	var types: Array = st["types"]
	var is_vec: bool = st["lowering"] == "vector"

	var accessors: Array = []
	var arrays: Array = []
	for i in fields.size():
		accessors.append(_vec_component(st, i) if is_vec else fields[i])
		arrays.append("%s_%s" % [vd.name, fields[i]])

	_soa[vd.name] = {
		"struct": vd.type.name,
		"fields": fields,
		"accessors": accessors,
		"elem_types": types,
		"arrays": arrays,
	}

	var trefs: Array = st.get("typerefs", [])
	for i in fields.size():
		var ftr = trefs[i] if i < trefs.size() else null
		if ftr != null and ((ftr as GateAST._TypeRef).array_depth > 0 or (ftr as GateAST._TypeRef).is_dict()
				or (ftr as GateAST._TypeRef).is_union() or (ftr as GateAST._TypeRef).is_tuple()
				or not (ftr as GateAST._TypeRef).generic_args.is_empty()):
			var fm: String = _map_type(ftr)
			var col: String = "Array"
			if fm.begins_with("Array") or fm.begins_with("Packed"):
				col = "Array[Array]" if fm.begins_with("Array") else "Array[%s]" % fm
			elif fm.begins_with("Dictionary"):
				col = "Array[Dictionary]"
			_line("var %s: %s = []" % [arrays[i], col], vd.line)
			continue
		var elem: String = types[i] if GateTypes.has_packed(types[i]) else GateTypes.canonical(types[i])
		var fst: Dictionary = _struct_of(types[i])
		if not fst.is_empty() and fst["lowering"] == "vector":
			elem = fst["vector"]
		var container: String = GateTypes.packed_for(elem)
		if not _warned_packed and GateTypes.narrows_width(String(types[i])) and container != "":
			_warn_packed(container, vd.line, vd.col)
		if container == "":
			container = "Array[%s]" % elem
			_line("var %s: %s = []" % [arrays[i], container], vd.line)
		else:
			_line("var %s: %s = %s()" % [arrays[i], container, container], vd.line)


func _accessor_head(vd: GateAST._VarDecl) -> String:
	if vd.inline_accessors != "":
		return " " + vd.inline_accessors
	if vd.setter != "" or vd.notify_line > 0:
		return ":"
	return ""


func _emit_accessor_tail(vd: GateAST._VarDecl) -> void:
	if vd.setter == "":
		if vd.notify_line > 0 and vd.inline_accessors == "":
			_emit_notifying_setter(vd)
		return
	var lines: PackedStringArray = vd.setter.split("\n")
	var base: int = 0
	for l in lines:
		if l.strip_edges() == "":
			continue
		var n: int = _leading_spaces(l)
		if n > 0 and (base == 0 or n < base):
			base = n
	var unit: int = 0
	for l in lines:
		if l.strip_edges() == "":
			continue
		var d: int = _leading_spaces(l) - base
		if d > 0:
			unit = d if unit == 0 else _gcd(unit, d)
	var src0: int = vd.setter_line if vd.setter_line > 0 else vd.line
	var blocks: Array = []
	if vd.get_ast != null:
		blocks.append([int(vd.get_span[0]), int(vd.get_span[1]), vd.get_ast, false])
	if vd.set_ast != null:
		blocks.append([int(vd.set_span[0]), int(vd.set_span[1]), vd.set_ast, vd.set_forced])
	var raw_out: PackedStringArray = PackedStringArray()
	var raw_map: Array[int] = []
	var in_string: bool = false
	for k in lines.size():
		var l2: String = lines[k]
		raw_out.append(l2 if in_string else _retab(l2, base, unit, _indent))
		raw_map.append(src0 + k)
		if _triple_quotes_in(l2) % 2 == 1:
			in_string = not in_string
	var k2: int = 0
	while k2 < lines.size():
		var block: Array = []
		for b in blocks:
			if int(b[0]) == k2:
				block = b
		if block.is_empty():
			_out.append(raw_out[k2])
			_map.append(raw_map[k2])
			k2 += 1
			continue
		var first: int = int(block[0])
		var last: int = int(block[1])
		var compiled: Array = _compiled_accessor(block[2], lines[first], src0 + first)
		var raw_text: String = "\n".join(raw_out.slice(first, last + 1))
		if bool(block[3]) or not _same_tokens(raw_text, "\n".join(PackedStringArray(compiled[0]))):
			_out.append_array(compiled[0])
			_map.append_array(compiled[1])
		else:
			_out.append_array(raw_out.slice(first, last + 1))
			_map.append_array(raw_map.slice(first, last + 1))
		k2 = last + 1


func _compiled_accessor(fd: GateAST._FuncDecl, head_line: String, line: int) -> Array:
	var head: String = head_line.strip_edges()
	var colon: int = head.find(":")
	if head.begins_with("set"):
		colon = head.find(":", maxi(head.find(")"), 0))   # after `set(value: T)`
	head = head.substr(0, colon + 1)
	var saved_out: PackedStringArray = _out
	var saved_map: Array[int] = _map
	_out = PackedStringArray()
	_map = []
	_indent += 1
	_line(head, line)
	_indent += 1
	_emit_fn_body(fd)
	_indent -= 2
	var got: Array = [_out, _map]
	_out = saved_out
	_map = saved_map
	return got


static func _same_tokens(a: String, b: String) -> bool:
	return _code_tokens(a) == _code_tokens(b)


static func _code_tokens(src: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var d: GateDiagnostics = GateDiagnostics.new()
	for t in GateLexer.new().tokenize(src, d):
		if t.type in [GateLexer._T.NEWLINE, GateLexer._T.INDENT, GateLexer._T.DEDENT,
				GateLexer._T.COMMENT, GateLexer._T.EOF]:
			continue
		var v: String = String(t.value)
		if v in ["(", ")", ",", ";", "not", "!"]:
			continue
		if v == ":=":
			out.append_array([":", "="])   # `var x: = 1` is the same declaration
			continue
		out.append({"&&": "and", "||": "or"}.get(v, v))
	return out


func _emit_notifying_setter(vd: GateAST._VarDecl) -> void:
	var name: String = vd.name
	if vd.visibility == "priv" and not name.begins_with("_"):
		name = "_" + name
	var param: String = "value" if name != "value" else "new_value"
	_indent += 1
	_line("set(%s):" % param, vd.notify_line)
	_indent += 1
	_line("%s = %s" % [name, param], vd.notify_line)
	_line("notify_property_list_changed()", vd.notify_line)
	_indent -= 2


static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t: int = b
		b = a % b
		a = t
	return a


static func _triple_quotes_in(line: String) -> int:
	var n: int = 0
	var i: int = 0
	while i < line.length() - 2:
		var c: String = line[i]
		if (c == '"' or c == "'") and line[i + 1] == c and line[i + 2] == c:
			n += 1
			i += 3
			continue
		i += 1
	return n


static func _leading_spaces(line: String) -> int:
	var n: int = 0
	while n < line.length() and line[n] == " ":
		n += 1
	return n


static func _retab(line: String, base: int, unit: int, outer: int) -> String:
	var spaces: int = _leading_spaces(line)
	if spaces == 0 or base <= 0:
		return line
	var levels: int = 1
	if unit > 0 and spaces > base:
		levels += int(round(float(spaces - base) / float(unit)))
	return "	".repeat(outer + levels) + line.substr(spaces)


func _emit_observable(vd: GateAST._VarDecl, name: String, value_src: String) -> void:
	var tname: String = _map_type(vd.type) if vd.type != null else ""
	var sig_param: String = "value" + (": " + tname if tname != "" else "")
	_flush_pending(vd.line)
	_line("signal on_%s_changed(%s)" % [vd.name, sig_param], vd.line)
	var backing: String = "__%s" % name
	var decl: String = "var %s" % backing
	if tname != "":
		decl += ": " + tname
	if value_src != "":
		decl += " = " + value_src
	_line(decl, vd.line)
	for a in vd.annotations:
		var va: GateAST._Annotation = a
		if va.line != vd.line and not (va.name in ["observable", "packed", "required", "export_if"]):
			_emit_annotation(va)
	var pub_decl: String = _inline_annotation_prefix(vd) + _export_if_prefix(vd) + "var %s" % name
	if tname != "":
		pub_decl += ": " + tname
	_line(pub_decl + ":", vd.line)
	_indent += 1
	_line("set(v):", vd.line)
	_indent += 1
	var obs_eq: String = ""
	if vd.type != null and vd.type.array_depth == 0 and _is_class_struct_name(vd.type.name):
		obs_eq = "%s.%s" % [_struct_class_text(vd.type.name),
			_eq_helper(_struct_of(vd.type.name), "_gate_eqv")]
	if obs_eq != "":
		_line("if %s(%s, v): return" % [obs_eq, backing], vd.line)
	elif tname == "" or tname == "Variant":
		_line("if typeof(%s) == typeof(v) and %s == v: return" % [backing, backing], vd.line)
	else:
		_line("if %s == v: return" % backing, vd.line)
	_line("%s = v" % backing, vd.line)
	_line("on_%s_changed.emit(v)" % vd.name, vd.line)
	if vd.notify_line > 0:
		_line("notify_property_list_changed()", vd.notify_line)
	_indent -= 1
	_line("get:", vd.line)
	_indent += 1
	_line("return %s" % backing, vd.line)
	_indent -= 2
	_blank_line(vd.line)

## `x?.f(args)` whose result is discarded becomes `if x != null: x.f(args)`. The
## expression form is a ternary, which does not load when `f` returns void. The
## receiver is named twice, so it is rendered once and hoisted unless it is a bare
## name.
func _emit_discarded_safe_call(e, line: int) -> bool:
	if not (e is GateAST._Call):
		return false
	var c: GateAST._Call = e
	if not (c.callee is GateAST._Member):
		return false
	var m: GateAST._Member = c.callee
	if not m.safe:
		return false
	var base: String = ""
	if m.target is GateAST._Ident or m.target is GateAST._SelfExpr:
		base = _render_once(m.target, _expr(m.target))
	else:
		# The method runs on the receiver itself; a struct copy would lose what it does.
		var recv: String = _expr(m.target)
		base = _render_once(m.target, recv)
	var saved_p: PackedStringArray = _pending
	_pending = PackedStringArray()
	var dfd: GateAST._FuncDecl = _gate_callee(c)
	var args: PackedStringArray = _ordered(c.args,
		func(i: int) -> String: return _arg_text(c, dfd, i))
	var arg_pending: PackedStringArray = _pending
	_pending = saved_p
	_flush_pending(line)
	_line("if %s != null:" % base, line)
	_indent += 1
	for h in arg_pending:
		_line(_deeper(h, 1), line)
	_line(_deeper("%s.%s(%s)" % [base, _method_emit_name(m.target, m.name, c.args.size(), m.member_class),
		", ".join(args)], 1), line)
	_indent -= 1
	return true


func _emit_statement(s) -> void:
	if s == null or s is GateAST._TypeAliasDecl:
		return
	if "line" in s and not (s is GateAST._Stmt and (s as GateAST._Stmt).injected):
		_blank_gap(s.line)
	if s is GateAST._AnnotatedStmt:
		var an: GateAST._AnnotatedStmt = s
		for a in an.annotations:
			_emit_annotation(a)
		if an.stmt != null:
			_emit_statement(an.stmt)
		return

	if s is GateAST._CommentStmt:
		_line((s as GateAST._CommentStmt).text, s.line)
	elif s is GateAST._RawStmt:
		_emit_raw(s)
	elif s is GateAST._VarDecl:
		_emit_var(s)
	elif s is GateAST._FuncDecl:
		_emit_func(s)
	elif s is GateAST._ClassDecl:
		_emit_class(s)
	elif s is GateAST._SimpleStmt:
		_line((s as GateAST._SimpleStmt).keyword, s.line)
	elif s is GateAST._ReturnStmt:
		var r: GateAST._ReturnStmt = s
		if r.value != null:
			var v: String = _copy_value(r.value)
			_flush_pending(r.line)
			_line("return " + v, r.line)
		else:
			_line("return", r.line)
	elif s is GateAST._ExprStmt:
		if _emit_struct_fill((s as GateAST._ExprStmt).expr, s.line):
			return
		if _emit_observable_call((s as GateAST._ExprStmt).expr, s.line):
			return
		if _emit_discarded_safe_call((s as GateAST._ExprStmt).expr, s.line):
			return
		var saved_stmt = _stmt_expr
		_stmt_expr = (s as GateAST._ExprStmt).expr
		var e: String = _expr((s as GateAST._ExprStmt).expr)
		_stmt_expr = saved_stmt
		_flush_pending(s.line)
		if e != "":
			_line(e, s.line)
	elif s is GateAST._AssignStmt:
		_emit_assign(s)
	elif s is GateAST._MultiAssign:
		_emit_multi_assign(s)
	elif s is GateAST._IfStmt:
		_emit_if(s)
	elif s is GateAST._ForStmt:
		_emit_for(s)
	elif s is GateAST._WhileStmt:
		_emit_while(s)
	elif s is GateAST._MatchStmt:
		_emit_match(s)
	elif s is GateAST._SignalDecl:
		_emit_signal(s)
	elif s is GateAST._EnumDecl:
		_emit_enum(s)
	else:
		diagnostics.warn("unhandled statement kind; emitting nothing", s.line, s.col)


func _emit_struct_fill(e, line: int) -> bool:
	if (not (e is GateAST._Call) or (e as GateAST._Call).args.size() != 1
			or not ((e as GateAST._Call).callee is GateAST._Member)):
		return false
	var cm: GateAST._Member = (e as GateAST._Call).callee
	if cm.safe or cm.name != "fill":
		return false
	var ct: GateAST._TypeRef = _container_tref(cm.target)
	if not _is_array_tref(ct):
		return false
	var et: GateAST._TypeRef = _array_elem(ct)
	if et == null or _copied("v", et) == "v":
		return false
	var arr: String = _render_once(cm.target, _postfix_base(cm.target))
	var v: String = _new_tmp()
	_hoist("var %s = %s" % [v, _expr((e as GateAST._Call).args[0])])
	var i: String = _new_tmp()
	_flush_pending(line)
	_line("for %s in %s.size():" % [i, arr], line)
	_indent += 1
	_line("%s[%s] = %s" % [arr, i, _copied(v, et)], line)
	_indent -= 1
	return true


func _emit_observable_call(e, line: int) -> bool:
	if not (e is GateAST._Call):
		return false
	if (e as GateAST._Call).callee is GateAST._Member and ((e as GateAST._Call).callee as GateAST._Member).safe:
		return _emit_observable_safe_call(e, line)
	var obs: Dictionary = _observable_call_root(e)
	if obs.is_empty():
		return false
	var first_args: Array = _args_first(e)
	var opened: Array = _observable_open(obs, (e as GateAST._Call).callee)
	var oc: GateAST._Call = GateAST._Call.new()
	oc.at(e.line, e.col)
	oc.callee = opened[2]
	oc.args = first_args
	var text: String = _emit_call(oc)
	_flush_pending(line)
	_line(text, line)
	_line("%s = %s" % [opened[0], opened[1]], line)
	return true


func _emit_observable_safe_call(c: GateAST._Call, line: int) -> bool:
	var cm: GateAST._Member = c.callee
	var sn: String = _observable_prop(cm.target)
	if sn == "" or not _struct_mutators(sn).has(cm.name):
		return false
	var lv: String = _observable_lvalue(cm.target)
	_flush_pending(line)
	_line("if %s != null:" % lv, line)
	_indent += 1
	var t: String = _new_tmp()
	_line("var %s = %s._gate_copy()" % [t, lv], line)
	_fn_locals[t] = {"t": sn, "e": ""}
	_var_types[t] = sn
	var recv: GateAST._Member = GateAST._Member.new()
	recv.at(cm.line, cm.col)
	recv.name = cm.name
	recv.target = _tmp_ident(t, cm)
	var oc: GateAST._Call = GateAST._Call.new()
	oc.at(c.line, c.col)
	oc.callee = recv
	oc.args = c.args
	var text: String = _emit_call(oc)
	_flush_pending(line)
	_line(text, line)
	_line("%s = %s" % [lv, t], line)
	_indent -= 1
	return true


func _emit_assign(a: GateAST._AssignStmt) -> void:
	if not _soa_cursor_write_ok(a.target):
		return
	var obs: Dictionary = _observable_root_of(a.target)
	if not obs.is_empty():
		var opened: Array = _observable_open(obs, a.target)
		var na: GateAST._AssignStmt = GateAST._AssignStmt.new()
		na.at(a.line, a.col)
		na.target = opened[2]
		na.op = a.op
		na.value = a.value
		_emit_assign(na)
		_line("%s = %s" % [opened[0], opened[1]], a.line)
		return
	if _emit_struct_compound(a):
		return
	if a.target is GateAST._Member:
		var sw: Dictionary = _swizzle_of(a.target)
		if not sw.is_empty():
			_emit_swizzle_write(a, a.target, sw)
			return
	if not _no_swizzle_below(a.target):
		return
	if _has_safe_step(a.target):
		_emit_safe_assign(a)
		return
	var saved_p: PackedStringArray = _pending
	var diag_mark: int = diagnostics.items.size()
	_pending = PackedStringArray()
	_in_lvalue += 1
	var t: String = _expr(a.target)
	_in_lvalue -= 1
	var target_pending: PackedStringArray = _pending
	_pending = PackedStringArray()
	var v: String = _copy_value(a.value) if a.op == "=" else _appended_value(a)
	var value_pending: PackedStringArray = _pending
	_pending = saved_p
	var redo: bool = not target_pending.is_empty() or (not value_pending.is_empty()
		and (a.target is GateAST._Member or a.target is GateAST._Index))
	if not redo:
		_rehoist(target_pending)
		_rehoist(value_pending)
		_flush_pending(a.line)
		_line("%s %s %s" % [t, a.op, v], a.line)
		return
	diagnostics.items.resize(diag_mark)
	_emit_ordered_assign(a)


func _emit_ordered_assign(a: GateAST._AssignStmt) -> void:
	var steps: Array = []
	var node = a.target
	while node is GateAST._Member or node is GateAST._Index:
		steps.push_front(node)
		node = node.target
	var root = node
	var n: int = steps.size()
	var last = steps[n - 1]
	var saved_p: PackedStringArray = _pending
	_pending = PackedStringArray()
	var root_text: String = _postfix_base(root)
	var root_pend: PackedStringArray = _pending
	var keys: Array = []
	var key_pend: Array = []
	for i in n - 1:
		_pending = PackedStringArray()
		keys.append(_expr((steps[i] as GateAST._Index).index) if steps[i] is GateAST._Index else "")
		key_pend.append(_pending)
	_pending = PackedStringArray()
	var v: String = _copy_value(a.value) if a.op == "=" else _appended_value(a)
	var value_pend: PackedStringArray = _pending
	_pending = PackedStringArray()
	var lk: String = _expr((last as GateAST._Index).index) if last is GateAST._Index else ""
	var lk_pend: PackedStringArray = _pending
	_pending = saved_p

	var last_hoist: int = 0 if not root_pend.is_empty() else -1
	for i in n - 1:
		if not (key_pend[i] as PackedStringArray).is_empty():
			last_hoist = 1 + i
	if not value_pend.is_empty():
		last_hoist = n
	if not lk_pend.is_empty():
		last_hoist = n + 1
	var upto: int = mini(last_hoist - 1, n - 1) if _assign_capturable(root, steps) else -1

	_rehoist(root_pend)
	var cur = root
	var backs: Array = []   # [place node, temporary, the node it stands for]
	if not (root is GateAST._Ident or root is GateAST._SelfExpr):
		var rt: String = _new_tmp()
		_hoist("var %s = %s" % [rt, root_text])
		cur = _tmp_like(rt, root)
	elif upto >= 0 and root is GateAST._Ident and not _stable(root, root_text) \
			and _is_field_name((root as GateAST._Ident).name):
		var ft: String = _new_tmp()
		_hoist("var %s = %s" % [ft, root_text])
		backs.append([root, ft, root])
		cur = _tmp_like(ft, root)
	for i in n - 1:
		_rehoist(key_pend[i])
		var st = steps[i]
		var key = null
		if st is GateAST._Index:
			key = _raw_like(keys[i], (st as GateAST._Index).index)
			if i + 1 <= upto and not _stable((st as GateAST._Index).index, keys[i]):
				var kt: String = _new_tmp()
				_hoist("var %s = %s" % [kt, keys[i]])
				key = _raw_like(kt, (st as GateAST._Index).index)
		var here = _step_on(st, cur, key)
		if i + 1 <= upto:
			var ct: String = _new_tmp()
			_hoist("var %s = %s" % [ct, _expr(here)])
			backs.append([here, ct, st])
			cur = _tmp_like(ct, st)
		else:
			cur = here
	_rehoist(value_pend)
	if last_hoist == n + 1 and not _stable(a.value, v):
		var vt: String = _new_tmp()
		_hoist("var %s = %s" % [vt, v])
		v = vt
	_rehoist(lk_pend)
	var target = _step_on(last, cur, _raw_like(lk, (last as GateAST._Index).index)
		if last is GateAST._Index else null)
	_in_lvalue += 1
	var t: String = _expr(target)
	_in_lvalue -= 1
	_flush_pending(a.line)
	_line("%s %s %s" % [t, a.op, v], a.line)
	for k in range(backs.size() - 1, -1, -1):
		var kind: String = _value_kind(backs[k][2])
		if kind == "ref":
			continue
		_in_lvalue += 1
		var place: String = _expr(backs[k][0])
		_in_lvalue -= 1
		if kind == "":
			_line("if typeof(%s) < TYPE_OBJECT:" % backs[k][1], a.line)
			_indent += 1
			_line("%s = %s" % [place, backs[k][1]], a.line)
			_indent -= 1
		else:
			_line("%s = %s" % [place, backs[k][1]], a.line)


func _assign_capturable(root, steps: Array) -> bool:
	if root is GateAST._Ident and (_soa.has((root as GateAST._Ident).name)
			or _soa_cursors.has((root as GateAST._Ident).name)):
		return false
	for st in steps:
		if _soa_name(st.target) != "":
			return false
	return true


func _is_field_name(n: String) -> bool:
	if _fn_locals.has(n) or n == "super":
		return false
	var q: String = _scope_class
	var seen: Dictionary = {}
	while q != "" and not seen.has(q) and (q == "." or _class_decls.has(q)):
		seen[q] = true
		if (_class_fields.get(q, {}) as Dictionary).has(n):
			return true
		var b: Dictionary = _base_of(q)
		if String(b["kind"]) == "ext":
			return not _field_info(String(b["name"]), n).is_empty()
		if String(b["kind"]) != "local":
			return false
		q = String(b["key"])
	return false


func _value_kind(e) -> String:
	var tr: GateAST._TypeRef = _value_tref(e)
	var key: String = ""
	if tr != null:
		if tr.array_depth > 0 or tr.is_dict() or tr.is_set() or tr.is_tuple():
			return "ref"
		if tr.is_union():
			return ""
		key = _name_key(_scope_class, _scalar_type_name(tr))
	if key == "":
		key = _declared_type_of(e)
	if key == "":
		return ""
	var c: String = GateTypes.canonical(key)
	if c == "Array" or c == "Dictionary" or (c.begins_with("Packed") and c.ends_with("Array")):
		return "ref"
	if c == "Variant":
		return ""
	if GateTypes.BUILTIN.has(c) or not _vector_struct_of_key(key).is_empty():
		return "value"
	return "ref" if _is_object_key(key) else ""


func _vector_struct_of_key(key: String) -> Dictionary:
	var st: Dictionary = _struct_of(key)
	return st if not st.is_empty() and st["lowering"] == "vector" else {}


static func _step_on(st, target, key):
	var out
	if st is GateAST._Member:
		out = GateAST._Member.new()
		(out as GateAST._Member).name = (st as GateAST._Member).name
	else:
		out = GateAST._Index.new()
		(out as GateAST._Index).index = key
	out.at(st.line, st.col)
	out.flow_type = st.flow_type
	out.target = target
	return out


func _emit_safe_assign(a: GateAST._AssignStmt) -> void:
	var chain: Array = []
	var node = a.target
	var safe_at: int = -1
	while node is GateAST._Member or node is GateAST._Index:
		chain.append(node)
		if node.safe:
			safe_at = chain.size() - 1   # the one nearest the root wins
		node = node.target
	var s = chain[safe_at]
	var recv: String = _render_once(s.target, _postfix_base(s.target))
	_flush_pending(a.line)
	var rebuilt: GateAST._Expr = _tmp_ident(recv, s)
	for i in range(safe_at, -1, -1):
		var old = chain[i]
		var nw
		if old is GateAST._Member:
			nw = GateAST._Member.new()
			nw.name = (old as GateAST._Member).name
			nw.safe = (old as GateAST._Member).safe and i != safe_at
		else:
			nw = GateAST._Index.new()
			nw.index = (old as GateAST._Index).index
			nw.safe = (old as GateAST._Index).safe and i != safe_at
		nw.at(old.line, old.col)
		nw.flow_type = old.flow_type
		nw.target = rebuilt
		rebuilt = nw
	var inner: GateAST._AssignStmt = GateAST._AssignStmt.new()
	inner.at(a.line, a.col)
	inner.op = a.op
	inner.value = a.value
	inner.target = rebuilt
	_line("if %s != null:" % recv, a.line)
	_indent += 1
	_emit_assign(inner)
	_indent -= 1


func _emit_struct_compound(a: GateAST._AssignStmt) -> bool:
	if a.op == "=" or not a.op.ends_with("="):
		return false
	var bop: String = a.op.trim_suffix("=")
	var tt: String = _static_type_of(a.target)
	if tt == "" or not (_ops_of(tt) as Dictionary).has(bop):
		return false
	var spine = _lvalue_spine(a.target)
	var bin: GateAST._Binary = GateAST._Binary.new()
	bin.at(a.line, a.col)
	bin.op = bop
	bin.left = spine
	bin.right = a.value
	var na: GateAST._AssignStmt = GateAST._AssignStmt.new()
	na.at(a.line, a.col)
	na.target = spine
	na.op = "="
	na.value = bin
	_emit_assign(na)
	return true


func _soa_cursor_write_ok(target) -> bool:
	var root = target
	while root is GateAST._Member or root is GateAST._Index:
		root = root.target
	if not (root is GateAST._Ident) or not _soa_cursors.has((root as GateAST._Ident).name) \
			or root == target:
		return true
	var cn: String = (root as GateAST._Ident).name
	var soa: String = String(_soa_cursors[cn]["soa"])
	var field: String = "field"
	var step = target
	while step is GateAST._Member or step is GateAST._Index:
		if step is GateAST._Member and step.target == root:
			field = (step as GateAST._Member).name
		step = step.target
	diagnostics.error("'%s' is a value read from the @soa array '%s', so writing to it changes nothing; write `%s[i].%s`"
			% [cn, soa, soa, field], (target as GateAST._Expr).line, (target as GateAST._Expr).col,
		"@soa keeps each field in its own array. Loop over the indices: `for i in range(%s.size()):`." % soa)
	return false


func _no_swizzle_below(target) -> bool:
	var node = target
	while node is GateAST._Member or node is GateAST._Index:
		var inner = node.target
		if inner is GateAST._Member and not _swizzle_of(inner).is_empty():
			var im: GateAST._Member = inner
			diagnostics.error("'%s' is a swizzle, a new vector, so assigning into it is lost"
					% im.name, im.line, im.col,
				"assign to the vector's own components instead.")
			return false
		node = inner
	return true


##
func _emit_swizzle_write(a: GateAST._AssignStmt, m: GateAST._Member, sw: Dictionary) -> void:
	if a.op != "=":
		diagnostics.error("a swizzle cannot take a compound assignment ('%s')" % a.op,
			a.line, a.col, "write v.xy = v.xy %s w" % a.op.trim_suffix("="))
		return
	if not _swizzle_in_range(m, sw):
		return
	for i in m.name.length():
		if m.name.find(m.name[i]) != i:
			diagnostics.error("a swizzle that is assigned to cannot repeat a component: "
					+ "'%s' names '%s' twice" % [m.name, m.name[i]], m.line, m.col,
				"each component can receive one value.")
			return
	if not _no_swizzle_below(m):
		return
	var rsize: int = int(SWIZZLE_SIZES.get(GateTypes.canonical(_declared_type_of(a.value)), 0))
	if rsize != 0 and rsize != m.name.length():
		diagnostics.error("'%s' names %d component(s) but the value is a %s"
				% [m.name, m.name.length(), GateTypes.canonical(_declared_type_of(a.value))],
			a.line, a.col, "the right side needs exactly one component per letter.")
		return
	var spine = _lvalue_spine(m.target)
	var base: String = _postfix_base(spine)
	var direct: bool = _lvalue_plain(spine)
	var cell: String = base
	if not direct:
		cell = _new_tmp()
		_hoist("var %s = %s" % [cell, base])
	var rhs: String = _new_tmp()
	_hoist("var %s = %s" % [rhs, _copy_value(a.value)])
	_flush_pending(a.line)
	for i in m.name.length():
		_line("%s.%s = %s.%s" % [cell, m.name[i], rhs, GateTypes.VECTOR_COMPONENTS[i]], a.line)
	if not direct:
		_line("%s = %s" % [base, cell], a.line)


func _lvalue_spine(e):
	if e is GateAST._Ident or e is GateAST._SelfExpr:
		return e
	if e is GateAST._Member and not (e as GateAST._Member).safe:
		var om: GateAST._Member = e
		var nm: GateAST._Member = GateAST._Member.new()
		nm.at(om.line, om.col)
		nm.name = om.name
		nm.flow_type = om.flow_type
		nm.target = _lvalue_spine(om.target)
		if nm.target is GateAST._Member:
			var ttext: String = _expr(nm.target)
			if (not _repeatable(nm.target, ttext)
					and _is_object_key(_declared_type_of(om.target))):
				nm.target = _tmp_ident(_render_once(nm.target, ttext), om)
		return nm
	if e is GateAST._Index and not (e as GateAST._Index).safe:
		var oi: GateAST._Index = e
		var ni: GateAST._Index = GateAST._Index.new()
		ni.at(oi.line, oi.col)
		ni.flow_type = oi.flow_type
		ni.target = _lvalue_spine(oi.target)
		var itxt: String = _expr(oi.index)
		if _repeatable(oi.index, itxt):
			ni.index = oi.index
		else:
			ni.index = _tmp_ident(_render_once(oi.index, itxt), oi)
		return ni
	return _tmp_ident(_render_once(e, _postfix_base(e)), e)


func _is_object_key(key: String) -> bool:
	if key == "" or GateTypes.BUILTIN.has(key):
		return false
	if key == ".":
		return true
	if _class_decls.has(key):
		var cd: GateAST._ClassDecl = _class_decls[key]
		if cd.form == "class":
			return true
		if cd.form == "struct":
			var st: Dictionary = _struct_of(cd.name)
			return st.is_empty() or st["lowering"] != "vector"
		return false
	return _reg_classes.has(key) or ClassDB.class_exists(key)


func _lvalue_plain(spine) -> bool:
	if spine is GateAST._Ident or spine is GateAST._SelfExpr:
		return _repeatable(spine, _expr(spine))
	if spine is GateAST._Member:
		return _repeatable(spine, _expr(spine))
	if spine is GateAST._Index:
		var ix: GateAST._Index = spine
		return (ix.target is GateAST._Ident and _repeatable(ix.target, _expr(ix.target))
			and _repeatable(ix.index, _expr(ix.index)))
	return false


func _emit_multi_assign(m: GateAST._MultiAssign) -> void:
	if m.destructure:
		var src: String = _expr(m.values[0])
		_flush_pending(m.line)
		var tmp: String = _new_tmp()
		_line("var %s = %s" % [tmp, src], m.line)
		var st_t: GateAST._TypeRef = (m.values[0] as GateAST._Expr).flow_type \
			if m.values[0] is GateAST._Expr else null
		var elems: Array = st_t.tuple_elems if st_t != null and st_t.is_tuple() else []
		var etrs: Array = []
		for i in m.targets.size():
			var et: GateAST._TypeRef = _elem_tref_of(m.values[0], i)
			if et == null and i < elems.size():
				et = elems[i]
			etrs.append(et)
		for i in m.targets.size():
			var name: String = (m.targets[i] as GateAST._Ident).name
			_line("var %s = %s" % [name, _copied("%s[%d]" % [tmp, i], etrs[i])], m.line)
			_bind_elem(name, etrs[i])
			if etrs[i] == null and m.values.size() == 1 and m.values[0] is GateAST._ArrayLit \
					and i < (m.values[0] as GateAST._ArrayLit).elements.size():
				var lit_t: String = _static_type_of((m.values[0] as GateAST._ArrayLit).elements[i])
				if lit_t != "":
					_var_types[name] = lit_t
					_var_depths[name] = 0
		return

	for st in m.targets:
		if not _soa_cursor_write_ok(st):
			return
		if st is GateAST._Member and not _swizzle_of(st).is_empty():
			diagnostics.error("a swizzle cannot be one of several assignment targets",
				(st as GateAST._Member).line, (st as GateAST._Member).col,
				"assign '%s' on its own line." % (st as GateAST._Member).name)
			return
		if not _no_swizzle_below(st):
			return
	var unpack: bool = m.values.size() == 1 and m.targets.size() > 1
	if not unpack and m.targets.size() != m.values.size():
		diagnostics.error("assignment has %d targets but %d values" % [m.targets.size(), m.values.size()],
			m.line, m.col)
		return
	var vals: PackedStringArray = _ordered(m.values,
		func(i: int) -> String: return _copy_value(m.values[i]))
	_flush_pending(m.line)
	var sources: PackedStringArray = PackedStringArray()
	if unpack:
		var tmp2: String = _new_tmp()
		_line("var %s = %s" % [tmp2, vals[0]], m.line)
		for i in m.targets.size():
			var uet: GateAST._TypeRef = _elem_tref_of(m.values[0], i)
			sources.append(_copied("%s[%d]" % [tmp2, i], uet))
	else:
		for i in vals.size():
			var tv: String = _new_tmp()
			sources.append(tv)
			_line("var %s = %s" % [tv, vals[i]], m.line)
	for i in m.targets.size():
		var each: GateAST._AssignStmt = GateAST._AssignStmt.new()
		each.at(m.line, m.col)
		each.target = m.targets[i]
		each.op = "="
		each.value = _raw_like(sources[i], m.targets[i])
		_emit_assign(each)


func _emit_if(st: GateAST._IfStmt) -> void:
	var c: String = _expr(st.cond)
	_flush_pending(st.line)
	_line("if %s:" % c, st.line)
	_emit_body(st.then_body, st.line)
	var opened: int = 0
	for pair in st.elifs:
		var el: int = (pair[0] as GateAST._Expr).line
		var ec: String = _expr(pair[0])
		if not _pending.is_empty():
			_line("else:", el)
			_indent += 1
			opened += 1
			for i in _pending.size():
				_pending[i] = _deeper(_pending[i], 1)
			_flush_pending(el)
			_line(_deeper("if %s:" % ec, 1), el)
			_emit_body(pair[1], el)
			continue
		_line("elif %s:" % ec, el)
		_emit_body(pair[1], el)
	if not st.else_body.is_empty():
		var ol: int = st.else_line if st.else_line > 0 else st.line
		_line("else:", ol)
		_emit_body(st.else_body, ol)
	_indent -= opened


func _emit_body(body: Array, src_line: int) -> void:
	_indent += 1
	var saved_locals: Dictionary = _fn_locals.duplicate()
	var saved_types: Dictionary = _var_types.duplicate()
	var saved_depths: Dictionary = _var_depths.duplicate()
	var saved_dicts: Dictionary = _var_dict_values.duplicate()
	if body.is_empty():
		_line("pass", src_line)
	else:
		for s in body:
			_emit_statement(s)
	_fn_locals = saved_locals
	_var_types = saved_types
	_var_depths = saved_depths
	_var_dict_values = saved_dicts
	_indent -= 1


func _emit_for(st: GateAST._ForStmt) -> void:
	var saved_locals: Dictionary = _fn_locals.duplicate()
	var saved_types: Dictionary = _var_types.duplicate()
	var saved_depths: Dictionary = _var_depths.duplicate()
	var saved_dicts: Dictionary = _var_dict_values.duplicate()
	_emit_for_inner(st)
	_fn_locals = saved_locals
	_var_types = saved_types
	_var_depths = saved_depths
	_var_dict_values = saved_dicts


func _loop_vars_in_scope(st: GateAST._ForStmt, shadow: bool = true, first: Dictionary = {}) -> void:
	for i in st.var_names.size():
		var vn: String = String(st.var_names[i])
		_fn_locals[vn] = first if i == 0 else {}
		if shadow:
			_shadow_name(vn)


func _bind_elem(name: String, etr: GateAST._TypeRef) -> void:
	_fn_locals[name] = _decl_info(_scope_class, etr) if etr != null else {}
	_shadow_name(name)
	if etr != null and etr.array_depth == 0 and not etr.is_union() and not etr.is_tuple():
		_var_types[name] = etr.name
		_var_depths[name] = 0


func _loop_var_info(st: GateAST._ForStmt) -> Dictionary:
	if st.var_type != null:
		return _decl_info(_scope_class, st.var_type)
	if not (st.iterable is GateAST._Ident):
		return {}
	var an: String = (st.iterable as GateAST._Ident).name
	var info: Dictionary = (_fn_locals[an] as Dictionary) if _fn_locals.has(an) \
		else _field_info(_scope_class, an)
	var tr = info.get("tr")
	var is_dict: bool = tr != null and ((tr as GateAST._TypeRef).is_dict()
		or (GateTypes.canonical((tr as GateAST._TypeRef).name) == "Dictionary"))
	var et: String = String(info.get("k" if is_dict else "e", ""))
	return {"t": et, "e": ""} if et != "" else {}


static func _iterates_keys(it) -> bool:
	return (it is GateAST._Call and (it as GateAST._Call).args.is_empty()
		and (it as GateAST._Call).callee is GateAST._Member
		and ((it as GateAST._Call).callee as GateAST._Member).name == "keys")


func _emit_for_inner(st: GateAST._ForStmt) -> void:
	if st.is_enumerate and st.var_names.size() == 2:
		var call: GateAST._Call = st.iterable
		var target: String = _expr(call.args[0]) if not call.args.is_empty() else "[]"
		_flush_pending(st.line)
		var tmp: String = _new_tmp()
		_line("var %s = %s" % [tmp, target], st.line)
		var etr: GateAST._TypeRef = _elem_tref_of(call.args[0]) if not call.args.is_empty() else null
		_line("for %s in range(%s.size()):" % [st.var_names[0], tmp], st.line)
		_indent += 1
		_line("var %s = %s" % [st.var_names[1],
			_copied("%s[%s]" % [tmp, st.var_names[0]], etr)], st.line)
		_indent -= 1
		_loop_vars_in_scope(st)
		_bind_elem(String(st.var_names[1]), etr)
		_emit_body(st.body, st.line)
		return

	if st.var_names.size() == 2:
		var it: String = _expr(st.iterable)
		var vtr: GateAST._TypeRef = _elem_tref_of(st.iterable)
		_flush_pending(st.line)
		var tmp2: String = _new_tmp()
		_line("var %s = %s" % [tmp2, it], st.line)
		_line("for %s in %s:" % [st.var_names[0], tmp2], st.line)
		_indent += 1
		_line("var %s = %s" % [st.var_names[1],
			_copied("%s[%s]" % [tmp2, st.var_names[0]], vtr)], st.line)
		_indent -= 1
		_loop_vars_in_scope(st)
		_bind_elem(String(st.var_names[1]), vtr)
		_emit_body(st.body, st.line)
		return

	var soa_src: String = _soa_name(st.iterable)
	if soa_src != "" and st.var_names.size() <= 1:
		var sinfo: Dictionary = _soa[soa_src]
		var idx: String = _new_tmp()
		_flush_pending(st.line)
		_line("for %s in range(%s.size()):" % [idx, sinfo["arrays"][0]], st.line)
		var cvn: String = st.var_names[0] if not st.var_names.is_empty() else "_"
		var had: bool = _soa_cursors.has(cvn)
		var prev = _soa_cursors.get(cvn, null)
		_soa_cursors[cvn] = {"soa": soa_src, "idx": idx}
		_emit_body(st.body, st.line)
		if had:
			_soa_cursors[cvn] = prev
		else:
			_soa_cursors.erase(cvn)
		return

	var first_info: Dictionary = _loop_var_info(st)
	var etr: GateAST._TypeRef = st.var_type if st.var_type != null else _loop_elem_tref(st.iterable)
	if st.var_names.size() == 1:
		_shadow_name(String(st.var_names[0]))
		if etr != null and etr.array_depth == 0 and not etr.is_union() and not etr.is_tuple() \
				and etr.name != "":
			_var_types[st.var_names[0]] = etr.name
			_var_depths[st.var_names[0]] = 0

	var it2: String = _expr(st.iterable)
	_flush_pending(st.line)
	var vn: String = st.var_names[0] if not st.var_names.is_empty() else "_"
	var copied: String = vn
	if vn != "_" and (etr != null or _iter_unknown(st.iterable)) and not _copies_first(st.body, vn) 			and not _iterates_keys(st.iterable):
		copied = _copied(vn, etr)
	var asks: bool = (copied != vn and etr == null
		and not _is_array_tref(_container_tref(st.iterable)))
	if asks and not _repeatable(st.iterable, it2):
		var held: String = _new_tmp()   # asked twice, so read once
		_line("var %s = %s" % [held, it2], st.line)
		it2 = held
	if st.var_type != null:
		_line("for %s: %s in %s:" % [vn, _map_type(st.var_type), it2], st.line)
	else:
		_line("for %s in %s:" % [vn, it2], st.line)
	if asks:
		copied = "(%s if typeof(%s) != TYPE_DICTIONARY else %s)" % [copied, it2, vn]
	if copied != vn:
		_indent += 1
		_line("%s = %s" % [vn, copied], st.line)
		_indent -= 1
	_loop_vars_in_scope(st, false, first_info)
	if st.var_names.size() == 1 and first_info.is_empty() and etr != null:
		_fn_locals[vn] = _decl_info(_scope_class, etr)
	_emit_body(st.body, st.line)


func _emit_while(st: GateAST._WhileStmt) -> void:
	var c: String = _expr(st.cond)
	if _pending.is_empty():
		_line("while %s:" % c, st.line)
		_emit_body(st.body, st.line)
		return
	var pend: PackedStringArray = _pending
	_pending = PackedStringArray()
	_line("while true:", st.line)
	_indent += 1
	for p in pend:
		_line(_deeper(p, 1), st.line)
	_line(_deeper("if %s:" % _not_text(st.cond, c), 1), st.line)
	_indent += 1
	_line("break", st.line)
	_indent -= 2
	_emit_body(st.body, st.line)


func _emit_match(st: GateAST._MatchStmt) -> void:
	var subj: String = _expr(st.subject)
	_flush_pending(st.line)
	var subject_t: String = _static_type_of(st.subject)
	var subject_struct: bool = _is_class_struct_name(subject_t)
	var union_structs: Array = []
	var sflow: GateAST._TypeRef = (st.subject as GateAST._Expr).flow_type \
		if st.subject is GateAST._Expr else null
	if sflow != null and sflow.is_union():
		for um in sflow.union_members:
			if _is_class_struct(um):
				union_structs.append((um as GateAST._TypeRef).name)
	var copied: Array = []
	for br0 in st.branches:
		for p0 in br0[0]:
			if p0 is GateAST._TypePattern:
				var tn: String = (p0 as GateAST._TypePattern).type.name
				if (p0 as GateAST._TypePattern).type.array_depth == 0 \
					and _is_class_struct_name(tn) and not copied.has(tn):
					copied.append(tn)
			elif subject_struct and _whole_binding(p0) != "" and not copied.has(subject_t):
				copied.append(subject_t)
			elif _whole_binding(p0) != "":
				for un in union_structs:
					if not copied.has(un):
						copied.append(un)
	if subject_struct and not copied.is_empty() and st.subject is GateAST._Ident:
		subj = "%s._gate_copy()" % subj
	elif not copied.is_empty() and _gate_copy_call(st.subject):
		pass   # already a copy of its own, on a recompile: no branch can alias it
	elif not copied.is_empty():
		var t: String = subj
		if not _repeatable(st.subject, subj):   # a property's getter is read once
			t = _new_tmp()
			_line("var %s = %s" % [t, subj], st.line)
		var tests: PackedStringArray = PackedStringArray()
		for cn in copied:
			tests.append("%s is %s" % [t, _map_type_name(cn)])
		subj = "(%s._gate_copy() if %s else %s)" % [t, " or ".join(tests), t]
	_line("match %s:" % subj, st.line)
	_indent += 1
	for br in st.branches:
		var pats: Array = br[0]
		var guard = br[1]
		var body: Array = br[2]
		var saved_types: Dictionary = _var_types.duplicate()
		var saved_depths: Dictionary = _var_depths.duplicate()
		var saved_locals: Dictionary = _fn_locals.duplicate()
		var saved_dicts: Dictionary = _var_dict_values.duplicate()
		var parts: PackedStringArray = PackedStringArray()
		var bind_copies: PackedStringArray = PackedStringArray()
		var bind_renames: Dictionary = {}
		for p in pats:
			if p is GateAST._RawExpr:
				var pc: Dictionary = _pattern_copies((p as GateAST._RawExpr).text, st.subject)
				parts.append(String(pc["text"]))
				bind_copies.append_array(pc["lines"])
				bind_renames.merge(pc["renames"])
				for bn in _pattern_binds((p as GateAST._RawExpr).text):
					_fn_locals[String(bn)] = {}
					_shadow_name(String(bn))
			else:
				parts.append(_expr(p))
		# A binding is a new local, then typed by its pattern: shadow first, then type.
		for p in pats:
			if p is GateAST._TypePattern:
				var tp: GateAST._TypePattern = p
				_var_types[tp.bind_name] = tp.type.name
				_var_depths[tp.bind_name] = tp.type.array_depth
				_fn_locals[tp.bind_name] = _decl_info(_scope_class, tp.type)
			elif subject_t != "" and _whole_binding(p) != "":
				_var_types[_whole_binding(p)] = subject_t
				_var_depths[_whole_binding(p)] = 0
		var head: String = ", ".join(parts)
		if guard != null:
			var saved_no_hoist: String = _no_hoist
			var saved_renames: Dictionary = _ident_renames
			_no_hoist = "guard"
			_ident_renames = bind_renames
			var g: String = _expr(guard)
			_ident_renames = saved_renames
			_no_hoist = saved_no_hoist
			if not _pending.is_empty():
				_pending = PackedStringArray()
				diagnostics.error(
					"this `when` guard needs a value computed before it, and a guard has "
						+ "nowhere to put one",
					st.line, st.col,
					"a guard runs only when its pattern matched, so nothing can be "
					+ "evaluated ahead of it. `??`, `?.` or `?[` after a call, a chained "
					+ "comparison, or a swizzle on something that is not a local need that. "
					+ "Compute the value into a local before the `match` and test that.")
			head += " when " + g
		var arm_line: int = st.line
		if not pats.is_empty() and pats[0] != null and pats[0].line > 0:
			arm_line = pats[0].line
		_line(head + ":", arm_line)
		_indent += 1
		for bc in bind_copies:
			_line(bc, arm_line)
		_indent -= 1
		_emit_body(body, arm_line)
		_fn_locals = saved_locals
		_var_types = saved_types
		_var_depths = saved_depths
		_var_dict_values = saved_dicts
	_indent -= 1


func _appended_value(a: GateAST._AssignStmt) -> String:
	var text: String = _expr(a.value)
	if a.op != "+=":
		return text
	var sname: String = _innermost_struct(_container_tref(a.target))
	if sname == "":
		sname = _innermost_struct(_container_tref(a.value))
	if sname == "" or not _is_value_class(sname):
		return text
	return "%s.%s(%s)" % [_struct_class_text(sname), _deep_helper(_struct_of(sname)), text]


func _pattern_copies(text: String, subject) -> Dictionary:
	var result: Dictionary = {"text": text, "lines": PackedStringArray(), "renames": {}}
	var out: PackedStringArray = PackedStringArray()
	var ct: GateAST._TypeRef = _container_tref(subject)
	if ct == null and not _structs_visible():
		return result
	var rewritten: String = ""
	var from: int = 0
	var stack: Array = []
	var quote: String = ""
	var i: int = 0
	while i < text.length():
		var ch: String = text[i]
		if quote != "":
			if ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "[" or ch == "{":
			stack.append(ch)
		elif ch == "]" or ch == "}":
			stack.pop_back()
		elif (text.substr(i, 4) == "var " and (i == 0 or not _is_ident_char(text[i - 1]))
				and not stack.is_empty()):
			var j: int = i + 4
			while j < text.length() and text[j] == " ":
				j += 1
			var k: int = j
			while k < text.length() and _is_ident_char(text[k]):
				k += 1
			var name: String = text.substr(j, k - j)
			var t: GateAST._TypeRef = ct
			for b in stack:
				if t == null:
					break
				if b == "[":
					t = _array_elem(t) if _is_array_tref(t) else null
				else:
					var parts: Array = _dict_parts(t)
					t = parts[1] if not parts.is_empty() else null
			if name != "":
				var inner: String = _innermost_struct(t) if t != null else ""
				var deep: bool = inner != "" and (_is_array_tref(t) or not _dict_parts(t).is_empty())
				if deep or t == null or _copied(name, t) != name:
					var tmp: String = _new_tmp()
					rewritten += text.substr(from, j - from) + tmp
					from = k
					var copied: String = _copied(tmp, t)
					if deep:
						copied = "%s.%s(%s)" % [_map_type_name(inner), _deep_helper(_struct_of(inner)), tmp]
					out.append("var %s = %s" % [name, copied])
					result["renames"][name] = tmp
			i = k
			continue
		i += 1
	result["text"] = rewritten + text.substr(from)
	result["lines"] = out
	return result


static func _gate_temp_name(n: String) -> bool:
	return n.length() > 3 and n.begins_with("__g") and n.substr(3, 1).is_valid_int()


static func _gate_copy_call(e) -> bool:
	return (e is GateAST._Call and (e as GateAST._Call).args.is_empty()
		and (e as GateAST._Call).callee is GateAST._Member
		and ((e as GateAST._Call).callee as GateAST._Member).name == "_gate_copy")


func _whole_binding(p) -> String:
	if p is GateAST._TypePattern:
		return (p as GateAST._TypePattern).bind_name
	if not (p is GateAST._RawExpr):
		return ""
	var raw: String = (p as GateAST._RawExpr).text.strip_edges()
	if not raw.begins_with("var "):
		return ""
	var n: String = raw.substr(4).strip_edges()
	return n if n.is_valid_identifier() else ""


func _is_class_struct_name(n: String) -> bool:
	if n == "":
		return false
	var s: Dictionary = _struct_of(n)
	return not s.is_empty() and s["lowering"] != "vector"


func _map_type_name(n: String) -> String:
	var t: GateAST._TypeRef = GateAST._TypeRef.new()
	t.name = n
	return _map_type(t)

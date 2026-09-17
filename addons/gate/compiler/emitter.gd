@tool
class_name GateEmitter
extends "res://addons/gate/compiler/emitter_expr.gd"

## Emitter layer 4: statements, declarations, and the module.
##
## Comments are dropped on re-read - don't emit them. Same for anything else this
## can't read back: it breaks the fixed point.


func emit(mod: GateAST.GateModule, diags: GateDiagnostics, path: String) -> Dictionary:
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
	_soa.clear()
	_soa_cursors.clear()
	_needs_iface_helper = false
	_preload_targets.clear()
	_pending_line_src = []
	_generic_renames.clear()
	_in_namespace = false
	_warned_narrow = false

	_declared_funcs.clear()
	_func_returns.clear()
	_field_types.clear()
	_class_bases.clear()
	_var_dict_values.clear()
	_cur_base = mod.extends_type.name if mod.extends_type != null else ""
	_cur_class = ""
	_index_declared_funcs(mod.members)
	_index_structs(mod.members)
	_index_external_structs()
	_index_generics(mod.members)
	_index_local_names(mod.members)
	_collect_instantiations(mod.members)
	for gt in mod.generic_uses:
		_note_type(gt)
	for pgt in _project_generic_uses:
		if _generics.has(pgt.name):
			_note_type(pgt)
	_close_instantiations()

	for hl in HEADER_LINES:
		_line((hl as String) % path if (hl as String).contains("%s") else hl, 1)
	for ha in mod.header_annotations:
		_emit_annotation(ha)
	if mod.class_name_decl != "":
		var cn: String = "class_name " + mod.class_name_decl
		_line(cn, mod.class_name_line)
	if mod.extends_type != null:
		_line("extends " + GateTypes.resolve(mod.extends_type, diagnostics),
			mod.extends_line)
	if mod.class_name_decl != "" or mod.extends_type != null:
		_blank_line(mod.extends_line)

	var preload_at: int = _out.size()

	for m in mod.members:
		_emit_member(m)

	_emit_monomorphised()

	if _needs_iface_helper:
		_emit_iface_helper()

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


func _emit_monomorphised() -> void:
	for mangled in _instantiations:
		var pair: Array = _instantiations[mangled]
		var cd: GateAST.GateClassDecl = pair[0]
		_subst = pair[1]
		_subst_depth = pair[2] if pair.size() > 2 else {}
		var saved_name: String = cd.name
		cd.name = mangled
		var saved_params: Array = cd.generic_params
		cd.generic_params = []
		_emit_class(cd)
		cd.name = saved_name
		cd.generic_params = saved_params
		_subst = {}
		_subst_depth = {}


func _emit_member(m) -> void:
	if m != null and "line" in m:
		_blank_gap(m.line)
	if m is GateAST.GateCommentStmt:
		_line((m as GateAST.GateCommentStmt).text, m.line)
	elif m is GateAST.GateClassDecl:
		_emit_class(m)
	elif m is GateAST.GateFuncDecl:
		_emit_func(m)
	elif m is GateAST.GateVarDecl:
		_emit_var(m)
	elif m is GateAST.GateSignalDecl:
		_emit_signal(m)
	elif m is GateAST.GateEnumDecl:
		_emit_enum(m)
	elif m is GateAST.GateRawStmt:
		_emit_raw(m)
	else:
		_emit_statement(m)


func _emit_raw(r: GateAST.GateRawStmt) -> void:
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


func _emit_signal(s: GateAST.GateSignalDecl) -> void:
	for a in s.annotations:
		_emit_annotation(a)
	var parts: PackedStringArray = PackedStringArray()
	for p in s.params:
		var pp: GateAST.GateParam = p
		if pp.type != null:
			parts.append("%s: %s" % [pp.name, _map_type(pp.type)])
		else:
			parts.append(pp.name)
	if s.params.is_empty():
		_line("signal %s" % s.name, s.line)
	else:
		_line("signal %s(%s)" % [s.name, ", ".join(parts)], s.line)


func _emit_enum(e: GateAST.GateEnumDecl) -> void:
	for a in e.annotations:
		_emit_annotation(a)
	var parts: PackedStringArray = PackedStringArray()
	for i in e.keys.size():
		if i < e.values.size() and e.values[i] != null:
			parts.append("%s = %s" % [e.keys[i], _expr(e.values[i])])
		else:
			parts.append(e.keys[i])
	_line("enum %s { %s }" % [e.name, ", ".join(parts)], e.line)


func _emit_class(cd: GateAST.GateClassDecl) -> void:
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
	_cur_class = cd.name
	_cur_base = cd.extends_type.name if cd.extends_type != null else ""
	_emit_interface_marker(cd)
	var before: int = _out.size()
	for m in cd.members:
		_emit_member(m)
	if not _emitted_code_since(before):
		_line("pass", cd.line)
	_cur_base = saved_base
	_cur_class = saved_class
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


func _emit_interface_doc(_cd: GateAST.GateClassDecl) -> void:
	pass


func _emit_interface_marker(cd: GateAST.GateClassDecl) -> void:
	if cd.interface_names.is_empty():
		return
	var quoted: PackedStringArray = PackedStringArray()
	for n in cd.interface_names:
		quoted.append("\"%s\"" % n)
	_line("const __gate_impl := [%s]" % ", ".join(quoted), cd.line)


func _emit_namespace(cd: GateAST.GateClassDecl) -> void:
	_line("class %s:" % cd.name, cd.line)
	_indent += 1
	var saved_ns: bool = _in_namespace
	var before: int = _out.size()
	for m in cd.members:
		# The namespace's own members are static so `Ns.f()` reaches them. A type
		# declared inside it is a real type, and its members are not.
		_in_namespace = not (m is GateAST.GateClassDecl)
		_emit_member(m)
	_in_namespace = saved_ns
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


func _emit_struct(cd: GateAST.GateClassDecl) -> void:
	if cd.lowering == "vector":
		var ftypes: Array = []
		for f in cd.members:
			if f is GateAST.GateVarDecl and (f as GateAST.GateVarDecl).type != null:
				ftypes.append((f as GateAST.GateVarDecl).type.name)
		_warn_narrowed("struct '%s' lowers to %s, which" % [cd.name, cd.vector_type],
			ftypes, cd.line, cd.col)
		return

	_line("class %s extends RefCounted:" % cd.name, cd.line)
	_indent += 1
	_emit_interface_marker(cd)
	var fields: Array = []
	for m in cd.members:
		if m is GateAST.GateVarDecl:
			fields.append(m)
		_emit_member(m)
	if not fields.is_empty():
		_blank_line(cd.line)
		var field_names: Array = []
		for f in fields:
			field_names.append((f as GateAST.GateVarDecl).name)
		var pre: String = _free_prefix(field_names, "p_")
		var ps: PackedStringArray = PackedStringArray()
		for f in fields:
			var fv: GateAST.GateVarDecl = f
			var ft: String = _map_type(fv.type) if fv.type != null else "Variant"
			var dv: String = ""
			if fv.value != null:
				dv = _expr(fv.value)
			elif fv.type != null:
				dv = _default_for(fv.type, false)
			else:
				dv = "null"
			ps.append("%s%s: %s = %s" % [pre, fv.name, ft, dv])
		_line("func _init(%s) -> void:" % ", ".join(ps), cd.line)
		_indent += 1
		for f2 in fields:
			var fv2: GateAST.GateVarDecl = f2
			_line("%s = %s%s" % [fv2.name, pre, fv2.name], cd.line)
		_indent -= 1

	if not fields.is_empty():
		_blank_line(cd.line)
		_line("func _gate_copy() -> %s:" % cd.name, cd.line)
		_indent += 1
		var names: Array = []
		for f in fields:
			names.append((f as GateAST.GateVarDecl).name)
		var loc: String = _free_name(names, "__gate_copy")
		_line("var %s := %s.new()" % [loc, cd.name], cd.line)
		for f in fields:
			var vd: GateAST.GateVarDecl = f
			_line("%s.%s = %s" % [loc, vd.name, vd.name], cd.line)
		_line("return %s" % loc, cd.line)
		_indent -= 1
	_indent -= 1
	_blank_line(cd.line)


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


func _emit_func(fd: GateAST.GateFuncDecl) -> void:
	for a in fd.annotations:
		_emit_annotation(a)

	var name: String = fd.mangled_name if fd.mangled_name != "" else fd.name
	if fd.visibility == "priv" and not name.begins_with("_"):
		name = "_" + name

	var head: String = ""
	if fd.is_static or (_in_namespace and not fd.name.begins_with("_")):
		head += "static "
	head += "func %s(%s)" % [name, _params(fd.params)]
	if fd.return_type != null:
		head += " -> " + _map_type(fd.return_type)
	elif fd.is_operator:
		pass
	if _annotated_with(fd.annotations, "abstract"):
		_line(head, fd.line)
		_blank_line(fd.line)
		return

	_line(head + ":", fd.line)

	_indent += 1
	var saved: Dictionary = _var_types.duplicate()
	var saved_depths: Dictionary = _var_depths.duplicate()
	for p in fd.params:
		var pp: GateAST.GateParam = p
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
		for s in fd.body:
			_emit_statement(s)
		_in_func_body = saved_in_body
		_scalar_repl = saved_repl
		_scalar_names = saved_names
	_var_types = saved
	_var_depths = saved_depths
	_indent -= 1
	_blank_line(fd.line)


func _emit_annotation(a: GateAST.GateAnnotation) -> void:
	if a.name == "observable":
		return  # handled by _emit_var
	_line(_annotation_text(a), a.line)


func _annotation_text(a: GateAST.GateAnnotation) -> String:
	if a.args.is_empty():
		return "@" + a.name
	var parts: PackedStringArray = PackedStringArray()
	for arg in a.args:
		parts.append(_expr(arg))
	return "@%s(%s)" % [a.name, ", ".join(parts)]


func _inline_annotation_prefix(node) -> String:
	var out: String = ""
	for a in node.annotations:
		var an: GateAST.GateAnnotation = a
		if an.name in ["observable", "packed", "soa"]:
			continue
		if an.line != node.line:
			continue
		out += _annotation_text(an) + " "
	return out


func _emit_scalar_replaced(vd: GateAST.GateVarDecl) -> void:
	var sname: String = _scalar_repl[vd.name]
	var st: Dictionary = _struct_of(sname)
	var fields: Array = st["fields"]
	var ftypes: Array = st["types"]
	var args: Array = (vd.value as GateAST.GateCall).args
	_flush_pending(vd.line)
	for i in fields.size():
		var trefs: Array = st.get("typerefs", [])
		var tr = trefs[i] if i < trefs.size() and trefs[i] != null else null
		if tr == null:
			tr = GateAST.GateTypeRef.new()
			tr.name = String(ftypes[i]) if i < ftypes.size() else "Variant"
		var mapped: String = _map_type(tr)
		var defaults: Array = st.get("defaults", [])
		var value: String = ""
		if i < args.size():
			value = _copy_value(args[i])
		elif i < defaults.size() and defaults[i] != null:
			value = _copy_value(defaults[i])
		else:
			value = _default_for(tr, false)
		_flush_pending(vd.line)
		var local: String = _scalar_names["%s.%s" % [vd.name, fields[i]]]
		if mapped != "" and mapped != "Variant":
			_line("var %s: %s = %s" % [local, mapped, value], vd.line)
		else:
			_line("var %s = %s" % [local, value], vd.line)


func _emit_var(vd: GateAST.GateVarDecl) -> void:
	var observable: bool = _has_annotation(vd, "observable")
	var packed: bool = _has_annotation(vd, "packed")

	if _has_annotation(vd, "soa"):
		_emit_soa_decl(vd)
		return

	for a in vd.annotations:
		var va: GateAST.GateAnnotation = a
		if va.name in ["observable", "packed"]:
			continue
		if va.line == vd.line:
			continue
		_emit_annotation(va)

	var name: String = vd.name
	if vd.visibility == "priv" and not name.begins_with("_"):
		name = "_" + name

	if vd.type != null and vd.type.is_dict() and vd.type.dict_value != null:
		_var_dict_values[name] = vd.type.dict_value.name
	if vd.type != null and vd.type.name != "":
		_var_types[name] = vd.type.name
		_var_depths[name] = vd.type.array_depth
		if GateTypes.canonical(vd.type.name) == "Dictionary" and vd.type.generic_args.size() == 2:
			_var_dict_values[name] = (vd.type.generic_args[1] as GateAST.GateTypeRef).name
		if GateTypes.canonical(vd.type.name) == "Array" and vd.type.generic_args.size() == 1:
			var elem_t: GateAST.GateTypeRef = vd.type.generic_args[0] as GateAST.GateTypeRef
			if elem_t != null and elem_t.name != "":
				_var_types[name] = elem_t.name
				_var_depths[name] = elem_t.array_depth + 1
	elif vd.value != null:
		var inferred: String = _static_type_of(vd.value)
		if inferred != "":
			_var_types[name] = inferred
			_var_depths[name] = 0

	if packed and vd.type != null and vd.type.array_depth == 0:
		diagnostics.warn("@packed only applies to array declarations", vd.line, vd.col)

	var infer_this: bool = vd.inferred

	var value_src: String = ""
	if vd.value != null:
		value_src = _copy_value(vd.value)
	elif vd.type != null and vd.setter == "" and (vd.type.strict or _is_class_struct(vd.type)):
		value_src = _default_for(vd.type, packed)

	if observable:
		_emit_observable(vd, name, value_src)
		return

	_flush_pending(vd.line)

	if _in_func_body and _scalar_repl.has(vd.name):
		_emit_scalar_replaced(vd)
		return

	var decl: String = _inline_annotation_prefix(vd)
	if vd.is_const:
		decl += "const %s" % name
	else:
		decl += "%svar %s" % [
			"static " if (vd.is_static or _in_namespace) else "", name]

	if vd.type != null:
		decl += ": " + _map_type(vd.type, packed)
	elif infer_this:
		decl += " :="
		if value_src != "":
			var itail: String = ":" if vd.setter != "" else ""
			if vd.inline_accessors != "":
				itail = " " + vd.inline_accessors
			_line(decl + " " + value_src + itail, vd.line)
			_emit_accessor_tail(vd)
			return

	var tail: String = ":" if vd.setter != "" else ""
	if vd.inline_accessors != "":
		tail = " " + vd.inline_accessors
	if value_src != "":
		if infer_this and vd.type == null:
			_line("%s := %s%s" % [decl.trim_suffix(" :="), value_src, tail], vd.line)
		else:
			_line(decl + " = " + value_src + tail, vd.line)
	else:
		_line(decl + tail, vd.line)
	_emit_accessor_tail(vd)


func _emit_soa_decl(vd: GateAST.GateVarDecl) -> void:
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
		accessors.append(GateTypes.VECTOR_COMPONENTS[i] if is_vec else fields[i])
		arrays.append("%s_%s" % [vd.name, fields[i]])

	_soa[vd.name] = {
		"struct": vd.type.name,
		"fields": fields,
		"accessors": accessors,
		"elem_types": types,
		"arrays": arrays,
	}

	for i in fields.size():
		var elem: String = types[i] if GateTypes.has_packed(types[i]) else GateTypes.canonical(types[i])
		var fst: Dictionary = _struct_of(types[i])
		if not fst.is_empty() and fst["lowering"] == "vector":
			elem = fst["vector"]
		var container: String = GateTypes.packed_for(elem)
		if container == "":
			container = "Array[%s]" % elem
			_line("var %s: %s = []" % [arrays[i], container], vd.line)
		else:
			_line("var %s: %s = %s()" % [arrays[i], container, container], vd.line)


func _emit_accessor_tail(vd: GateAST.GateVarDecl) -> void:
	if vd.setter == "":
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
	var in_string: bool = false
	var src0: int = vd.setter_line if vd.setter_line > 0 else vd.line
	var k: int = 0
	for l2 in lines:
		if in_string:
			_out.append(l2)
		else:
			_out.append(_retab(l2, base, unit, _indent))
		if _triple_quotes_in(l2) % 2 == 1:
			in_string = not in_string
		_map.append(src0 + k)
		k += 1


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


func _emit_observable(vd: GateAST.GateVarDecl, name: String, value_src: String) -> void:
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
	var pub_decl: String = "var %s" % name
	if tname != "":
		pub_decl += ": " + tname
	_line(pub_decl + ":", vd.line)
	_indent += 1
	_line("set(v):", vd.line)
	_indent += 1
	_line("if %s == v: return" % backing, vd.line)
	_line("%s = v" % backing, vd.line)
	_line("on_%s_changed.emit(v)" % vd.name, vd.line)
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
	if not (e is GateAST.GateCall):
		return false
	var c: GateAST.GateCall = e
	if not (c.callee is GateAST.GateMember):
		return false
	var m: GateAST.GateMember = c.callee
	if not m.safe:
		return false
	var base: String = ""
	if m.target is GateAST.GateIdent or m.target is GateAST.GateSelfExpr:
		base = _expr(m.target)
	else:
		var recv: String = _copy_value(m.target)
		if _is_bare_ident(recv):
			base = recv
		else:
			base = _new_tmp()
			_hoist("var %s = %s" % [base, recv])
	var args: PackedStringArray = PackedStringArray()
	for a in c.args:
		args.append(_copy_value(a))
	_flush_pending(line)
	_line("if %s != null:" % base, line)
	_indent += 1
	_line("%s.%s(%s)" % [base, m.name, ", ".join(args)], line)
	_indent -= 1
	return true


func _emit_statement(s) -> void:
	if s == null:
		return
	if "line" in s:
		_blank_gap(s.line)
	if s is GateAST.GateAnnotatedStmt:
		var an: GateAST.GateAnnotatedStmt = s
		for a in an.annotations:
			_emit_annotation(a)
		_emit_statement(an.stmt)
		return

	if s is GateAST.GateCommentStmt:
		_line((s as GateAST.GateCommentStmt).text, s.line)
	elif s is GateAST.GateRawStmt:
		_emit_raw(s)
	elif s is GateAST.GateVarDecl:
		_emit_var(s)
	elif s is GateAST.GateFuncDecl:
		_emit_func(s)
	elif s is GateAST.GateClassDecl:
		_emit_class(s)
	elif s is GateAST.GateSimpleStmt:
		_line((s as GateAST.GateSimpleStmt).keyword, s.line)
	elif s is GateAST.GateReturnStmt:
		var r: GateAST.GateReturnStmt = s
		if r.value != null:
			var v: String = _copy_value(r.value)
			_flush_pending(r.line)
			_line("return " + v, r.line)
		else:
			_line("return", r.line)
	elif s is GateAST.GateExprStmt:
		if _emit_discarded_safe_call((s as GateAST.GateExprStmt).expr, s.line):
			return
		var e: String = _expr((s as GateAST.GateExprStmt).expr)
		_flush_pending(s.line)
		if e != "":
			_line(e, s.line)
	elif s is GateAST.GateAssignStmt:
		_emit_assign(s)
	elif s is GateAST.GateMultiAssign:
		_emit_multi_assign(s)
	elif s is GateAST.GateIfStmt:
		_emit_if(s)
	elif s is GateAST.GateForStmt:
		_emit_for(s)
	elif s is GateAST.GateWhileStmt:
		_emit_while(s)
	elif s is GateAST.GateMatchStmt:
		_emit_match(s)
	elif s is GateAST.GateSignalDecl:
		_emit_signal(s)
	elif s is GateAST.GateEnumDecl:
		_emit_enum(s)
	else:
		diagnostics.warn("unhandled statement kind; emitting nothing", s.line, s.col)


func _emit_assign(a: GateAST.GateAssignStmt) -> void:
	var t: String = _expr(a.target)
	var v: String = _copy_value(a.value) if a.op == "=" else _expr(a.value)
	_flush_pending(a.line)
	_line("%s %s %s" % [t, a.op, v], a.line)


func _emit_multi_assign(m: GateAST.GateMultiAssign) -> void:
	if m.destructure:
		var src: String = _expr(m.values[0])
		_flush_pending(m.line)
		var tmp: String = _new_tmp()
		_line("var %s = %s" % [tmp, src], m.line)
		for i in m.targets.size():
			var name: String = (m.targets[i] as GateAST.GateIdent).name
			_line("var %s = %s[%d]" % [name, tmp, i], m.line)
		return

	var vals: PackedStringArray = PackedStringArray()
	for v in m.values:
		vals.append(_copy_value(v))
	var targets: PackedStringArray = PackedStringArray()
	for t in m.targets:
		targets.append(_expr(t))
	_flush_pending(m.line)

	if m.values.size() == 1 and m.targets.size() > 1:
		var tmp2: String = _new_tmp()
		_line("var %s = %s" % [tmp2, vals[0]], m.line)
		for i in targets.size():
			_line("%s = %s[%d]" % [targets[i], tmp2, i], m.line)
		return

	if targets.size() != vals.size():
		diagnostics.error("assignment has %d targets but %d values" % [targets.size(), vals.size()],
			m.line, m.col)
		return

	var tmps: PackedStringArray = PackedStringArray()
	for i in vals.size():
		var tv: String = _new_tmp()
		tmps.append(tv)
		_line("var %s = %s" % [tv, vals[i]], m.line)
	for i in targets.size():
		_line("%s = %s" % [targets[i], tmps[i]], m.line)


func _emit_if(st: GateAST.GateIfStmt) -> void:
	var c: String = _expr(st.cond)
	_flush_pending(st.line)
	_line("if %s:" % c, st.line)
	_emit_body(st.then_body, st.line)
	var opened: int = 0
	for pair in st.elifs:
		var el: int = (pair[0] as GateAST.GateExpr).line
		var ec: String = _expr(pair[0])
		if not _pending.is_empty():
			_line("else:", el)
			_indent += 1
			opened += 1
			_flush_pending(el)
			_line("if %s:" % ec, el)
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
	if body.is_empty():
		_line("pass", src_line)
	else:
		for s in body:
			_emit_statement(s)
	_indent -= 1


func _emit_for(st: GateAST.GateForStmt) -> void:
	if st.is_enumerate and st.var_names.size() == 2:
		var call: GateAST.GateCall = st.iterable
		var target: String = _expr(call.args[0]) if not call.args.is_empty() else "[]"
		_flush_pending(st.line)
		var tmp: String = _new_tmp()
		_line("var %s = %s" % [tmp, target], st.line)
		_line("for %s in range(%s.size()):" % [st.var_names[0], tmp], st.line)
		_indent += 1
		_line("var %s = %s[%s]" % [st.var_names[1], tmp, st.var_names[0]], st.line)
		_indent -= 1
		_emit_body(st.body, st.line)
		return

	if st.var_names.size() == 2:
		var it: String = _expr(st.iterable)
		_flush_pending(st.line)
		var tmp2: String = _new_tmp()
		_line("var %s = %s" % [tmp2, it], st.line)
		_line("for %s in %s:" % [st.var_names[0], tmp2], st.line)
		_indent += 1
		_line("var %s = %s[%s]" % [st.var_names[1], tmp2, st.var_names[0]], st.line)
		_indent -= 1
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

	if st.var_names.size() == 1:
		var elem: String = ""
		if st.var_type != null:
			elem = st.var_type.name
		elif st.iterable is GateAST.GateIdent:
			var an: String = (st.iterable as GateAST.GateIdent).name
			if int(_var_depths.get(an, 0)) == 1:
				elem = String(_var_types.get(an, ""))
		if elem != "":
			_var_types[st.var_names[0]] = elem
			_var_depths[st.var_names[0]] = 0

	var it2: String = _expr(st.iterable)
	_flush_pending(st.line)
	var vn: String = st.var_names[0] if not st.var_names.is_empty() else "_"
	if st.var_type != null:
		_line("for %s: %s in %s:" % [vn, _map_type(st.var_type), it2], st.line)
	else:
		_line("for %s in %s:" % [vn, it2], st.line)
	var elem_t: String = String(_var_types.get(vn, ""))
	var est: Dictionary = _struct_of(elem_t)
	if not est.is_empty() and est["lowering"] != "vector":
		_indent += 1
		_line("%s = %s._gate_copy()" % [vn, vn], st.line)
		_indent -= 1
	_emit_body(st.body, st.line)


func _emit_while(st: GateAST.GateWhileStmt) -> void:
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
		_line(p, st.line)
	_line("if not (%s): break" % c, st.line)
	_indent -= 1
	_emit_body(st.body, st.line)


func _emit_match(st: GateAST.GateMatchStmt) -> void:
	var subj: String = _expr(st.subject)
	_flush_pending(st.line)
	_line("match %s:" % subj, st.line)
	_indent += 1
	for br in st.branches:
		var pats: Array = br[0]
		var guard = br[1]
		var body: Array = br[2]
		var parts: PackedStringArray = PackedStringArray()
		for p in pats:
			parts.append(_expr(p))
		var head: String = ", ".join(parts)
		if guard != null:
			var g: String = _expr(guard)
			if not _pending.is_empty():
				_pending = PackedStringArray()
				diagnostics.error(
					"a `when` guard cannot contain `??`, `?.`, `?[` or a chained comparison",
					st.line, st.col,
					"those need a temporary evaluated before the test, and a guard "
					+ "has nowhere to put one. Compute it into a local before the "
					+ "`match` and test that instead.")
			head += " when " + g
		var arm_line: int = st.line
		if not pats.is_empty() and pats[0] != null and pats[0].line > 0:
			arm_line = pats[0].line
		_line(head + ":", arm_line)
		_emit_body(body, arm_line)
	_indent -= 1

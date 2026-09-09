@tool
class_name GateChecker
extends RefCounted

## Semantic pass. Inlines traits, resolves interfaces, decides struct lowering,
## and mangles overloads. Mutates the AST so the emitter stays simple.

var diagnostics: GateDiagnostics

var interfaces: Dictionary = {}   ## name -> ClassDecl
var traits: Dictionary = {}       ## name -> ClassDecl
var structs: Dictionary = {}      ## name -> ClassDecl
var classes: Dictionary = {}      ## name -> ClassDecl

const ENGINE_PREFIX := "_"


func check(mod: GateAST.Module, diags: GateDiagnostics, registry = null) -> void:
	diagnostics = diags
	interfaces.clear(); traits.clear(); structs.clear(); classes.clear()

	_collect(mod.members)
	if registry != null:
		for k in registry.interfaces:
			if not interfaces.has(k): interfaces[k] = registry.interfaces[k]
		for k in registry.traits:
			if not traits.has(k): traits[k] = registry.traits[k]
		for k in registry.structs:
			if not structs.has(k): structs[k] = registry.structs[k]
		for k in registry.classes:
			if not classes.has(k): classes[k] = registry.classes[k]
	for m in mod.members:
		_process(m)
	_process_overloads(mod.members)
	_link_inherited_overloads(mod.members)
	_check_generated_names(mod.members, false)
	_check_type_names(mod.members, {})


func _check_type_names(members: Array, known: Dictionary) -> void:
	for m in members:
		if m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
			var inner: Dictionary = known.duplicate()
			for gp in cd.generic_params:
				inner[String(gp)] = true
			_check_type_names(cd.members, inner)
		elif m is GateAST.VarDecl:
			var vd: GateAST.VarDecl = m
			if vd.type != null and vd.type.strict:
				_verify_type_name(vd.type, known)
		elif m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			for p in fd.params:
				var pp: GateAST.Param = p
				if pp.type != null and pp.type.strict:
					_verify_type_name(pp.type, known)
			if fd.return_type != null and fd.return_type.strict:
				_verify_type_name(fd.return_type, known)
			_check_type_names(fd.body, known)


func _verify_type_name(t: GateAST.TypeRef, known: Dictionary) -> void:
	if t == null or t.is_path_literal:
		return
	for g in t.generic_args:
		_verify_type_name(g, known)
	if t.dict_key != null:
		_verify_type_name(t.dict_key, known)
	if t.dict_value != null:
		_verify_type_name(t.dict_value, known)
	if t.set_elem != null:
		_verify_type_name(t.set_elem, known)
	var n: String = t.name
	if n == "" or n.contains("."):
		return   # qualified names resolve at load time
	if known.has(n):
		return   # a generic parameter in scope
	if GateTypes.SHORTHAND.has(n) or GateTypes.BUILTIN.has(GateTypes.canonical(n)):
		return
	if interfaces.has(n) or traits.has(n) or structs.has(n) or classes.has(n):
		return
	if ClassDB.class_exists(n):
		return
	for c in ProjectSettings.get_global_class_list():
		if c["class"] == n:
			return
	var hint: String = "declare it, or use one of GATE's shorthands (int, float, bool, str, vec2, ...)"
	for sh in GateTypes.SHORTHAND:
		if GateTypes.SHORTHAND[sh].to_lower() == n.to_lower():
			hint = "GATE spells that `%s`" % sh
			break
	diagnostics.error("unknown type '%s'" % n, t.line, t.col, hint)


func _check_generated_names(members: Array, in_struct: bool) -> void:
	var names: Dictionary = {}
	var signals: Dictionary = {}
	for m in members:
		if m is GateAST.VarDecl:
			names[(m as GateAST.VarDecl).name] = true
		elif m is GateAST.SignalDecl:
			signals[(m as GateAST.SignalDecl).name] = true

	for m in members:
		if m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
			_check_generated_names(cd.members, cd.form == "struct")
			continue
		if not (m is GateAST.VarDecl):
			continue
		var vd: GateAST.VarDecl = m
		if _annotated(vd, "observable"):
			_check_observable(vd, names, signals, in_struct)
		elif _annotated(vd, "soa"):
			_check_soa_names(vd, names)


func _annotated(vd: GateAST.VarDecl, what: String) -> bool:
	for a in vd.annotations:
		if (a as GateAST.Annotation).name == what:
			return true
	return false


func _check_observable(vd: GateAST.VarDecl, names: Dictionary, signals: Dictionary, in_struct: bool) -> void:
	if in_struct:
		diagnostics.error("@observable is not available on a struct field", vd.line, vd.col,
			"a struct lowers to a Vector or to a plain data class, and neither can carry "
			+ "a signal. Use a `class` if '%s' needs to notify on change." % vd.name)
		return
	if vd.is_static:
		diagnostics.error("@observable is not available on a static variable", vd.line, vd.col,
			"the generated `on_%s_changed` signal is per instance, so there is nothing "
			% vd.name + "for a static setter to emit it on.")
	if vd.setter != "":
		diagnostics.error("'%s' is @observable and also declares its own accessors"
			% vd.name, vd.line, vd.col,
			"@observable generates the getter and setter, so the ones written here would "
			+ "be discarded. Keep one or the other.")
	var backing: String = "__" + vd.name
	if names.has(backing):
		diagnostics.error("@observable on '%s' needs the name '%s', which is already declared"
			% [vd.name, backing], vd.line, vd.col,
			"@observable keeps the value in a backing field of that name. Rename one of them.")
	var sig: String = "on_%s_changed" % vd.name
	if signals.has(sig):
		diagnostics.error("@observable on '%s' generates signal '%s', which is already declared"
			% [vd.name, sig], vd.line, vd.col,
			"remove the hand-written signal - @observable emits this one itself.")


func _check_soa_names(vd: GateAST.VarDecl, names: Dictionary) -> void:
	if vd.type == null or not structs.has(vd.type.name):
		return
	var sd: GateAST.ClassDecl = structs[vd.type.name]
	for f in sd.members:
		if not (f is GateAST.VarDecl):
			continue
		var generated: String = "%s_%s" % [vd.name, (f as GateAST.VarDecl).name]
		if names.has(generated):
			diagnostics.error("@soa on '%s' needs the name '%s', which is already declared"
				% [vd.name, generated], vd.line, vd.col,
				"@soa emits one array per struct field, named `<array>_<field>`. "
				+ "Rename one of them.")


func _collect(members: Array) -> void:
	for m in members:
		if m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
			match cd.form:
				"interface": interfaces[cd.name] = cd
				"trait": traits[cd.name] = cd
				"struct": structs[cd.name] = cd
				_: classes[cd.name] = cd
			_collect(cd.members)


func _process(node: GateAST.Stmt) -> void:
	if not (node is GateAST.ClassDecl):
		return
	var cd: GateAST.ClassDecl = node

	match cd.form:
		"struct":
			_check_struct(cd)
		"interface":
			_check_interface_decl(cd)
		"trait":
			pass
		"namespace":
			_check_namespace(cd)
		_:
			pass

	if cd.form in ["class", "struct", "namespace"]:
		_apply_traits(cd)
		_flatten_interfaces(cd)
		_verify_conformance(cd)
		_verify_overrides(cd)

	for m in cd.members:
		_process(m)
	_process_overloads(cd.members)


func _apply_traits(cd: GateAST.ClassDecl) -> void:
	if cd.traits.is_empty():
		return
	var seen: Dictionary = {}
	for existing in cd.members:
		var n: String = _member_name(existing)
		if n != "":
			seen[n] = "the class itself"

	var injected: Array = []
	for tname in cd.traits:
		if not traits.has(tname):
			diagnostics.error("unknown trait '%s'" % tname, cd.line, cd.col,
				"traits must be declared with `trait %s:` before use" % tname)
			continue
		var tr: GateAST.ClassDecl = traits[tname]

		for req in tr.requires:
			if not seen.has(req):
				diagnostics.error(
					"'%s' requires a member '%s', which '%s' does not provide" % [tname, req, cd.name],
					cd.line, cd.col)

		for tm in tr.members:
			var n2: String = _member_name(tm)
			if n2 == "":
				continue
			if seen.has(n2):
				var owner: String = seen[n2]
				if owner == "the class itself":
					continue
				diagnostics.error(
					"trait conflict: '%s' is provided by both '%s' and '%s'" % [n2, owner, tname],
					cd.line, cd.col,
					"remove one, or override it in '%s' to disambiguate" % cd.name)
				continue
			seen[n2] = tname
			injected.append(tm)

		for impl in tr.implements:
			if not cd.implements.has(impl):
				cd.implements.append(impl)

	if not injected.is_empty():
		var rest: Array = cd.members.duplicate()
		cd.members = injected
		cd.members.append_array(rest)


func _member_name(m) -> String:
	if m is GateAST.FuncDecl: return (m as GateAST.FuncDecl).name
	if m is GateAST.VarDecl: return (m as GateAST.VarDecl).name
	if m is GateAST.SignalDecl: return (m as GateAST.SignalDecl).name
	return ""


func _check_interface_decl(cd: GateAST.ClassDecl) -> void:
	for m in cd.members:
		if m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			if not fd.body.is_empty():
				diagnostics.warn("interface method '%s' has a body; it will be ignored" % fd.name,
					fd.line, fd.col, "interfaces declare signatures only")


func _flatten_interfaces(cd: GateAST.ClassDecl) -> void:
	var names: Array = []
	var queue: Array = cd.implements.duplicate()
	while not queue.is_empty():
		var n: String = queue.pop_front()
		if names.has(n):
			continue
		names.append(n)
		if interfaces.has(n):
			var idecl: GateAST.ClassDecl = interfaces[n]
			for parent in idecl.implements:
				queue.append(parent)
		else:
			diagnostics.error("unknown interface '%s'" % n, cd.line, cd.col,
				"declare it with `interface %s:` or remove it from the implements list" % n)
	cd.interface_names = names


func _verify_conformance(cd: GateAST.ClassDecl) -> void:
	if cd.interface_names.is_empty():
		return
	var provided: Dictionary = {}
	for m in cd.members:
		if m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			provided[fd.name] = fd
		elif m is GateAST.VarDecl:
			provided[(m as GateAST.VarDecl).name] = m

	for iname in cd.interface_names:
		if not interfaces.has(iname):
			continue
		var idecl: GateAST.ClassDecl = interfaces[iname]
		for im in idecl.members:
			if im is GateAST.VarDecl:
				var ivd: GateAST.VarDecl = im
				if not provided.has(ivd.name):
					var tn: String = ivd.type.describe() if ivd.type != null else "Variant"
					var acc: String = ""
					if not ivd.accessor_requirement.is_empty():
						acc = " { %s }" % ", ".join(PackedStringArray(ivd.accessor_requirement))
					diagnostics.error(
						"'%s' does not provide '%s.%s'" % [cd.name, iname, ivd.name],
						cd.line, cd.col,
						"add: %s %s%s" % [tn, ivd.name, acc])
				continue
			if im is GateAST.FuncDecl:
				var ifd: GateAST.FuncDecl = im
				if not provided.has(ifd.name):
					diagnostics.error(
						"'%s' does not implement '%s.%s'" % [cd.name, iname, ifd.name],
						cd.line, cd.col,
						"add: func %s(%s) -> %s" % [
							ifd.name, _params_sig(ifd.params),
							GateTypes.resolve(ifd.return_type) if ifd.return_type else "void"])
					continue
				var got = provided[ifd.name]
				if got is GateAST.FuncDecl:
					var gfd: GateAST.FuncDecl = got
					if gfd.params.size() != ifd.params.size():
						diagnostics.error(
							"'%s.%s' takes %d parameter(s) but '%s' declares %d" % [
								cd.name, gfd.name, gfd.params.size(), iname, ifd.params.size()],
							gfd.line, gfd.col)


func _params_sig(params: Array) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for p in params:
		var pp: GateAST.Param = p
		parts.append("%s: %s" % [pp.name, GateTypes.resolve(pp.type) if pp.type else "Variant"])
	return ", ".join(parts)


func _verify_overrides(cd: GateAST.ClassDecl) -> void:
	for m in cd.members:
		if not (m is GateAST.FuncDecl):
			continue
		var fd: GateAST.FuncDecl = m
		if not fd.is_override:
			continue
		if fd.name.begins_with(ENGINE_PREFIX):
			continue
		var found: bool = false
		if cd.extends_type != null and classes.has(cd.extends_type.name):
			var parent: GateAST.ClassDecl = classes[cd.extends_type.name]
			for pm in parent.members:
				if pm is GateAST.FuncDecl and (pm as GateAST.FuncDecl).name == fd.name:
					found = true
					if (pm as GateAST.FuncDecl).is_final:
						diagnostics.error(
							"cannot override '%s': it is declared final in '%s'" % [fd.name, parent.name],
							fd.line, fd.col)
					break
		elif cd.extends_type != null:
			found = true
		if not found and cd.extends_type != null:
			diagnostics.error(
				"'%s' is marked override but '%s' declares no such method" % [fd.name, cd.extends_type.name],
				fd.line, fd.col,
				"check the spelling, or remove `override`")


func _check_struct(cd: GateAST.ClassDecl) -> void:
	var field_types: Array = []
	var fields: Array = []
	for m in cd.members:
		if m is GateAST.VarDecl:
			var vd: GateAST.VarDecl = m
			fields.append(vd)
			if vd.type != null:
				field_types.append(vd.type.name)
			else:
				field_types.append("Variant")
		elif m is GateAST.FuncDecl:
			pass
		elif m is GateAST.CommentStmt:
			pass

	if fields.is_empty():
		diagnostics.error("struct '%s' has no fields" % cd.name, cd.line, cd.col)
		cd.lowering = "class"
		return

	var has_methods: bool = false
	for m2 in cd.members:
		if m2 is GateAST.FuncDecl:
			has_methods = true
			break

	var low: Dictionary = GateTypes.struct_lowering(field_types)
	if low["kind"] == "vector" and not has_methods:
		cd.lowering = "vector"
		cd.vector_type = low["vector"]
		diagnostics.info(
			"struct '%s' lowered to %s (value semantics, no allocation)" % [cd.name, cd.vector_type],
			cd.line, cd.col)
	else:
		cd.lowering = "class"
		var why: String = "it has %d fields" % fields.size()
		if has_methods:
			why = "it declares methods"
		elif fields.size() >= 2 and fields.size() <= 4:
			why = "its fields are not all the same numeric type"
		diagnostics.info(
			"struct '%s' lowered to a class because %s; value semantics are kept by copying"
				% [cd.name, why],
			cd.line, cd.col,
			"structs of 2-4 same-typed int/float fields lower to Vector2/3/4 and copy for free. "
			+ "This one allocates on each copy - use `class` if you want reference semantics.")


func _check_namespace(cd: GateAST.ClassDecl) -> void:
	for m in cd.members:
		if m is GateAST.ClassDecl:
			var inner: GateAST.ClassDecl = m
			if inner.extends_type != null:
				var base: String = GateTypes.canonical(inner.extends_type.name)
				if base.begins_with("Node") or base.ends_with("Body2D") or base.ends_with("Body3D"):
					diagnostics.warn(
						"'%s.%s' extends a Node type inside a namespace" % [cd.name, inner.name],
						inner.line, inner.col,
						"namespaced classes become inner classes and cannot be attached to nodes "
						+ "as scripts. Move it to the top level if it needs to be a node script.")

const REST_ARITY := -1


func _link_inherited_overloads(members: Array) -> void:
	for m in members:
		if not (m is GateAST.ClassDecl):
			continue
		var cd: GateAST.ClassDecl = m
		_link_inherited_overloads(cd.members)
		if cd.extends_type == null:
			continue
		var seen: Dictionary = {}
		var base_name: String = cd.extends_type.name
		while base_name != "" and not seen.has(base_name):
			seen[base_name] = true
			var bcd = classes.get(base_name, null)
			if not (bcd is GateAST.ClassDecl):
				break
			for bm in (bcd as GateAST.ClassDecl).members:
				if not (bm is GateAST.FuncDecl):
					continue
				var bfd: GateAST.FuncDecl = bm
				if bfd.mangled_name == "":
					continue
				for dm in cd.members:
					if not (dm is GateAST.FuncDecl):
						continue
					var dfd: GateAST.FuncDecl = dm
					if (dfd.mangled_name == "" and dfd.name == bfd.name
							and dfd.params.size() == bfd.params.size()):
						dfd.mangled_name = bfd.mangled_name
			var bx = (bcd as GateAST.ClassDecl).extends_type
			base_name = bx.name if bx != null else ""


func _process_overloads(members: Array) -> void:
	var by_name: Dictionary = {}
	for m in members:
		if m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			if not by_name.has(fd.name):
				by_name[fd.name] = []
			by_name[fd.name].append(fd)

	var taken: Dictionary = {}
	for m2 in members:
		if m2 is GateAST.FuncDecl:
			taken[(m2 as GateAST.FuncDecl).name] = true

	for name in by_name:
		var group: Array = by_name[name]
		if group.size() < 2:
			continue
		var first: GateAST.FuncDecl = group[0]
		if String(name).begins_with(ENGINE_PREFIX):
			diagnostics.error(
				"cannot overload '%s': names starting with '_' are reachable from the engine" % name,
				first.line, first.col,
				"engine callbacks and virtuals are called by name, so they must not be mangled. "
				+ "Use distinct names, or default parameters.")
			continue
		var by_arity: Dictionary = {}
		for f in group:
			var fd2: GateAST.FuncDecl = f
			var is_variadic: bool = (not fd2.params.is_empty()
				and (fd2.params[fd2.params.size() - 1] as GateAST.Param).is_rest)
			var arity: int = REST_ARITY if is_variadic else fd2.params.size()
			if by_arity.has(arity):
				if is_variadic:
					diagnostics.error(
						"cannot overload '%s': two definitions are variadic" % name,
						fd2.line, fd2.col,
						"a variadic overload already matches every argument count, so a "
						+ "second one can never be reached.")
				else:
					diagnostics.error(
						"cannot overload '%s': two definitions both take %d parameter(s)" % [name, arity],
						fd2.line, fd2.col,
						"overloads are resolved by argument count, so each must have a distinct arity. "
						+ "Use different names, or default parameters.")
				continue
			by_arity[arity] = fd2
			var mangled: String = "__%s_%s" % [name, "rest" if is_variadic else str(arity)]
			while taken.has(mangled):
				mangled = "_" + mangled
			taken[mangled] = true
			fd2.mangled_name = mangled

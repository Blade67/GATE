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

var _registry: Variant = null
var _enum_names: Dictionary = {}


func check(mod: GateAST.Module, diags: GateDiagnostics, registry = null) -> void:
	diagnostics = diags
	_registry = registry
	_path = mod.path
	_parsed = {}
	super_calls = {}
	interfaces.clear(); traits.clear(); structs.clear(); classes.clear()
	_alias_targets = []
	_enum_names = {}
	_collect_enum_names(mod.members)

	_cycle_names = registry.alias_cycles if registry != null and "alias_cycles" in registry else {}
	_substitute_aliases(mod, registry)
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
	_tp_enums = {}
	_tp_collect_enums(mod.members)
	_tp_members(mod.members, {})
	_tp_instances(mod)
	_check_member_annotations(mod, mod.members, mod.extends_type, mod.is_tool)
	for at in _alias_targets:
		_verify_type_name(at[0], at[1])
	for gu in mod.generic_uses:
		_verify_type_arguments(gu, {})


func _collect_enum_names(members: Array) -> void:
	for m in members:
		if m is GateAST.EnumDecl and (m as GateAST.EnumDecl).name != "":
			_enum_names[(m as GateAST.EnumDecl).name] = true
		elif m is GateAST.ClassDecl:
			_collect_enum_names((m as GateAST.ClassDecl).members)


var _alias_targets: Array = []


## Aliases are visible across files, but a declaration of the same name in scope wins.
func _substitute_aliases(mod: GateAST.Module, registry) -> void:
	var scope: Dictionary = {}
	if registry != null and "aliases" in registry:
		for k in registry.aliases:
			scope[k] = registry.aliases[k]
	if scope.is_empty() and not mod.has_aliases:
		return
	var walk: AliasWalk = AliasWalk.new()
	walk.report = func(msg: String, line: int, col: int, hint: String) -> void:
		diagnostics.error(msg, line, col, hint)
	walk.on_alias = func(target: GateAST.TypeRef, known: Dictionary) -> void:
		_alias_targets.append([target, known])
	walk.global_taken = project_names(registry, mod.path)
	walk.inherited = _inherited_names(mod, registry)
	scope = {} if walk.inherited.has("*") else shadowed(scope, walk.inherited)
	var module_taken: Dictionary = {}
	if mod.class_name_decl != "":
		module_taken[mod.class_name_decl] = "this file's class_name"
	if registry != null:
		for am in mod.members:
			if not (am is GateAST.TypeAliasDecl):
				continue
			var an: String = (am as GateAST.TypeAliasDecl).name
			var at: String = String(registry.origin.get(an, ""))
			if registry.classes.has(an) and registry.top_level.has(an) and at != "" \
					and at != mod.path and not walk.global_taken.has(an):
				diagnostics.warn("'%s' is also a class in %s, which wins wherever it is visible, "
						% [an, at] + "so this alias is never used", (am as GateAST.TypeAliasDecl).line,
					(am as GateAST.TypeAliasDecl).col, "rename the alias or the class")
				walk.dropped[an] = true
	if registry != null and "alias_files" in registry:
		for m in mod.members:
			if m is GateAST.TypeAliasDecl and registry.alias_files.has((m as GateAST.TypeAliasDecl).name):
				var others: PackedStringArray = PackedStringArray()
				for p in registry.alias_files[(m as GateAST.TypeAliasDecl).name]:
					if String(p) != mod.path:
						others.append(String(p))
				if not others.is_empty() and not walk.global_taken.has((m as GateAST.TypeAliasDecl).name):
					module_taken[(m as GateAST.TypeAliasDecl).name] = "an alias in %s" % ", ".join(others)
	walk.members(mod.members, scope, {}, {}, module_taken)
	if mod.extends_type != null and not module_taken.has(mod.extends_type.name):
		substitute_type(mod.extends_type, shadowed(scope, block_names(mod.members)))
	for gu in mod.generic_uses:
		substitute_type(gu, scope)
	mod.generic_uses.append_array(walk.generic_uses)


func _check_duplicate_kinds(mod: GateAST.Module, registry) -> void:
	if registry == null or not ("declared_in" in registry):
		return
	for m in mod.members:
		if not (m is GateAST.ClassDecl):
			continue
		var cd: GateAST.ClassDecl = m
		var kind: String = cd.form
		if kind == "class":
			if cd.generic_params.is_empty():
				continue
			kind = "generic class"
		if not ("kind_files" in registry):
			continue
		var files: Array = registry.kind_files.get("%s|%s" % [kind, cd.name], [])
		if files.size() < 2 or not files.has(mod.path):
			continue
		var origin: String = String(files[files.size() - 1])
		if origin == mod.path:
			continue
		var others: PackedStringArray = PackedStringArray()
		for f in files:
			if String(f) != mod.path:
				others.append(String(f))
		diagnostics.error("'%s' is a %s here and in %s" % [cd.name, kind, ", ".join(others)],
			cd.line, cd.col,
			"a %s is visible in every file, so only one of them can be it: %s is the one " % [kind, origin]
			+ "every other file gets. Rename this one")


func _check_global_names(mod: GateAST.Module) -> void:
	for m in mod.members:
		if not (m is GateAST.ClassDecl):
			continue
		var cd: GateAST.ClassDecl = m
		if cd.name == mod.class_name_decl or not is_global_identifier(cd.name):
			continue
		if cd.form != "class" or not cd.generic_params.is_empty():
			diagnostics.error("'%s' is already a global name (a class_name, an autoload, or one of "
					% cd.name + "Godot's), so this %s cannot take it" % ("generic class"
					if cd.form == "class" else cd.form), cd.line, cd.col,
				"rename it; every other file would still reach the global one")
		else:
			diagnostics.warn("'%s' is also a global name (a class_name, an autoload, or one of "
					% cd.name + "Godot's): other files keep using that one", cd.line, cd.col,
				"this file sees its own class; rename it to use it from elsewhere")


## Names no alias may take: a class_name, an autoload, a GDScript global.
static func project_names(registry, own_path: String, with_classes: bool = false) -> Dictionary:
	var out: Dictionary = {}
	for gname in GateInfer.GLOBAL_FUNCTIONS:
		out[gname] = "a GDScript global function"
	for cname in ["PI", "TAU", "INF", "NAN"]:
		out[cname] = "a GDScript global constant"
	for entry in ProjectSettings.get_global_class_list():
		out[String(entry["class"])] = "a class_name in %s" % String(entry["path"])
	if registry != null and "gd_class_names" in registry:
		for gname in registry.gd_class_names:
			out[gname] = "a class_name in %s" % String(registry.gd_class_names[gname])
	for prop in ProjectSettings.get_property_list():
		var pn: String = String(prop["name"])
		if pn.begins_with("autoload/"):
			out[pn.substr(9)] = "an autoload"
	if registry != null:
		for sname in registry.script_class_names:
			var where: String = String(registry.script_class_names[sname])
			if where != own_path:
				out[sname] = "a class_name in %s" % where
		var tables: Array = [[registry.structs, "a struct"],
				[registry.generics, "a generic class"], [registry.interfaces, "an interface"],
				[registry.traits, "a trait"], [registry.namespaces, "a namespace"]]
		if with_classes:
			tables.append([registry.classes, "a class"])
		for table in tables:
			for tname in table[0]:
				var at: String = String(registry.origin.get(tname, ""))
				if registry.top_level.has(tname) and at != own_path and not out.has(tname):
					out[tname] = "%s in %s" % [table[1], at]
	return out


func _inherited_names(mod: GateAST.Module, registry) -> Dictionary:
	var chain: Dictionary = base_chain(mod.extends_type, mod.path, registry)
	if chain["unknown"]:
		return {"*": true}
	var out: Dictionary = {}
	for n in chain["names"]:
		out[n] = true
	var base: String = chain["engine"]
	if base != "":
		for m in ClassDB.class_get_method_list(base):
			out[String(m["name"])] = true
		for p in ClassDB.class_get_property_list(base):
			out[String(p["name"])] = true
		for s in ClassDB.class_get_signal_list(base):
			out[String(s["name"])] = true
		for c in ClassDB.class_get_integer_constant_list(base):
			out[String(c)] = true
	return out


static func base_chain(ext_t: GateAST.TypeRef, path: String, registry) -> Dictionary:
	var names: Dictionary = {}
	var types: Dictionary = {}   ## inner classes and named enums
	var funcs: Dictionary = {}
	var out: Dictionary = {"names": names, "types": types, "funcs": funcs, "engine": "",
		"unknown": false, "gate": false}
	var unknown: Dictionary = out.duplicate()
	unknown["unknown"] = true
	var base: String = ext_t.name if ext_t != null else "RefCounted"
	var from: String = path
	var ctx: GateAST.Module = null
	var seen: Dictionary = {}
	while base != "" and not seen.has(from + "|" + base):
		seen[from + "|" + base] = true
		var smod: GateAST.Module = null
		var inner: PackedStringArray = PackedStringArray()
		if base.begins_with("\"") or base.begins_with("'"):
			var split: Array = split_extends_path(base)
			var script: String = split[0]
			if not script.begins_with("res://"):
				script = from.get_base_dir().path_join(script).simplify_path()
			smod = read_script(script)
			if String(split[1]) != "":
				inner = String(split[1]).split(".")
		elif ctx != null and _inner_class(ctx.members, base.get_slice(".", 0)) != null:
			smod = ctx
			inner = base.split(".")
		elif ClassDB.class_exists(base):
			out["engine"] = base
			return out
		elif registry != null and registry.classes.has(base):
			var cd: GateAST.ClassDecl = registry.classes[base]
			from = String(registry.origin.get(base, from))
			_note_members(cd.members, from, names, types, funcs)
			base = cd.extends_type.name if cd.extends_type != null else "RefCounted"
			ctx = null
			continue
		else:
			var script2: String = _global_script(base.get_slice(".", 0), registry)
			smod = read_script(script2) if script2 != "" else null
			if base.contains("."):
				inner = base.split(".").slice(1)
		if smod == null:
			return unknown
		var members: Array = smod.members
		var ext: GateAST.TypeRef = smod.extends_type
		for part in inner:
			var icd: GateAST.ClassDecl = _inner_class(members, part)
			if icd == null:
				return unknown
			members = icd.members
			ext = icd.extends_type
		from = smod.path
		ctx = smod
		if from.get_extension() == "gate" and inner.is_empty():
			out["gate"] = true   # its output declares consts GATE writes (`__gate_dep_*`)
		_note_members(members, from, names, types, funcs)
		base = ext.name if ext != null else "RefCounted"
	return out


static func _note_members(members: Array, from: String, names: Dictionary, types: Dictionary,
		funcs: Dictionary) -> void:
	for n2 in block_names(members):
		if not names.has(n2):
			names[n2] = from
	for em in members:
		if em is GateAST.EnumDecl:
			var ed: GateAST.EnumDecl = em
			if ed.name == "":
				for k in ed.keys:
					if not names.has(String(k)):
						names[String(k)] = from
			else:
				types[ed.name] = true
		elif em is GateAST.ClassDecl:
			types[(em as GateAST.ClassDecl).name] = true
		elif em is GateAST.FuncDecl:
			funcs[(em as GateAST.FuncDecl).name] = true


static func _inner_class(members: Array, cname: String) -> GateAST.ClassDecl:
	for m in members:
		if m is GateAST.ClassDecl and (m as GateAST.ClassDecl).name == cname:
			return m
	return null


static func hidden_by_base(mod: GateAST.Module, registry, chain: Dictionary = {}) -> Dictionary:
	var hidden: Dictionary = {}
	if registry == null:
		return hidden
	var cross: Array = []
	for table in [registry.classes, registry.structs, registry.generics, registry.namespaces,
			registry.interfaces, registry.traits]:
		for n in table:
			if String(registry.origin.get(n, "")) != mod.path:
				cross.append(n)
	if cross.is_empty():
		return hidden
	if chain.is_empty():
		chain = base_chain(mod.extends_type, mod.path, registry)
	var names: Dictionary = chain["names"]
	var engine: String = chain["engine"]
	for cn in cross:
		var n: String = String(cn)
		if is_global_identifier(n):
			hidden[n] = true   # Godot's globals and the project's class_names and autoloads win
		elif chain["unknown"]:
			hidden[n] = true
		elif names.has(n):
			if String(names[n]) != String(registry.origin.get(n, "")):
				hidden[n] = true
		elif engine != "" and (ClassDB.class_has_method(engine, n) or ClassDB.class_has_signal(engine, n)
				or ClassDB.class_has_integer_constant(engine, n) or ClassDB.class_has_enum(engine, n)
				or _engine_property_names(engine).has(n)):
			hidden[n] = true
	return hidden


static var _engine_props: Dictionary = {}


static func _engine_property_names(cls: String) -> Dictionary:
	if not _engine_props.has(cls):
		var names: Dictionary = {}
		for pr in ClassDB.class_get_property_list(cls):
			names[String(pr["name"])] = true
		_engine_props[cls] = names
	return _engine_props[cls]


static var _global_idents: Dictionary = {}


static func forget_global_identifiers() -> void:
	_global_idents = {}


static func is_global_identifier(n: String) -> bool:
	if n == "" or not n.is_valid_identifier():
		return false
	if not _global_idents.has(n):
		var found: bool = ClassDB.class_exists(n)
		if not found:
			var saved: bool = Engine.print_error_messages
			Engine.print_error_messages = false
			for form in ["func f():\n\tvar _v = %s\n", "func f(_x: %s):\n\tpass\n"]:
				var g: GDScript = GDScript.new()
				g.source_code = form % n
				if g.reload() == OK:
					found = true
					break
			Engine.print_error_messages = saved
		_global_idents[n] = found
	return _global_idents[n]


static func _global_script(cname: String, registry) -> String:
	if registry != null and registry.script_class_names.has(cname):
		return String(registry.script_class_names[cname])
	if registry != null and "gd_class_names" in registry and registry.gd_class_names.has(cname):
		return String(registry.gd_class_names[cname])
	for c in ProjectSettings.get_global_class_list():
		if String(c["class"]) == cname:
			return String(c["path"])
	return ""


static var _script_cache: Dictionary = {}


static func read_script(path: String) -> GateAST.Module:
	var src_path: String = path
	if path.get_extension() == "gd" and FileAccess.file_exists(path.get_basename() + ".gate"):
		src_path = path.get_basename() + ".gate"
	if not FileAccess.file_exists(src_path) or not GateProject.is_utf8(src_path):
		return null
	var src: String = FileAccess.get_file_as_string(src_path)
	var stamp: String = "%d:%d:%d" % [FileAccess.get_modified_time(src_path), src.length(), src.hash()]
	var hit: Array = _script_cache.get(src_path, [])
	if not hit.is_empty() and String(hit[0]) == stamp:
		return hit[1]
	var d: GateDiagnostics = GateDiagnostics.new()
	var smod: GateAST.Module = GateParser.new().parse(GateLexer.new().tokenize(src, d), src, d)
	if d.error_count() > 0:
		smod = null
	else:
		smod.path = src_path
	_script_cache[src_path] = [stamp, smod]
	return smod


static func fold_int(e, consts: Dictionary, depth: int = 0) -> Variant:
	if e == null or depth > 16:
		return null
	if e is GateAST.Literal:
		var lit: GateAST.Literal = e
		return int(lit.raw) if lit.kind == "number" and lit.raw.is_valid_int() else null
	if e is GateAST.Ident:
		var n: String = (e as GateAST.Ident).name
		return fold_int(consts.get(n, null), consts, depth + 1) if consts.has(n) else null
	if e is GateAST.Unary:
		var u: GateAST.Unary = e
		var v: Variant = fold_int(u.operand, consts, depth + 1)
		if v == null:
			return null
		match u.op:
			"-": return -int(v)
			"+": return int(v)
			"~": return ~int(v)
		return null
	if e is GateAST.CastExpr:
		var ce: GateAST.CastExpr = e
		if ce.type != null and GateTypes.canonical(ce.type.name) == "int":
			return fold_int(ce.operand, consts, depth + 1)
		return null
	if not (e is GateAST.Binary):
		return null
	var b: GateAST.Binary = e
	var l: Variant = fold_int(b.left, consts, depth + 1)
	var r: Variant = fold_int(b.right, consts, depth + 1)
	if l == null or r == null:
		return null
	match b.op:
		"+": return int(l) + int(r)
		"-": return int(l) - int(r)
		"*": return int(l) * int(r)
		"/": return int(l) / int(r) if int(r) != 0 else null
		"%": return int(l) % int(r) if int(r) != 0 else null
		"<<": return int(l) << int(r) if int(r) >= 0 else null
		">>": return int(l) >> int(r) if int(r) >= 0 else null
		"&": return int(l) & int(r)
		"|": return int(l) | int(r)
		"^": return int(l) ^ int(r)
	return null


static func const_values(members: Array, out: Dictionary = {}) -> Dictionary:
	for m in members:
		if m is GateAST.VarDecl and (m as GateAST.VarDecl).is_const \
				and (m as GateAST.VarDecl).value != null:
			out[(m as GateAST.VarDecl).name] = (m as GateAST.VarDecl).value
		elif m is GateAST.ClassDecl:
			const_values((m as GateAST.ClassDecl).members, out)
		elif m is GateAST.FuncDecl:
			const_values((m as GateAST.FuncDecl).body, out)
		elif m is GateAST.AnnotatedStmt:
			const_values([(m as GateAST.AnnotatedStmt).stmt], out)
	return out


static func block_names(members: Array) -> Dictionary:
	var out: Dictionary = {}
	for m in members:
		if m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
			out[cd.name] = "a %s in this file" % ("class" if cd.form == "class" else cd.form)
		elif m is GateAST.EnumDecl:
			if (m as GateAST.EnumDecl).name != "":
				out[(m as GateAST.EnumDecl).name] = "an enum in this file"
		elif m is GateAST.VarDecl:
			var vd: GateAST.VarDecl = m
			out[vd.name] = "a constant in this file" if vd.is_const else "a variable in this scope"
		elif m is GateAST.FuncDecl:
			out[(m as GateAST.FuncDecl).name] = "a function in this file"
		elif m is GateAST.SignalDecl:
			out[(m as GateAST.SignalDecl).name] = "a signal in this file"
		elif m is GateAST.AnnotatedStmt:
			out.merge(block_names([(m as GateAST.AnnotatedStmt).stmt]))
	return out


static func own_names(members: Array) -> Dictionary:
	var out: Dictionary = block_names(members)
	_own_types_deep(members, out)
	return out


static func _own_types_deep(members: Array, out: Dictionary) -> void:
	for m in members:
		if m is GateAST.ClassDecl:
			out[(m as GateAST.ClassDecl).name] = true
			_own_types_deep((m as GateAST.ClassDecl).members, out)
		elif m is GateAST.EnumDecl and (m as GateAST.EnumDecl).name != "":
			out[(m as GateAST.EnumDecl).name] = true


static func local_names(params: Array, body: Array) -> Dictionary:
	var out: Dictionary = {}
	for p in params:
		out[(p as GateAST.Param).name] = "a parameter"
	_locals_deep(body, out)
	return out


static func _locals_deep(body: Array, out: Dictionary) -> void:
	for s in body:
		if s is GateAST.VarDecl:
			out[(s as GateAST.VarDecl).name] = "a local variable"
		elif s is GateAST.AnnotatedStmt:
			_locals_deep([(s as GateAST.AnnotatedStmt).stmt], out)
		elif s is GateAST.MultiAssign and (s as GateAST.MultiAssign).declares:
			for t in (s as GateAST.MultiAssign).targets:
				if t is GateAST.Ident:
					out[(t as GateAST.Ident).name] = "a local variable"
		elif s is GateAST.IfStmt:
			var ifs: GateAST.IfStmt = s
			_locals_deep(ifs.then_body, out)
			for pair in ifs.elifs:
				_locals_deep(pair[1], out)
			_locals_deep(ifs.else_body, out)
		elif s is GateAST.ForStmt:
			for vn in (s as GateAST.ForStmt).var_names:
				out[String(vn)] = "a loop variable"
			_locals_deep((s as GateAST.ForStmt).body, out)
		elif s is GateAST.WhileStmt:
			_locals_deep((s as GateAST.WhileStmt).body, out)
		elif s is GateAST.MatchStmt:
			for br in (s as GateAST.MatchStmt).branches:
				_locals_deep(br[2], out)


static var _binding_re: RegEx = null


static func release_statics() -> void:
	_binding_re = null


static func pattern_bindings(patterns: Array) -> Dictionary:
	var out: Dictionary = {}
	for p in patterns:
		if p is GateAST.TypePattern:
			out[(p as GateAST.TypePattern).bind_name] = "a match binding"
		elif p is GateAST.RawExpr and (p as GateAST.RawExpr).text.contains("var"):
			if _binding_re == null:
				_binding_re = RegEx.create_from_string("\\bvar\\s+([A-Za-z_][A-Za-z0-9_]*)")
			for m in _binding_re.search_all((p as GateAST.RawExpr).text):
				out[m.get_string(1)] = "a match binding"
	return out


static func shadowed(scope: Dictionary, names: Dictionary) -> Dictionary:
	var hit: bool = false
	for n in names:
		if scope.has(n):
			hit = true
			break
	if not hit:
		return scope
	var out: Dictionary = scope.duplicate()
	for n2 in names:
		out.erase(n2)
	return out


static func _alias_decls_in(members: Array) -> Array:
	var out: Array = []
	for m in members:
		if m is GateAST.TypeAliasDecl:
			out.append(m)
	return out


static func _alias_decls_deep(body: Array, out: Array) -> void:
	for s in body:
		if s is GateAST.TypeAliasDecl:
			out.append(s)
		elif s is GateAST.IfStmt:
			var ifs: GateAST.IfStmt = s
			_alias_decls_deep(ifs.then_body, out)
			for pair in ifs.elifs:
				_alias_decls_deep(pair[1], out)
			_alias_decls_deep(ifs.else_body, out)
		elif s is GateAST.ForStmt:
			_alias_decls_deep((s as GateAST.ForStmt).body, out)
		elif s is GateAST.WhileStmt:
			_alias_decls_deep((s as GateAST.WhileStmt).body, out)
		elif s is GateAST.MatchStmt:
			for br in (s as GateAST.MatchStmt).branches:
				_alias_decls_deep(br[2], out)


static func extend_alias_scope(outer: Dictionary, decls: Array, known: Dictionary,
		report: Callable, on_alias: Callable, taken: Dictionary = {},
		cycles: Dictionary = {}) -> Dictionary:
	if decls.is_empty():
		return outer
	var scope: Dictionary = outer.duplicate()
	var pending: Dictionary = {}
	for d in decls:
		var ad: GateAST.TypeAliasDecl = d
		if pending.has(ad.name):
			if report.is_valid():
				report.call("'%s' is already an alias in this scope" % ad.name, ad.line, ad.col,
					"rename one of them")
			continue
		if GateTypes.is_shorthand(ad.name) or GateTypes.BUILTIN.has(ad.name) \
				or ClassDB.class_exists(ad.name) or known.has(ad.name):
			if report.is_valid():
				report.call("'%s' is already a type, so it cannot be an alias" % ad.name,
					ad.line, ad.col, "pick a name that is not a type")
			continue
		if taken.has(ad.name):
			if report.is_valid():
				report.call("'%s' is already %s, so it cannot also be an alias" % [ad.name,
						taken[ad.name]], ad.line, ad.col,
					"an alias is visible wherever that name is, so the two would collide. "
					+ "Rename the alias")
			continue
		pending[ad.name] = ad
	var state: Dictionary = {"done": {}, "stack": [], "reported": {}, "cycles": cycles}
	for n in pending:
		_resolve_alias(n, pending, scope, state, report)
	for n2 in pending:
		if on_alias.is_valid() and not (state["reported"] as Dictionary).has(n2):
			on_alias.call(scope[n2], known)
	return scope


static func _resolve_alias(name: String, pending: Dictionary, scope: Dictionary,
		state: Dictionary, report: Callable) -> GateAST.TypeRef:
	var done: Dictionary = state["done"]
	if done.has(name):
		return scope.get(name, null)
	var stack: Array = state["stack"]
	if stack.has(name):
		var cycle: Array = stack.slice(stack.find(name))
		cycle.append(name)
		var reported: Dictionary = state["reported"]
		var already: bool = false
		for c in cycle:
			if reported.has(c):
				already = true
		var shown: String = " -> ".join(PackedStringArray(cycle))
		for c2 in cycle:
			reported[c2] = true
			(state["cycles"] as Dictionary)[c2] = shown
		if not already and report.is_valid():
			var first: GateAST.TypeAliasDecl = pending[cycle[0]]
			report.call("type alias '%s' is a cycle: %s" % [first.name, shown],
				first.line, first.col, "an alias must end at a real type")
		return null
	stack.append(name)
	var ad: GateAST.TypeAliasDecl = pending[name]
	var t: GateAST.TypeRef = copy_type(ad.target)
	_substitute_resolving(t, pending, scope, state, report)
	stack.pop_back()
	if (state["reported"] as Dictionary).has(name):
		var v: GateAST.TypeRef = GateAST.TypeRef.new()
		v.at(ad.line, ad.col)
		v.name = "Variant"
		t = v
	done[name] = true
	scope[name] = t
	return t


static func _substitute_resolving(t: GateAST.TypeRef, pending: Dictionary, scope: Dictionary,
		state: Dictionary, report: Callable) -> void:
	if t == null or t.is_path_literal:
		return
	for child in _type_children(t):
		_substitute_resolving(child, pending, scope, state, report)
	var target: GateAST.TypeRef = null
	if pending.has(t.name):
		target = _resolve_alias(t.name, pending, scope, state, report)
		if target == null:
			return
	elif scope.has(t.name):
		target = scope[t.name]
	if target != null:
		_apply_alias(t, target)


static func substitute_type(t: GateAST.TypeRef, scope: Dictionary) -> void:
	if t == null or t.is_path_literal or scope.is_empty():
		return
	for child in _type_children(t):
		substitute_type(child, scope)
	if scope.has(t.name):
		_apply_alias(t, scope[t.name])


static func _type_children(t: GateAST.TypeRef) -> Array:
	var out: Array = []
	out.append_array(t.generic_args)
	out.append_array(t.union_members)
	out.append_array(t.tuple_elems)
	for cp in t.callable_params:
		if cp != null:
			out.append(cp)
	for x in [t.dict_key, t.dict_value, t.set_elem, t.callable_return]:
		if x != null:
			out.append(x)
	return out


static func _apply_alias(use: GateAST.TypeRef, target: GateAST.TypeRef) -> void:
	var c: GateAST.TypeRef = copy_type(target)
	var depth: int = use.array_depth
	if depth > 0:
		if c.array_depth == 0 and (c.nullable or use.elem_nullable):
			c.elem_nullable = true
		c.nullable = use.nullable
		c.array_depth += depth
	else:
		c.nullable = c.nullable or use.nullable
	use.name = c.name
	use.array_depth = c.array_depth
	use.dict_key = c.dict_key
	use.dict_value = c.dict_value
	use.set_elem = c.set_elem
	use.nullable = c.nullable
	use.is_path_literal = c.is_path_literal
	use.elem_nullable = c.elem_nullable
	use.generic_args = c.generic_args
	use.callable_return = c.callable_return
	use.shape = c.shape


static func copy_type(t: GateAST.TypeRef) -> GateAST.TypeRef:
	if t == null:
		return null
	var c: GateAST.TypeRef = GateAST.TypeRef.new()
	c.at(t.line, t.col)
	c.name = t.name
	c.array_depth = t.array_depth
	c.dict_key = copy_type(t.dict_key)
	c.dict_value = copy_type(t.dict_value)
	c.set_elem = copy_type(t.set_elem)
	c.nullable = t.nullable
	c.strict = t.strict
	c.is_path_literal = t.is_path_literal
	c.elem_nullable = t.elem_nullable
	for g in t.generic_args:
		c.generic_args.append(copy_type(g))
	c.callable_return = copy_type(t.callable_return)
	if t.shape != null:
		var s: GateAST.TypeShape = c.shaped()
		for u in t.shape.union_members:
			s.union_members.append(copy_type(u))
		for e in t.shape.tuple_elems:
			s.tuple_elems.append(copy_type(e))
		s.is_func_type = t.shape.is_func_type
		s.sig_known = t.shape.sig_known
		for p in t.shape.callable_params:
			s.callable_params.append(copy_type(p))
		s.callable_optional = t.shape.callable_optional
		s.callable_rest = t.shape.callable_rest
	return c


const _SHAPE_VIEWS := {"union_members": true, "tuple_elems": true, "callable_params": true,
	"is_func_type": true, "sig_known": true, "callable_optional": true, "callable_rest": true}
static var _ast_props: Dictionary = {}


static func _props_of(o: Object) -> PackedStringArray:
	var sc: Script = o.get_script()
	if _ast_props.has(sc):
		return _ast_props[sc]
	var out: PackedStringArray = PackedStringArray()
	var is_type: bool = o is GateAST.TypeRef
	for p in o.get_property_list():
		if (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		if is_type and _SHAPE_VIEWS.has(String(p["name"])):
			continue
		out.append(String(p["name"]))
	_ast_props[sc] = out
	return out


static func clone_ast(v: Variant, memo: Dictionary) -> Variant:
	if v is Array:
		var a: Array = (v as Array).duplicate(false)
		for i in a.size():
			a[i] = clone_ast(a[i], memo)
		return a
	if v is Dictionary:
		var d: Dictionary = (v as Dictionary).duplicate(false)
		for k in d.keys():
			d[k] = clone_ast(d[k], memo)
		return d
	if not (v is GateAST.ASTNode or v is GateAST.TypeShape):
		return v
	var id: int = (v as Object).get_instance_id()
	if memo.has(id):
		return memo[id]
	var c: Object = (v as Object).get_script().new()
	memo[id] = c
	for pn in _props_of(v):
		c.set(pn, clone_ast((v as Object).get(pn), memo))
	return c


static func bind_generic(cd: GateAST.ClassDecl, args: Array) -> void:
	var scope: Dictionary = {}
	for i in mini(cd.generic_params.size(), args.size()):
		scope[String(cd.generic_params[i])] = args[i]
	cd.generic_params = []
	_bind_walk(cd, scope, {})


static func _bind_walk(v: Variant, scope: Dictionary, seen: Dictionary) -> void:
	if v is Array:
		for x in v:
			_bind_walk(x, scope, seen)
		return
	if v is Dictionary:
		for x2 in (v as Dictionary).values():
			_bind_walk(x2, scope, seen)
		return
	if v is GateAST.TypeRef:
		substitute_type(v, scope)
		return
	if not (v is GateAST.ASTNode):
		return
	var id: int = (v as Object).get_instance_id()
	if seen.has(id):
		return
	seen[id] = true
	if v is GateAST.Ident and scope.has((v as GateAST.Ident).name):
		var at: GateAST.TypeRef = scope[(v as GateAST.Ident).name]
		if at.shape == null and at.array_depth == 0 and not at.is_dict() and at.generic_args.is_empty():
			(v as GateAST.Ident).name = at.name
	for pn in _props_of(v):
		_bind_walk((v as Object).get(pn), scope, seen)


static func _uses_in(v: Variant, templates: Dictionary, out: Array, seen: Dictionary) -> void:
	if v is Array:
		for x in v:
			_uses_in(x, templates, out, seen)
		return
	if v is Dictionary:
		for x2 in (v as Dictionary).values():
			_uses_in(x2, templates, out, seen)
		return
	if v is GateAST.TypeRef:
		if not (v as GateAST.TypeRef).generic_args.is_empty() and templates.has((v as GateAST.TypeRef).name):
			out.append(v)
		for ch in _type_children(v):
			_uses_in(ch, templates, out, seen)
		return
	if not (v is GateAST.ASTNode):
		return
	var id: int = (v as Object).get_instance_id()
	if seen.has(id):
		return
	seen[id] = true
	for pn in _props_of(v):
		_uses_in((v as Object).get(pn), templates, out, seen)


static func _generic_templates(members: Array, out: Dictionary) -> void:
	for m in members:
		if m is GateAST.ClassDecl:
			if not (m as GateAST.ClassDecl).generic_params.is_empty():
				out[(m as GateAST.ClassDecl).name] = m
			_generic_templates((m as GateAST.ClassDecl).members, out)


static func generic_instances(mod: GateAST.Module, registry) -> Array:
	var templates: Dictionary = {}
	var origin: Dictionary = {}
	if registry != null:
		for g in registry.generics:
			templates[g] = registry.generics[g]
			origin[g] = String(registry.origin.get(g, ""))
	var own: Dictionary = {}
	_generic_templates(mod.members, own)
	for g2 in own:
		templates[g2] = own[g2]
		origin.erase(g2)
	if templates.is_empty():
		return []
	var params: Dictionary = {}
	for g3 in templates:
		for p in (templates[g3] as GateAST.ClassDecl).generic_params:
			params[String(p)] = true
	var work: Array = []
	for gu in mod.generic_uses:
		work.append([gu, gu])
	var out: Array = []
	var seen: Dictionary = {}
	while not work.is_empty() and out.size() < GENERIC_RECHECK_LIMIT:
		var w: Array = work.pop_front()
		var t: GateAST.TypeRef = w[0]
		for ch in _type_children(t):
			work.append([ch, w[1]])
		if t.generic_args.is_empty() or not templates.has(t.name):
			continue
		var cd: GateAST.ClassDecl = templates[t.name]
		if t.generic_args.size() != cd.generic_params.size() or _names_param(t, params, own, registry):
			continue
		var key: String = GateParser.mangle_generic(t)
		if seen.has(key):
			continue
		seen[key] = true
		var bound: GateAST.ClassDecl = clone_ast(cd, {})
		bind_generic(bound, t.generic_args)
		out.append([cd, t.generic_args, w[1], origin.get(t.name, ""), bound])
		var inner: Array = []
		_uses_in(bound.members, templates, inner, {})
		for iu in inner:
			work.append([iu, w[1]])
	if not work.is_empty():
		out.append([null, [], work[0][1], "", null])   # the caller says GATE stopped reading
	return out


static func _names_param(t: GateAST.TypeRef, params: Dictionary, own: Dictionary, registry) -> bool:
	for g in _type_children(t):
		var ga: GateAST.TypeRef = g
		if params.has(ga.name) and not GateTypes.BUILTIN.has(GateTypes.canonical(ga.name)) \
				and not ClassDB.class_exists(ga.name) and not own.has(ga.name) \
				and (registry == null or not (registry.classes.has(ga.name) or registry.structs.has(ga.name))):
			return true
		if _names_param(ga, params, own, registry):
			return true
	return false


static func report_instance(into: GateDiagnostics, found: GateDiagnostics, inst: Array,
		only: Dictionary = {}) -> void:
	var have: Dictionary = {}
	for d in into.items:
		have["%d|%d|%s" % [d.line, d.col, d.message]] = true
	var cd: GateAST.ClassDecl = inst[0]
	var args: Array = inst[1]
	var site: GateAST.TypeRef = inst[2]
	var binds: PackedStringArray = PackedStringArray()
	for i in mini(cd.generic_params.size(), args.size()):
		binds.append("%s = %s" % [cd.generic_params[i], (args[i] as GateAST.TypeRef).describe()])
	for d2 in found.items:
		if d2.level != GateDiagnostics.Level.ERROR or have.has("%d|%d|%s" % [d2.line, d2.col, d2.message]):
			continue
		if not only.is_empty() and not only.has("%d:%d" % [d2.line, d2.col]):
			continue
		var where: String = "line %d of '%s'" % [d2.line, cd.name]
		if String(inst[3]) != "":
			where += " in %s" % inst[3]
		into.error("with %s, %s is an error: %s" % [", ".join(binds), where, d2.message],
			site.line, site.col, d2.hint)


static func positions_in(v: Variant, out: Dictionary, seen: Dictionary) -> void:
	if v is Array:
		for x in v:
			positions_in(x, out, seen)
		return
	if v is Dictionary:
		for x2 in (v as Dictionary).values():
			positions_in(x2, out, seen)
		return
	if not (v is GateAST.ASTNode):
		return
	var id: int = (v as Object).get_instance_id()
	if seen.has(id):
		return
	seen[id] = true
	out["%d:%d" % [(v as GateAST.ASTNode).line, (v as GateAST.ASTNode).col]] = true
	for pn in _props_of(v):
		positions_in((v as Object).get(pn), out, seen)


## Substitutes aliases with lexical scope. The checker reports; the project index is silent.
class AliasWalk extends RefCounted:
	var report: Callable = Callable()      ## (msg, line, col, hint)
	var on_alias: Callable = Callable()    ## (resolved target, generic params in scope)
	var global_taken: Dictionary = {}      ## name -> what it already is, project-wide
	var dropped: Dictionary = {}           ## aliases another file's class of the same name hides
	var inherited: Dictionary = {}         ## members the module reaches via `extends`
	var generic_uses: Array = []           ## instantiations named by an alias used as a value

	func members(ms: Array, scope: Dictionary, own: Dictionary, known: Dictionary,
			extra_taken: Dictionary = {}) -> void:
		var names: Dictionary = GateChecker.block_names(ms)
		names.merge(extra_taken)
		var here: Dictionary = GateChecker.shadowed(scope, names)
		var here_own: Dictionary = GateChecker.shadowed(own, names)
		var decls: Array = GateChecker._alias_decls_in(ms)
		if not dropped.is_empty():
			decls = decls.filter(func(d: GateAST.TypeAliasDecl) -> bool: return not dropped.has(d.name))
		if not decls.is_empty():
			var taken: Dictionary = global_taken.duplicate()
			taken.merge(names, true)
			here = GateChecker.extend_alias_scope(here, decls, known, report, on_alias, taken)
			here_own = _with_own(here_own, decls, here)
		for m in ms:
			stmt(m, here, here_own, known)

	func _with_own(own: Dictionary, decls: Array, scope: Dictionary) -> Dictionary:
		var out: Dictionary = own.duplicate()
		for d in decls:
			var n: String = (d as GateAST.TypeAliasDecl).name
			if scope.has(n):
				out[n] = true
		return out

	func _body_scope(params: Array, body: Array, scope: Dictionary, own: Dictionary,
			known: Dictionary) -> Array:
		var locals: Dictionary = GateChecker.local_names(params, body)
		var fscope: Dictionary = GateChecker.shadowed(scope, locals)
		var fown: Dictionary = GateChecker.shadowed(own, locals)
		var decls: Array = []
		GateChecker._alias_decls_deep(body, decls)
		if not decls.is_empty():
			var taken: Dictionary = global_taken.duplicate()
			taken.merge(locals, true)
			fscope = GateChecker.extend_alias_scope(fscope, decls, known, report, on_alias, taken)
			fown = _with_own(fown, decls, fscope)
		return [fscope, fown]

	func stmt(s, scope: Dictionary, own: Dictionary, known: Dictionary) -> void:
		if s == null:
			return
		if s is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = s
			var inner: Dictionary = scope
			var inner_own: Dictionary = own
			var inner_known: Dictionary = known
			if not cd.generic_params.is_empty():
				inner_known = known.duplicate()
				var gp_names: Dictionary = {}
				for gp in cd.generic_params:
					inner_known[String(gp)] = true
					gp_names[String(gp)] = "a generic parameter"
				inner = GateChecker.shadowed(scope, gp_names)
				inner_own = GateChecker.shadowed(own, gp_names)
			GateChecker.substitute_type(cd.extends_type, inner)
			members(cd.members, inner, inner_own, inner_known)
		elif s is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = s
			var fs: Array = _body_scope(fd.params, fd.body, scope, own, known)
			for p in fd.params:
				GateChecker.substitute_type((p as GateAST.Param).type, fs[0])
				expr((p as GateAST.Param).default, fs[0], fs[1], "value")
			GateChecker.substitute_type(fd.return_type, fs[0])
			for st in fd.body:
				stmt(st, fs[0], fs[1], known)
		elif s is GateAST.VarDecl:
			GateChecker.substitute_type((s as GateAST.VarDecl).type, scope)
			expr((s as GateAST.VarDecl).value, scope, own, "value")
		elif s is GateAST.SignalDecl:
			for p2 in (s as GateAST.SignalDecl).params:
				GateChecker.substitute_type((p2 as GateAST.Param).type, scope)
		elif s is GateAST.AnnotatedStmt:
			stmt((s as GateAST.AnnotatedStmt).stmt, scope, own, known)
		elif s is GateAST.IfStmt:
			var ifs: GateAST.IfStmt = s
			expr(ifs.cond, scope, own, "value")
			for a in ifs.then_body: stmt(a, scope, own, known)
			for pair in ifs.elifs:
				expr(pair[0], scope, own, "value")
				for b in pair[1]: stmt(b, scope, own, known)
			for c in ifs.else_body: stmt(c, scope, own, known)
		elif s is GateAST.ForStmt:
			var fo: GateAST.ForStmt = s
			GateChecker.substitute_type(fo.var_type, scope)
			expr(fo.iterable, scope, own, "value")
			for d in fo.body: stmt(d, scope, own, known)
		elif s is GateAST.WhileStmt:
			expr((s as GateAST.WhileStmt).cond, scope, own, "value")
			for e in (s as GateAST.WhileStmt).body: stmt(e, scope, own, known)
		elif s is GateAST.MatchStmt:
			var ms: GateAST.MatchStmt = s
			expr(ms.subject, scope, own, "value")
			for br in ms.branches:
				var binds: Dictionary = GateChecker.pattern_bindings(br[0])
				var arm: Dictionary = GateChecker.shadowed(scope, binds)
				var arm_own: Dictionary = GateChecker.shadowed(own, binds)
				expr(br[1], arm, arm_own, "value")
				for f in br[2]: stmt(f, arm, arm_own, known)
		elif s is GateAST.ReturnStmt:
			expr((s as GateAST.ReturnStmt).value, scope, own, "value")
		elif s is GateAST.ExprStmt:
			expr((s as GateAST.ExprStmt).expr, scope, own, "value")
		elif s is GateAST.AssignStmt:
			expr((s as GateAST.AssignStmt).target, scope, own, "value")
			expr((s as GateAST.AssignStmt).value, scope, own, "value")
		elif s is GateAST.MultiAssign:
			var ma: GateAST.MultiAssign = s
			if not ma.declares:
				for t in ma.targets:
					expr(t, scope, own, "value")
			for v in ma.values:
				expr(v, scope, own, "value")

	func expr(e, scope: Dictionary, own: Dictionary, pos: String) -> void:
		if e == null:
			return
		if e is GateAST.Ident:
			var id: GateAST.Ident = e
			if id.generic_type != null:
				GateChecker.substitute_type(id.generic_type, scope)
				return
			if scope.has(id.name) and not inherited.has(id.name) and not inherited.has("*"):
				_alias_as_value(id, scope[id.name], own.has(id.name), pos)
		elif e is GateAST.Unary:
			expr((e as GateAST.Unary).operand, scope, own, "value")
		elif e is GateAST.Binary:
			expr((e as GateAST.Binary).left, scope, own, "value")
			expr((e as GateAST.Binary).right, scope, own, "value")
		elif e is GateAST.NullCoalesce:
			expr((e as GateAST.NullCoalesce).left, scope, own, "value")
			expr((e as GateAST.NullCoalesce).right, scope, own, "value")
		elif e is GateAST.Ternary:
			expr((e as GateAST.Ternary).cond, scope, own, "value")
			expr((e as GateAST.Ternary).if_true, scope, own, "value")
			expr((e as GateAST.Ternary).if_false, scope, own, "value")
		elif e is GateAST.Member:
			expr((e as GateAST.Member).target, scope, own, "target")
		elif e is GateAST.Index:
			expr((e as GateAST.Index).target, scope, own, "value")
			expr((e as GateAST.Index).index, scope, own, "value")
		elif e is GateAST.Call:
			expr((e as GateAST.Call).callee, scope, own, "callee")
			for a in (e as GateAST.Call).args:
				expr(a, scope, own, "value")
		elif e is GateAST.ArrayLit:
			for el in (e as GateAST.ArrayLit).elements:
				expr(el, scope, own, "value")
		elif e is GateAST.DictLit:
			for k in (e as GateAST.DictLit).keys:
				expr(k, scope, own, "value")
			for v in (e as GateAST.DictLit).values:
				expr(v, scope, own, "value")
		elif e is GateAST.Lambda:
			var lam: GateAST.Lambda = e
			var ls: Array = _body_scope(lam.params, lam.body, scope, own, {})
			for p in lam.params:
				GateChecker.substitute_type((p as GateAST.Param).type, ls[0])
				expr((p as GateAST.Param).default, ls[0], ls[1], "value")
			GateChecker.substitute_type(lam.return_type, ls[0])
			for st in lam.body:
				stmt(st, ls[0], ls[1], {})
			expr(lam.expr_body, ls[0], ls[1], "value")
		elif e is GateAST.AwaitExpr:
			expr((e as GateAST.AwaitExpr).operand, scope, own, "value")
		elif e is GateAST.CastExpr:
			expr((e as GateAST.CastExpr).operand, scope, own, "value")
			GateChecker.substitute_type((e as GateAST.CastExpr).type, scope)
		elif e is GateAST.IsExpr:
			expr((e as GateAST.IsExpr).operand, scope, own, "value")
			GateChecker.substitute_type((e as GateAST.IsExpr).type, scope)
		elif e is GateAST.FString:
			for part in (e as GateAST.FString).parts:
				if not (part is String):
					expr(part, scope, own, "value")
		elif e is GateAST.ObjectInit:
			GateChecker.substitute_type((e as GateAST.ObjectInit).type, scope)
			for v2 in (e as GateAST.ObjectInit).values:
				expr(v2, scope, own, "value")

	func _alias_as_value(id: GateAST.Ident, target: GateAST.TypeRef, is_own: bool, pos: String) -> void:
		var plain: bool = target.array_depth == 0 and not target.is_dict() and not target.is_set() \
			and not target.is_union() and not target.is_tuple() and not target.is_func_type \
			and not target.nullable
		if pos == "value" or not plain:
			if is_own and report.is_valid():
				var what: String = "an alias for the type %s" % target.describe()
				report.call("'%s' is %s; it has no value here" % [id.name, what], id.line, id.col,
					"use a variable, or the type's own constructor or constants")
			return
		if not target.generic_args.is_empty():
			var gt: GateAST.TypeRef = GateChecker.copy_type(target)
			id.name = GateParser.mangle_generic(gt)
			id.generic_base = gt.name
			id.generic_type = gt
			generic_uses.append(gt)
			return
		id.name = GateTypes.canonical(target.name)


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
			_check_one_type(vd.type, known)
			_check_type_names_in_expr(vd.value, known)
		elif m is GateAST.SignalDecl:
			for sp in (m as GateAST.SignalDecl).params:
				_check_one_type((sp as GateAST.Param).type, known, _registry != null)
		elif m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			for p in fd.params:
				var pp: GateAST.Param = p
				_check_one_type(pp.type, known)
				_check_type_names_in_expr(pp.default, known)
			_check_one_type(fd.return_type, known)
			_check_type_names(fd.body, known)
		elif m is GateAST.AnnotatedStmt:
			_check_type_names([(m as GateAST.AnnotatedStmt).stmt], known)
		elif m is GateAST.IfStmt:
			var ifs: GateAST.IfStmt = m
			_check_type_names_in_expr(ifs.cond, known)
			_check_type_names(ifs.then_body, known)
			for pair in ifs.elifs:
				_check_type_names_in_expr(pair[0], known)
				_check_type_names(pair[1], known)
			_check_type_names(ifs.else_body, known)
		elif m is GateAST.ForStmt:
			var fo: GateAST.ForStmt = m
			_check_one_type(fo.var_type, known)
			_check_type_names_in_expr(fo.iterable, known)
			_check_type_names(fo.body, known)
		elif m is GateAST.WhileStmt:
			_check_type_names_in_expr((m as GateAST.WhileStmt).cond, known)
			_check_type_names((m as GateAST.WhileStmt).body, known)
		elif m is GateAST.MatchStmt:
			var ms: GateAST.MatchStmt = m
			_check_type_names_in_expr(ms.subject, known)
			for br in ms.branches:
				for pat in br[0]:
					if pat is GateAST.TypePattern:
						_check_one_type((pat as GateAST.TypePattern).type, known)
				_check_type_names_in_expr(br[1], known)
				_check_type_names(br[2], known)
		elif m is GateAST.ReturnStmt:
			_check_type_names_in_expr((m as GateAST.ReturnStmt).value, known)
		elif m is GateAST.ExprStmt:
			_check_type_names_in_expr((m as GateAST.ExprStmt).expr, known)
		elif m is GateAST.AssignStmt:
			_check_type_names_in_expr((m as GateAST.AssignStmt).value, known)
		elif m is GateAST.MultiAssign:
			for v in (m as GateAST.MultiAssign).values:
				_check_type_names_in_expr(v, known)


func _check_type_names_in_expr(e, known: Dictionary) -> void:
	if e == null:
		return
	if e is GateAST.Lambda:
		var lam: GateAST.Lambda = e
		for p in lam.params:
			_check_one_type((p as GateAST.Param).type, known)
		_check_one_type(lam.return_type, known)
		_check_type_names(lam.body, known)
		_check_type_names_in_expr(lam.expr_body, known)
	elif e is GateAST.Call:
		_check_type_names_in_expr((e as GateAST.Call).callee, known)
		for a in (e as GateAST.Call).args:
			_check_type_names_in_expr(a, known)
	elif e is GateAST.Binary:
		_check_type_names_in_expr((e as GateAST.Binary).left, known)
		_check_type_names_in_expr((e as GateAST.Binary).right, known)
	elif e is GateAST.Unary:
		_check_type_names_in_expr((e as GateAST.Unary).operand, known)
	elif e is GateAST.Ternary:
		_check_type_names_in_expr((e as GateAST.Ternary).cond, known)
		_check_type_names_in_expr((e as GateAST.Ternary).if_true, known)
		_check_type_names_in_expr((e as GateAST.Ternary).if_false, known)
	elif e is GateAST.NullCoalesce:
		_check_type_names_in_expr((e as GateAST.NullCoalesce).left, known)
		_check_type_names_in_expr((e as GateAST.NullCoalesce).right, known)
	elif e is GateAST.ArrayLit:
		for el in (e as GateAST.ArrayLit).elements:
			_check_type_names_in_expr(el, known)
	elif e is GateAST.DictLit:
		for v in (e as GateAST.DictLit).values:
			_check_type_names_in_expr(v, known)


func _check_one_type(t: GateAST.TypeRef, known: Dictionary, always: bool = false) -> void:
	if t == null:
		return
	if always or _checkable(t):
		_verify_type_name(t, known)
	_check_type_depth(t)


func _check_type_depth(t: GateAST.TypeRef) -> void:
	if t == null:
		return
	for g in t.generic_args:
		_check_type_depth(g)
	for sub in [t.dict_key, t.dict_value, t.set_elem, t.callable_return]:
		_check_type_depth(sub)
	for u in t.union_members:
		_check_type_depth(u)
	for te in t.tuple_elems:
		_check_type_depth(te)
	var levels: int = array_levels(t)
	if levels < 3:
		return
	diagnostics.error("'%s' is %d levels of array, and GDScript nests typed arrays only one level deep"
			% [t.describe(), levels], t.line, t.col,
		"an array of arrays of arrays cannot be written in GDScript (proposal #12224). "
		+ "Hold the inner arrays in a struct or a class, or keep the type untyped")


static func array_levels(t: GateAST.TypeRef) -> int:
	if t == null or t.is_dict() or t.is_set() or t.is_union() or t.is_tuple():
		return 0
	var n: int = t.array_depth
	if GateTypes.canonical(t.name) == "Array" and t.generic_args.size() == 1:
		n += 1 + array_levels(t.generic_args[0])
	return n


func _checkable(t: GateAST.TypeRef) -> bool:
	return t != null and (t.strict or is_gate_only_type(t) or _has_angle_args(t)
		or (not _cycle_names.is_empty() and _cycle_names.has(t.name)))


var _cycle_names: Dictionary = {}


static func _has_angle_args(t: GateAST.TypeRef) -> bool:
	if t == null:
		return false
	var base: String = GateTypes.canonical(t.name)
	if not t.generic_args.is_empty() and base != "Array" and base != "Dictionary":
		return true
	for g in t.generic_args:
		if _has_angle_args(g):
			return true
	return false


func _verify_type_arguments(t: GateAST.TypeRef, known: Dictionary) -> void:
	if t.generic_args.is_empty() or known.has(t.name):
		return
	var base: String = GateTypes.canonical(t.name)
	if base == "PackedScene":
		if t.generic_args.size() != 1:
			diagnostics.error("PackedScene takes one type argument, but %d given"
					% t.generic_args.size(), t.line, t.col,
				"the scene's root node type, as in `PackedScene<Enemy>`")
			return
		var arg: GateAST.TypeRef = t.generic_args[0]
		var node: int = _is_node_type(arg, known)
		if node == 0:
			diagnostics.error("PackedScene<%s>: %s is not a Node type" % [arg.describe(),
					arg.describe()], arg.line, arg.col,
				"a scene's root is a Node, so instantiate() never returns anything else")
		return
	var template: GateAST.ClassDecl = null
	if classes.has(t.name) and classes[t.name] is GateAST.ClassDecl:
		template = classes[t.name]
	elif _registry != null and _registry.generics.has(t.name):
		template = _registry.generics[t.name]
	if template == null or base == "Array" or base == "Dictionary":
		return
	var want: int = template.generic_params.size()
	if want == 0:
		diagnostics.error("'%s' is not generic, so it takes no type arguments" % t.name,
			t.line, t.col)
	elif t.generic_args.size() != want:
		diagnostics.error("'%s' takes %d type argument(s), but %d given"
				% [t.name, want, t.generic_args.size()], t.line, t.col,
			"it is declared `%s<%s>`" % [t.name, ", ".join(PackedStringArray(template.generic_params))])


func _is_node_type(t: GateAST.TypeRef, known: Dictionary) -> int:
	if t.nullable or t.array_depth > 0 or t.is_dict() or t.is_set() or t.is_union() \
			or t.is_tuple() or t.is_func_type:
		return 0
	if known.has(t.name) or t.name.contains("."):
		return -1
	var seen: Dictionary = {}
	var c: String = GateTypes.canonical(t.name)
	while c != "" and not seen.has(c):
		seen[c] = true
		if c == "Node" or (ClassDB.class_exists(c) and ClassDB.is_parent_class(c, "Node")):
			return 1
		if ClassDB.class_exists(c) or GateTypes.BUILTIN.has(c) or structs.has(c) \
				or GateTypeCompat.PACKED_ARRAYS.has(c) or _enum_names.has(c):
			return 0
		if classes.has(c):
			var cd: GateAST.ClassDecl = classes[c]
			c = cd.extends_type.name if cd.extends_type != null else "RefCounted"
			continue
		return -1
	return -1


static func is_gate_only_type(t: GateAST.TypeRef) -> bool:
	if t == null:
		return false
	if t.is_union() or t.is_tuple() or t.is_func_type:
		return true
	for g in t.generic_args:
		if is_gate_only_type(g):
			return true
	return is_gate_only_type(t.dict_key) or is_gate_only_type(t.dict_value)


func _verify_type_name(t: GateAST.TypeRef, known: Dictionary) -> void:
	if t == null or t.is_path_literal:
		return
	for um in t.union_members:
		_verify_type_name(um, known)
	for te in t.tuple_elems:
		_verify_type_name(te, known)
	for cp in t.callable_params:
		_verify_type_name(cp, known)
	if t.is_func_type and t.callable_return != null and t.callable_return.name != "void":
		_verify_type_name(t.callable_return, known)
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
	if _registry != null and _registry.script_class_names.has(n):
		return   # a class_name another file of this project declares
	if _registry != null and "alias_cycles" in _registry and _registry.alias_cycles.has(n):
		diagnostics.error("'%s' is a type alias in a cycle: %s" % [n, _registry.alias_cycles[n]],
			t.line, t.col, "an alias must end at a real type")
		return
	if _registry != null and "alias_files" in _registry and _registry.alias_files.has(n) \
			and (_registry.alias_files[n] as Array).size() > 1:
		diagnostics.error("'%s' is an alias in more than one file, so it is ambiguous here" % n,
			t.line, t.col, "it is declared in %s. Keep one, or declare it in this file too"
				% ", ".join(PackedStringArray(_registry.alias_files[n])))
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

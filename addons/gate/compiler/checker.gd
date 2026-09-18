@tool
class_name GateChecker
extends RefCounted

## Semantic pass. Inlines traits, resolves interfaces, decides struct lowering,
## and mangles overloads. Mutates the AST so the emitter stays simple.

var diagnostics: GateDiagnostics

var interfaces: Dictionary = {}   ## name -> _ClassDecl
var traits: Dictionary = {}       ## name -> _ClassDecl
var structs: Dictionary = {}      ## name -> _ClassDecl
var classes: Dictionary = {}      ## name -> _ClassDecl

const GENERIC_RECHECK_LIMIT := 256

const ENGINE_PREFIX := "_"

var _registry: Variant = null
var _enum_names: Dictionary = {}


func check(mod: GateAST._Module, diags: GateDiagnostics, registry = null) -> void:
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
		var own: Dictionary = own_names(mod.members)
		for k in registry.structs:
			if not structs.has(k) and not own.has(k): structs[k] = registry.structs[k]
		for k in registry.classes:
			if not classes.has(k): classes[k] = registry.classes[k]
	_check_global_names(mod)
	_check_duplicate_kinds(mod, registry)
	for m in mod.members:
		_process(m)
	_verify_overrides_in(mod.members, mod.extends_type, [])
	_check_struct_consts(mod.members)
	_process_overloads(mod.members)
	_link_inherited_overloads(mod.members, mod.extends_type)
	_check_generated_names(mod.members, false, mod.extends_type)
	_check_file_helpers(mod)
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
		if m is GateAST._EnumDecl and (m as GateAST._EnumDecl).name != "":
			_enum_names[(m as GateAST._EnumDecl).name] = true
		elif m is GateAST._ClassDecl:
			_collect_enum_names((m as GateAST._ClassDecl).members)


var _alias_targets: Array = []


## Aliases are visible across files, but a declaration of the same name in scope wins.
func _substitute_aliases(mod: GateAST._Module, registry) -> void:
	var scope: Dictionary = {}
	if registry != null and "aliases" in registry:
		for k in registry.aliases:
			scope[k] = registry.aliases[k]
	if scope.is_empty() and not mod.has_aliases:
		return
	var walk: _AliasWalk = _AliasWalk.new()
	walk.report = func(msg: String, line: int, col: int, hint: String) -> void:
		diagnostics.error(msg, line, col, hint)
	walk.on_alias = func(target: GateAST._TypeRef, known: Dictionary) -> void:
		_alias_targets.append([target, known])
	walk.global_taken = project_names(registry, mod.path)
	walk.inherited = _inherited_names(mod, registry)
	scope = {} if walk.inherited.has("*") else shadowed(scope, walk.inherited)
	var module_taken: Dictionary = {}
	if mod.class_name_decl != "":
		module_taken[mod.class_name_decl] = "this file's class_name"
	if registry != null:
		for am in mod.members:
			if not (am is GateAST._TypeAliasDecl):
				continue
			var an: String = (am as GateAST._TypeAliasDecl).name
			var at: String = String(registry.origin.get(an, ""))
			if registry.classes.has(an) and registry.top_level.has(an) and at != "" \
					and at != mod.path and not walk.global_taken.has(an):
				diagnostics.warn("'%s' is also a class in %s, which wins wherever it is visible, "
						% [an, at] + "so this alias is never used", (am as GateAST._TypeAliasDecl).line,
					(am as GateAST._TypeAliasDecl).col, "rename the alias or the class")
				walk.dropped[an] = true
	if registry != null and "alias_files" in registry:
		for m in mod.members:
			if m is GateAST._TypeAliasDecl and registry.alias_files.has((m as GateAST._TypeAliasDecl).name):
				var others: PackedStringArray = PackedStringArray()
				for p in registry.alias_files[(m as GateAST._TypeAliasDecl).name]:
					if String(p) != mod.path:
						others.append(String(p))
				if not others.is_empty() and not walk.global_taken.has((m as GateAST._TypeAliasDecl).name):
					module_taken[(m as GateAST._TypeAliasDecl).name] = "an alias in %s" % ", ".join(others)
	walk.members(mod.members, scope, {}, {}, module_taken)
	if mod.extends_type != null and not module_taken.has(mod.extends_type.name):
		substitute_type(mod.extends_type, shadowed(scope, block_names(mod.members)))
	for gu in mod.generic_uses:
		substitute_type(gu, scope)
	mod.generic_uses.append_array(walk.generic_uses)


func _check_duplicate_kinds(mod: GateAST._Module, registry) -> void:
	if registry == null or not ("declared_in" in registry):
		return
	for m in mod.members:
		if not (m is GateAST._ClassDecl):
			continue
		var cd: GateAST._ClassDecl = m
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


func _check_global_names(mod: GateAST._Module) -> void:
	for m in mod.members:
		if not (m is GateAST._ClassDecl):
			continue
		var cd: GateAST._ClassDecl = m
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


func _inherited_names(mod: GateAST._Module, registry) -> Dictionary:
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


static func base_chain(ext_t: GateAST._TypeRef, path: String, registry) -> Dictionary:
	var names: Dictionary = {}
	var types: Dictionary = {}   ## inner classes and named enums
	var funcs: Dictionary = {}
	var out: Dictionary = {"names": names, "types": types, "funcs": funcs, "engine": "",
		"unknown": false, "gate": false}
	var unknown: Dictionary = out.duplicate()
	unknown["unknown"] = true
	var base: String = ext_t.name if ext_t != null else "RefCounted"
	var from: String = path
	var ctx: GateAST._Module = null
	var seen: Dictionary = {}
	while base != "" and not seen.has(from + "|" + base):
		seen[from + "|" + base] = true
		var smod: GateAST._Module = null
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
			var cd: GateAST._ClassDecl = registry.classes[base]
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
		var ext: GateAST._TypeRef = smod.extends_type
		for part in inner:
			var icd: GateAST._ClassDecl = _inner_class(members, part)
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
		if em is GateAST._EnumDecl:
			var ed: GateAST._EnumDecl = em
			if ed.name == "":
				for k in ed.keys:
					if not names.has(String(k)):
						names[String(k)] = from
			else:
				types[ed.name] = true
		elif em is GateAST._ClassDecl:
			types[(em as GateAST._ClassDecl).name] = true
		elif em is GateAST._FuncDecl:
			funcs[(em as GateAST._FuncDecl).name] = true


static func _inner_class(members: Array, cname: String) -> GateAST._ClassDecl:
	for m in members:
		if m is GateAST._ClassDecl and (m as GateAST._ClassDecl).name == cname:
			return m
	return null


static func hidden_by_base(mod: GateAST._Module, registry, chain: Dictionary = {}) -> Dictionary:
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


static func read_script(path: String) -> GateAST._Module:
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
	var smod: GateAST._Module = GateParser.new().parse(GateLexer.new().tokenize(src, d), src, d)
	if d.error_count() > 0:
		smod = null
	else:
		smod.path = src_path
	_script_cache[src_path] = [stamp, smod]
	return smod


static func fold_int(e, consts: Dictionary, depth: int = 0) -> Variant:
	if e == null or depth > 16:
		return null
	if e is GateAST._Literal:
		var lit: GateAST._Literal = e
		return int(lit.raw) if lit.kind == "number" and lit.raw.is_valid_int() else null
	if e is GateAST._Ident:
		var n: String = (e as GateAST._Ident).name
		return fold_int(consts.get(n, null), consts, depth + 1) if consts.has(n) else null
	if e is GateAST._Unary:
		var u: GateAST._Unary = e
		var v: Variant = fold_int(u.operand, consts, depth + 1)
		if v == null:
			return null
		match u.op:
			"-": return -int(v)
			"+": return int(v)
			"~": return ~int(v)
		return null
	if e is GateAST._CastExpr:
		var ce: GateAST._CastExpr = e
		if ce.type != null and GateTypes.canonical(ce.type.name) == "int":
			return fold_int(ce.operand, consts, depth + 1)
		return null
	if not (e is GateAST._Binary):
		return null
	var b: GateAST._Binary = e
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
		if m is GateAST._VarDecl and (m as GateAST._VarDecl).is_const \
				and (m as GateAST._VarDecl).value != null:
			out[(m as GateAST._VarDecl).name] = (m as GateAST._VarDecl).value
		elif m is GateAST._ClassDecl:
			const_values((m as GateAST._ClassDecl).members, out)
		elif m is GateAST._FuncDecl:
			const_values((m as GateAST._FuncDecl).body, out)
		elif m is GateAST._AnnotatedStmt:
			const_values([(m as GateAST._AnnotatedStmt).stmt], out)
	return out


static func block_names(members: Array) -> Dictionary:
	var out: Dictionary = {}
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			out[cd.name] = "a %s in this file" % ("class" if cd.form == "class" else cd.form)
		elif m is GateAST._EnumDecl:
			if (m as GateAST._EnumDecl).name != "":
				out[(m as GateAST._EnumDecl).name] = "an enum in this file"
		elif m is GateAST._VarDecl:
			var vd: GateAST._VarDecl = m
			out[vd.name] = "a constant in this file" if vd.is_const else "a variable in this scope"
		elif m is GateAST._FuncDecl:
			out[(m as GateAST._FuncDecl).name] = "a function in this file"
		elif m is GateAST._SignalDecl:
			out[(m as GateAST._SignalDecl).name] = "a signal in this file"
		elif m is GateAST._AnnotatedStmt:
			out.merge(block_names([(m as GateAST._AnnotatedStmt).stmt]))
	return out


static func own_names(members: Array) -> Dictionary:
	var out: Dictionary = block_names(members)
	_own_types_deep(members, out)
	return out


static func _own_types_deep(members: Array, out: Dictionary) -> void:
	for m in members:
		if m is GateAST._ClassDecl:
			out[(m as GateAST._ClassDecl).name] = true
			_own_types_deep((m as GateAST._ClassDecl).members, out)
		elif m is GateAST._EnumDecl and (m as GateAST._EnumDecl).name != "":
			out[(m as GateAST._EnumDecl).name] = true


static func local_names(params: Array, body: Array) -> Dictionary:
	var out: Dictionary = {}
	for p in params:
		out[(p as GateAST._Param).name] = "a parameter"
	_locals_deep(body, out)
	return out


static func _locals_deep(body: Array, out: Dictionary) -> void:
	for s in body:
		if s is GateAST._VarDecl:
			out[(s as GateAST._VarDecl).name] = "a local variable"
		elif s is GateAST._AnnotatedStmt:
			_locals_deep([(s as GateAST._AnnotatedStmt).stmt], out)
		elif s is GateAST._MultiAssign and (s as GateAST._MultiAssign).declares:
			for t in (s as GateAST._MultiAssign).targets:
				if t is GateAST._Ident:
					out[(t as GateAST._Ident).name] = "a local variable"
		elif s is GateAST._IfStmt:
			var ifs: GateAST._IfStmt = s
			_locals_deep(ifs.then_body, out)
			for pair in ifs.elifs:
				_locals_deep(pair[1], out)
			_locals_deep(ifs.else_body, out)
		elif s is GateAST._ForStmt:
			for vn in (s as GateAST._ForStmt).var_names:
				out[String(vn)] = "a loop variable"
			_locals_deep((s as GateAST._ForStmt).body, out)
		elif s is GateAST._WhileStmt:
			_locals_deep((s as GateAST._WhileStmt).body, out)
		elif s is GateAST._MatchStmt:
			for br in (s as GateAST._MatchStmt).branches:
				_locals_deep(br[2], out)


static var _binding_re: RegEx = null


static func release_statics() -> void:
	_binding_re = null


static func pattern_bindings(patterns: Array) -> Dictionary:
	var out: Dictionary = {}
	for p in patterns:
		if p is GateAST._TypePattern:
			out[(p as GateAST._TypePattern).bind_name] = "a match binding"
		elif p is GateAST._RawExpr and (p as GateAST._RawExpr).text.contains("var"):
			if _binding_re == null:
				_binding_re = RegEx.create_from_string("\\bvar\\s+([A-Za-z_][A-Za-z0-9_]*)")
			for m in _binding_re.search_all((p as GateAST._RawExpr).text):
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
		if m is GateAST._TypeAliasDecl:
			out.append(m)
	return out


static func _alias_decls_deep(body: Array, out: Array) -> void:
	for s in body:
		if s is GateAST._TypeAliasDecl:
			out.append(s)
		elif s is GateAST._IfStmt:
			var ifs: GateAST._IfStmt = s
			_alias_decls_deep(ifs.then_body, out)
			for pair in ifs.elifs:
				_alias_decls_deep(pair[1], out)
			_alias_decls_deep(ifs.else_body, out)
		elif s is GateAST._ForStmt:
			_alias_decls_deep((s as GateAST._ForStmt).body, out)
		elif s is GateAST._WhileStmt:
			_alias_decls_deep((s as GateAST._WhileStmt).body, out)
		elif s is GateAST._MatchStmt:
			for br in (s as GateAST._MatchStmt).branches:
				_alias_decls_deep(br[2], out)


static func extend_alias_scope(outer: Dictionary, decls: Array, known: Dictionary,
		report: Callable, on_alias: Callable, taken: Dictionary = {},
		cycles: Dictionary = {}) -> Dictionary:
	if decls.is_empty():
		return outer
	var scope: Dictionary = outer.duplicate()
	var pending: Dictionary = {}
	for d in decls:
		var ad: GateAST._TypeAliasDecl = d
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
		state: Dictionary, report: Callable) -> GateAST._TypeRef:
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
			var first: GateAST._TypeAliasDecl = pending[cycle[0]]
			report.call("type alias '%s' is a cycle: %s" % [first.name, shown],
				first.line, first.col, "an alias must end at a real type")
		return null
	stack.append(name)
	var ad: GateAST._TypeAliasDecl = pending[name]
	var t: GateAST._TypeRef = copy_type(ad.target)
	_substitute_resolving(t, pending, scope, state, report)
	stack.pop_back()
	if (state["reported"] as Dictionary).has(name):
		var v: GateAST._TypeRef = GateAST._TypeRef.new()
		v.at(ad.line, ad.col)
		v.name = "Variant"
		t = v
	done[name] = true
	scope[name] = t
	return t


static func _substitute_resolving(t: GateAST._TypeRef, pending: Dictionary, scope: Dictionary,
		state: Dictionary, report: Callable) -> void:
	if t == null or t.is_path_literal:
		return
	for child in _type_children(t):
		_substitute_resolving(child, pending, scope, state, report)
	var target: GateAST._TypeRef = null
	if pending.has(t.name):
		target = _resolve_alias(t.name, pending, scope, state, report)
		if target == null:
			return
	elif scope.has(t.name):
		target = scope[t.name]
	if target != null:
		_apply_alias(t, target)


static func substitute_type(t: GateAST._TypeRef, scope: Dictionary) -> void:
	if t == null or t.is_path_literal or scope.is_empty():
		return
	for child in _type_children(t):
		substitute_type(child, scope)
	if scope.has(t.name):
		_apply_alias(t, scope[t.name])


static func _type_children(t: GateAST._TypeRef) -> Array:
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


static func _apply_alias(use: GateAST._TypeRef, target: GateAST._TypeRef) -> void:
	var c: GateAST._TypeRef = copy_type(target)
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


static func copy_type(t: GateAST._TypeRef) -> GateAST._TypeRef:
	if t == null:
		return null
	var c: GateAST._TypeRef = GateAST._TypeRef.new()
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
		var s: GateAST._TypeShape = c.shaped()
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
	var is_type: bool = o is GateAST._TypeRef
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
	if not (v is GateAST._ASTNode or v is GateAST._TypeShape):
		return v
	var id: int = (v as Object).get_instance_id()
	if memo.has(id):
		return memo[id]
	var c: Object = (v as Object).get_script().new()
	memo[id] = c
	for pn in _props_of(v):
		c.set(pn, clone_ast((v as Object).get(pn), memo))
	return c


static func bind_generic(cd: GateAST._ClassDecl, args: Array) -> void:
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
	if v is GateAST._TypeRef:
		substitute_type(v, scope)
		return
	if not (v is GateAST._ASTNode):
		return
	var id: int = (v as Object).get_instance_id()
	if seen.has(id):
		return
	seen[id] = true
	if v is GateAST._Ident and scope.has((v as GateAST._Ident).name):
		var at: GateAST._TypeRef = scope[(v as GateAST._Ident).name]
		if at.shape == null and at.array_depth == 0 and not at.is_dict() and at.generic_args.is_empty():
			(v as GateAST._Ident).name = at.name
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
	if v is GateAST._TypeRef:
		if not (v as GateAST._TypeRef).generic_args.is_empty() and templates.has((v as GateAST._TypeRef).name):
			out.append(v)
		for ch in _type_children(v):
			_uses_in(ch, templates, out, seen)
		return
	if not (v is GateAST._ASTNode):
		return
	var id: int = (v as Object).get_instance_id()
	if seen.has(id):
		return
	seen[id] = true
	for pn in _props_of(v):
		_uses_in((v as Object).get(pn), templates, out, seen)


static func _generic_templates(members: Array, out: Dictionary) -> void:
	for m in members:
		if m is GateAST._ClassDecl:
			if not (m as GateAST._ClassDecl).generic_params.is_empty():
				out[(m as GateAST._ClassDecl).name] = m
			_generic_templates((m as GateAST._ClassDecl).members, out)


static func generic_instances(mod: GateAST._Module, registry) -> Array:
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
		for p in (templates[g3] as GateAST._ClassDecl).generic_params:
			params[String(p)] = true
	var work: Array = []
	for gu in mod.generic_uses:
		work.append([gu, gu])
	var out: Array = []
	var seen: Dictionary = {}
	while not work.is_empty() and out.size() < GENERIC_RECHECK_LIMIT:
		var w: Array = work.pop_front()
		var t: GateAST._TypeRef = w[0]
		for ch in _type_children(t):
			work.append([ch, w[1]])
		if t.generic_args.is_empty() or not templates.has(t.name):
			continue
		var cd: GateAST._ClassDecl = templates[t.name]
		if t.generic_args.size() != cd.generic_params.size() or _names_param(t, params, own, registry):
			continue
		var key: String = GateParser.mangle_generic(t)
		if seen.has(key):
			continue
		seen[key] = true
		var bound: GateAST._ClassDecl = clone_ast(cd, {})
		bind_generic(bound, t.generic_args)
		out.append([cd, t.generic_args, w[1], origin.get(t.name, ""), bound])
		var inner: Array = []
		_uses_in(bound.members, templates, inner, {})
		for iu in inner:
			work.append([iu, w[1]])
	if not work.is_empty():
		out.append([null, [], work[0][1], "", null])   # the caller says GATE stopped reading
	return out


static func _names_param(t: GateAST._TypeRef, params: Dictionary, own: Dictionary, registry) -> bool:
	for g in _type_children(t):
		var ga: GateAST._TypeRef = g
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
	var cd: GateAST._ClassDecl = inst[0]
	var args: Array = inst[1]
	var site: GateAST._TypeRef = inst[2]
	var binds: PackedStringArray = PackedStringArray()
	for i in mini(cd.generic_params.size(), args.size()):
		binds.append("%s = %s" % [cd.generic_params[i], (args[i] as GateAST._TypeRef).describe()])
	for d2 in found.items:
		if d2.level != GateDiagnostics._Level.ERROR or have.has("%d|%d|%s" % [d2.line, d2.col, d2.message]):
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
	if not (v is GateAST._ASTNode):
		return
	var id: int = (v as Object).get_instance_id()
	if seen.has(id):
		return
	seen[id] = true
	out["%d:%d" % [(v as GateAST._ASTNode).line, (v as GateAST._ASTNode).col]] = true
	for pn in _props_of(v):
		positions_in((v as Object).get(pn), out, seen)


## Substitutes aliases with lexical scope. The checker reports; the project index is silent.
class _AliasWalk extends RefCounted:
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
			decls = decls.filter(func(d: GateAST._TypeAliasDecl) -> bool: return not dropped.has(d.name))
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
			var n: String = (d as GateAST._TypeAliasDecl).name
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
		if s is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = s
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
		elif s is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = s
			var fs: Array = _body_scope(fd.params, fd.body, scope, own, known)
			for p in fd.params:
				GateChecker.substitute_type((p as GateAST._Param).type, fs[0])
				expr((p as GateAST._Param).default, fs[0], fs[1], "value")
			GateChecker.substitute_type(fd.return_type, fs[0])
			for st in fd.body:
				stmt(st, fs[0], fs[1], known)
		elif s is GateAST._VarDecl:
			GateChecker.substitute_type((s as GateAST._VarDecl).type, scope)
			expr((s as GateAST._VarDecl).value, scope, own, "value")
		elif s is GateAST._SignalDecl:
			for p2 in (s as GateAST._SignalDecl).params:
				GateChecker.substitute_type((p2 as GateAST._Param).type, scope)
		elif s is GateAST._AnnotatedStmt:
			stmt((s as GateAST._AnnotatedStmt).stmt, scope, own, known)
		elif s is GateAST._IfStmt:
			var ifs: GateAST._IfStmt = s
			expr(ifs.cond, scope, own, "value")
			for a in ifs.then_body: stmt(a, scope, own, known)
			for pair in ifs.elifs:
				expr(pair[0], scope, own, "value")
				for b in pair[1]: stmt(b, scope, own, known)
			for c in ifs.else_body: stmt(c, scope, own, known)
		elif s is GateAST._ForStmt:
			var fo: GateAST._ForStmt = s
			GateChecker.substitute_type(fo.var_type, scope)
			expr(fo.iterable, scope, own, "value")
			for d in fo.body: stmt(d, scope, own, known)
		elif s is GateAST._WhileStmt:
			expr((s as GateAST._WhileStmt).cond, scope, own, "value")
			for e in (s as GateAST._WhileStmt).body: stmt(e, scope, own, known)
		elif s is GateAST._MatchStmt:
			var ms: GateAST._MatchStmt = s
			expr(ms.subject, scope, own, "value")
			for br in ms.branches:
				var binds: Dictionary = GateChecker.pattern_bindings(br[0])
				var arm: Dictionary = GateChecker.shadowed(scope, binds)
				var arm_own: Dictionary = GateChecker.shadowed(own, binds)
				expr(br[1], arm, arm_own, "value")
				for f in br[2]: stmt(f, arm, arm_own, known)
		elif s is GateAST._ReturnStmt:
			expr((s as GateAST._ReturnStmt).value, scope, own, "value")
		elif s is GateAST._ExprStmt:
			expr((s as GateAST._ExprStmt).expr, scope, own, "value")
		elif s is GateAST._AssignStmt:
			expr((s as GateAST._AssignStmt).target, scope, own, "value")
			expr((s as GateAST._AssignStmt).value, scope, own, "value")
		elif s is GateAST._MultiAssign:
			var ma: GateAST._MultiAssign = s
			if not ma.declares:
				for t in ma.targets:
					expr(t, scope, own, "value")
			for v in ma.values:
				expr(v, scope, own, "value")

	func expr(e, scope: Dictionary, own: Dictionary, pos: String) -> void:
		if e == null:
			return
		if e is GateAST._Ident:
			var id: GateAST._Ident = e
			if id.generic_type != null:
				GateChecker.substitute_type(id.generic_type, scope)
				return
			if scope.has(id.name) and not inherited.has(id.name) and not inherited.has("*"):
				_alias_as_value(id, scope[id.name], own.has(id.name), pos)
		elif e is GateAST._Unary:
			expr((e as GateAST._Unary).operand, scope, own, "value")
		elif e is GateAST._Binary:
			expr((e as GateAST._Binary).left, scope, own, "value")
			expr((e as GateAST._Binary).right, scope, own, "value")
		elif e is GateAST._NullCoalesce:
			expr((e as GateAST._NullCoalesce).left, scope, own, "value")
			expr((e as GateAST._NullCoalesce).right, scope, own, "value")
		elif e is GateAST._Ternary:
			expr((e as GateAST._Ternary).cond, scope, own, "value")
			expr((e as GateAST._Ternary).if_true, scope, own, "value")
			expr((e as GateAST._Ternary).if_false, scope, own, "value")
		elif e is GateAST._Member:
			expr((e as GateAST._Member).target, scope, own, "target")
		elif e is GateAST._Index:
			expr((e as GateAST._Index).target, scope, own, "value")
			expr((e as GateAST._Index).index, scope, own, "value")
		elif e is GateAST._Call:
			expr((e as GateAST._Call).callee, scope, own, "callee")
			for a in (e as GateAST._Call).args:
				expr(a, scope, own, "value")
		elif e is GateAST._ArrayLit:
			for el in (e as GateAST._ArrayLit).elements:
				expr(el, scope, own, "value")
		elif e is GateAST._DictLit:
			for k in (e as GateAST._DictLit).keys:
				expr(k, scope, own, "value")
			for v in (e as GateAST._DictLit).values:
				expr(v, scope, own, "value")
		elif e is GateAST._Lambda:
			var lam: GateAST._Lambda = e
			var ls: Array = _body_scope(lam.params, lam.body, scope, own, {})
			for p in lam.params:
				GateChecker.substitute_type((p as GateAST._Param).type, ls[0])
				expr((p as GateAST._Param).default, ls[0], ls[1], "value")
			GateChecker.substitute_type(lam.return_type, ls[0])
			for st in lam.body:
				stmt(st, ls[0], ls[1], {})
			expr(lam.expr_body, ls[0], ls[1], "value")
		elif e is GateAST._AwaitExpr:
			expr((e as GateAST._AwaitExpr).operand, scope, own, "value")
		elif e is GateAST._CastExpr:
			expr((e as GateAST._CastExpr).operand, scope, own, "value")
			GateChecker.substitute_type((e as GateAST._CastExpr).type, scope)
		elif e is GateAST._IsExpr:
			expr((e as GateAST._IsExpr).operand, scope, own, "value")
			GateChecker.substitute_type((e as GateAST._IsExpr).type, scope)
		elif e is GateAST._FString:
			for part in (e as GateAST._FString).parts:
				if not (part is String):
					expr(part, scope, own, "value")
		elif e is GateAST._ObjectInit:
			GateChecker.substitute_type((e as GateAST._ObjectInit).type, scope)
			for v2 in (e as GateAST._ObjectInit).values:
				expr(v2, scope, own, "value")

	func _alias_as_value(id: GateAST._Ident, target: GateAST._TypeRef, is_own: bool, pos: String) -> void:
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
			var gt: GateAST._TypeRef = GateChecker.copy_type(target)
			id.name = GateParser.mangle_generic(gt)
			id.generic_base = gt.name
			id.generic_type = gt
			generic_uses.append(gt)
			return
		id.name = GateTypes.canonical(target.name)


func _check_type_names(members: Array, known: Dictionary) -> void:
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			var inner: Dictionary = known.duplicate()
			for gp in cd.generic_params:
				inner[String(gp)] = true
			_check_type_names(cd.members, inner)
		elif m is GateAST._VarDecl:
			var vd: GateAST._VarDecl = m
			_check_one_type(vd.type, known)
			_check_type_names_in_expr(vd.value, known)
		elif m is GateAST._SignalDecl:
			for sp in (m as GateAST._SignalDecl).params:
				_check_one_type((sp as GateAST._Param).type, known, _registry != null)
		elif m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
			for p in fd.params:
				var pp: GateAST._Param = p
				_check_one_type(pp.type, known)
				_check_type_names_in_expr(pp.default, known)
			_check_one_type(fd.return_type, known)
			_check_type_names(fd.body, known)
		elif m is GateAST._AnnotatedStmt:
			_check_type_names([(m as GateAST._AnnotatedStmt).stmt], known)
		elif m is GateAST._IfStmt:
			var ifs: GateAST._IfStmt = m
			_check_type_names_in_expr(ifs.cond, known)
			_check_type_names(ifs.then_body, known)
			for pair in ifs.elifs:
				_check_type_names_in_expr(pair[0], known)
				_check_type_names(pair[1], known)
			_check_type_names(ifs.else_body, known)
		elif m is GateAST._ForStmt:
			var fo: GateAST._ForStmt = m
			_check_one_type(fo.var_type, known)
			_check_type_names_in_expr(fo.iterable, known)
			_check_type_names(fo.body, known)
		elif m is GateAST._WhileStmt:
			_check_type_names_in_expr((m as GateAST._WhileStmt).cond, known)
			_check_type_names((m as GateAST._WhileStmt).body, known)
		elif m is GateAST._MatchStmt:
			var ms: GateAST._MatchStmt = m
			_check_type_names_in_expr(ms.subject, known)
			for br in ms.branches:
				for pat in br[0]:
					if pat is GateAST._TypePattern:
						_check_one_type((pat as GateAST._TypePattern).type, known)
				_check_type_names_in_expr(br[1], known)
				_check_type_names(br[2], known)
		elif m is GateAST._ReturnStmt:
			_check_type_names_in_expr((m as GateAST._ReturnStmt).value, known)
		elif m is GateAST._ExprStmt:
			_check_type_names_in_expr((m as GateAST._ExprStmt).expr, known)
		elif m is GateAST._AssignStmt:
			_check_type_names_in_expr((m as GateAST._AssignStmt).value, known)
		elif m is GateAST._MultiAssign:
			for v in (m as GateAST._MultiAssign).values:
				_check_type_names_in_expr(v, known)


func _check_type_names_in_expr(e, known: Dictionary) -> void:
	if e == null:
		return
	if e is GateAST._Lambda:
		var lam: GateAST._Lambda = e
		for p in lam.params:
			_check_one_type((p as GateAST._Param).type, known)
		_check_one_type(lam.return_type, known)
		_check_type_names(lam.body, known)
		_check_type_names_in_expr(lam.expr_body, known)
	elif e is GateAST._Call:
		_check_type_names_in_expr((e as GateAST._Call).callee, known)
		for a in (e as GateAST._Call).args:
			_check_type_names_in_expr(a, known)
	elif e is GateAST._Binary:
		_check_type_names_in_expr((e as GateAST._Binary).left, known)
		_check_type_names_in_expr((e as GateAST._Binary).right, known)
	elif e is GateAST._Unary:
		_check_type_names_in_expr((e as GateAST._Unary).operand, known)
	elif e is GateAST._Ternary:
		_check_type_names_in_expr((e as GateAST._Ternary).cond, known)
		_check_type_names_in_expr((e as GateAST._Ternary).if_true, known)
		_check_type_names_in_expr((e as GateAST._Ternary).if_false, known)
	elif e is GateAST._NullCoalesce:
		_check_type_names_in_expr((e as GateAST._NullCoalesce).left, known)
		_check_type_names_in_expr((e as GateAST._NullCoalesce).right, known)
	elif e is GateAST._ArrayLit:
		for el in (e as GateAST._ArrayLit).elements:
			_check_type_names_in_expr(el, known)
	elif e is GateAST._DictLit:
		for v in (e as GateAST._DictLit).values:
			_check_type_names_in_expr(v, known)


func _check_one_type(t: GateAST._TypeRef, known: Dictionary, always: bool = false) -> void:
	if t == null:
		return
	if always or _checkable(t):
		_verify_type_name(t, known)
	_check_type_depth(t)


func _check_type_depth(t: GateAST._TypeRef) -> void:
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


static func array_levels(t: GateAST._TypeRef) -> int:
	if t == null or t.is_dict() or t.is_set() or t.is_union() or t.is_tuple():
		return 0
	var n: int = t.array_depth
	if GateTypes.canonical(t.name) == "Array" and t.generic_args.size() == 1:
		n += 1 + array_levels(t.generic_args[0])
	return n


func _checkable(t: GateAST._TypeRef) -> bool:
	return t != null and (t.strict or is_gate_only_type(t) or _has_angle_args(t)
		or (not _cycle_names.is_empty() and _cycle_names.has(t.name)))


var _cycle_names: Dictionary = {}


static func _has_angle_args(t: GateAST._TypeRef) -> bool:
	if t == null:
		return false
	var base: String = GateTypes.canonical(t.name)
	if not t.generic_args.is_empty() and base != "Array" and base != "Dictionary":
		return true
	for g in t.generic_args:
		if _has_angle_args(g):
			return true
	return false


func _verify_type_arguments(t: GateAST._TypeRef, known: Dictionary) -> void:
	if t.generic_args.is_empty() or known.has(t.name):
		return
	var base: String = GateTypes.canonical(t.name)
	if base == "PackedScene":
		if t.generic_args.size() != 1:
			diagnostics.error("PackedScene takes one type argument, but %d given"
					% t.generic_args.size(), t.line, t.col,
				"the scene's root node type, as in `PackedScene<Enemy>`")
			return
		var arg: GateAST._TypeRef = t.generic_args[0]
		var node: int = _is_node_type(arg, known)
		if node == 0:
			diagnostics.error("PackedScene<%s>: %s is not a Node type" % [arg.describe(),
					arg.describe()], arg.line, arg.col,
				"a scene's root is a Node, so instantiate() never returns anything else")
		return
	var template: GateAST._ClassDecl = null
	if classes.has(t.name) and classes[t.name] is GateAST._ClassDecl:
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


func _is_node_type(t: GateAST._TypeRef, known: Dictionary) -> int:
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
			var cd: GateAST._ClassDecl = classes[c]
			c = cd.extends_type.name if cd.extends_type != null else "RefCounted"
			continue
		return -1
	return -1


static func is_gate_only_type(t: GateAST._TypeRef) -> bool:
	if t == null:
		return false
	if t.is_union() or t.is_tuple() or t.is_func_type:
		return true
	for g in t.generic_args:
		if is_gate_only_type(g):
			return true
	return is_gate_only_type(t.dict_key) or is_gate_only_type(t.dict_value)


func _verify_type_name(t: GateAST._TypeRef, known: Dictionary) -> void:
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
	_verify_type_arguments(t, known)
	var n: String = t.name
	if n == "" or n.contains("."):
		return   # qualified names resolve at load time
	if known.has(n):
		return   # a generic parameter in scope
	if GateTypes.is_shorthand(n) or GateTypes.BUILTIN.has(GateTypes.canonical(n)):
		return
	if interfaces.has(n) or traits.has(n) or structs.has(n) or classes.has(n):
		return
	if _registry != null and _registry.generics.has(n):
		return   # a generic template from another file
	if _registry != null and _registry.script_class_names.has(n):
		return   # a class_name of this build, not in Godot's class list yet
	if _registry != null and "gd_class_names" in _registry and _registry.gd_class_names.has(n):
		return   # a class_name a plain .gd of this project declares
	if _enum_names.has(n) or GateTypeCompat.PACKED_ARRAYS.has(n):
		return   # an enum of this file, or a Packed array
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


static func declared_members(members: Array) -> Dictionary:
	var out: Dictionary = {}
	for m in members:
		var s = m
		if s is GateAST._AnnotatedStmt:
			s = (s as GateAST._AnnotatedStmt).stmt
		if s is GateAST._VarDecl:
			out[(s as GateAST._VarDecl).name] = "a constant" if (s as GateAST._VarDecl).is_const \
				else "a variable"
		elif s is GateAST._FuncDecl:
			out[(s as GateAST._FuncDecl).name] = "a function"
		elif s is GateAST._SignalDecl:
			out[(s as GateAST._SignalDecl).name] = "a signal"
		elif s is GateAST._EnumDecl:
			var ed: GateAST._EnumDecl = s
			if ed.name != "":
				out[ed.name] = "an enum"
			else:
				for k in ed.keys:
					out[String(k)] = "an enum key"
		elif s is GateAST._ClassDecl:
			out[(s as GateAST._ClassDecl).name] = "a %s" % (s as GateAST._ClassDecl).form
		elif s is GateAST._TypeAliasDecl:
			out[(s as GateAST._TypeAliasDecl).name] = "a type alias"
	return out


func _check_generated_names(members: Array, in_struct: bool, ext_t: GateAST._TypeRef) -> void:
	var declared: Dictionary = declared_members(members)
	var taken: Dictionary = {}
	for n in declared:
		taken[n] = "%s in this scope" % declared[n]
	var anc: Dictionary = _ancestry(ext_t)
	for n2 in anc["names"]:
		if not taken.has(n2):
			taken[n2] = anc["names"][n2]
	var engine: String = anc["engine"]
	if engine != "":
		for mn in _engine_funcs(engine):
			if not taken.has(mn):
				taken[mn] = "a method of %s" % engine
		for pn in _engine_property_names(engine):
			if not taken.has(pn):
				taken[pn] = "a property of %s" % engine
		for sg in ClassDB.class_get_signal_list(engine):
			if not taken.has(String(sg["name"])):
				taken[String(sg["name"])] = "a signal of %s" % engine

	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			_check_generated_names(cd.members, cd.form == "struct", cd.extends_type)
			_check_lowered_names(cd)
			continue
		_check_priv_name(m, taken)
		if not (m is GateAST._VarDecl):
			continue
		var vd: GateAST._VarDecl = m
		if _annotated(vd, "observable"):
			_check_observable(vd, taken, in_struct)
		elif _annotated(vd, "soa"):
			_check_soa_names(vd, taken)


static func priv_name(m) -> String:
	if not (m is GateAST._VarDecl or m is GateAST._FuncDecl):
		return ""
	if String(m.visibility) != "priv" or String(m.name).begins_with("_"):
		return ""
	return "_" + String(m.name)


static func priv_renames(members: Array) -> Dictionary:
	var out: Dictionary = {}
	for m in members:
		var s = m
		if s is GateAST._AnnotatedStmt:
			s = (s as GateAST._AnnotatedStmt).stmt
		var pn: String = priv_name(s)
		if pn != "":
			out[pn] = String(s.name)
	return out


func _check_priv_name(m, taken: Dictionary) -> void:
	var s = m
	if s is GateAST._AnnotatedStmt:
		s = (s as GateAST._AnnotatedStmt).stmt
	var emitted: String = priv_name(s)
	if emitted == "" or not taken.has(emitted):
		return
	diagnostics.error("'%s' is priv, so it is emitted as '%s', which is already %s"
			% [s.name, emitted, taken[emitted]], s.line, s.col,
		"`priv` prefixes the underscore GDScript uses for a private member. Rename one of them.")


func _check_lowered_names(cd: GateAST._ClassDecl) -> void:
	var declared: Dictionary = declared_members(cd.members)
	if declared.has("__gate_impl") and (not cd.interface_names.is_empty()
			or not cd.implements.is_empty()):
		diagnostics.error(
			"'%s' declares '__gate_impl', which is the list of interfaces GATE writes" % cd.name,
			cd.line, cd.col,
			"a class that implements an interface carries `const __gate_impl`. Rename this one.")


func _check_file_helpers(mod: GateAST._Module) -> void:
	var declared: Dictionary = declared_members(mod.members)
	var uses: Dictionary = {"iface": false, "init": false}
	_note_helper_uses(mod.members, uses)
	if declared.has("__gate_is") and uses["iface"]:
		diagnostics.error("'__gate_is' is the interface test GATE writes into this file",
			mod.line, mod.col,
			"`x is <an interface>` compiles to a call to it, so the name is taken here. "
			+ "Rename this one.")
	if declared.has("__gate_init") and uses["init"]:
		diagnostics.error("'__gate_init' is the object initialiser GATE writes into this file",
			mod.line, mod.col,
			"`X.new({ ... })` compiles to a call to it, so the name is taken here. "
			+ "Rename this one.")


func _note_helper_uses(node, uses: Dictionary) -> void:
	if node is Array:
		for x in node:
			_note_helper_uses(x, uses)
		return
	if not (node is GateAST._ASTNode):
		return
	if node is GateAST._ObjectInit or _keyed_construction(node):
		uses["init"] = true
	elif node is GateAST._IsExpr:
		_note_iface_test((node as GateAST._IsExpr).type, uses)
	elif node is GateAST._CastExpr:
		_note_iface_test((node as GateAST._CastExpr).type, uses)
	elif node is GateAST._TypePattern:
		_note_iface_test((node as GateAST._TypePattern).type, uses)
	for pn in _props_of(node):
		var v = (node as Object).get(pn)
		if v is Array or v is GateAST._ASTNode:
			_note_helper_uses(v, uses)


static func _keyed_construction(node) -> bool:
	if not (node is GateAST._Call):
		return false
	var c: GateAST._Call = node
	if not (c.callee is GateAST._Member) or c.args.size() != 1:
		return false
	if not ((c.callee as GateAST._Member).name in ["new", "instantiate"]):
		return false
	if not (c.args[0] is GateAST._DictLit):
		return false
	var dl: GateAST._DictLit = c.args[0]
	if dl.keys.is_empty():
		return false
	for k in dl.keys:
		if not (k is GateAST._Ident):
			return false
	return true


func _note_iface_test(t: GateAST._TypeRef, uses: Dictionary) -> void:
	if t != null and (interfaces.has(t.name) or traits.has(t.name)):
		uses["iface"] = true


func _annotated(vd: GateAST._VarDecl, what: String) -> bool:
	for a in vd.annotations:
		if (a as GateAST._Annotation).name == what:
			return true
	return false


func _check_observable(vd: GateAST._VarDecl, taken: Dictionary, in_struct: bool) -> void:
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
	var emitted: String = vd.name
	if vd.visibility == "priv" and not emitted.begins_with("_"):
		emitted = "_" + emitted
	var backing: String = "__" + emitted
	if taken.has(backing):
		diagnostics.error("@observable on '%s' needs the name '%s', which is already %s"
			% [vd.name, backing, taken[backing]], vd.line, vd.col,
			"@observable keeps the value in a backing field of that name. Rename one of them.")
	var sig: String = "on_%s_changed" % vd.name
	if taken.has(sig):
		diagnostics.error("@observable on '%s' generates signal '%s', which is already %s"
			% [vd.name, sig, taken[sig]], vd.line, vd.col,
			"@observable emits that signal itself. Rename one of them.")


func _check_soa_names(vd: GateAST._VarDecl, taken: Dictionary) -> void:
	if vd.type == null or not structs.has(vd.type.name):
		return
	var sd: GateAST._ClassDecl = structs[vd.type.name]
	for f in struct_fields(sd):
		var generated: String = "%s_%s" % [vd.name, (f as GateAST._VarDecl).name]
		if taken.has(generated):
			diagnostics.error("@soa on '%s' needs the name '%s', which is already %s"
				% [vd.name, generated, taken[generated]], vd.line, vd.col,
				"@soa emits one array per struct field, named `<array>_<field>`. "
				+ "Rename one of them.")


func _collect(members: Array) -> void:
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			match cd.form:
				"interface": interfaces[cd.name] = cd
				"trait": traits[cd.name] = cd
				"struct": structs[cd.name] = cd
				_: classes[cd.name] = cd
			_collect(cd.members)


func _process(node: GateAST._Stmt) -> void:
	if not (node is GateAST._ClassDecl):
		return
	var cd: GateAST._ClassDecl = node

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


func _apply_traits(cd: GateAST._ClassDecl) -> void:
	if cd.traits.is_empty():
		return
	var seen: Dictionary = {}
	for existing in cd.members:
		var n: String = _member_key(existing)
		if n != "":
			seen[n] = "the class itself"

	var injected: Array = []
	for tname in cd.traits:
		if not traits.has(tname):
			diagnostics.error("unknown trait '%s'" % tname, cd.line, cd.col,
				"traits must be declared with `trait %s:` before use" % tname)
			continue
		var tr: GateAST._ClassDecl = traits[tname]

		for req in tr.requires:
			if not seen.has(req):
				diagnostics.error(
					"'%s' requires a member '%s', which '%s' does not provide" % [tname, req, cd.name],
					cd.line, cd.col)

		for tm in tr.members:
			var n2: String = _member_key(tm)
			if n2 == "":
				continue
			if seen.has(n2):
				var owner: String = seen[n2]
				if owner == "the class itself":
					continue
				diagnostics.error(
					"trait conflict: '%s' is provided by both '%s' and '%s'"
						% [_member_name(tm), owner, tname],
					cd.line, cd.col,
					"remove one, or override it in '%s' to disambiguate" % cd.name)
				continue
			seen[n2] = tname
			injected.append(clone_ast(tm, {}) if tm is GateAST._FuncDecl else tm)

		for impl in tr.implements:
			if not cd.implements.has(impl):
				cd.implements.append(impl)

	if not injected.is_empty():
		var rest: Array = cd.members.duplicate()
		cd.members = injected
		cd.members.append_array(rest)


func _member_key(m) -> String:
	var n: String = _member_name(m)
	if n == "" or not (m is GateAST._FuncDecl):
		return n
	return "%s/%d" % [n, (m as GateAST._FuncDecl).params.size()]


func _member_name(m) -> String:
	if m is GateAST._FuncDecl: return (m as GateAST._FuncDecl).name
	if m is GateAST._VarDecl: return (m as GateAST._VarDecl).name
	if m is GateAST._SignalDecl: return (m as GateAST._SignalDecl).name
	return ""


func _check_interface_decl(cd: GateAST._ClassDecl) -> void:
	for m in cd.members:
		if m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
			if not fd.body.is_empty():
				diagnostics.warn("interface method '%s' has a body; it will be ignored" % fd.name,
					fd.line, fd.col, "interfaces declare signatures only")


func _flatten_interfaces(cd: GateAST._ClassDecl) -> void:
	var names: Array = []
	var queue: Array = cd.implements.duplicate()
	while not queue.is_empty():
		var n: String = queue.pop_front()
		if names.has(n):
			continue
		names.append(n)
		if interfaces.has(n):
			var idecl: GateAST._ClassDecl = interfaces[n]
			for parent in idecl.implements:
				queue.append(parent)
		else:
			diagnostics.error("unknown interface '%s'" % n, cd.line, cd.col,
				"declare it with `interface %s:` or remove it from the implements list" % n)
	cd.interface_names = names


func _verify_conformance(cd: GateAST._ClassDecl) -> void:
	if cd.interface_names.is_empty():
		return
	var found: Dictionary = _conformance_members(cd)
	if not bool(found["known"]):
		return   # a base GATE cannot read may provide anything
	var provided: Dictionary = found["names"]
	var engine: String = String(found["engine"])

	for iname in cd.interface_names:
		if not interfaces.has(iname):
			continue
		var idecl: GateAST._ClassDecl = interfaces[iname]
		for im in idecl.members:
			if im is GateAST._VarDecl:
				var ivd: GateAST._VarDecl = im
				if engine != "" and _engine_property_names(engine).has(ivd.name):
					continue
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
			if im is GateAST._FuncDecl:
				var ifd: GateAST._FuncDecl = im
				if engine != "" and ClassDB.class_has_method(engine, ifd.name):
					continue
				if not provided.has(ifd.name):
					diagnostics.error(
						"'%s' does not implement '%s.%s'" % [cd.name, iname, ifd.name],
						cd.line, cd.col,
						"add: func %s(%s) -> %s" % [
							ifd.name, _params_sig(ifd.params),
							GateTypes.resolve(ifd.return_type) if ifd.return_type else "void"])
					continue
				var group: Array = provided[ifd.name]
				var first: GateAST._FuncDecl = null
				var fits: bool = false
				for got in group:
					if not (got is GateAST._FuncDecl):
						fits = true   # a variable or a signal of that name: not ours to judge
						break
					var gfd: GateAST._FuncDecl = got
					if first == null:
						first = gfd
					if gfd.params.size() == ifd.params.size():
						fits = true
				if not fits and first != null:
					diagnostics.error(
						"'%s.%s' takes %d parameter(s) but '%s' declares %d" % [
							cd.name, first.name, first.params.size(), iname, ifd.params.size()],
						first.line, first.col)


func _conformance_members(cd: GateAST._ClassDecl) -> Dictionary:
	var names: Dictionary = {}
	var seen: Dictionary = {}
	var cur: GateAST._ClassDecl = cd
	while cur != null:
		for m in cur.members:
			var n: String = _member_name(m)
			if n == "":
				continue
			if not names.has(n):
				names[n] = []
			names[n].append(m)
		if cur.extends_type == null:
			return {"names": names, "engine": "", "known": true}
		var base: String = cur.extends_type.name
		if seen.has(base):
			return {"names": names, "engine": "", "known": true}
		seen[base] = true
		if classes.has(base):
			cur = classes[base]
			continue
		if structs.has(base):
			cur = structs[base]
			continue
		if ClassDB.class_exists(base):
			return {"names": names, "engine": base, "known": true}
		return {"names": names, "engine": "", "known": false}
	return {"names": names, "engine": "", "known": true}


func _params_sig(params: Array) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for p in params:
		var pp: GateAST._Param = p
		parts.append("%s: %s" % [pp.name, GateTypes.resolve(pp.type) if pp.type else "Variant"])
	return ", ".join(parts)


func _verify_overrides(cd: GateAST._ClassDecl) -> void:
	var declared_by: Array = []
	for n in cd.interface_names:
		if interfaces.has(n):
			declared_by.append(interfaces[n])
	for n2 in cd.traits:
		if traits.has(n2):
			declared_by.append(traits[n2])
	_verify_overrides_in(cd.members, cd.extends_type, declared_by)


func _verify_overrides_in(members: Array, ext_t: GateAST._TypeRef, declared_by: Array) -> void:
	var anc: Dictionary = {}
	for m in members:
		if not (m is GateAST._FuncDecl):
			continue
		var fd: GateAST._FuncDecl = m
		if anc.is_empty():
			anc = _ancestry(ext_t)
		var hit: Array = (anc["funcs"] as Dictionary).get(fd.name, [])
		if not hit.is_empty() and hit[0] is GateAST._FuncDecl and (hit[0] as GateAST._FuncDecl).is_final:
			diagnostics.error(
				"cannot override '%s': it is declared final in '%s'" % [fd.name, hit[1]],
				fd.line, fd.col, "rename this method, or remove `final` from the one in '%s'" % hit[1])
			continue
		if not fd.is_override or not hit.is_empty() or anc["unknown"] or fd.name in ["_init", "_static_init"]:
			continue
		var engine: String = anc["engine"]
		if engine != "" and _engine_funcs(engine).has(fd.name):
			continue
		var in_contract: bool = false
		for c in declared_by:
			if _func_names((c as GateAST._ClassDecl).members).has(fd.name):
				in_contract = true
		if in_contract:
			continue
		diagnostics.error(
			"'%s' is marked override but '%s' declares no such method, and nor does anything it extends"
				% [fd.name, ext_t.name if ext_t != null else "RefCounted"],
			fd.line, fd.col, "check the spelling, or remove `override`")


static var _engine_func_cache: Dictionary = {}


static func _engine_funcs(cls: String) -> Dictionary:
	if _engine_func_cache.has(cls):
		return _engine_func_cache[cls]
	var out: Dictionary = {}
	for m in ClassDB.class_get_method_list(cls):
		out[String(m["name"])] = true
	_engine_func_cache[cls] = out
	return out


func _ancestry(ext_t: GateAST._TypeRef) -> Dictionary:
	var funcs: Dictionary = {}
	var names: Dictionary = {}
	var out: Dictionary = {"funcs": funcs, "names": names, "engine": "", "unknown": false}
	var base: String = ext_t.name if ext_t != null else "RefCounted"
	var from: String = _path
	var ctx: GateAST._Module = null
	var seen: Dictionary = {}
	while base != "":
		if seen.has(from + "|" + base):
			out["unknown"] = true
			return out
		seen[from + "|" + base] = true
		var members: Array = []
		var ext: GateAST._TypeRef = null
		var owner: String = base
		var smod: GateAST._Module = null
		var inner: PackedStringArray = PackedStringArray()
		var last: String = base.get_slice(".", base.get_slice_count(".") - 1)
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
		elif ctx == null and (classes.has(base) or (base.contains(".")
				and classes.has(base.get_slice(".", 0)) and classes.has(last))):
			var cd: GateAST._ClassDecl = classes[last]
			members = cd.members
			ext = cd.extends_type
			owner = cd.name
			for tn in cd.traits:
				if traits.has(tn):
					_note_funcs((traits[tn] as GateAST._ClassDecl).members, owner, funcs)
					_note_declared((traits[tn] as GateAST._ClassDecl).members, owner, names)
		elif ClassDB.class_exists(base):
			out["engine"] = base
			return out
		else:
			var script2: String = _global_script(base.get_slice(".", 0), _registry)
			smod = read_script(script2) if script2 != "" else null
			if base.contains("."):
				inner = base.split(".").slice(1)
			if smod == null:
				out["unknown"] = true
				return out
		if smod != null:
			members = smod.members
			ext = smod.extends_type
			for part in inner:
				var icd: GateAST._ClassDecl = _inner_class(members, part)
				if icd == null:
					out["unknown"] = true
					return out
				members = icd.members
				ext = icd.extends_type
			from = smod.path
			ctx = smod
			if inner.is_empty():
				owner = smod.class_name_decl if smod.class_name_decl != "" else smod.path.get_file()
			else:
				owner = inner[inner.size() - 1]
		_note_funcs(members, owner, funcs)
		_note_declared(members, owner, names)
		base = ext.name if ext != null else "RefCounted"
	out["unknown"] = true
	return out


static func _note_funcs(members: Array, owner: String, funcs: Dictionary) -> void:
	for m in members:
		if m is GateAST._FuncDecl and not funcs.has((m as GateAST._FuncDecl).name):
			funcs[(m as GateAST._FuncDecl).name] = [m, owner]
	for wn in GateInject.will_define(members):
		if not funcs.has(wn):
			funcs[wn] = [null, owner]


static func _note_declared(members: Array, owner: String, names: Dictionary) -> void:
	var here: Dictionary = declared_members(members)
	for n in here:
		if not names.has(n):
			names[n] = "%s in '%s'" % [here[n], owner]
	var renamed: Dictionary = priv_renames(members)
	for pn in renamed:
		if not names.has(pn):
			names[pn] = "the emitted name of priv '%s' in '%s'" % [renamed[pn], owner]


static func struct_fields(cd: GateAST._ClassDecl) -> Array:
	var out: Array = []
	for m in cd.members:
		if m is GateAST._VarDecl and not (m as GateAST._VarDecl).is_const \
				and not (m as GateAST._VarDecl).is_static:
			out.append(m)
	return out


static func struct_needs_class(cd: GateAST._ClassDecl) -> bool:
	for m in cd.members:
		if m is GateAST._FuncDecl:
			return true
		if m is GateAST._VarDecl and ((m as GateAST._VarDecl).is_const or (m as GateAST._VarDecl).is_static):
			return true
	return false


static func scope_names(members: Array, all_static: bool) -> Dictionary:
	var out: Dictionary = {}
	for m in members:
		if m is GateAST._VarDecl:
			var vd: GateAST._VarDecl = m
			out[vd.name] = "static" if (all_static or vd.is_const or vd.is_static) else "instance"
		elif m is GateAST._FuncDecl:
			out[(m as GateAST._FuncDecl).name] = "static" if (all_static
				or (m as GateAST._FuncDecl).is_static) else "instance"
		elif m is GateAST._SignalDecl:
			out[(m as GateAST._SignalDecl).name] = "instance"
		elif m is GateAST._ClassDecl:
			out[(m as GateAST._ClassDecl).name] = "static"
		elif m is GateAST._EnumDecl:
			var ed: GateAST._EnumDecl = m
			if ed.name != "":
				out[ed.name] = "static"
			else:
				for k in ed.keys:
					out[String(k)] = "static"
	return out


static func idents_in(e, out: Dictionary, skip_lambdas: bool = false) -> void:
	if e == null:
		return
	if e is Array:
		for x in e:
			idents_in(x, out, skip_lambdas)
		return
	if not (e is Object) or (e as Object).get_script() == null:
		return
	if e is GateAST._Ident:
		out[(e as GateAST._Ident).name] = true
		return
	if e is GateAST._Lambda and skip_lambdas:
		return
	if e is GateAST._TypeRef:
		return
	for prop in (e as Object).get_property_list():
		var pn: String = prop["name"]
		if pn in ["script", "Built-in script", "RefCounted", "Object"]:
			continue
		var v = (e as Object).get(pn)
		if v is Array or (v is Object and v != null and (v as Object).get_script() != null):
			idents_in(v, out, skip_lambdas)


func _check_struct(cd: GateAST._ClassDecl) -> void:
	var field_types: Array = []
	var fields: Array = struct_fields(cd)
	for f in fields:
		var vd: GateAST._VarDecl = f
		field_types.append(GateTypes.struct_field_kind(vd.type))

	if fields.is_empty():
		diagnostics.error("struct '%s' has no fields" % cd.name, cd.line, cd.col)
		cd.lowering = "class"
		return

	for i in fields.size():
		var fv: GateAST._VarDecl = fields[i]
		if fv.value == null:
			continue
		var read: Dictionary = {}
		idents_in(fv.value, read, true)
		for j in range(i, fields.size()):
			var later: String = (fields[j] as GateAST._VarDecl).name
			if not read.has(later):
				continue
			diagnostics.error("the default of '%s' reads '%s', %s" % [fv.name, later,
					"its own field" if j == i else "which is declared after it"],
				fv.line, fv.col,
				"a default is filled in when the field is omitted, and may read only the "
				+ "fields declared before it")
			break

	for f3 in fields:
		var av: GateAST._VarDecl = f3
		if av.setter != "" or av.getter != "" or av.inline_accessors != "":
			diagnostics.error("struct field '%s' has an accessor; use a method instead" % av.name,
				av.line, av.col,
				"a struct's fields are copied, built and scalar-replaced as plain values, so a "
				+ "getter or setter would run at times you did not write, or not at all. Write a "
				+ "method such as `set_%s(v)`." % av.name)
	for rm in cd.members:
		var rname: String = String(rm.name) if ("name" in rm) else ""
		if not (rname in ["_gate_copy", "_gate_eq"]):
			continue
		if rm is GateAST._FuncDecl or rm is GateAST._VarDecl:
			diagnostics.error("struct '%s' declares '%s', which GATE writes for every struct"
					% [cd.name, rname], rm.line, rm.col,
				"a copy and an equality are called on values whose type is not known, so the "
				+ "names cannot move. Rename this member; `_gate_deep`, `_gate_value`, "
				+ "`_gate_index` and `_gate_eqv` are renamed around instead.")
	for m in cd.members:
		if m is GateAST._FuncDecl and (m as GateAST._FuncDecl).name == "_init":
			diagnostics.error("struct '%s' declares _init, but a struct's constructor is built from its fields"
					% cd.name, (m as GateAST._FuncDecl).line, (m as GateAST._FuncDecl).col,
				"`%s(...)` takes one value per field and fills the rest from their defaults. " % cd.name
				+ "Give the fields defaults instead, or declare a `class` to write your own _init.")
	for f2 in fields:
		var through: String = _struct_cycle(cd.name, f2, {})
		if through != "":
			diagnostics.error("struct '%s' contains itself through '%s', so it can never be built"
					% [cd.name, through], (f2 as GateAST._VarDecl).line, (f2 as GateAST._VarDecl).col,
				"a struct holds its fields by value. Make the field nullable (`%s? %s`) or an array."
					% [(f2 as GateAST._VarDecl).type.name, (f2 as GateAST._VarDecl).name])
			break

	var has_methods: bool = struct_needs_class(cd)

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
			why = "it declares constants or statics"
			for m in cd.members:
				if m is GateAST._FuncDecl:
					why = "it declares methods"
		elif fields.size() >= 2 and fields.size() <= 4:
			why = "its fields are not all the same numeric type"
		diagnostics.info(
			"struct '%s' lowered to a class because %s; value semantics are kept by copying"
				% [cd.name, why],
			cd.line, cd.col,
			"structs of 2-4 same-typed int/float fields lower to Vector2/3/4 and copy for free. "
			+ "This one allocates on each copy - use `class` if you want reference semantics.")


func _struct_cycle(target: String, f, seen: Dictionary) -> String:
	var vd: GateAST._VarDecl = f
	var t: GateAST._TypeRef = vd.type
	if t == null or t.nullable or t.array_depth != 0 or t.is_dict() or t.is_union() or t.is_tuple():
		return ""
	var n: String = t.name.get_slice(".", t.name.get_slice_count(".") - 1)
	if n == target:
		return vd.name
	if seen.has(n) or not structs.has(n):
		return ""
	seen[n] = true
	for inner in struct_fields(structs[n]):
		var rest: String = _struct_cycle(target, inner, seen)
		if rest != "":
			return "%s.%s" % [vd.name, rest]
	return ""


func _check_struct_consts(nodes: Array) -> void:
	for n in nodes:
		if n is GateAST._ClassDecl:
			_check_struct_consts((n as GateAST._ClassDecl).members)
		elif n is GateAST._FuncDecl:
			_check_struct_consts((n as GateAST._FuncDecl).body)
		elif n is GateAST._VarDecl and (n as GateAST._VarDecl).is_const:
			var vd: GateAST._VarDecl = n
			var sn: String = _const_struct_named(vd)
			if sn != "" and struct_decl(sn) != null and struct_decl(sn).lowering == "class":
				diagnostics.error("'%s' holds a struct lowered to a class, which cannot be a const"
						% vd.name, vd.line, vd.col,
					"GDScript constants cannot hold objects. Use `static var %s`, or a struct " % vd.name
					+ "of 2-4 same-typed numbers, which lowers to a Vector and can be a const.")
		elif n is GateAST._Stmt:
			for sub in _blocks_of(n):
				_check_struct_consts(sub)


static func _blocks_of(s) -> Array:
	if s is GateAST._IfStmt:
		var out: Array = [(s as GateAST._IfStmt).then_body, (s as GateAST._IfStmt).else_body]
		for pair in (s as GateAST._IfStmt).elifs:
			out.append(pair[1])
		return out
	if s is GateAST._ForStmt:
		return [(s as GateAST._ForStmt).body]
	if s is GateAST._WhileStmt:
		return [(s as GateAST._WhileStmt).body]
	if s is GateAST._MatchStmt:
		var arms: Array = []
		for br in (s as GateAST._MatchStmt).branches:
			arms.append(br[2])
		return arms
	if s is GateAST._AnnotatedStmt and (s as GateAST._AnnotatedStmt).stmt != null:
		return [[(s as GateAST._AnnotatedStmt).stmt]]
	return []


func _check_namespace(cd: GateAST._ClassDecl) -> void:
	for m in cd.members:
		if m is GateAST._ClassDecl:
			var inner: GateAST._ClassDecl = m
			if inner.extends_type != null:
				var base: String = GateTypes.canonical(inner.extends_type.name)
				if base.begins_with("Node") or base.ends_with("Body2D") or base.ends_with("Body3D"):
					diagnostics.warn(
						"'%s.%s' extends a Node type inside a namespace" % [cd.name, inner.name],
						inner.line, inner.col,
						"namespaced classes become inner classes and cannot be attached to nodes "
						+ "as scripts. Move it to the top level if it needs to be a node script.")

const REST_ARITY := -1


func _link_inherited_overloads(members: Array, module_base: GateAST._TypeRef = null) -> void:
	if module_base != null:
		_link_to_base(members, module_base.name)
	for m in members:
		if not (m is GateAST._ClassDecl):
			continue
		var cd: GateAST._ClassDecl = m
		_link_inherited_overloads(cd.members)
		if cd.extends_type != null:
			_link_to_base(cd.members, cd.extends_type.name)


func _link_to_base(members: Array, first_base: String) -> void:
	var seen: Dictionary = {}
	var base_name: String = first_base
	while base_name != "" and not seen.has(base_name):
		seen[base_name] = true
		var bcd = classes.get(base_name, null)
		if not (bcd is GateAST._ClassDecl) and _registry != null and "script_class_decls" in _registry:
			bcd = _registry.script_class_decls.get(base_name, null)
		if not (bcd is GateAST._ClassDecl):
			break
		var arities: Dictionary = {}
		for bm0 in (bcd as GateAST._ClassDecl).members:
			if bm0 is GateAST._FuncDecl:
				var bn: String = (bm0 as GateAST._FuncDecl).name
				arities[bn] = int(arities.get(bn, 0)) + 1
		for bm in (bcd as GateAST._ClassDecl).members:
			if not (bm is GateAST._FuncDecl):
				continue
			var bfd: GateAST._FuncDecl = bm
			var bmangled: String = bfd.mangled_name
			if bmangled == "" and int(arities.get(bfd.name, 0)) > 1 \
					and not bfd.name.begins_with(ENGINE_PREFIX):
				var variadic: bool = (not bfd.params.is_empty()
					and (bfd.params[bfd.params.size() - 1] as GateAST._Param).is_rest)
				bmangled = "__%s_%s" % [bfd.name, "rest" if variadic else str(bfd.params.size())]
			if bmangled == "":
				continue
			for dm in members:
				if not (dm is GateAST._FuncDecl):
					continue
				var dfd: GateAST._FuncDecl = dm
				if (dfd.mangled_name == "" and dfd.name == bfd.name
						and dfd.params.size() == bfd.params.size()):
					dfd.mangled_name = bmangled
		var bx = (bcd as GateAST._ClassDecl).extends_type
		base_name = bx.name if bx != null else ""


func _process_overloads(members: Array) -> void:
	var by_name: Dictionary = {}
	for m in members:
		if m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
			if not by_name.has(fd.name):
				by_name[fd.name] = []
			by_name[fd.name].append(fd)

	var taken: Dictionary = {}
	for m2 in members:
		var tn: String = _member_name(m2)
		if tn != "":
			taken[tn] = true
		if m2 is GateAST._ClassDecl:
			taken[(m2 as GateAST._ClassDecl).name] = true
		elif m2 is GateAST._EnumDecl:
			var ed: GateAST._EnumDecl = m2
			if ed.name != "":
				taken[ed.name] = true
			for k in ed.keys:
				taken[String(k)] = true

	for name in by_name:
		var group: Array = by_name[name]
		if group.size() < 2:
			continue
		var first: GateAST._FuncDecl = group[0]
		if String(name).begins_with(ENGINE_PREFIX):
			diagnostics.error(
				"cannot overload '%s': names starting with '_' are reachable from the engine" % name,
				first.line, first.col,
				"engine callbacks and virtuals are called by name, so they must not be mangled. "
				+ "Use distinct names, or default parameters.")
			continue
		var by_arity: Dictionary = {}
		for f in group:
			var fd2: GateAST._FuncDecl = f
			var is_variadic: bool = (not fd2.params.is_empty()
				and (fd2.params[fd2.params.size() - 1] as GateAST._Param).is_rest)
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


var _tp_generics: Dictionary = {}
var _tp_fields: Dictionary = {}
var _tp_funcs: Dictionary = {}          ## name -> declared return type, in the class being walked
var _tp_enums: Dictionary = {}


func _tp_collect_enums(members: Array) -> void:
	for m in members:
		if m is GateAST._EnumDecl and (m as GateAST._EnumDecl).name != "":
			_tp_enums[(m as GateAST._EnumDecl).name] = true
		elif m is GateAST._ClassDecl:
			_tp_collect_enums((m as GateAST._ClassDecl).members)


func _tp_members(members: Array, generics: Dictionary) -> void:
	var saved_g: Dictionary = _tp_generics
	var saved_f: Dictionary = _tp_fields
	var saved_fn: Dictionary = _tp_funcs
	_tp_generics = generics
	_tp_fields = {}
	_tp_funcs = {}
	for m in members:
		if m is GateAST._VarDecl and (m as GateAST._VarDecl).type != null:
			_tp_fields[(m as GateAST._VarDecl).name] = (m as GateAST._VarDecl).type
		elif m is GateAST._FuncDecl:
			var rfd: GateAST._FuncDecl = m
			_tp_funcs[rfd.name] = null if _tp_funcs.has(rfd.name) else rfd.return_type
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			var inner: Dictionary = generics.duplicate()
			for gp in cd.generic_params:
				inner[String(gp)] = true
			_tp_members(cd.members, inner)
		elif m is GateAST._FuncDecl:
			_tp_func((m as GateAST._FuncDecl).params, (m as GateAST._FuncDecl).body, [])
		elif m is GateAST._VarDecl:
			_tp_expr((m as GateAST._VarDecl).value, [])
	_tp_generics = saved_g
	_tp_fields = saved_f
	_tp_funcs = saved_fn


func _tp_instances(mod: GateAST._Module) -> void:
	for inst in generic_instances(mod, _registry):
		if inst[0] == null:
			var at: GateAST._TypeRef = inst[2]
			diagnostics.warn("more than %d generic instantiations: the rest are emitted, but "
					% GENERIC_RECHECK_LIMIT + "their bodies are not checked again", at.line, at.col,
				"every instantiation is still built; GATE only stops re-reading the template's "
				+ "body for each one")
			continue
		var found: GateDiagnostics = GateDiagnostics.new()
		var saved: GateDiagnostics = diagnostics
		diagnostics = found
		_tp_members([inst[4]], {})
		diagnostics = saved
		report_instance(diagnostics, found, inst)


func _tp_func(params: Array, body: Array, outer: Array) -> void:
	var scope: Dictionary = {}
	for p in params:
		var pp: GateAST._Param = p
		scope[pp.name] = pp.type
	var scopes: Array = outer.duplicate()
	scopes.append(scope)
	_tp_block(body, scopes)


func _tp_block(body: Array, outer: Array) -> void:
	var scopes: Array = outer.duplicate()
	scopes.append({})
	for s in body:
		_tp_stmt(s, scopes)


func _tp_stmt(s, scopes: Array) -> void:
	var here: Dictionary = scopes[scopes.size() - 1]
	if s is GateAST._AnnotatedStmt:
		_tp_stmt((s as GateAST._AnnotatedStmt).stmt, scopes)
	elif s is GateAST._VarDecl:
		var vd: GateAST._VarDecl = s
		_tp_expr(vd.value, scopes)
		here[vd.name] = vd.type if vd.type != null else (_tp_value_type(vd.value) if vd.inferred else null)
	elif s is GateAST._AssignStmt:
		_tp_expr((s as GateAST._AssignStmt).target, scopes)
		_tp_expr((s as GateAST._AssignStmt).value, scopes)
	elif s is GateAST._MultiAssign:
		var ma: GateAST._MultiAssign = s
		for v in ma.values:
			_tp_expr(v, scopes)
		if ma.declares:
			for t in ma.targets:
				if t is GateAST._Ident:
					here[(t as GateAST._Ident).name] = null
	elif s is GateAST._ExprStmt:
		_tp_expr((s as GateAST._ExprStmt).expr, scopes)
	elif s is GateAST._ReturnStmt:
		_tp_expr((s as GateAST._ReturnStmt).value, scopes)
	elif s is GateAST._IfStmt:
		var i: GateAST._IfStmt = s
		_tp_expr(i.cond, scopes)
		_tp_block(i.then_body, scopes)
		for pair in i.elifs:
			_tp_expr(pair[0], scopes)
			_tp_block(pair[1], scopes)
		_tp_block(i.else_body, scopes)
	elif s is GateAST._ForStmt:
		var fo: GateAST._ForStmt = s
		_tp_expr(fo.iterable, scopes)
		var loop: Array = scopes.duplicate()
		var vars: Dictionary = {}
		for vn in fo.var_names:
			vars[String(vn)] = fo.var_type
		if fo.var_type == null and fo.var_names.size() == 1:
			var it: GateAST._TypeRef = _tp_path_type(fo.iterable, scopes)
			if it != null and it.array_depth > 0:
				var et: GateAST._TypeRef = copy_type(it)
				et.array_depth -= 1
				et.nullable = it.elem_nullable
				et.elem_nullable = false
				vars[String(fo.var_names[0])] = et
		loop.append(vars)
		_tp_block(fo.body, loop)
	elif s is GateAST._WhileStmt:
		_tp_expr((s as GateAST._WhileStmt).cond, scopes)
		_tp_block((s as GateAST._WhileStmt).body, scopes)
	elif s is GateAST._MatchStmt:
		_tp_match(s, scopes)
	elif s is GateAST._FuncDecl:
		_tp_func((s as GateAST._FuncDecl).params, (s as GateAST._FuncDecl).body, scopes)


func _tp_match(mt: GateAST._MatchStmt, scopes: Array) -> void:
	_tp_expr(mt.subject, scopes)
	var subject_t: GateAST._TypeRef = _tp_path_type(mt.subject, scopes)
	if subject_t != null:
		pass
	elif mt.subject is GateAST._Call and (mt.subject as GateAST._Call).callee is GateAST._Ident:
		var fname: String = ((mt.subject as GateAST._Call).callee as GateAST._Ident).name
		if not _tp_declared(fname, scopes):
			subject_t = _tp_funcs.get(fname, null)
	for br in mt.branches:
		var arm: Array = scopes.duplicate()
		var binds: Dictionary = {}
		for p in br[0]:
			if p is GateAST._TypePattern:
				var tp: GateAST._TypePattern = p
				_tp_check(tp, subject_t, scopes)
				binds[tp.bind_name] = null
				_tp_pattern_types[tp.type] = true
			elif p is GateAST._RawExpr:
				for bn in GateInfer._var_binds((p as GateAST._RawExpr).text):
					binds[bn] = null
		arm.append(binds)
		_tp_expr(br[1], arm)
		_tp_block(br[2], arm)


func _tp_expr(e, scopes: Array) -> void:
	if e == null:
		return
	if e is GateAST._Lambda:
		var lam: GateAST._Lambda = e
		var sc: Dictionary = {}
		for p in lam.params:
			sc[(p as GateAST._Param).name] = (p as GateAST._Param).type
		var inner: Array = scopes.duplicate()
		inner.append(sc)
		_tp_block(lam.body, inner)
		_tp_expr(lam.expr_body, inner)
	elif e is GateAST._Call:
		_tp_expr((e as GateAST._Call).callee, scopes)
		for a in (e as GateAST._Call).args:
			_tp_expr(a, scopes)
	elif e is GateAST._Binary:
		var cur = e
		while cur is GateAST._Binary:
			_tp_expr((cur as GateAST._Binary).right, scopes)
			cur = (cur as GateAST._Binary).left
		_tp_expr(cur, scopes)
	elif e is GateAST._Unary:
		_tp_expr((e as GateAST._Unary).operand, scopes)
	elif e is GateAST._Ternary:
		_tp_expr((e as GateAST._Ternary).cond, scopes)
		_tp_expr((e as GateAST._Ternary).if_true, scopes)
		_tp_expr((e as GateAST._Ternary).if_false, scopes)
	elif e is GateAST._NullCoalesce:
		_tp_expr((e as GateAST._NullCoalesce).left, scopes)
		_tp_expr((e as GateAST._NullCoalesce).right, scopes)
	elif e is GateAST._Member:
		_tp_expr((e as GateAST._Member).target, scopes)
	elif e is GateAST._Index:
		_tp_expr((e as GateAST._Index).target, scopes)
		_tp_expr((e as GateAST._Index).index, scopes)
	elif e is GateAST._ArrayLit:
		for el in (e as GateAST._ArrayLit).elements:
			_tp_expr(el, scopes)
	elif e is GateAST._DictLit:
		for k in (e as GateAST._DictLit).keys:
			_tp_expr(k, scopes)
		for v in (e as GateAST._DictLit).values:
			_tp_expr(v, scopes)
	elif e is GateAST._ObjectInit:
		for v2 in (e as GateAST._ObjectInit).values:
			_tp_expr(v2, scopes)
	elif e is GateAST._FString:
		for part in (e as GateAST._FString).parts:
			if not (part is String):
				_tp_expr(part, scopes)
	elif e is GateAST._AwaitExpr:
		_tp_expr((e as GateAST._AwaitExpr).operand, scopes)
	elif e is GateAST._CastExpr:
		_tp_tested((e as GateAST._CastExpr).type, "as")
		_tp_expr((e as GateAST._CastExpr).operand, scopes)
	elif e is GateAST._IsExpr:
		var ie: GateAST._IsExpr = e
		_tp_tested(ie.type, "is", _tp_path_type(ie.operand, scopes))
		_tp_expr(ie.operand, scopes)


var _tp_pattern_types: Dictionary = {}


func _tp_tested(t: GateAST._TypeRef, kw: String, operand_t: GateAST._TypeRef = null) -> void:
	if t == null or _tp_pattern_types.has(t):
		return
	if not_single_type(t):
		diagnostics.error("`%s` needs a single type, not %s" % [kw, t.describe()], t.line, t.col,
			"test each member instead, as in `x is int or x is String`")
		return
	if _packed_scene_of(t):
		diagnostics.error("`%s` can only test PackedScene; the scene's root type is not known "
				% kw + "until it is instantiated", t.line, t.col,
			"test `PackedScene`, and check what `instantiate()` returns")
		return
	if kw == "is" and _vector_runtime(t) != "" and not _tp_shape_sound(t, operand_t):
		var shown: String = _vector_runtime_shown(t)
		diagnostics.error(
			"%s is stored as %s, so `is` cannot tell it from any other %s"
				% [_struct_shown(t), _article(shown), shown],
			t.line, t.col, "compare its fields instead, or give the struct a method so it "
				+ "lowers to a class")


static func not_single_type(t: GateAST._TypeRef) -> bool:
	return t != null and (t.is_union() or t.is_tuple() or t.is_func_type)


func _tp_declared(name: String, scopes: Array) -> bool:
	for sc in scopes:
		if (sc as Dictionary).has(name):
			return true
	return false


func _tp_path_type(e, scopes: Array, depth: int = 0) -> GateAST._TypeRef:
	if e == null or depth > 24:
		return null
	if e is GateAST._Ident:
		return _tp_lookup((e as GateAST._Ident).name, scopes)
	if e is GateAST._Member and not (e as GateAST._Member).safe:
		var m: GateAST._Member = e
		if m.target is GateAST._SelfExpr:
			return _tp_fields.get(m.name, null)
		var bt: GateAST._TypeRef = _tp_path_type(m.target, scopes, depth + 1)
		if bt == null or bt.array_depth > 0 or bt.is_dict() or bt.is_union() or bt.is_tuple():
			return null
		return _tp_class_field(bt.name, m.name)
	if e is GateAST._Index and not (e as GateAST._Index).safe:
		var at: GateAST._TypeRef = _tp_path_type((e as GateAST._Index).target, scopes, depth + 1)
		if at == null or at.array_depth == 0:
			return null
		var el: GateAST._TypeRef = copy_type(at)
		el.array_depth -= 1
		el.nullable = at.elem_nullable
		el.elem_nullable = false
		return el
	return null


func _tp_class_field(cls: String, field: String) -> GateAST._TypeRef:
	var seen: Dictionary = {}
	var c: String = cls
	while c != "" and not seen.has(c) and classes.has(c):
		seen[c] = true
		var cd: GateAST._ClassDecl = classes[c]
		for m in cd.members:
			if m is GateAST._VarDecl and (m as GateAST._VarDecl).name == field:
				return (m as GateAST._VarDecl).type
		c = cd.extends_type.name if cd.extends_type != null else ""
	return null


func _tp_lookup(name: String, scopes: Array) -> GateAST._TypeRef:
	for i in range(scopes.size() - 1, -1, -1):
		if (scopes[i] as Dictionary).has(name):
			return scopes[i][name]
	return _tp_fields.get(name, null)


func _tp_value_type(v) -> GateAST._TypeRef:
	var t: GateAST._TypeRef = GateAST._TypeRef.new()
	if v is GateAST._Call and (v as GateAST._Call).callee is GateAST._Member:
		var cm: GateAST._Member = (v as GateAST._Call).callee
		if cm.name == "new" and cm.target is GateAST._Ident:
			t.name = (cm.target as GateAST._Ident).name
			return t
	if v is GateAST._Literal:
		var l: GateAST._Literal = v
		match l.kind:
			"string":
				t.name = "String"
			"bool":
				t.name = "bool"
			"number":
				t.name = "float" if (l.raw.contains(".") or l.raw.contains("e")) \
					and not l.raw.begins_with("0x") and not l.raw.begins_with("0b") else "int"
			_:
				return null
		return t
	return null


func _tp_check(tp: GateAST._TypePattern, subject_t: GateAST._TypeRef, scopes: Array) -> void:
	var n: String = tp.type.name
	var cn: String = GateTypes.canonical(n)
	if _tp_declared(tp.bind_name, scopes):
		diagnostics.error(
			"'%s' is already declared here, so a type pattern cannot bind it" % tp.bind_name,
			tp.line, tp.col,
			"GDScript does not let a pattern reuse a name in scope; pick a new one, as in `%s %s2:`"
				% [tp.type.describe(), tp.bind_name])
	if not_single_type(tp.type):
		diagnostics.error("a type pattern needs a single type, not %s" % tp.type.describe(),
			tp.line, tp.col,
			"give each member its own arm, or bind with `var %s` and test the members in a "
				% tp.bind_name + "`when` guard")
		return
	if cn == "Variant" and tp.type.array_depth == 0:
		diagnostics.error("a type pattern of `%s` matches every value, null included" % n,
			tp.line, tp.col, "write `var %s:` to bind whatever the value is" % tp.bind_name)
		return
	if _packed_scene_of(tp.type):
		diagnostics.error("a type pattern can only test PackedScene; the scene's root type is "
				+ "not known until it is instantiated", tp.line, tp.col,
			"write `PackedScene %s:`, and check what `instantiate()` returns" % tp.bind_name)
		return
	if tp.type.array_depth == 0 and _tp_enums.has(n):
		return
	var before: int = diagnostics.error_count()
	_verify_type_name(tp.type, _tp_generics)
	if diagnostics.error_count() > before:
		return
	var vkey: String = _vector_runtime(tp.type)
	if vkey != "" and not _tp_shape_sound(tp.type, subject_t):
		var shown: String = _vector_runtime_shown(tp.type)
		diagnostics.error(
			"%s is stored as %s, so a type pattern cannot tell it from any other %s"
				% [_struct_shown(tp.type), _article(shown), shown],
			tp.line, tp.col,
			"match its fields instead (`var %s when %s is %s and ...`), or give the struct a "
				% [tp.bind_name, tp.bind_name, shown]
			+ "method so it lowers to a class")
		return
	if subject_t != null and not _tp_compatible(subject_t, tp.type):
		diagnostics.error(
			"the subject is declared '%s', so it can never be a '%s'"
				% [subject_t.describe(), tp.type.describe()],
			tp.line, tp.col,
			"Godot rejects the `is` test this pattern lowers to; remove the arm, or widen "
				+ "the subject's type")


static func _packed_scene_of(t: GateAST._TypeRef) -> bool:
	return t != null and t.array_depth == 0 and GateTypes.canonical(t.name) == "PackedScene" \
		and not t.generic_args.is_empty()


func struct_decl(name: String) -> GateAST._ClassDecl:
	if structs.has(name):
		return structs[name]
	if not name.contains("."):
		return null
	var last: String = name.get_slice(".", name.get_slice_count(".") - 1)
	return structs[last] if structs.has(last) else null


func _const_struct_named(vd: GateAST._VarDecl) -> String:
	if vd.type != null and vd.type.array_depth == 0 and struct_decl(vd.type.name) != null:
		return vd.type.name
	var found: Array = []
	_struct_builds_in(vd.value, found)
	if not found.is_empty():
		return String(found[0])
	if vd.type != null and vd.type.array_depth == 0:
		return vd.type.name
	return ""


func _struct_builds_in(e, found: Array) -> void:
	if e == null or not found.is_empty() or not (e is Object) or (e as Object).get_script() == null:
		return
	if e is GateAST._Call and (e as GateAST._Call).callee is GateAST._Ident:
		var cn: String = ((e as GateAST._Call).callee as GateAST._Ident).name
		if struct_decl(cn) != null:
			found.append(cn)
			return
	elif e is GateAST._Call and (e as GateAST._Call).callee is GateAST._Member:
		var qn: String = (e as GateAST._Call).callee.name
		if struct_decl(qn) != null:
			found.append(qn)
			return
	elif e is GateAST._ObjectInit:
		found.append((e as GateAST._ObjectInit).type.name)
		return
	for prop in (e as Object).get_property_list():
		var pn: String = prop["name"]
		if pn in ["script", "Built-in script", "RefCounted", "Object", "flow_type"]:
			continue
		var v = (e as Object).get(pn)
		if v is Array:
			for y in v:
				_struct_builds_in(y, found)
		elif v is Object:
			_struct_builds_in(v, found)


func _vector_runtime(t: GateAST._TypeRef) -> String:
	if t == null or t.is_dict() or t.is_union() or t.is_tuple():
		return ""
	var sd: GateAST._ClassDecl = struct_decl(t.name)
	if sd == null or sd.lowering != "vector":
		return ""
	return "%s|%d" % [sd.vector_type, t.array_depth]


static func _article(noun: String) -> String:
	return ("an " if noun.begins_with("A") else "a ") + noun


func _struct_shown(t: GateAST._TypeRef) -> String:
	return "struct '%s'" % t.name if t.array_depth == 0 else "'%s'" % t.describe()


func _vector_runtime_shown(t: GateAST._TypeRef) -> String:
	var vt: String = struct_decl(t.name).vector_type
	return vt if t.array_depth == 0 else "Array[%s]" % vt + "[]".repeat(t.array_depth - 1)


func _runtime_key(t: GateAST._TypeRef) -> String:
	var vk: String = _vector_runtime(t)
	if vk != "":
		return vk
	return "%s|%d" % [GateTypes.canonical(t.name), t.array_depth]


func _tp_shape_sound(t: GateAST._TypeRef, subject_t: GateAST._TypeRef) -> bool:
	if subject_t == null or subject_t.is_dict():
		return false
	var key: String = _vector_runtime(t)
	var members: Array = subject_t.union_members if subject_t.is_union() else [subject_t]
	if subject_t.is_union() and subject_t.array_depth > 0:
		return false   # an array of a union holds any mix
	var found: bool = false
	for m in members:
		if m == null:
			return false
		var mt: GateAST._TypeRef = m
		if mt.is_dict():
			continue
		if mt.name == t.name and mt.array_depth == t.array_depth:
			found = true
			continue
		var cmn: String = GateTypes.canonical(mt.name)
		if cmn in ["", "Variant"]:
			return false
		if t.array_depth > 0 and mt.array_depth == 0 and cmn == "Array" and mt.generic_args.is_empty():
			return false   # an untyped Array could be any array
		if _runtime_key(mt) == key:
			return false
	return found


func _tp_compatible(a: GateAST._TypeRef, b: GateAST._TypeRef) -> bool:
	if a.array_depth > 0 or b.array_depth > 0 or a.is_dict() or b.is_dict() \
		or not a.generic_args.is_empty() or not b.generic_args.is_empty():
		return true
	var an: String = GateTypes.canonical(a.name)
	var bn: String = GateTypes.canonical(b.name)
	if an == bn or an in ["", "Variant"] or bn in ["", "Variant"]:
		return true
	if interfaces.has(an) or interfaces.has(bn) or traits.has(an) or traits.has(bn):
		return true
	var a_builtin: bool = GateTypes.BUILTIN.has(an)
	var b_builtin: bool = GateTypes.BUILTIN.has(bn)
	if a_builtin and b_builtin:
		return false   # `int` is never a `float`: Godot rejects that too
	if a_builtin or b_builtin:
		return not _tp_is_object(bn if a_builtin else an)
	var up_a: Array = _tp_chain(an)
	var up_b: Array = _tp_chain(bn)
	if up_a.has(bn) or up_b.has(an):
		return true
	return not (up_a.has("Object") and up_b.has("Object"))


func _tp_is_object(n: String) -> bool:
	return _tp_chain(n).has("Object")


func _tp_chain(n: String) -> Array:
	var out: Array = []
	var c: String = n
	while c != "" and not out.has(c):
		out.append(c)
		var nxt: String = ""
		if classes.has(c):
			var cd: GateAST._ClassDecl = classes[c]
			nxt = cd.extends_type.name if cd.extends_type != null else "RefCounted"
		elif structs.has(c):
			nxt = "RefCounted"
		elif ClassDB.class_exists(c):
			nxt = ClassDB.get_parent_class(c)
		else:
			for gc in ProjectSettings.get_global_class_list():
				if String(gc["class"]) == c:
					nxt = String(gc["base"])
					break
		c = nxt
	return out


enum _NodeKind { NOT_NODE, IS_NODE, UNKNOWN }

enum _Inherits { NO, YES, UNKNOWN }

const INJECTING_ANNOTATIONS: Array = ["required", "export_if"]

const CONSTANT_GLOBALS: Array = ["PI", "TAU", "INF", "NAN"]

var super_calls: Dictionary = {}

var _path: String = ""
var _parsed: Dictionary = {}


func _annotation(annotations: Array, name: String) -> GateAST._Annotation:
	for a in annotations:
		if (a as GateAST._Annotation).name == name:
			return a
	return null


func _check_member_annotations(owner: Object, members: Array, base: GateAST._TypeRef,
		is_tool: bool, where: String = "", outer: Dictionary = {}) -> void:
	var props: Dictionary = {}
	var consts: Dictionary = outer.duplicate()
	for m in members:
		if m is GateAST._VarDecl:
			var v: GateAST._VarDecl = m
			if v.is_const:
				consts[v.name] = true
			else:
				props[v.name] = v
		elif m is GateAST._EnumDecl:
			var ed: GateAST._EnumDecl = m
			consts[ed.name] = true
			for k in ed.keys:
				consts[String(k)] = true
		elif m is GateAST._ClassDecl:
			consts[(m as GateAST._ClassDecl).name] = true
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			_misplaced(cd.annotations)
			if cd.form == "trait":
				continue   # its members are checked where they are inlined
			_check_member_annotations(cd, cd.members, cd.extends_type, is_tool,
				"" if cd.form == "class" else cd.form, consts)
		elif m is GateAST._VarDecl:
			_check_required_var(m, base, where)
			_check_export_if_var(m, is_tool, where, props, consts, members)
			_check_export_struct(m)
		elif m is GateAST._FuncDecl:
			_misplaced((m as GateAST._FuncDecl).annotations)
			_misplaced_in_body((m as GateAST._FuncDecl).body)
		elif m is GateAST._SignalDecl:
			_misplaced((m as GateAST._SignalDecl).annotations)
		elif m is GateAST._EnumDecl:
			_misplaced((m as GateAST._EnumDecl).annotations)
	if where == "":
		_check_synthesised(owner, members, base)


func _check_export_struct(vd: GateAST._VarDecl) -> void:
	if vd.type == null:
		return
	var cd: GateAST._ClassDecl = struct_decl(vd.type.name)
	if cd == null:
		return
	var exported: bool = false
	for a in vd.annotations:
		if String((a as GateAST._Annotation).name).begins_with("export"):
			exported = true
	if not exported or cd.lowering == "vector":
		return
	diagnostics.error("'%s' is %s, a struct lowered to a class, and export needs a built-in or "
			% [vd.name, vd.type.describe()] + "Resource type", vd.line, vd.col,
		"a struct is exported only when it lowers to a Vector: 2 to 4 fields of one numeric type")


func _check_synthesised(owner: Object, members: Array, base: GateAST._TypeRef) -> void:
	var asks: Dictionary = {}   ## function name -> the first annotation that needs it
	for m in members:
		if not (m is GateAST._VarDecl):
			continue
		var vd: GateAST._VarDecl = m
		var req: GateAST._Annotation = _annotation(vd.annotations, "required")
		if req != null and not asks.has("_ready") and _node_kind(base) == _NodeKind.IS_NODE:
			asks["_ready"] = req
		var ei: GateAST._Annotation = _annotation(vd.annotations, "export_if")
		if ei != null and not asks.has("_validate_property"):
			asks["_validate_property"] = ei
	for fname in asks:
		var a: GateAST._Annotation = asks[fname]
		var own: GateAST._FuncDecl = GateInject.find_func(members, fname)
		if own != null:
			if own.is_static:
				diagnostics.error("@%s needs an instance %s, and this class's is static"
					% [a.name, fname], a.line, a.col,
					"GATE puts its code at the top of %s, and a static function cannot read "
					% fname + "the properties it checks. Godot never calls a static one anyway.")
			continue
		match _inherited_defines(base, fname):
			_Inherits.YES:
				if not super_calls.has(owner):
					super_calls[owner] = {}
				super_calls[owner][fname] = true
			_Inherits.UNKNOWN:
				diagnostics.error("@%s needs this class to declare %s" % [a.name, fname],
					a.line, a.col,
					"GATE writes %s here, and it cannot read '%s' to tell whether that " % [
						fname, base.name if base != null else "?"]
					+ "already declares one - a new one would replace it. Declare %s in this " % fname
					+ "class, calling super() if the base has one, and GATE adds to it.")


func _check_required_var(vd: GateAST._VarDecl, base: GateAST._TypeRef, where: String) -> void:
	var req: GateAST._Annotation = _annotation(vd.annotations, "required")
	if req == null:
		return
	if where != "":
		diagnostics.error("@required is not available in a %s" % where, req.line, req.col,
			"it checks a node's exported property when the node is ready, and a %s is "
			% where + "never a node.")
		return
	if vd.is_const or vd.is_static:
		_misplaced(vd.annotations)
		return
	if not GateInject.has_export(vd.annotations):
		diagnostics.error("@required needs @export on the same declaration", req.line, req.col,
			"it checks that the inspector set '%s', and only an exported property " % vd.name
			+ "appears there. Write `@export @required`.")
	if not _is_object_type(vd.type):
		diagnostics.error("@required only applies to an object type; '%s' is %s"
			% [vd.name, vd.type.describe() if vd.type != null else "untyped"], req.line, req.col,
			"an int, a vector or an array always holds a value, so there is nothing to "
			+ "check. Use it on a node or resource type.")
	match _node_kind(base):
		_NodeKind.NOT_NODE:
			diagnostics.error("@required needs a script that extends Node", req.line, req.col,
				"the check is an assert at the top of _ready, which only a node receives; "
				+ "this extends %s." % (base.name if base != null else "RefCounted"))
		_NodeKind.UNKNOWN:
			diagnostics.error("@required needs a script that extends Node", req.line, req.col,
				"GATE cannot tell whether '%s' extends Node, and the check is an assert in "
				% base.name + "_ready, which only a node receives. Extend a node class "
				+ "GATE can see: an engine class, or a class declared in a .gate file.")


func _check_export_if_var(vd: GateAST._VarDecl, is_tool: bool, where: String,
		props: Dictionary, consts: Dictionary, members: Array) -> void:
	var ei: GateAST._Annotation = _annotation(vd.annotations, "export_if")
	if ei == null:
		return
	if where != "":
		diagnostics.error("@export_if is not available in a %s" % where, ei.line, ei.col,
			"it hides an inspector property, and a %s has no inspector." % where)
		return
	if vd.is_const or vd.is_static:
		_misplaced(vd.annotations)
		return
	if not is_tool:
		diagnostics.error("@export_if needs @tool: the inspector only runs code for tool scripts",
			ei.line, ei.col,
			"add @tool at the top of the file. GATE never adds it for you: a tool script "
			+ "also runs its _ready and _process inside the editor.")
	if ei.args.size() != 1:
		diagnostics.error("@export_if takes one condition: `@export_if(<condition>)`",
			ei.line, ei.col)
		return
	for n in GateInject.condition_reads(ei.args[0]):
		var name: String = String(n)
		if props.has(name):
			_check_condition_property(props[name], ei, members)
		elif not (consts.has(name) or CONSTANT_GLOBALS.has(name) or _is_type_name(name)):
			diagnostics.error("@export_if reads '%s', which is not a property of this class"
				% name, ei.line, ei.col,
				"a condition may read this class's exported properties, and constants.")
	var hidden: String = _unwatched(ei.args[0], consts)
	if hidden != "":
		diagnostics.warn("@export_if's condition depends on `%s`, which no setter here reports"
			% hidden, ei.line, ei.col,
			"the inspector re-reads the condition when a property it reads is set. What a "
			+ "call returns, or a field of another object, can change without that, and "
			+ "the inspector keeps showing the old answer until something else refreshes it.")


func _unwatched(e, consts: Dictionary) -> String:
	if e is GateAST._Call:
		var c: GateAST._Call = e
		if c.callee is GateAST._Ident:
			return "%s()" % (c.callee as GateAST._Ident).name
		if c.callee is GateAST._Member:
			return "%s()" % (c.callee as GateAST._Member).name
		return "a call"
	if e is GateAST._Member:
		var m: GateAST._Member = e
		if m.target is GateAST._SelfExpr:
			return ""
		if m.target is GateAST._Ident:
			var t: String = (m.target as GateAST._Ident).name
			if consts.has(t) or _is_type_name(t) or CONSTANT_GLOBALS.has(t):
				return ""   # `Shape.BALL`: a constant
			return "%s.%s" % [t, m.name]
		return ".%s" % m.name
	if e is GateAST._ASTNode:
		for p in (e as Object).get_property_list():
			if not (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE):
				continue
			var v = (e as Object).get(p["name"])
			var found: String = ""
			if v is GateAST._Expr:
				found = _unwatched(v, consts)
			elif v is Array:
				for x in v:
					if found == "" and x is GateAST._Expr:
						found = _unwatched(x, consts)
			if found != "":
				return found
	return ""


func _check_condition_property(dep: GateAST._VarDecl, ei: GateAST._Annotation, members: Array) -> void:
	if not GateInject.has_export(dep.annotations):
		diagnostics.error("@export_if reads '%s', which is not exported" % dep.name,
			ei.line, ei.col,
			"the inspector re-reads the condition when an exported property changes; "
			+ "nothing else can change it there. Export '%s', or use a constant." % dep.name)
		return
	var setter_fn: String = GateInject.inline_setter(dep)
	var lines: PackedStringArray = dep.setter.split("\n")
	var has_block_set: bool = false
	for i in GateInject.accessor_lines(dep.setter):
		var t: String = lines[i].strip_edges()
		if t.begins_with("set(") or t.begins_with("set ("):
			has_block_set = true
	if (dep.setter != "" and not has_block_set) or (dep.inline_accessors != "" and setter_fn == ""):
		diagnostics.error("@export_if reads '%s', which has a getter and no setter" % dep.name,
			ei.line, ei.col,
			"GATE adds notify_property_list_changed() to the setter of every property a "
			+ "condition reads, so the inspector re-reads it. Give '%s' a setter." % dep.name)
	elif setter_fn != "" and GateInject.find_func(members, setter_fn) == null:
		diagnostics.error("@export_if reads '%s', whose setter '%s' is not declared in this class"
			% [dep.name, setter_fn], ei.line, ei.col,
			"GATE adds notify_property_list_changed() to that setter, so it must be a "
			+ "function of this class.")


func _is_type_name(n: String) -> bool:
	if GateTypes.is_shorthand(n) or GateTypes.BUILTIN.has(GateTypes.canonical(n)):
		return true
	if classes.has(n) or structs.has(n) or interfaces.has(n) or ClassDB.class_exists(n):
		return true
	if _registry != null and _registry.script_class_names.has(n):
		return true
	for c in ProjectSettings.get_global_class_list():
		if String(c["class"]) == n:
			return true
	return false


func _misplaced(annotations: Array) -> void:
	for name in INJECTING_ANNOTATIONS:
		var a: GateAST._Annotation = _annotation(annotations, name)
		if a != null:
			diagnostics.error("@%s only applies to a member variable" % name, a.line, a.col,
				"it works through the inspector, which only shows a class's own properties.")


func _misplaced_in_body(body: Array) -> void:
	for s in body:
		if s is GateAST._AnnotatedStmt:
			_misplaced((s as GateAST._AnnotatedStmt).annotations)
			_misplaced_in_body([(s as GateAST._AnnotatedStmt).stmt])
		elif s is GateAST._VarDecl:
			_misplaced((s as GateAST._VarDecl).annotations)
		elif s is GateAST._IfStmt:
			var st: GateAST._IfStmt = s
			_misplaced_in_body(st.then_body)
			for pair in st.elifs:
				_misplaced_in_body(pair[1])
			_misplaced_in_body(st.else_body)
		elif s is GateAST._ForStmt:
			_misplaced_in_body((s as GateAST._ForStmt).body)
		elif s is GateAST._WhileStmt:
			_misplaced_in_body((s as GateAST._WhileStmt).body)
		elif s is GateAST._MatchStmt:
			for br in (s as GateAST._MatchStmt).branches:
				_misplaced_in_body(br[2])


func _is_object_type(t: GateAST._TypeRef) -> bool:
	if t == null or t.is_array() or t.is_dict() or t.is_set():
		return false
	var n: String = GateTypes.canonical(t.name)
	if n == "":
		return false
	if n.contains("."):
		return true
	if structs.has(n):
		return (structs[n] as GateAST._ClassDecl).lowering == "class"
	if classes.has(n) or interfaces.has(n) or traits.has(n):
		return true
	if ClassDB.class_exists(n):
		return true
	if _registry != null and _registry.script_class_names.has(n):
		return true
	for c in ProjectSettings.get_global_class_list():
		if String(c["class"]) == n:
			return true
	return false


func _node_kind(base: GateAST._TypeRef) -> _NodeKind:
	var ext: String = _ext_name(base)
	var from: String = _path
	var seen: Dictionary = {}
	while not seen.has(ext + "|" + from):
		seen[ext + "|" + from] = true
		var link: Dictionary = _chain_link(ext, from)
		if link.is_empty():
			return _NodeKind.UNKNOWN
		if link.has("native"):
			return (_NodeKind.IS_NODE if ClassDB.is_parent_class(String(link["native"]), "Node")
				else _NodeKind.NOT_NODE)
		ext = link["extends"]
		from = link["from"]
	return _NodeKind.UNKNOWN


func _inherited_defines(base: GateAST._TypeRef, fname: String) -> _Inherits:
	var ext: String = _ext_name(base)
	var from: String = _path
	var seen: Dictionary = {}
	while not seen.has(ext + "|" + from):
		seen[ext + "|" + from] = true
		var link: Dictionary = _chain_link(ext, from)
		if link.is_empty():
			return _Inherits.UNKNOWN
		if link.has("native"):
			return _Inherits.NO
		if (link["defines"] as Array).has(fname):
			return _Inherits.YES
		ext = link["extends"]
		from = link["from"]
	return _Inherits.UNKNOWN


static func split_extends_path(ext: String) -> Array:
	var close: int = ext.find(ext[0], 1)
	if close < 0:
		return [ext.substr(1), ""]
	return [ext.substr(1, close - 1), ext.substr(close + 2) if close + 1 < ext.length() else ""]


static func _ext_name(t: GateAST._TypeRef) -> String:
	return t.name if t != null else ""


func _chain_link(ext: String, from_path: String) -> Dictionary:
	if ext == "":
		return {"native": "RefCounted"}
	if ext.begins_with("\"") or ext.begins_with("'"):
		var split: Array = split_extends_path(ext)
		if split[1] != "":
			return {}   # an inner class of a script: not followed
		var p: String = split[0]
		if not p.begins_with("res://"):
			p = from_path.get_base_dir().path_join(p).simplify_path()
		return _script_link(p)
	if ClassDB.class_exists(ext):
		return {"native": ext}
	var inner: String = ext.get_slice(".", ext.get_slice_count(".") - 1)
	if classes.has(inner):
		var cd: GateAST._ClassDecl = classes[inner]
		return {"extends": _ext_name(cd.extends_type), "from": from_path,
			"defines": _func_names(cd.members)}
	if _registry != null and _registry.script_class_names.has(ext):
		return _script_link(String(_registry.script_class_names[ext]))
	for c in ProjectSettings.get_global_class_list():
		if String(c["class"]) == ext:
			return _script_link(String(c["path"]))
	return {}


func _script_link(path: String) -> Dictionary:
	var gate: String = path if path.get_extension() == "gate" else path.get_basename() + ".gate"
	if _registry != null and _registry.script_modules.has(gate):
		var info: Dictionary = _registry.script_modules[gate]
		return {"extends": info["extends"], "from": gate, "defines": info["defines"]}
	var src_path: String = gate if FileAccess.file_exists(gate) else path
	if not _parsed.has(src_path):
		_parsed[src_path] = null
		if FileAccess.file_exists(src_path) and GateProject.is_utf8(src_path):
			var src: String = FileAccess.get_file_as_string(src_path)
			var d: GateDiagnostics = GateDiagnostics.new()
			_parsed[src_path] = GateParser.new().parse(GateLexer.new().tokenize(src, d), src, d)
	var mod: GateAST._Module = _parsed[src_path]
	if mod == null:
		return {}
	return {"extends": _ext_name(mod.extends_type), "from": src_path,
		"defines": _func_names(mod.members)}


static func _func_names(members: Array) -> Array:
	var out: Array = GateInject.will_define(members)
	for m in members:
		if m is GateAST._FuncDecl:
			out.append((m as GateAST._FuncDecl).name)
	return out

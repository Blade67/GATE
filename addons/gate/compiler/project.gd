@tool
class_name GateProject
extends RefCounted

## Project-wide declaration index, so a type declared in one file is usable in
## another.


class Registry extends RefCounted:
	var interfaces: Dictionary = {}   ## name -> ClassDecl
	var traits: Dictionary = {}       ## name -> ClassDecl
	var structs: Dictionary = {}      ## name -> ClassDecl
	var classes: Dictionary = {}      ## name -> ClassDecl
	var namespaces: Dictionary = {}   ## name -> ClassDecl
	var generics: Dictionary = {}     ## name -> ClassDecl (the template)
	var generic_uses: Array = []   ## Array[TypeRef]
	var script_class_names: Dictionary = {}
	var gd_class_names: Dictionary = {}   ## class_name -> the plain .gd declaring it
	var class_name_declared_in: Dictionary = {}   ## class_name -> every .gate declaring it
	var script_modules: Dictionary = {}
	var script_class_decls: Dictionary = {}   ## class_name -> that script's members, as a class
	var injects: bool = false
	var gd_bases: Dictionary = {}
	var gd_chain: Dictionary = {}     ## .gate path -> the hand-written .gd bases it extends, hashed
	var trait_text: Dictionary = {}   ## trait name -> hash of its source lines
	var aliases: Dictionary = {}      ## name -> TypeRef, fully resolved
	var alias_decls: Dictionary = {}  ## name -> TypeAliasDecl, as written
	var alias_files: Dictionary = {}  ## name -> every file declaring an alias of that name
	var alias_cycles: Dictionary = {} ## name -> the cycle it is part of, as "X -> Y -> X"
	var kind_files: Dictionary = {}   ## "<kind>|<name>" -> every file declaring it that way
	var module_names: Dictionary = {} ## .gate path -> {name: "static" | "instance"} at its top level

	var origin: Dictionary = {}
	var top_level: Dictionary = {}
	var declared_in: Dictionary = {}
	var methods: Dictionary = {}
	var fields: Dictionary = {}
	var bases: Dictionary = {}

	func describe(name: String) -> String:
		return origin.get(name, "<unknown file>")

	## A fingerprint of everything a file compiles against. Declaration shape only, so
	## editing a function body does not rebuild the project.
	func signature() -> String:
		var parts: PackedStringArray = PackedStringArray()
		for table_name in ["interfaces", "traits", "structs", "classes",
				"namespaces", "generics"]:
			var table: Dictionary = get(table_name)
			var names: Array = table.keys()
			names.sort()
			for n in names:
				var cd: GateAST.ClassDecl = table[n]
				parts.append("%s|%s|%s|%s|%s|%s|%s" % [table_name, n,
					origin.get(n, ""), top_level.has(n), cd.lowering,
					cd.vector_type,
					cd.extends_type.name if cd.extends_type != null else ""])
				for m in cd.members:
					if m is GateAST.VarDecl:
						var vd: GateAST.VarDecl = m
						parts.append(" v:%s:%s" % [vd.name, _type_sig(vd.type)])
					elif m is GateAST.FuncDecl:
						var fdm: GateAST.FuncDecl = m
						var ps: PackedStringArray = PackedStringArray()
						for pp in fdm.params:
							ps.append(_type_sig((pp as GateAST.Param).type))
						parts.append(" f:%s(%s):%s" % [fdm.name, ",".join(ps),
							_type_sig(fdm.return_type)])
		for label in [["F", fields], ["B", bases]]:
			var keys: Array = (label[1] as Dictionary).keys()
			keys.sort()
			for k in keys:
				var v = (label[1] as Dictionary)[k]
				parts.append("%s:%s:%s" % [label[0], k,
					_type_sig(v) if v is GateAST.TypeRef else String(v)])
		var mkeys: Array = methods.keys()
		mkeys.sort()
		for k2 in mkeys:
			parts.append("M:%s:%d" % [k2, (methods[k2] as Array).size()])
		var gu: PackedStringArray = PackedStringArray()
		for g in generic_uses:
			gu.append(GateParser.mangle_generic(g))
		gu.sort()
		parts.append_array(gu)
		return "\n".join(parts)

	static func _type_sig(t) -> String:
		if not (t is GateAST.TypeRef):
			return ""
		var tr: GateAST.TypeRef = t
		if tr.is_union() or tr.is_tuple() or tr.is_func_type:
			return tr.describe()
		var g: PackedStringArray = PackedStringArray()
		for a in tr.generic_args:
			g.append(_type_sig(a))
		return "%s[%d]%s%s" % [tr.name, tr.array_depth,
			"?" if tr.nullable else "", "<" + ",".join(g) + ">" if g.size() > 0 else ""]

const IGNORE_DIRS := ["addons", ".godot", ".git", ".import"]

var registry: Registry = Registry.new()


func index(root: String = "res://") -> Registry:
	registry = Registry.new()
	_file_names = {}
	_generic_use_paths = []
	var lexed: Array = []
	var generics: Dictionary = {}
	var aliases: Dictionary = {}
	for path in find_gate_files(root):
		var f: FileAccess = FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var src: String = f.get_as_text()
		f.close()
		if not is_utf8(path):
			continue   # the builder reports it
		var diags: GateDiagnostics = GateDiagnostics.new()
		diags.file = path
		var sum: String = src.md5_text()
		var kept: Array = _lexed(path, src, sum, diags)
		generics.merge(kept[3])
		aliases.merge(kept[4])
		lexed.append([path, src, kept[1], diags, sum, kept[5]])
	var names_key: String = "%s|%s" % [",".join(PackedStringArray(_sorted_keys(generics))),
		",".join(PackedStringArray(_sorted_keys(aliases)))]
	var shorthand: Dictionary = _shadowing_classes()
	for entry in lexed:
		var shadows: Dictionary = (entry[5] as Dictionary).duplicate()
		shadows.merge(shorthand)
		var key: String = "%s|%s|%s" % [entry[4], names_key, ",".join(PackedStringArray(_sorted_keys(shadows)))]
		var parsed: Array = _parsed_memo.get(entry[0], [])
		if parsed.is_empty() or String(parsed[0]) != key:
			GateTypes.shadow_declared(entry[2])
		_index_file(entry[0], entry[1], entry[2], entry[3], generics, aliases, key)
	GateTypes.shadowed.clear()
	_resolve_aliases()
	_index_gd_bases()
	_index_gd_class_names(root)
	return registry


func _index_file(path: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var taken: Dictionary = GateChecker.project_names(registry, "", true)
	var usable: Array = []
	for aname in registry.alias_decls:
		var path: String = String((registry.alias_files[aname] as Array)[0])
		if (registry.alias_files[aname] as Array).size() > 1 or taken.has(aname):
			continue
		if (_file_names.get(path, {}) as Dictionary).has(aname):
			continue
		usable.append(registry.alias_decls[aname])
	registry.aliases = GateChecker.extend_alias_scope({}, usable, {}, Callable(), Callable(), {},
		registry.alias_cycles)
	for cyc in registry.alias_cycles:
		registry.aliases.erase(cyc)
	for aname2 in registry.aliases:
		var target: GateAST.TypeRef = registry.aliases[aname2]
		if not target.generic_args.is_empty():
			registry.generic_uses.append(GateChecker.copy_type(target))
			_generic_use_paths.append("")
	var walk: GateChecker.AliasWalk = GateChecker.AliasWalk.new()
	walk.inherited = {"*": true}
	for table in [registry.classes, registry.structs, registry.namespaces, registry.generics,
			registry.interfaces, registry.traits]:
		for cname in table:
			if registry.top_level.has(cname):
				walk.stmt(table[cname], _scope_for(String(registry.origin.get(cname, ""))), {}, {})
	for i in registry.generic_uses.size():
		var gpath: String = _generic_use_paths[i] if i < _generic_use_paths.size() else ""
		GateChecker.substitute_type(registry.generic_uses[i], _scope_for(gpath))
	for sname in registry.structs:
		_compute_struct_lowering(registry.structs[sname])
	for table2 in [registry.classes, registry.structs, registry.namespaces, registry.generics]:
		for cname2 in table2:
			var cd: GateAST.ClassDecl = table2[cname2]
			if cd.extends_type != null:
				registry.bases[cname2] = cd.extends_type.name


func _index_file(path: String, src: String, tokens: Array, diags: GateDiagnostics,
		generics: Dictionary, aliases: Dictionary, key: String = "") -> void:
	var mod: GateAST.Module = null
	var kept: Array = _parsed_memo.get(path, [])
	if key != "" and not kept.is_empty() and String(kept[0]) == key:
		mod = kept[1]
	else:
		var parser: GateParser = GateParser.new()
		parser.known_generics = generics
		parser.known_aliases = aliases
		mod = parser.parse(tokens, src, diags)
		if key != "":
			_parsed_memo[path] = [key, mod]

	if mod.class_name_decl != "":
		registry.script_class_names[mod.class_name_decl] = path
	for m in mod.members:
		if m is GateAST.ClassDecl:
			registry.top_level[(m as GateAST.ClassDecl).name] = true
		elif m is GateAST.TypeAliasDecl:
			var ad: GateAST.TypeAliasDecl = m
			registry.alias_decls[ad.name] = ad
			if not registry.alias_files.has(ad.name):
				registry.alias_files[ad.name] = []
			if not registry.alias_files[ad.name].has(path):
				registry.alias_files[ad.name].append(path)
	_index_trait_text(mod.members, src.split("\n"), src)
	var own: Dictionary = GateChecker.block_names(mod.members)
	if mod.class_name_decl != "":
		own[mod.class_name_decl] = true
	_file_names[path] = own
	registry.module_names[path] = GateChecker.scope_names(mod.members, false)
	_collect(mod.members, path)
	for gu in mod.generic_uses:
		registry.generic_uses.append(gu)
		_generic_use_paths.append(path)


func _collect(members: Array, path: String) -> void:
	for m in members:
		if not (m is GateAST.ClassDecl):
			continue
		var cd: GateAST.ClassDecl = m
		match cd.form:
			"interface":
				registry.interfaces[cd.name] = cd
			"trait":
				registry.traits[cd.name] = cd
			"struct":
				_compute_struct_lowering(cd)
				registry.structs[cd.name] = cd
			"namespace":
				registry.namespaces[cd.name] = cd
			_:
				if not cd.generic_params.is_empty():
					registry.generics[cd.name] = cd
				else:
					registry.classes[cd.name] = cd
		registry.origin[cd.name] = path
		if not registry.declared_in.has(cd.name):
			registry.declared_in[cd.name] = []
		if not registry.declared_in[cd.name].has(path):
			registry.declared_in[cd.name].append(path)
		if cd.extends_type != null:
			registry.bases[cd.name] = cd.extends_type.name
		for mm in cd.members:
			if mm is GateAST.FuncDecl:
				var key: String = "%s.%s" % [cd.name, (mm as GateAST.FuncDecl).name]
				if not registry.methods.has(key):
					registry.methods[key] = []
				registry.methods[key].append(mm)
			elif mm is GateAST.VarDecl:
				var fvd: GateAST.VarDecl = mm
				if fvd.type != null:
					registry.fields["%s.%s" % [cd.name, fvd.name]] = fvd.type
		_collect(cd.members, path)


func _compute_struct_lowering(cd: GateAST.ClassDecl) -> void:
	var field_types: Array = []
	var has_methods: bool = GateChecker.struct_needs_class(cd)
	for f in GateChecker.struct_fields(cd):
		var vd: GateAST.VarDecl = f
		field_types.append(GateTypes.struct_field_kind(vd.type))
	var low: Dictionary = GateTypes.struct_lowering(field_types)
	if low["kind"] == "vector" and not has_methods:
		cd.lowering = "vector"
		cd.vector_type = low["vector"]
	else:
		cd.lowering = "class"


static func _is_gdignored(dir: String) -> bool:
	return FileAccess.file_exists(dir.path_join(".gdignore"))


static func find_gate_files(root: String) -> Array[String]:
	var out: Array[String] = []
	var d: DirAccess = DirAccess.open(root)
	if d == null:
		return out
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		var p: String = root.path_join(n)
		if d.current_is_dir():
			if (not n.begins_with(".") and not IGNORE_DIRS.has(n)
					and not d.is_link(p) and not _is_gdignored(p)):
				out.append_array(find_gate_files(p))
		elif n.get_extension().to_lower() == "gate":
			out.append(p)
		n = d.get_next()
	d.list_dir_end()
	return out

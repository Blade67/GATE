@tool
class_name GateProject
extends RefCounted

## Project-wide declaration index, so a type declared in one file is usable in
## another.


class GateRegistry extends RefCounted:
	var interfaces: Dictionary = {}   ## name -> ClassDecl
	var traits: Dictionary = {}       ## name -> ClassDecl
	var structs: Dictionary = {}      ## name -> ClassDecl
	var classes: Dictionary = {}      ## name -> ClassDecl
	var namespaces: Dictionary = {}   ## name -> ClassDecl
	var generics: Dictionary = {}     ## name -> ClassDecl (the template)
	var generic_uses: Array = []   ## Array[TypeRef]
	var script_class_names: Dictionary = {}

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
				var cd: GateAST.GateClassDecl = table[n]
				parts.append("%s|%s|%s|%s|%s|%s|%s" % [table_name, n,
					origin.get(n, ""), top_level.has(n), cd.lowering,
					cd.vector_type,
					cd.extends_type.name if cd.extends_type != null else ""])
				for m in cd.members:
					if m is GateAST.GateVarDecl:
						var vd: GateAST.GateVarDecl = m
						parts.append(" v:%s:%s" % [vd.name, _type_sig(vd.type)])
					elif m is GateAST.GateFuncDecl:
						var fdm: GateAST.GateFuncDecl = m
						var ps: PackedStringArray = PackedStringArray()
						for pp in fdm.params:
							ps.append(_type_sig((pp as GateAST.GateParam).type))
						parts.append(" f:%s(%s):%s" % [fdm.name, ",".join(ps),
							_type_sig(fdm.return_type)])
		for label in [["F", fields], ["B", bases]]:
			var keys: Array = (label[1] as Dictionary).keys()
			keys.sort()
			for k in keys:
				var v = (label[1] as Dictionary)[k]
				parts.append("%s:%s:%s" % [label[0], k,
					_type_sig(v) if v is GateAST.GateTypeRef else String(v)])
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
		if not (t is GateAST.GateTypeRef):
			return ""
		var tr: GateAST.GateTypeRef = t
		var g: PackedStringArray = PackedStringArray()
		for a in tr.generic_args:
			g.append(_type_sig(a))
		return "%s[%d]%s%s" % [tr.name, tr.array_depth,
			"?" if tr.nullable else "", "<" + ",".join(g) + ">" if g.size() > 0 else ""]

const IGNORE_DIRS := ["addons", ".godot", ".git", ".import"]

var registry: Registry = Registry.new()


func index(root: String = "res://") -> Registry:
	registry = Registry.new()
	for path in find_gate_files(root):
		_index_file(path)
	return registry


func _index_file(path: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var src: String = f.get_as_text()
	f.close()

	var diags: GateDiagnostics = GateDiagnostics.new()
	diags.file = path
	var lexer: GateLexer = GateLexer.new()
	var tokens: Array[GateLexer.GateToken] = lexer.tokenize(src, diags)
	var parser: GateParser = GateParser.new()
	var mod: GateAST.GateModule = parser.parse(tokens, src, diags)

	if mod.class_name_decl != "":
		registry.script_class_names[mod.class_name_decl] = path
	for m in mod.members:
		if m is GateAST.GateClassDecl:
			registry.top_level[(m as GateAST.GateClassDecl).name] = true
	_collect(mod.members, path)
	for gu in mod.generic_uses:
		registry.generic_uses.append(gu)


func _collect(members: Array, path: String) -> void:
	for m in members:
		if not (m is GateAST.GateClassDecl):
			continue
		var cd: GateAST.GateClassDecl = m
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
			if mm is GateAST.GateFuncDecl:
				var key: String = "%s.%s" % [cd.name, (mm as GateAST.GateFuncDecl).name]
				if not registry.methods.has(key):
					registry.methods[key] = []
				registry.methods[key].append(mm)
			elif mm is GateAST.GateVarDecl:
				var fvd: GateAST.GateVarDecl = mm
				if fvd.type != null:
					registry.fields["%s.%s" % [cd.name, fvd.name]] = fvd.type
		_collect(cd.members, path)


func _compute_struct_lowering(cd: GateAST.GateClassDecl) -> void:
	var field_types: Array = []
	var has_methods: bool = false
	for m in cd.members:
		if m is GateAST.GateVarDecl:
			var vd: GateAST.GateVarDecl = m
			field_types.append(vd.type.name if vd.type != null else "Variant")
		elif m is GateAST.GateFuncDecl:
			has_methods = true
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

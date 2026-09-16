@tool
class_name GateCompiler
extends RefCounted

## Pipeline driver: lex -> parse -> check -> emit.


class Result extends RefCounted:
	var ok: bool = false
	var source: String = ""
	var map: Array[int] = []
	var deps: Array = []
	var diagnostics: GateDiagnostics = null

	func error_text() -> String:
		return diagnostics.format_all() if diagnostics else ""


static func strip_header(src: String) -> String:
	if not src.begins_with(GateEmitter.HEADER_MARKER):
		return src
	var lines: PackedStringArray = src.split("\n")
	var n: int = mini(GateEmitter.HEADER_LINES.size(), lines.size())
	var kept: PackedStringArray = PackedStringArray()
	for i in range(n, lines.size()):
		kept.append(lines[i])
	return "\n".join(kept)


func compile(src_in: String, path: String, registry = null) -> Result:
	# Normalise line endings once, before anything reads the text. Constructs
	# re-emitted as raw source would otherwise carry a bare CR into the output.
	var src: String = src_in.replace("\r\n", "\n").replace("\r", "\n")
	var res: Result = Result.new()
	var diags: GateDiagnostics = GateDiagnostics.new()
	diags.file = path
	res.diagnostics = diags

	var lexer: GateLexer = GateLexer.new()
	var tokens: Array[GateLexer.Token] = lexer.tokenize(src, diags)
	GateTypes.shadow_declared(tokens, registry.script_class_names if registry != null else {})

	var parser: GateParser = GateParser.new()
	if registry != null:
		for gname in registry.generics:
			parser.known_generics[gname] = true
		if "aliases" in registry:
			for aname in registry.aliases:
				parser.known_aliases[aname] = true
	var mod: GateAST.Module = parser.parse(tokens, src, diags)
	mod.path = path

	var checker: GateChecker = GateChecker.new()
	checker.check(mod, diags, registry)

	if not diags.has_errors():
		GateInject.run(mod, diags, checker.super_calls, checker.traits)
		var nullcheck: GateNullCheck = GateNullCheck.new()
		nullcheck.check(mod, diags, registry)

	if diags.has_errors():
		res.ok = false
		diags.sort_by_position()
		return res

	var emitter: GateEmitter = GateEmitter.new()
	emitter.set_source(src)
	emitter.set_interfaces(checker.interfaces.keys())
	emitter.set_erased_types(checker.interfaces.keys() + checker.traits.keys())
	if registry != null:
		emitter.set_external_structs(registry.structs)
	emitter.set_registry(registry, path)
	emitter.set_base_chain(chain)
	var overloads: Dictionary = _build_overload_map(mod)
	var overload_owners: Dictionary = _build_overload_owners(mod)
	_registry_overloads(registry, path, overloads, overload_owners)
	emitter.set_overloads(overloads)
	emitter.set_overload_owners(overload_owners)
	var out: Dictionary = emitter.emit(mod, diags, path)

	res.ok = not diags.has_errors()
	res.source = out["source"]
	res.map = out["map"]
	res.deps = out["deps"]
	diags.sort_by_position()
	return res


func _build_overload_map(mod: GateAST.Module) -> Dictionary:
	var map: Dictionary = {}
	_scan_overloads(mod.members, map, "")
	return map


func _build_overload_owners(mod: GateAST.Module) -> Dictionary:
	var owners: Dictionary = {}
	_scan_overload_owners(mod.members, owners, "")
	return owners


func _scan_overload_owners(members: Array, owners: Dictionary, owner: String) -> void:
	for m in members:
		if m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			if fd.mangled_name != "":
				if not owners.has(fd.name):
					owners[fd.name] = {}
				owners[fd.name][owner] = true
		elif m is GateAST.ClassDecl:
			var cd: GateAST.ClassDecl = m
			_scan_overload_owners(cd.members, owners, cd.name)


func _scan_overloads(members: Array, map: Dictionary, _owner: String) -> void:
	for m in members:
		if m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			if fd.mangled_name != "":
				if not map.has(fd.name):
					map[fd.name] = {}
				var rest: bool = (not fd.params.is_empty()
					and (fd.params[fd.params.size() - 1] as GateAST.Param).is_rest)
				map[fd.name][GateChecker.REST_ARITY if rest else fd.params.size()] = fd.mangled_name
		elif m is GateAST.ClassDecl:
			_scan_overloads((m as GateAST.ClassDecl).members, map, (m as GateAST.ClassDecl).name)


static func _registry_overloads(registry, path: String, map: Dictionary, owners: Dictionary) -> void:
	if registry == null:
		return
	var tables: Array = [registry.classes]
	if "script_class_decls" in registry:
		tables.append(registry.script_class_decls)
	for ti in tables.size():
		var table: Dictionary = tables[ti]
		for cname in table:
			var origin: String = String(registry.origin.get(cname, "")) if ti == 0 \
				else String(registry.script_class_names.get(cname, ""))
			if origin == path:
				continue
			var named: Array = _mangle_overloads((table[cname] as GateAST.ClassDecl).members)
			for pair in named:
				var fd: GateAST.FuncDecl = pair[0]
				var rest: bool = (not fd.params.is_empty()
					and (fd.params[fd.params.size() - 1] as GateAST.Param).is_rest)
				if not map.has(fd.name):
					map[fd.name] = {}
				if not (map[fd.name] as Dictionary).has(GateChecker.REST_ARITY if rest else fd.params.size()):
					map[fd.name][GateChecker.REST_ARITY if rest else fd.params.size()] = pair[1]
				if not owners.has(fd.name):
					owners[fd.name] = {}
				owners[fd.name][String(cname)] = true


static func _mangle_overloads(members: Array) -> Array:
	var by_name: Dictionary = {}
	var taken: Dictionary = {}
	for m in members:
		if m is GateAST.FuncDecl:
			var fd: GateAST.FuncDecl = m
			if not by_name.has(fd.name):
				by_name[fd.name] = []
			by_name[fd.name].append(fd)
			taken[fd.name] = true
	var out: Array = []
	for name in by_name:
		var group: Array = by_name[name]
		if group.size() < 2 or String(name).begins_with(GateChecker.ENGINE_PREFIX):
			continue
		var by_arity: Dictionary = {}
		for f in group:
			var fd2: GateAST.FuncDecl = f
			var variadic: bool = (not fd2.params.is_empty()
				and (fd2.params[fd2.params.size() - 1] as GateAST.Param).is_rest)
			var arity: int = GateChecker.REST_ARITY if variadic else fd2.params.size()
			if by_arity.has(arity):
				continue
			by_arity[arity] = fd2
			var mangled: String = "__%s_%s" % [name, "rest" if variadic else str(arity)]
			while taken.has(mangled):
				mangled = "_" + mangled
			taken[mangled] = true
			out.append([fd2, mangled])
	return out


static func write_sourcemap(gd_path: String, gate_path: String, map: Array[int]) -> void:
	var f: FileAccess = FileAccess.open(gd_path + ".map", FileAccess.WRITE)
	if f == null:
		return
	var d: Dictionary = {
		"version": 1,
		"source": gate_path,
		"generated": gd_path,
		"lines": map,
	}
	f.store_string(JSON.stringify(d))
	f.close()


static func map_line(map: Array[int], generated_line: int) -> int:
	var idx: int = generated_line - 1
	if idx < 0 or idx >= map.size():
		return 0
	return map[idx]

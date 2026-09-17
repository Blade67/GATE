@tool
class_name GateCompiler
extends RefCounted

## Pipeline driver: lex -> parse -> check -> emit.


class GateResult extends RefCounted:
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


func compile(src_in: String, path: String, registry = null) -> GateResult:
	# Normalise line endings once, before anything reads the text. Constructs
	# re-emitted as raw source would otherwise carry a bare CR into the output.
	var src: String = src_in.replace("\r\n", "\n").replace("\r", "\n")
	var res: GateResult = GateResult.new()
	var diags: GateDiagnostics = GateDiagnostics.new()
	diags.file = path
	res.diagnostics = diags

	var lexer: GateLexer = GateLexer.new()
	var tokens: Array[GateLexer.GateToken] = lexer.tokenize(src, diags)

	var parser: GateParser = GateParser.new()
	var mod: GateAST.GateModule = parser.parse(tokens, src, diags)
	mod.path = path

	var checker: GateChecker = GateChecker.new()
	checker.check(mod, diags, registry)

	if not diags.has_errors():
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
	emitter.set_overloads(_build_overload_map(mod))
	emitter.set_overload_owners(_build_overload_owners(mod))
	var out: Dictionary = emitter.emit(mod, diags, path)

	res.ok = not diags.has_errors()
	res.source = out["source"]
	res.map = out["map"]
	res.deps = out["deps"]
	diags.sort_by_position()
	return res


func _build_overload_map(mod: GateAST.GateModule) -> Dictionary:
	var map: Dictionary = {}
	_scan_overloads(mod.members, map, "")
	return map


func _build_overload_owners(mod: GateAST.GateModule) -> Dictionary:
	var owners: Dictionary = {}
	_scan_overload_owners(mod.members, owners, "")
	return owners


func _scan_overload_owners(members: Array, owners: Dictionary, owner: String) -> void:
	for m in members:
		if m is GateAST.GateFuncDecl:
			var fd: GateAST.GateFuncDecl = m
			if fd.mangled_name != "":
				if not owners.has(fd.name):
					owners[fd.name] = {}
				owners[fd.name][owner] = true
		elif m is GateAST.GateClassDecl:
			var cd: GateAST.GateClassDecl = m
			_scan_overload_owners(cd.members, owners, cd.name)


func _scan_overloads(members: Array, map: Dictionary, _owner: String) -> void:
	for m in members:
		if m is GateAST.GateFuncDecl:
			var fd: GateAST.GateFuncDecl = m
			if fd.mangled_name != "":
				if not map.has(fd.name):
					map[fd.name] = {}
				var rest: bool = (not fd.params.is_empty()
					and (fd.params[fd.params.size() - 1] as GateAST.GateParam).is_rest)
				map[fd.name][GateChecker.REST_ARITY if rest else fd.params.size()] = fd.mangled_name
		elif m is GateAST.GateClassDecl:
			_scan_overloads((m as GateAST.GateClassDecl).members, map, (m as GateAST.GateClassDecl).name)


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

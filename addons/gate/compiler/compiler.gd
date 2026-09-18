@tool
class_name GateCompiler
extends RefCounted


class _Result extends RefCounted:
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


var indent: String = ""


static func indent_of(src: String) -> String:
	var inside: Dictionary = lines_inside_strings(src)
	var lines: PackedStringArray = src.split("\n")
	for i in lines.size():
		if inside.has(i):
			continue
		var line: String = lines[i]
		if line.strip_edges() == "" or not (line.begins_with("\t") or line.begins_with(" ")):
			continue
		var n: int = 0
		while n < line.length() and line[n] == line[0]:
			n += 1
		return "\t" if line[0] == "\t" else " ".repeat(n)
	return "\t"


static func reindent(text: String, unit: String) -> String:
	if unit == "" or unit == "\t" or not text.contains("\t"):
		return text
	var inside: Dictionary = lines_inside_strings(text)
	var lines: PackedStringArray = text.split("\n")
	for i in lines.size():
		if inside.has(i):
			continue
		var line: String = lines[i]
		var n: int = 0
		while n < line.length() and line[n] == "\t":
			n += 1
		if n > 0:
			lines[i] = unit.repeat(n) + line.substr(n)
	return "\n".join(lines)


static func lines_inside_strings(text: String) -> Dictionary:
	var out: Dictionary = {}
	var quote: String = ""
	var line: int = 0
	var i: int = 0
	var n: int = text.length()
	while i < n:
		var ch: String = text[i]
		if ch == "\n":
			line += 1
			if quote.length() == 3:
				out[line] = true
			i += 1
			continue
		if quote != "":
			if ch == "\\":
				if i + 1 < n and text[i + 1] == "\n":
					line += 1
					if quote.length() == 3:
						out[line] = true
				i += 2
				continue
			if text.substr(i, quote.length()) == quote:
				i += quote.length()
				quote = ""
				continue
			i += 1
			continue
		if ch == "#":
			while i < n and text[i] != "\n":
				i += 1
			continue
		var three: String = text.substr(i, 3)
		if three == '"""' or three == "'''":
			quote = three
			i += 3
			continue
		if ch == '"' or ch == "'":
			quote = ch
			i += 1
			continue
		i += 1
	return out


const MAX_TREE_DEPTH := 180


static func too_deep(members: Array, limit: int) -> GateAST._ASTNode:
	var items: Array = [members]
	var depths: PackedInt32Array = PackedInt32Array([0])
	var roots: Array = [null]
	while not items.is_empty():
		var top: int = items.size() - 1
		var n = items[top]
		var d: int = depths[top]
		var root = roots[top]
		items.resize(top)
		depths.resize(top)
		roots.resize(top)
		if n is Array:
			for i in range((n as Array).size() - 1, -1, -1):
				items.append((n as Array)[i])
				depths.append(d)
				roots.append(root)
			continue
		if not (n is GateAST._ASTNode) or n is GateAST._TypeRef:
			continue
		if root == null and n is GateAST._Expr:
			root = n
		if root != null:
			d += 1
			if d > limit:
				return _expression_start(root)
		for pn in GateAST.child_names(n):
			var v = (n as Object).get(pn)
			if v is Array or v is Object:
				items.append(v)
				depths.append(d)
				roots.append(root)
	return null


static func _expression_start(e: GateAST._Expr) -> GateAST._Expr:
	var cur: GateAST._Expr = e
	while true:
		var nxt: GateAST._Expr = null
		if cur is GateAST._Binary:
			nxt = (cur as GateAST._Binary).left
		elif cur is GateAST._NullCoalesce:
			nxt = (cur as GateAST._NullCoalesce).left
		elif cur is GateAST._Ternary:
			nxt = (cur as GateAST._Ternary).if_true
		elif cur is GateAST._Member:
			nxt = (cur as GateAST._Member).target
		elif cur is GateAST._Index:
			nxt = (cur as GateAST._Index).target
		elif cur is GateAST._Call:
			nxt = (cur as GateAST._Call).callee
		elif cur is GateAST._CastExpr:
			nxt = (cur as GateAST._CastExpr).operand
		if nxt == null:
			return cur
		cur = nxt
	return cur


func compile(src_in: String, path: String, registry = null) -> _Result:
	# Normalise line endings once, before anything reads the text. Constructs
	# re-emitted as raw source would otherwise carry a bare CR into the output.
	var src: String = src_in.replace("\r\n", "\n").replace("\r", "\n")
	var res: _Result = _Result.new()
	var diags: GateDiagnostics = GateDiagnostics.new()
	diags.file = path
	res.diagnostics = diags

	var lexer: GateLexer = GateLexer.new()
	var tokens: Array[GateLexer._Token] = lexer.tokenize(src, diags)
	GateTypes.shadow_declared(tokens, registry.script_class_names if registry != null else {})

	var parser: GateParser = GateParser.new()
	if registry != null:
		for gname in registry.generics:
			parser.known_generics[gname] = true
		if "aliases" in registry:
			for aname in registry.aliases:
				parser.known_aliases[aname] = true
	var mod: GateAST._Module = parser.parse(tokens, src, diags)
	mod.path = path
	GateInject.expand_accessors(mod.members)
	var deep: GateAST._ASTNode = too_deep(mod.members, MAX_TREE_DEPTH)
	if deep != null:
		diags.error("expression nests deeper than %d levels" % MAX_TREE_DEPTH, deep.line, deep.col,
			"GATE's passes are written in GDScript and walk the tree once per level, so they "
			+ "run out of stack well before Godot's own parser does. A chain counts a level for "
			+ "every operator, call and member. Split the expression into locals.")
		res.ok = false
		diags.sort_by_position()
		return res
	var chain: Dictionary = GateChecker.base_chain(mod.extends_type, path, registry)
	for tn in chain["types"]:
		if GateTypes.SHORTHAND.has(tn):
			GateTypes.shadowed[tn] = true
	if registry != null:
		var hidden: Dictionary = GateChecker.hidden_by_base(mod, registry, chain)
		if not hidden.is_empty():
			registry = registry.without(hidden)

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
	res.source = reindent(String(out["source"]), indent if indent != "" else indent_of(src))
	res.map = out["map"]
	res.deps = out["deps"]
	diags.sort_by_position()
	return res


func _build_overload_map(mod: GateAST._Module) -> Dictionary:
	var map: Dictionary = {}
	_scan_overloads(mod.members, map, "")
	return map


func _build_overload_owners(mod: GateAST._Module) -> Dictionary:
	var owners: Dictionary = {}
	_scan_overload_owners(mod.members, owners, "")
	return owners


func _scan_overload_owners(members: Array, owners: Dictionary, owner: String) -> void:
	for m in members:
		if m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
			if fd.mangled_name != "":
				if not owners.has(fd.name):
					owners[fd.name] = {}
				owners[fd.name][owner] = true
		elif m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			_scan_overload_owners(cd.members, owners, cd.name)


func _scan_overloads(members: Array, map: Dictionary, _owner: String) -> void:
	for m in members:
		if m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
			if fd.mangled_name != "":
				if not map.has(fd.name):
					map[fd.name] = {}
				var rest: bool = (not fd.params.is_empty()
					and (fd.params[fd.params.size() - 1] as GateAST._Param).is_rest)
				map[fd.name][GateChecker.REST_ARITY if rest else fd.params.size()] = fd.mangled_name
		elif m is GateAST._ClassDecl:
			_scan_overloads((m as GateAST._ClassDecl).members, map, (m as GateAST._ClassDecl).name)


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
			var named: Array = _mangle_overloads((table[cname] as GateAST._ClassDecl).members)
			for pair in named:
				var fd: GateAST._FuncDecl = pair[0]
				var rest: bool = (not fd.params.is_empty()
					and (fd.params[fd.params.size() - 1] as GateAST._Param).is_rest)
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
		if m is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = m
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
			var fd2: GateAST._FuncDecl = f
			var variadic: bool = (not fd2.params.is_empty()
				and (fd2.params[fd2.params.size() - 1] as GateAST._Param).is_rest)
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

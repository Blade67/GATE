@tool
class_name GateProject
extends RefCounted

## Project-wide declaration index, so a type declared in one file is usable in
## another.


class _Registry extends RefCounted:
	var interfaces: Dictionary = {}   ## name -> _ClassDecl
	var traits: Dictionary = {}       ## name -> _ClassDecl
	var structs: Dictionary = {}      ## name -> _ClassDecl
	var classes: Dictionary = {}      ## name -> _ClassDecl
	var namespaces: Dictionary = {}   ## name -> _ClassDecl
	var generics: Dictionary = {}     ## name -> _ClassDecl (the template)
	var generic_uses: Array = []   ## Array[_TypeRef]
	var script_class_names: Dictionary = {}
	var gd_class_names: Dictionary = {}   ## class_name -> the plain .gd declaring it
	var class_name_declared_in: Dictionary = {}   ## class_name -> every .gate declaring it
	var script_modules: Dictionary = {}
	var script_class_decls: Dictionary = {}   ## class_name -> that script's members, as a class
	var injects: bool = false
	var gd_bases: Dictionary = {}
	var gd_chain: Dictionary = {}     ## .gate path -> the hand-written .gd bases it extends, hashed
	var trait_text: Dictionary = {}   ## trait name -> hash of its source lines
	var aliases: Dictionary = {}      ## name -> _TypeRef, fully resolved
	var alias_decls: Dictionary = {}  ## name -> _TypeAliasDecl, as written
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

	func without(names: Dictionary) -> _Registry:
		var r: _Registry = _Registry.new()
		for p in get_property_list():
			if (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
				r.set(p["name"], get(p["name"]))
		for t in ["interfaces", "traits", "structs", "classes", "namespaces", "generics",
				"top_level", "origin", "declared_in", "bases"]:
			var d: Dictionary = (get(t) as Dictionary).duplicate()
			for n in names:
				d.erase(n)
			r.set(t, d)
		for t2 in ["methods", "fields"]:
			var src: Dictionary = get(t2)
			var kept: Dictionary = {}
			for k in src:
				if not names.has(String(k).get_slice(".", 0)):
					kept[k] = src[k]
			r.set(t2, kept)
		return r

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
				var cd: GateAST._ClassDecl = table[n]
				parts.append("%s|%s|%s|%s|%s|%s|%s" % [table_name, n,
					origin.get(n, ""), top_level.has(n), cd.lowering,
					cd.vector_type,
					cd.extends_type.name if cd.extends_type != null else ""])
				_member_sigs(parts, cd.members)
				if trait_text.has(n):
					parts.append(" t:" + String(trait_text[n]))
		var gnames: Array = gd_class_names.keys()
		gnames.sort()
		for gn in gnames:
			parts.append("GDCN:%s:%s" % [gn, gd_class_names[gn]])
		var cnames: Array = script_class_names.keys()
		cnames.sort()
		for cn in cnames:
			parts.append("CN:%s:%s" % [cn, script_class_names[cn]])
		var scnames: Array = script_class_decls.keys()
		scnames.sort()
		for sc in scnames:
			var scd: GateAST._ClassDecl = script_class_decls[sc]
			parts.append("SC|%s|%s" % [sc, scd.extends_type.name if scd.extends_type != null else ""])
			_member_sigs(parts, scd.members)
		if injects:
			var skeys: Array = script_modules.keys()
			skeys.sort()
			for sk in skeys:
				var info: Dictionary = script_modules[sk]
				parts.append("S:%s:%s:%s" % [sk, info["extends"],
					",".join(PackedStringArray(info["defines"]))])
			var gkeys: Array = gd_bases.keys()
			gkeys.sort()
			for gk in gkeys:
				parts.append("G:%s:%s" % [gk, gd_bases[gk]])
		var anames: Array = aliases.keys()
		anames.sort()
		for an in anames:
			parts.append("alias|%s|%s|%s" % [an, ",".join(PackedStringArray(alias_files.get(an, []))),
				_type_sig(aliases[an])])
		var mpaths: Array = []
		for sn in structs:
			var sp: String = String(origin.get(sn, ""))
			if module_names.has(sp) and not mpaths.has(sp):
				mpaths.append(sp)
		mpaths.sort()
		for mp in mpaths:
			var mnames: Array = (module_names[mp] as Dictionary).keys()
			mnames.sort()
			parts.append("N:%s:%s" % [mp, ",".join(PackedStringArray(mnames))])
		for label in [["F", fields], ["B", bases]]:
			var keys: Array = (label[1] as Dictionary).keys()
			keys.sort()
			for k in keys:
				var v = (label[1] as Dictionary)[k]
				parts.append("%s:%s:%s" % [label[0], k,
					_type_sig(v) if v is GateAST._TypeRef else String(v)])
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

	static func _member_sigs(parts: PackedStringArray, members: Array) -> void:
		for m in members:
			if m is GateAST._VarDecl:
				var vd: GateAST._VarDecl = m
				parts.append(" v:%s:%s" % [vd.name, _type_sig(vd.type)])
			elif m is GateAST._FuncDecl:
				var fdm: GateAST._FuncDecl = m
				var ps: PackedStringArray = PackedStringArray()
				for pp in fdm.params:
					var par: GateAST._Param = pp
					ps.append("%s%s%s" % [_type_sig(par.type), "=" if par.default != null else "",
						"..." if par.is_rest else ""])
				parts.append(" f:%s/%d(%s):%s" % [fdm.name, ps.size(), ",".join(ps),
					_type_sig(fdm.return_type)])
		var writes: Array = GateInject.will_define(members)
		if not writes.is_empty():
			parts.append(" w:" + ",".join(PackedStringArray(writes)))

	static func _type_sig(t) -> String:
		if not (t is GateAST._TypeRef):
			return ""
		var tr: GateAST._TypeRef = t
		if tr.is_union() or tr.is_tuple() or tr.is_func_type:
			return tr.describe()
		var g: PackedStringArray = PackedStringArray()
		for a in tr.generic_args:
			g.append(_type_sig(a))
		return "%s[%d]%s%s" % [tr.name, tr.array_depth,
			"?" if tr.nullable else "", "<" + ",".join(g) + ">" if g.size() > 0 else ""]

const IGNORE_DIRS := ["addons", ".godot", ".git", ".import"]

const SYNTHESISED := ["_ready", "_validate_property"]

var registry: _Registry = _Registry.new()


func index(root: String = "res://") -> _Registry:
	registry = _Registry.new()
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


func _index_gd_bases() -> void:
	var globals: Dictionary = {}
	for c in ProjectSettings.get_global_class_list():
		globals[String(c["class"])] = String(c["path"])
	_chain_memo = {}
	for p in registry.script_modules:
		_add_chain(String(p), _follow_gd(String(registry.script_modules[p]["extends"]), String(p), globals, 0))
	for cname in registry.classes:
		var cd: GateAST._ClassDecl = registry.classes[cname]
		if cd.extends_type != null:
			var origin: String = String(registry.origin.get(cname, ""))
			_add_chain(origin, _follow_gd(cd.extends_type.name, origin, globals, 0))


var _chain_memo: Dictionary = {}


func _add_chain(gate_path: String, chain: String) -> void:
	if chain != "" and not String(registry.gd_chain.get(gate_path, "")).contains(chain):
		registry.gd_chain[gate_path] = String(registry.gd_chain.get(gate_path, "")) + chain


func _follow_gd(ext: String, from: String, globals: Dictionary, depth: int) -> String:
	if ext == "" or depth > 32:
		return ""
	var path: String = ""
	if ext.begins_with("\"") or ext.begins_with("'"):
		path = String(GateChecker.split_extends_path(ext)[0])
		if not path.begins_with("res://"):
			path = from.get_base_dir().path_join(path).simplify_path()
	elif globals.has(ext):
		path = globals[ext]
	if _chain_memo.has(path):
		return _chain_memo[path]
	if (path.get_extension().to_lower() != "gd" or not FileAccess.file_exists(path)
			or FileAccess.file_exists(path.get_basename() + ".gate")
			or FileAccess.file_exists(path.get_basename() + ".GATE")):
		return ""
	_chain_memo[path] = ""   # a cycle ends here
	var text: String = FileAccess.get_file_as_string(path)
	registry.gd_bases[path] = gd_surface(text)
	var chain: String = "%s=%s;" % [path, registry.gd_bases[path]]
	var re: RegEx = RegEx.create_from_string(
		"(?m)^(?:class_name\\s+\\w+\\s+)?extends\\s+(\"[^\"]*\"|'[^']*'|[^\\s#:]+)")
	var m: RegExMatch = re.search(text)
	if m != null:
		chain += _follow_gd(m.get_string(1), path, globals, depth + 1)
	_chain_memo[path] = chain
	return chain


var _file_names: Dictionary = {}

static var _lexed_memo: Dictionary = {}
static var _parsed_memo: Dictionary = {}


static func forget_parsed() -> void:
	_lexed_memo.clear()
	_parsed_memo.clear()
	_surface_memo.clear()


static var _surface_memo: Dictionary = {}
static var _func_re: RegEx = null


static func gd_surface(text: String) -> String:
	var sum: String = text.md5_text()
	if _surface_memo.has(sum):
		return _surface_memo[sum]
	if _func_re == null:
		_func_re = RegEx.create_from_string("^(?:@\\S+\\s+)*(?:static\\s+)?func\\b")
	var kept: PackedStringArray = PackedStringArray()
	var body_at: int = -1
	var func_at: int = -1
	var header: bool = false
	var depth: int = 0
	for raw in GateBuilder._code_only(text).split("\n"):
		var line: String = String(raw).strip_edges(false, true)
		var code: String = line.strip_edges()
		if code == "":
			continue
		var at: int = line.length() - line.lstrip("\t ").length()
		if body_at >= 0:
			if at > body_at:
				continue
			body_at = -1
		kept.append("%d|%s" % [at, code])
		if not header:
			if _func_re.search(code) == null:
				continue
			header = true
			func_at = at
			depth = 0
		var colon: bool = false
		for ch in code:
			if ch == "(" or ch == "[" or ch == "{":
				depth += 1
			elif ch == ")" or ch == "]" or ch == "}":
				depth -= 1
			elif ch == ":" and depth <= 0:
				colon = true
		if depth <= 0 and colon:
			header = false
			body_at = func_at
	var out: String = "\n".join(kept).md5_text()
	_surface_memo[sum] = out
	return out
	_warm_stage = 0


static var _warm_stage: int = 0
static var _warm_files: Array[String] = []
static var _warm_at: int = 0
static var _warm_generics: Dictionary = {}
static var _warm_aliases: Dictionary = {}


static func warm_step(root: String, budget_usec: int) -> bool:
	var until: int = Time.get_ticks_usec() + budget_usec
	if _warm_stage == 0:
		_warm_files = find_gate_files(root)
		_warm_at = 0
		_warm_generics = {}
		_warm_aliases = {}
		_warm_stage = 1
	while _warm_stage < 3 and Time.get_ticks_usec() < until:
		if _warm_at >= _warm_files.size():
			_warm_at = 0
			_warm_stage += 1
			continue
		var path: String = _warm_files[_warm_at]
		_warm_at += 1
		if not FileAccess.file_exists(path) or not is_utf8(path):
			continue
		var src: String = FileAccess.get_file_as_string(path)
		var sum: String = src.md5_text()
		var kept: Array = _lexed(path, src, sum, GateDiagnostics.new())
		if _warm_stage == 1:
			_warm_generics.merge(kept[3])
			_warm_aliases.merge(kept[4])
			continue
		GateTypes.shadow_declared(kept[1])
		var key: String = "%s|%s|%s|%s" % [sum, ",".join(PackedStringArray(_sorted_keys(_warm_generics))),
			",".join(PackedStringArray(_sorted_keys(_warm_aliases))),
			",".join(PackedStringArray(_sorted_keys(GateTypes.shadowed)))]
		var parsed: Array = _parsed_memo.get(path, [])
		if parsed.is_empty() or String(parsed[0]) != key:
			var parser: GateParser = GateParser.new()
			parser.known_generics = _warm_generics
			parser.known_aliases = _warm_aliases
			_parsed_memo[path] = [key, parser.parse(kept[1], src, GateDiagnostics.new())]
		GateTypes.shadowed.clear()
	return _warm_stage >= 3


static func _lexed(path: String, src: String, sum: String, diags: GateDiagnostics) -> Array:
	var kept: Array = _lexed_memo.get(path, [])
	if not kept.is_empty() and String(kept[0]) == sum and kept.size() > 5:
		return kept
	var tokens: Array[GateLexer._Token] = []
	if not kept.is_empty() and String(kept[0]) == sum:
		tokens = kept[1]
	else:
		tokens = GateLexer.new().tokenize(src, diags)
	var generics: Dictionary = {}
	var aliases: Dictionary = {}
	_scan_declared_names(tokens, generics, aliases)
	GateTypes.shadow_declared(tokens)
	var own: Dictionary = {}
	for n in GateTypes.shadowed:
		own[n] = true
	for c in ProjectSettings.get_global_class_list():
		own.erase(String(c["class"]))
	GateTypes.shadowed.clear()
	kept = [sum, tokens, _tokens_hash(tokens), generics, aliases, own]
	_lexed_memo[path] = kept
	return kept


static func _shadowing_classes() -> Dictionary:
	var out: Dictionary = {}
	for c in ProjectSettings.get_global_class_list():
		if GateTypes.SHORTHAND.has(String(c["class"])):
			out[String(c["class"])] = true
	return out


static func token_hash(path: String) -> String:
	var kept: Array = _lexed_memo.get(path, [])
	return String(kept[2]) if kept.size() > 2 else ""


static func _tokens_hash(tokens: Array) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var last: int = -1
	for t in tokens:
		var tk: GateLexer._Token = t
		if tk.type == GateLexer._T.COMMENT or (tk.type == GateLexer._T.NEWLINE and last == GateLexer._T.NEWLINE):
			continue
		last = tk.type
		parts.append("%d|%s|%s" % [tk.type, tk.value, tk.extra])
	return "~".join(parts).md5_text()


static func _sorted_keys(d: Dictionary) -> Array:
	var keys: Array = d.keys()
	keys.sort()
	return keys
var _generic_use_paths: Array = []


func _scope_for(path: String) -> Dictionary:
	return GateChecker.shadowed(registry.aliases, _file_names.get(path, {}))


static func _scan_declared_names(tokens: Array, generics: Dictionary, aliases: Dictionary) -> void:
	var n: int = tokens.size()
	for i in n - 2:
		var t: GateLexer._Token = tokens[i]
		var nx: GateLexer._Token = tokens[i + 1]
		if nx.type != GateLexer._T.IDENT:
			continue
		if (t.is_kw("class") or t.is_kw("struct")) and tokens[i + 2].is_op("<"):
			generics[nx.value] = true
		elif t.type == GateLexer._T.IDENT and t.value == "type" and tokens[i + 2].is_op("="):
			aliases[nx.value] = true


func _resolve_aliases() -> void:
	if registry.alias_decls.is_empty():
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
		var target: GateAST._TypeRef = registry.aliases[aname2]
		if not target.generic_args.is_empty():
			registry.generic_uses.append(GateChecker.copy_type(target))
			_generic_use_paths.append("")
	var walk: GateChecker._AliasWalk = GateChecker._AliasWalk.new()
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
			var cd: GateAST._ClassDecl = table2[cname2]
			if cd.extends_type != null:
				registry.bases[cname2] = cd.extends_type.name


func _index_file(path: String, src: String, tokens: Array, diags: GateDiagnostics,
		generics: Dictionary, aliases: Dictionary, key: String = "") -> void:
	var mod: GateAST._Module = null
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
		var scd: GateAST._ClassDecl = GateAST._ClassDecl.new()
		scd.name = mod.class_name_decl
		scd.form = "class"
		scd.extends_type = mod.extends_type
		scd.members = mod.members
		registry.script_class_decls[mod.class_name_decl] = scd
		if scd.extends_type != null and not registry.bases.has(scd.name):
			registry.bases[scd.name] = scd.extends_type.name
		for sm in mod.members:
			if sm is GateAST._FuncDecl:
				var skey: String = "%s.%s" % [scd.name, (sm as GateAST._FuncDecl).name]
				if not registry.methods.has(skey):
					registry.methods[skey] = []
				registry.methods[skey].append(sm)
			elif sm is GateAST._VarDecl and (sm as GateAST._VarDecl).type != null:
				registry.fields["%s.%s" % [scd.name, (sm as GateAST._VarDecl).name]] = (sm as GateAST._VarDecl).type
		if not registry.class_name_declared_in.has(mod.class_name_decl):
			registry.class_name_declared_in[mod.class_name_decl] = []
		registry.class_name_declared_in[mod.class_name_decl].append(path)
	var defines: Array = []
	for fm in mod.members:
		if fm is GateAST._FuncDecl and SYNTHESISED.has((fm as GateAST._FuncDecl).name):
			defines.append((fm as GateAST._FuncDecl).name)
	for wn in GateInject.will_define(mod.members):
		if not defines.has(wn):
			defines.append(wn)
	registry.script_modules[path] = {
		"extends": mod.extends_type.name if mod.extends_type != null else "",
		"defines": defines,
	}
	if not registry.injects and _injects(mod.members):
		registry.injects = true
	for m in mod.members:
		if m is GateAST._ClassDecl:
			registry.top_level[(m as GateAST._ClassDecl).name] = true
		elif m is GateAST._TypeAliasDecl:
			var ad: GateAST._TypeAliasDecl = m
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
		if not (m is GateAST._ClassDecl):
			continue
		var cd: GateAST._ClassDecl = m
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
		var kind: String = cd.form
		if kind == "class" and not cd.generic_params.is_empty():
			kind = "generic class"
		if kind != "class":
			var kkey: String = "%s|%s" % [kind, cd.name]
			if not registry.kind_files.has(kkey):
				registry.kind_files[kkey] = []
			if not registry.kind_files[kkey].has(path):
				registry.kind_files[kkey].append(path)
		if not registry.declared_in.has(cd.name):
			registry.declared_in[cd.name] = []
		if not registry.declared_in[cd.name].has(path):
			registry.declared_in[cd.name].append(path)
		if cd.extends_type != null:
			registry.bases[cd.name] = cd.extends_type.name
		for mm in cd.members:
			if mm is GateAST._FuncDecl:
				var key: String = "%s.%s" % [cd.name, (mm as GateAST._FuncDecl).name]
				if not registry.methods.has(key):
					registry.methods[key] = []
				registry.methods[key].append(mm)
			elif mm is GateAST._VarDecl:
				var fvd: GateAST._VarDecl = mm
				if fvd.type != null:
					registry.fields["%s.%s" % [cd.name, fvd.name]] = fvd.type
		_collect(cd.members, path)


func _index_trait_text(members: Array, lines: PackedStringArray, whole: String) -> void:
	for i in members.size():
		if not (members[i] is GateAST._ClassDecl):
			continue
		var cd: GateAST._ClassDecl = members[i]
		if cd.form != "trait":
			_index_trait_text_nested(cd.members, whole)
			continue
		var last: int = lines.size()
		for j in range(i + 1, members.size()):
			var next_line: int = int(members[j].line) if "line" in members[j] else 0
			if next_line > cd.line:
				last = next_line - 1
				break
		var text: String = "\n".join(lines.slice(maxi(cd.line - 1, 0), last))
		registry.trait_text[cd.name] = "%d:%d" % [text.hash(), text.length()]


func _index_trait_text_nested(members: Array, whole: String) -> void:
	for m in members:
		if m is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = m
			if cd.form == "trait":
				registry.trait_text[cd.name] = "%d:%d" % [whole.hash(), whole.length()]
			_index_trait_text_nested(cd.members, whole)


static func _injects(members: Array) -> bool:
	for m in members:
		if m is GateAST._ClassDecl and _injects((m as GateAST._ClassDecl).members):
			return true
		if m is GateAST._VarDecl:
			for a in (m as GateAST._VarDecl).annotations:
				if (a as GateAST._Annotation).name in ["required", "export_if"]:
					return true
	return false


func _compute_struct_lowering(cd: GateAST._ClassDecl) -> void:
	var field_types: Array = []
	var has_methods: bool = GateChecker.struct_needs_class(cd)
	for f in GateChecker.struct_fields(cd):
		var vd: GateAST._VarDecl = f
		field_types.append(GateTypes.struct_field_kind(vd.type))
	var low: Dictionary = GateTypes.struct_lowering(field_types)
	if low["kind"] == "vector" and not has_methods:
		cd.lowering = "vector"
		cd.vector_type = low["vector"]
	else:
		cd.lowering = "class"


static func _is_gdignored(dir: String) -> bool:
	return FileAccess.file_exists(dir.path_join(".gdignore"))


static func is_utf8(path: String) -> bool:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
		bytes = bytes.slice(3)
	return bytes.get_string_from_utf8().to_utf8_buffer() == bytes


func _index_gd_class_names(root: String) -> void:
	for path in find_gd_files(root):
		var name: String = gd_class_name_of(path)
		if name != "" and not registry.gd_class_names.has(name):
			registry.gd_class_names[name] = path


static var _gd_name_cache: Dictionary = {}
static var _class_name_re: RegEx = null


static func release_statics() -> void:
	_class_name_re = null


static func gd_class_name_of(path: String) -> String:
	var stamp: int = FileAccess.get_modified_time(path)
	var hit: Array = _gd_name_cache.get(path, [])
	if not hit.is_empty() and int(hit[0]) == stamp:
		return String(hit[1])
	var name: String = ""
	var text: String = FileAccess.get_file_as_string(path)
	if text.contains("class_name"):
		if _class_name_re == null:
			_class_name_re = RegEx.create_from_string(
				"(?m)^(?:@[A-Za-z_]\\w*(?:\\([^)]*\\))?\\s+)*class_name\\s+([A-Za-z_]\\w*)")
		var m: RegExMatch = _class_name_re.search(text)
		if m != null:
			name = m.get_string(1)
	_gd_name_cache[path] = [stamp, name]
	return name


static func find_gd_files(root: String) -> Array[String]:
	var out: Array[String] = []
	var d: DirAccess = DirAccess.open(root)
	if d == null:
		return out
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		var p: String = root.path_join(n)
		if d.current_is_dir():
			if n == "addons" or walks_into(d, n, p):
				out.append_array(find_gd_files(p))
		elif n.get_extension().to_lower() == "gd":
			out.append(p)
		n = d.get_next()
	d.list_dir_end()
	return out


static func walks_into(d: DirAccess, n: String, p: String) -> bool:
	return (not n.begins_with(".") and not IGNORE_DIRS.has(n) and not d.is_link(p)
		and not _is_gdignored(p) and not FileAccess.file_exists(p.path_join("project.godot")))


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
			if walks_into(d, n, p):
				out.append_array(find_gate_files(p))
		elif n.get_extension().to_lower() == "gate":
			out.append(p)
		n = d.get_next()
	d.list_dir_end()
	return out

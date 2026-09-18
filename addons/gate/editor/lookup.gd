@tool
extends RefCounted

## Ctrl-click and F1 on a symbol in a `.gate`.
##
## The editor hands over the whole file with U+FFFF marking the caret, the word
## under it, and nothing else - no type, no scope, no expression. So this parses the
## file the way the compiler would, finds what the word refers to from where the
## caret is, and answers with a file and a line.
##
## What it resolves, in the order it tries:
##
##   1. a local or parameter in the function the caret is in
##   2. a field, method, signal or enum of the class the caret is in, then of each
##      of its bases that GATE compiled
##   3. `X.member`, where `X` is a type name or a variable whose declared type is
##      known - the one case where the word alone is not enough, read back off the
##      line to the left of the caret
##   4. a struct, class, interface, trait, namespace, generic or alias declared
##      anywhere in the project
##   5. a `class_name` declared by another `.gate`
##   6. a `class_name` declared by a hand-written `.gd`
##   7. an engine class, answered with its documentation page
##
## Anything else returns ERR_UNAVAILABLE, and the editor then draws no underline
## under the word. A lookup that cannot work must not look like one that can.

const _Index: GDScript = preload("res://addons/gate/editor/index.gd")
const _Autoload: GDScript = preload("res://addons/gate/editor/autoload.gd")
const _Complete: GDScript = preload("res://addons/gate/editor/complete.gd")

const CURSOR: String = "￿"

## `ScriptLanguage.LookupResultType`, which is not exposed to scripts.
const RESULT_SCRIPT_LOCATION: int = 0
const RESULT_CLASS: int = 1

const NOT_FOUND: Dictionary = {
	"result": ERR_UNAVAILABLE, "type": 0, "script": null, "class_name": "",
	"class_member": "", "class_path": "", "location": 0,
}

const TYPE_TABLES: Array[String] = [
	"structs", "classes", "interfaces", "traits", "namespaces", "generics",
]


static func find(code: String, symbol: String, path: String) -> Dictionary:
	if symbol.strip_edges() == "":
		return NOT_FOUND
	var reg: RefCounted = _Index.registry()
	if reg == null:
		return NOT_FOUND
	_Complete.editing(path)

	var at: int = code.find(CURSOR)
	var text: String = code.replace(CURSOR, "")
	var line: int = 0
	var column: int = 0
	if at >= 0:
		line = code.substr(0, at).count("\n")
		column = at - (code.rfind("\n", at) + 1)

	var module: GateAST._Module = _Index.module_for(text, path, reg)

	var qualifier: String = ""
	if at >= 0:
		qualifier = _qualifier(text.split("\n")[line] if line < text.count("\n") + 1 else "",
			column, symbol)

	var scope: Dictionary = {}
	var owner: GateAST._ClassDecl = null
	if module != null:
		owner = _enclosing_class(module.members, line + 1)
		_scope(module.members, line + 1, scope)

	if qualifier != "":
		var qualified: Dictionary = _qualified(qualifier, symbol, scope, module, reg)
		if not qualified.is_empty():
			return _location(qualified["path"], qualified["line"], path)
		# `X.y` where X is known and y is not: answering with whatever else `y`
		# happens to name would send the user somewhere unrelated.
		if _type_named(qualifier, reg) != null or _script_class(qualifier, reg) != null:
			return NOT_FOUND
		var chain: Array = _Complete._chain_before(_through_symbol(
			text.split("\n")[line] if line < text.count("\n") + 1 else "", column, symbol))
		if not chain.is_empty() and String(chain[0]) != "self":
			var through: String = _Complete._resolve_chain(chain, module, reg, line + 1)
			if through != "":
				var reached: Dictionary = _in_any_type(through, symbol, reg)
				if reached.is_empty():
					return NOT_FOUND
				return _location(reached["path"], reached["line"], path)

	if scope.has(symbol):
		return _location(path, int(scope[symbol]), path)

	var members: Array = module.members if module != null else []
	if owner != null:
		members = owner.members
	var here: int = _member_line(members, symbol)
	if here > 0:
		return _location(path, here, path)
	if owner != null:
		var outer: int = _member_line(module.members, symbol)
		if outer > 0:
			return _location(path, outer, path)

	var own_class: String = module.class_name_decl if module != null else ""
	if module != null:
		var from: String = own_class if own_class != "" else _Complete.THIS_FILE
		var inherited: Dictionary = _in_any_type(_Complete._base_of(from, reg, module), symbol, reg)
		if not inherited.is_empty():
			return _location(inherited["path"], inherited["line"], path)

	var declared: Dictionary = _declaration(symbol, reg)
	if not declared.is_empty():
		return _location(declared["path"], declared["line"], path)

	var autoload: Dictionary = _Autoload.resolve(symbol)
	if not autoload.is_empty() and String(autoload["script"]) != "":
		return _location(String(autoload["script"]), 1, path)

	if ClassDB.class_exists(symbol):
		return {
			"result": OK, "type": RESULT_CLASS, "script": null, "class_name": symbol,
			"class_member": "", "class_path": "", "location": 0,
		}
	return NOT_FOUND


# ───────────────────────── the answer ─────────────────────────

## `request_open_script_at_line` wants the script and a 1-based line; a jump inside
## the file being edited wants the line and no script, or the editor reopens the tab.
static func _location(target: String, line: int, from: String) -> Dictionary:
	if line <= 0:
		return NOT_FOUND
	var script: Script = null
	if target != from:
		var loaded: Resource = ResourceLoader.load(target, "", ResourceLoader.CACHE_MODE_REUSE)
		if loaded is Script:
			script = loaded
		else:
			return NOT_FOUND
	return {
		"result": OK, "type": RESULT_SCRIPT_LOCATION, "script": script, "class_name": "",
		"class_member": "", "class_path": target, "location": line,
	}


# ───────────────────────── reading the caret ─────────────────────────

## The identifier immediately before the `.` that precedes the symbol, or "".
static func _qualifier(line: String, column: int, symbol: String) -> String:
	var start: int = column
	# The caret can be anywhere inside the word; walk back to where it begins.
	while start > 0 and _is_word(line[start - 1]):
		start -= 1
	if line.substr(start, symbol.length()) != symbol:
		return ""
	var before: int = start - 1
	while before >= 0 and line[before] == " ":
		before -= 1
	if before < 0 or line[before] != ".":
		return ""
	before -= 1
	while before >= 0 and line[before] == " ":
		before -= 1
	var end: int = before + 1
	while before >= 0 and _is_word(line[before]):
		before -= 1
	return line.substr(before + 1, end - before - 1)


static func _through_symbol(line: String, column: int, symbol: String) -> String:
	var start: int = mini(column, line.length())
	while start > 0 and _is_word(line[start - 1]):
		start -= 1
	if line.substr(start, symbol.length()) != symbol:
		return ""
	return line.substr(0, start + symbol.length())


static func _is_word(character: String) -> bool:
	return character == "_" or character.is_valid_identifier() or character.is_valid_int()


# ───────────────────────── scope in this file ─────────────────────────

## The last line any part of `node` occupies, so a block can be told from the code
## after it. Lines are the only positions the AST carries.
static func _extent(node: Object) -> int:
	if node == null or not (node is GateAST._ASTNode):
		return 0
	var last: int = (node as GateAST._ASTNode).line
	for property in node.get_property_list():
		if (int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var value: Variant = node.get(property["name"])
		if value is Array:
			for item in value:
				if item is GateAST._ASTNode:
					last = maxi(last, _extent(item))
		elif value is GateAST._ASTNode:
			last = maxi(last, _extent(value))
	return last


static func _contains(node: GateAST._ASTNode, line: int) -> bool:
	return node.line <= line and line <= _extent(node)


## Everything nameable that is in scope at `line`, as name -> the line declaring it.
static func _scope(members: Array, line: int, out: Dictionary) -> void:
	for member in members:
		if member is GateAST._FuncDecl:
			var decl: GateAST._FuncDecl = member
			if not _contains(decl, line):
				continue
			for parameter in decl.params:
				out[(parameter as GateAST._Param).name] = (parameter as GateAST._Param).line
			_locals(decl.body, line, out)
		elif member is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = member
			if _contains(cd, line):
				_scope(cd.members, line, out)


static func _locals(body: Array, line: int, out: Dictionary) -> void:
	for statement in body:
		if not (statement is GateAST._ASTNode):
			continue
		var node: GateAST._ASTNode = statement
		if node.line > line:
			continue
		if node is GateAST._VarDecl:
			out[(node as GateAST._VarDecl).name] = node.line
		elif node is GateAST._ForStmt:
			var loop: GateAST._ForStmt = node
			for name in _loop_names(loop):
				out[name] = loop.line
		for property in node.get_property_list():
			if (int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
				continue
			var value: Variant = node.get(property["name"])
			if value is Array and property["name"] in ["body", "else_body", "branches", "cases"]:
				_locals(value, line, out)


static func _loop_names(loop: GateAST._ForStmt) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for property in ["name", "key_name", "value_name", "index_name"]:
		if property in loop and String(loop.get(property)) != "":
			out.append(String(loop.get(property)))
	return out


static func _enclosing_class(members: Array, line: int) -> GateAST._ClassDecl:
	for member in members:
		if not (member is GateAST._ClassDecl):
			continue
		var cd: GateAST._ClassDecl = member
		if not _contains(cd, line):
			continue
		var inner: GateAST._ClassDecl = _enclosing_class(cd.members, line)
		return inner if inner != null else cd
	return null


## The line a member with this name is declared on, or 0.
static func _member_line(members: Array, name: String) -> int:
	for member in members:
		var found: int = 0
		if member is GateAST._FuncDecl and (member as GateAST._FuncDecl).name == name:
			found = (member as GateAST._FuncDecl).line
		elif member is GateAST._VarDecl and (member as GateAST._VarDecl).name == name:
			found = (member as GateAST._VarDecl).line
		elif member is GateAST._SignalDecl and (member as GateAST._SignalDecl).name == name:
			found = (member as GateAST._SignalDecl).line
		elif member is GateAST._EnumDecl and (member as GateAST._EnumDecl).name == name:
			found = (member as GateAST._EnumDecl).line
		elif member is GateAST._ClassDecl and (member as GateAST._ClassDecl).name == name:
			found = (member as GateAST._ClassDecl).line
		elif member is GateAST._TypeAliasDecl and (member as GateAST._TypeAliasDecl).name == name:
			found = (member as GateAST._TypeAliasDecl).line
		elif member is GateAST._AnnotatedStmt:
			found = _member_line([(member as GateAST._AnnotatedStmt).stmt], name)
		if found > 0:
			return found
	return 0


# ───────────────────────── the project ─────────────────────────

static func _type_named(name: String, reg: RefCounted) -> GateAST._ClassDecl:
	for table in TYPE_TABLES:
		var declarations: Dictionary = reg.get(table)
		if declarations.has(name):
			return declarations[name]
	return null


static func _script_class(name: String, reg: RefCounted) -> GateAST._ClassDecl:
	if reg.script_class_decls.has(name):
		return reg.script_class_decls[name]
	return null


## Where `symbol` is declared, as {path, line}, or {}.
static func _declaration(symbol: String, reg: RefCounted) -> Dictionary:
	var declared: GateAST._ClassDecl = _type_named(symbol, reg)
	if declared != null and reg.origin.has(symbol):
		return {"path": String(reg.origin[symbol]), "line": declared.line}
	if reg.alias_decls.has(symbol):
		var alias: GateAST._TypeAliasDecl = reg.alias_decls[symbol]
		var files: Array = reg.alias_files.get(symbol, [])
		if not files.is_empty():
			return {"path": String(files[0]), "line": alias.line}
	if reg.script_class_names.has(symbol):
		var where: String = String(reg.script_class_names[symbol])
		return {"path": where, "line": _class_name_line(where, symbol)}
	var global: String = _global_class_path(symbol)
	if global != "":
		return {"path": global, "line": _class_name_line(global, symbol)}
	return {}


## A `class_name` is on the _Module, not in the registry, so it is read back off the
## file. One file, on a click the user asked for.
static func _class_name_line(path: String, name: String) -> int:
	if not FileAccess.file_exists(path):
		return 1
	var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
	for i in lines.size():
		var text: String = lines[i].strip_edges()
		if text.begins_with("class_name ") and text.substr(11).strip_edges().get_slice(" ", 0) == name:
			return i + 1
	return 1


static func _global_class_path(name: String) -> String:
	for entry in ProjectSettings.get_global_class_list():
		if String(entry["class"]) == name:
			return String(entry["path"])
	return ""


## `X.member`, where X names a type or a variable of a known type.
static func _qualified(qualifier: String, symbol: String, scope: Dictionary,
		module: GateAST._Module, reg: RefCounted) -> Dictionary:
	var type_name: String = qualifier
	if _type_named(qualifier, reg) == null and _script_class(qualifier, reg) == null:
		type_name = _declared_type(qualifier, scope, module, reg)
	if type_name == "":
		return {}
	return _in_type(type_name, symbol, reg)


## The type a local, parameter or field was declared with, by name.
static func _declared_type(name: String, scope: Dictionary, module: GateAST._Module,
		reg: RefCounted) -> String:
	if module == null:
		return ""
	var found: GateAST._TypeRef = _declared_type_in(module.members, name, scope.get(name, 0))
	if found != null:
		return found.name
	return ""


static func _declared_type_in(members: Array, name: String, line: int) -> GateAST._TypeRef:
	for member in members:
		if member is GateAST._VarDecl:
			var vd: GateAST._VarDecl = member
			if vd.name == name and vd.type != null and (line == 0 or vd.line == line):
				return vd.type
		elif member is GateAST._FuncDecl:
			var decl: GateAST._FuncDecl = member
			for parameter in decl.params:
				var p: GateAST._Param = parameter
				if p.name == name and p.type != null and (line == 0 or p.line == line):
					return p.type
			var inner: GateAST._TypeRef = _declared_type_in(decl.body, name, line)
			if inner != null:
				return inner
		elif member is GateAST._ClassDecl:
			var nested: GateAST._TypeRef = _declared_type_in(
				(member as GateAST._ClassDecl).members, name, line)
			if nested != null:
				return nested
		elif member is GateAST._ASTNode and "body" in member:
			var deeper: GateAST._TypeRef = _declared_type_in(member.get("body"), name, line)
			if deeper != null:
				return deeper
	return null


static func _in_type(type_name: String, symbol: String, reg: RefCounted) -> Dictionary:
	return _in_any_type(type_name, symbol, reg)


static func _in_any_type(type_name: String, symbol: String, reg: RefCounted,
		depth: int = 0) -> Dictionary:
	if type_name == "" or depth > _Complete.MAX_CHAIN * 4:
		return {}
	if type_name.begins_with("res://"):
		var file: GateAST._Module = _Autoload.module(type_name, reg)
		if file == null:
			return {}
		var here: int = _member_line(file.members, symbol)
		if here > 0:
			return {"path": type_name, "line": here}
		return _in_any_type(_Complete._base_of(type_name, reg), symbol, reg, depth + 1)
	var declared: GateAST._ClassDecl = _type_named(type_name, reg)
	var where: String = String(reg.origin.get(type_name, ""))
	if declared == null:
		declared = _script_class(type_name, reg)
		where = String(reg.script_class_names.get(type_name, ""))
	if declared == null:
		var script: String = _global_class_path(type_name)
		if script == "" or not script.get_extension().to_lower() == "gd":
			return {}
		return _in_any_type(_Complete._script_type(script, reg), symbol, reg, depth + 1)
	if where != "":
		var line: int = _member_line(declared.members, symbol)
		if line > 0:
			return {"path": where, "line": line}
	return _in_any_type(_Complete._base_of(type_name, reg), symbol, reg, depth + 1)


static func _in_bases(type_name: String, symbol: String, reg: RefCounted) -> Dictionary:
	return _in_any_type(_Complete._base_of(type_name, reg), symbol, reg)

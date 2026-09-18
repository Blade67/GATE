@tool
extends RefCounted

## Autocompletion for `.gate`.
##
## GDScript's own completion cannot be borrowed. `ScriptLanguage` exposes no methods
## to scripts at all - `ClassDB.class_get_method_list("ScriptLanguage")` is empty - so
## there is no way to hand it the compiled `.gd` and a position and get its answer
## back. Checked before anything here was written, because it would have been the
## cheap route: compile the line, map the cursor through the `.gd.map`, ask GDScript.
## It is not available.
##
## So the list is built from what GATE and the engine already know:
##
##   GATE's registry   every struct, class, interface, trait, namespace, generic and
##                     alias in the project, with its members, from the same index the
##                     compiler resolves cross-file types against
##   the parsed file   locals, parameters and the members of the class the caret is in
##   ClassDB          every engine class and, for a type that reaches one, its whole
##                     inherited API
##   the class list    a `class_name` in a hand-written `.gd`, through the Script
##
## The one thing it will not do is guess. Where the type of what is left of the dot
## cannot be established, the answer is no options rather than a list assembled from
## somewhere else - a completion list that is confidently wrong costs more than an
## empty one.

const _Index: GDScript = preload("res://addons/gate/editor/index.gd")
const _Autoload: GDScript = preload("res://addons/gate/editor/autoload.gd")
const _Builtins: GDScript = preload("res://addons/gate/editor/builtin_api.gd")

const CURSOR: String = "\uFFFF"

## `ScriptLanguage.CodeCompletionKind`, which is not exposed to scripts.
const KIND_CLASS: int = 0
const KIND_FUNCTION: int = 1
const KIND_SIGNAL: int = 2
const KIND_VARIABLE: int = 3
const KIND_MEMBER: int = 4
const KIND_ENUM: int = 5
const KIND_CONSTANT: int = 6
const KIND_PLAIN_TEXT: int = 9

## `ScriptLanguage.CodeCompletionLocation`. Lower sorts first.
const HERE: int = 0
const PARENT: int = 1 << 8
const OTHER_USER_CODE: int = 1 << 9
const FAR: int = 1 << 10

const NOTHING: Dictionary = {"result": OK, "force": false, "call_hint": "", "options": []}

## How far a dotted chain is followed before giving up. Real code does not go deep,
## and each step costs a lookup.
const MAX_CHAIN: int = 8

## Stands for "the file being edited", which has no name of its own until it
## declares a `class_name`. A script without one still has members, and `self.` in it
## has to offer them as well as the base's. Brackets and a space keep the name
## from ever colliding with a type somebody actually declared.
const THIS_FILE: String = "(this file)"

const GATE_KEYWORDS: Array[String] = [
	"struct", "trait", "interface", "namespace", "implements", "with", "pub", "priv",
	"final", "virtual", "override", "enumerate", "when", "type", "func", "var",
	"const", "static", "class", "class_name", "extends", "signal", "enum", "if",
	"elif", "else", "for", "while", "match", "return", "break", "continue", "pass",
	"await", "self", "super", "true", "false", "null", "not", "and", "or", "is", "as",
	"in", "preload", "assert", "breakpoint", "void",
]

const SHORTHANDS: Array[String] = [
	"int", "float", "bool", "str", "i32", "i64", "f32", "f64",
	"vec2", "vec2i", "vec3", "vec3i", "vec4", "vec4i", "rect2", "rect2i",
	"quat", "xform2d", "xform3d", "color", "aabb", "plane", "basis", "proj",
	"nodepath", "rid", "sname", "any",
]

const ANNOTATIONS: Array[String] = [
	"@tool", "@export", "@export_if", "@required", "@observable", "@soa", "@packed",
	"@onready", "@icon", "@static_unload", "@warning_ignore", "@rpc",
	"@export_range", "@export_enum", "@export_file", "@export_dir", "@export_group",
	"@export_category", "@export_multiline", "@export_color_no_alpha",
	"@export_node_path", "@export_flags", "@export_subgroup",
]

## One parsed module, and the text it was parsed from.
##
## Parsing is the whole cost of a completion request - measured at 16 ms on a
## 128-line file, 104 ms at 908 lines and 488 ms at 4,208 - so the same parse is
## reused for as long as it is provably still true of the file. That is wider than
## "the text is identical": see `_same_declarations`.
static var _cached_text: String = ""
static var _cached_path: String = ""
static var _cached_module: GateAST._Module = null

static var _editing: String = ""


static func editing(path: String) -> void:
	_editing = path

## Words that can only appear on a line that declares something. A line carrying
## none of them, and no quote that could open or close a `"""` block, cannot change
## what the file declares no matter what is typed into it.
const DECLARING: Array[String] = [
	"func", "var", "const", "class", "class_name", "struct", "interface", "trait",
	"namespace", "extends", "signal", "enum", "type", "static", "pub", "priv",
]


static func complete(code: String, path: String, owner: Object) -> Dictionary:
	var at: int = code.find(CURSOR)
	if at < 0:
		return NOTHING
	var text: String = code.replace(CURSOR, "")
	var line_start: int = code.rfind("\n", at) + 1
	var head: String = code.substr(line_start, at - line_start)
	var row: int = code.substr(0, at).count("\n")

	var reg: RefCounted = _Index.registry()
	if reg == null:
		return NOTHING
	editing(path)
	var module: GateAST._Module = _module(text, path, reg)

	# `@` starts an annotation and nothing else can follow it.
	var annotation: int = head.rfind("@")
	if annotation >= 0 and head.substr(annotation).find(" ") < 0 \
			and head.substr(annotation).find("(") < 0:
		return _wrap(_annotations())

	var chain: Array = _chain_before(head)
	if not chain.is_empty():
		var type_name: String = _resolve_chain(chain, module, reg, row + 1)
		if type_name == "":
			# The dot is real but the type behind it is not knowable. Saying nothing
			# is the honest answer; anything else here is a list about a different
			# object than the one on screen.
			return NOTHING
		var outside: bool = chain.size() > 1 or String(chain[0]) != "self"
		return _wrap(_members_of(type_name, reg, module, outside))

	return _wrap(_in_scope(module, reg, row + 1))


static func _module(text: String, path: String, reg: RefCounted) -> GateAST._Module:
	if _cached_path == path and _cached_module != null 			and (_cached_text == text or _same_declarations(_cached_text, text)):
		return _cached_module
	_cached_module = _Index.module_for(text, path, reg)
	_cached_text = text
	_cached_path = path
	return _cached_module


## True when the only difference between two versions of a file is inside a single
## line that declares nothing.
##
## Typing an expression - which is what is happening on almost every completion
## request - cannot add, remove or retype a declaration, so the parse from before
## the keystroke is still exactly right and the file does not need parsing again.
## The test is deliberately narrow, because being wrong here means completing
## against a file that no longer exists:
##
##   * the same number of lines, so no line was added or removed
##   * exactly one line differs
##   * that line has no declaring word in it, in either version
##   * that line has no quote in it, in either version, so it cannot open or close
##     a `"""` block and change how everything below it parses
##   * and everything on it before the first `=`, `(` or `.` is unchanged
##
## The last one is there because GATE declares without a keyword. `Blade later = x`
## is a declaration and carries none of the words above, so the keyword list alone
## would happily reuse a parse across `Blade later` becoming `Damage later` and then
## complete the wrong type's members. What is left of the first `=`, `(` or `.` is
## the type and the name; what is right of it is an expression, and typing an
## expression is what a completion request almost always follows.
##
## Anything else falls through to a fresh parse.
static func _same_declarations(before: String, after: String) -> bool:
	var was: PackedStringArray = before.split("
")
	var now: PackedStringArray = after.split("
")
	if was.size() != now.size():
		return false
	var changed: int = -1
	for i in was.size():
		if was[i] == now[i]:
			continue
		if changed >= 0:
			return false
		changed = i
	if changed < 0:
		return true
	return (_is_plain(was[changed]) and _is_plain(now[changed])
		and _declared_part(was[changed]) == _declared_part(now[changed]))


## The part of a line that could name a type or a variable: everything before the
## first `=`, `(` or `.`.
static func _declared_part(line: String) -> String:
	var end: int = line.length()
	for mark in ["=", "(", "."]:
		var at: int = line.find(mark)
		if at >= 0:
			end = mini(end, at)
	return line.substr(0, end)


static func _is_plain(line: String) -> bool:
	if line.contains("\"") or line.contains("'"):
		return false
	for word in DECLARING:
		var at: int = line.find(word)
		while at >= 0:
			var before_ok: bool = at == 0 or not _is_word(line[at - 1])
			var after: int = at + word.length()
			var after_ok: bool = after >= line.length() or not _is_word(line[after])
			if before_ok and after_ok:
				return false
			at = line.find(word, at + 1)
	return true


static func forget() -> void:
	_inferers.clear()
	_cached_module = null
	_cached_text = ""
	_cached_path = ""


# ───────────────────────── the answer ─────────────────────────

## Every key is required. An option missing any one of `kind`, `display`,
## `insert_text`, `font_color`, `icon`, `default_value` or `location` is dropped by
## the engine without a word - measured by sending nine options each missing a
## different key and counting what came back. Only `display_text` is optional.
static func option(kind: int, display: String, insert: String, location: int) -> Dictionary:
	return {
		"kind": kind,
		"display": display,
		"insert_text": insert,
		"font_color": Color.WHITE,
		"icon": null,
		"default_value": null,
		"location": location,
	}


static func _wrap(options: Array) -> Dictionary:
	return {"result": OK, "force": false, "call_hint": "", "options": options}


static func _annotations() -> Array:
	var out: Array = []
	for name in ANNOTATIONS:
		out.append(option(KIND_PLAIN_TEXT, name, name.substr(1), HERE))
	return out


# ───────────────────────── reading the caret ─────────────────────────

## The dotted path immediately left of the caret, innermost last, or [] when the
## caret is not after a `.`. `a.b().c` reads back as ["a", "b", "c"]; the partial
static func _chain_before(head: String) -> Array:
	var at: int = head.length()
	# Step over the word being typed.
	while at > 0 and _is_word(head[at - 1]):
		at -= 1
	if at == 0 or head[at - 1] != ".":
		return []
	at -= 1
	# `?.` is the same access with a null guard in front of it.
	if at > 0 and head[at - 1] == "?":
		at -= 1
	var parts: Array = []
	while parts.size() < MAX_CHAIN:
		var indexes: int = 0
		while at > 0 and (head[at - 1] == ")" or head[at - 1] == "]"):
			var close: String = head[at - 1]
			var open: String = "(" if close == ")" else "["
			if close == "]":
				indexes += 1
			var depth: int = 0
			while at > 0:
				at -= 1
				if head[at] == close:
					depth += 1
				elif head[at] == open:
					depth -= 1
					if depth == 0:
						break
			if at <= 0:
				return []
		for i in indexes:
			parts.push_front("[]")
		var end: int = at
		while at > 0 and _is_word(head[at - 1]):
			at -= 1
		if at == end:
			var literal: String = _literal_before(head, at)
			if literal == "":
				return []
			parts.push_front(literal)
			break
		parts.push_front(head.substr(at, end - at))
		if at > 0 and head[at - 1] == ".":
			at -= 1
			if at > 0 and head[at - 1] == "?":
				at -= 1
			continue
		break
	return parts


static func _literal_before(head: String, at: int) -> String:
	if at < 2 or (head[at - 1] != "\"" and head[at - 1] != "'"):
		return ""
	var quote: String = head[at - 1]
	var open: int = head.rfind(quote, at - 2)
	while open > 0 and head[open - 1] == "\\":
		open = head.rfind(quote, open - 2)
	if open < 0:
		return ""
	if open > 0 and head[open - 1] == "&":
		return "@StringName"
	if open > 0 and head[open - 1] == "^":
		return "@NodePath"
	return "@String"


static func _is_word(character: String) -> bool:
	return character == "_" or character.is_valid_identifier() or character.is_valid_int()


# ───────────────────────── resolving a type ─────────────────────────

## The type name the chain ends on, or "".
static func _resolve_chain(chain: Array, module: GateAST._Module, reg: RefCounted,
		line: int) -> String:
	if _resolving > MAX_CHAIN:
		return ""
	_resolving += 1
	var first: String = String(chain[0])
	var current: String = first.substr(1) if first.begins_with("@") \
		else _base_type(first, module, reg, line)
	for i in range(1, chain.size()):
		if current == "":
			break
		var part: String = String(chain[i])
		current = _element_of(current) if part == "[]" else _member_type(current, part, reg, module)
	_resolving -= 1
	return current


static var _resolving: int = 0


## What the first name in a chain stands for: a type used statically, or a value
## whose declared type is known.
static func _base_type(name: String, module: GateAST._Module, reg: RefCounted,
		line: int) -> String:
	if name == "self":
		if module != null and module.class_name_decl != "":
			return module.class_name_decl
		return THIS_FILE if module != null else ""
	if _declaration_of(name, reg) != null or ClassDB.class_exists(name) \
			or _global_class(name) != "":
		return name
	if module == null:
		return _autoload_type(name, reg)
	var declared: String = _declared_type(module.members, name, line, module, reg)
	if declared != "":
		return declared
	var visible: Dictionary = {}
	_locals(module.members, line, visible)
	if visible.has(name):
		return ""
	var own: String = module.class_name_decl if module.class_name_decl != "" else THIS_FILE
	var inherited: String = _member_type(own, name, reg, module)
	if inherited != "":
		return inherited
	return _autoload_type(name, reg)


static func _autoload_type(name: String, reg: RefCounted) -> String:
	var target: Dictionary = _Autoload.resolve(name)
	if target.is_empty():
		return ""
	var script: String = String(target["script"])
	if script == "":
		var native: String = String(target["native"])
		return native if ClassDB.class_exists(native) else ""
	return _script_type(script, reg)


static func _is_file(type_name: String) -> bool:
	return type_name.begins_with("res://")


static func _file_module(type_name: String, module: GateAST._Module,
		reg: RefCounted) -> GateAST._Module:
	return module if type_name == THIS_FILE else _Autoload.module(type_name, reg)


static func _declared_type(members: Array, name: String, line: int,
		module: GateAST._Module, reg: RefCounted) -> String:
	var best: String = ""
	var best_line: int = -1
	for member in members:
		if member is GateAST._VarDecl:
			var vd: GateAST._VarDecl = member
			if vd.name == name and vd.line <= line and vd.line > best_line:
				var fixed: String = _var_type(vd, module, _editing, reg)
				if fixed != "":
					best = fixed
					best_line = vd.line
		elif member is GateAST._FuncDecl:
			var decl: GateAST._FuncDecl = member
			for parameter in decl.params:
				var p: GateAST._Param = parameter
				if p.name == name and p.type != null and decl.line <= line:
					best = _type_name(p.type)
					best_line = decl.line
			var inner: String = _declared_type(decl.body, name, line, module, reg)
			if inner != "":
				best = inner
				best_line = line
		elif member is GateAST._ClassDecl:
			var nested: String = _declared_type(
				(member as GateAST._ClassDecl).members, name, line, module, reg)
			if nested != "" and best == "":
				best = nested
		elif member is GateAST._ForStmt:
			var loop: GateAST._ForStmt = member
			var at: int = loop.var_names.find(name)
			if at >= 0 and loop.line <= line and loop.line > best_line:
				best = _loop_type(loop, at, module, reg)
				best_line = loop.line
			var within: String = _declared_type(loop.body, name, line, module, reg)
			if within != "":
				best = within
				best_line = line
		elif member is GateAST._ASTNode and "body" in member:
			var deeper: String = _declared_type(member.get("body"), name, line, module, reg)
			if deeper != "" and best == "":
				best = deeper
	return best


static func _loop_type(loop: GateAST._ForStmt, index: int, module: GateAST._Module,
		reg: RefCounted) -> String:
	var count: int = loop.var_names.size()
	if loop.var_type != null and index == count - 1:
		return _type_name(loop.var_type)
	var iterable: Variant = loop.iterable
	if loop.is_enumerate:
		if index == 0:
			return "int"
		var call: GateAST._Call = iterable
		if call.args.is_empty():
			return ""
		iterable = call.args[0]
	var chain: Array = _expr_chain(iterable)
	if chain.is_empty():
		return ""
	var over: String = _resolve_chain(chain, module, reg, loop.line)
	if count == 2 and not loop.is_enumerate:
		var pair: PackedStringArray = _arguments(over)
		return pair[index] if _container(over) == "Dictionary" and pair.size() == 2 else ""
	return _iterated_of(over)


static func _expr_chain(expr: Variant) -> Array:
	if expr is GateAST._Ident:
		return [(expr as GateAST._Ident).name]
	if expr is GateAST._SelfExpr:
		return ["self"]
	if expr is GateAST._FString:
		return ["@String"]
	if expr is GateAST._Literal:
		var literal: GateAST._Literal = expr
		if literal.kind == "string":
			return ["@String"]
		if literal.kind == "number":
			return ["@float"] if literal.raw.contains(".") else ["@int"]
		return []
	if expr is GateAST._Member:
		var through: Array = _expr_chain((expr as GateAST._Member).target)
		if not through.is_empty():
			through.append((expr as GateAST._Member).name)
		return through
	if expr is GateAST._Index:
		var indexed: Array = _expr_chain((expr as GateAST._Index).target)
		if not indexed.is_empty():
			indexed.append("[]")
		return indexed
	if expr is GateAST._Call:
		var callee: Variant = (expr as GateAST._Call).callee
		if callee is GateAST._Ident and (callee as GateAST._Ident).name == "range":
			return ["@int"]
		return _expr_chain(callee)
	return []


static func _var_type(vd: GateAST._VarDecl, file: GateAST._Module, source: String,
		reg: RefCounted) -> String:
	if vd.type != null:
		return _type_name(vd.type, _is_packed(vd))
	if vd.value == null or not (vd.inferred or vd.is_const) or file == null:
		return ""
	var loaded: String = _preloaded(vd.value, source, reg)
	if loaded != "":
		return loaded
	var self_type: GateAST._TypeRef = GateAST._TypeRef.new()
	self_type.name = file.class_name_decl if file.class_name_decl != "" else GateInfer.MODULE_CLASS
	var found: GateAST._TypeRef = _infer_for(file, reg).type_of(vd.value, {"self": self_type})
	var text: String = _type_name(found) if found != null else ""
	if text != "" and _is_known(text, reg):
		return text
	var chain: Array = _expr_chain(vd.value)
	if chain.is_empty():
		return ""
	var was: String = _editing
	_editing = source
	text = _resolve_chain(chain, file, reg, vd.line)
	_editing = was
	return text


static func _is_known(type_name: String, reg: RefCounted) -> bool:
	var base: String = _container(type_name)
	return (base == "int" or base == "float" or base == "bool" or not _builtin(base).is_empty()
		or ClassDB.class_exists(base) or _declaration_of(base, reg) != null
		or _global_class(base) != "" or reg.gd_class_names.has(base))


static func _preloaded(value: Variant, source: String, reg: RefCounted) -> String:
	if not (value is GateAST._Call):
		return ""
	var call: GateAST._Call = value
	if not (call.callee is GateAST._Ident) or (call.callee as GateAST._Ident).name != "preload" \
			or call.args.size() != 1 or not (call.args[0] is GateAST._Literal):
		return ""
	var raw: String = (call.args[0] as GateAST._Literal).raw
	var path: String = raw.substr(1, raw.length() - 2)
	if path.begins_with("uid://"):
		path = _Autoload._path(path)
	elif not path.begins_with("res://") and source != "":
		path = source.get_base_dir().path_join(path).simplify_path()
	if not path.begins_with("res://"):
		return ""
	var extension: String = path.get_extension().to_lower()
	if extension == "gd" or extension == "gate":
		return _script_type(path, reg)
	if extension == "tscn" or extension == "scn":
		return "PackedScene"
	if not Engine.is_editor_hint():
		return ""
	var kind: String = String(EditorInterface.get_resource_filesystem().get_file_type(path))
	return kind if ClassDB.class_exists(kind) else ""


static var _inferers: Array = []


static func _infer_for(file: GateAST._Module, reg: RefCounted) -> GateInfer:
	for entry in _inferers:
		if is_same(entry[0], file.members) and int(entry[1]) == reg.get_instance_id():
			return entry[2]
	var made: GateInfer = GateInfer.new()
	made.build(file, reg)
	_inferers.push_front([file.members, reg.get_instance_id(), made])
	if _inferers.size() > 8:
		_inferers.pop_back()
	return made


static func _declaring(owner: String, declared: GateAST._ClassDecl, module: GateAST._Module,
		reg: RefCounted) -> Array:
	if owner == THIS_FILE:
		return [module, _editing]
	if _is_file(owner):
		return [_file_module(owner, module, reg), owner]
	var file: GateAST._Module = GateAST._Module.new()
	file.members = declared.members
	file.extends_type = declared.extends_type
	if reg.script_class_decls.has(owner):
		file.class_name_decl = owner
	return [file, String(reg.script_class_names.get(owner, reg.origin.get(owner, "")))]


## `Thing?`, `Thing[]` and `Thing[]?` all name `Thing`.
static func _bare(name: String) -> String:
	return name.trim_suffix("?").replace("[]", "").strip_edges()


static func _type_name(type: GateAST._TypeRef, packed: bool = false) -> String:
	if type == null:
		return ""
	var text: String = ""
	if type.dict_key != null and type.dict_value != null:
		var key: String = _type_name(type.dict_key)
		var value: String = _type_name(type.dict_value)
		text = "Dictionary[%s, %s]" % [key, value] if key != "" and value != "" else "Dictionary"
	else:
		text = _canonical(_bare(type.name))
		if text == "":
			return ""
		if (text == "Array" or text == "Dictionary") and not type.generic_args.is_empty():
			var arguments: PackedStringArray = PackedStringArray()
			for argument in type.generic_args:
				arguments.append(_type_name(argument))
			if not arguments.has(""):
				text += "[" + ", ".join(arguments) + "]"
	for depth in type.array_depth:
		var lowered: String = GateTypes.packed_for(text) if packed and depth == 0 else ""
		text = lowered if lowered != "" else "Array[%s]" % text
	return text


static func _is_packed(declared: GateAST._VarDecl) -> bool:
	for annotation in declared.annotations:
		if (annotation as GateAST._Annotation).name == "packed":
			return true
	return false


static func _canonical(name: String) -> String:
	if not GateTypes.SHORTHAND.has(name):
		return name
	var reg: RefCounted = _Index.registry()
	if reg != null and (_declaration_of(name, reg) != null or reg.script_class_names.has(name)):
		return name
	return String(GateTypes.SHORTHAND[name])


const ARRAY_ELEMENT: Array[String] = [
	"get", "front", "back", "pick_random", "pop_back", "pop_front", "pop_at", "max", "min",
]


static func _container(type_name: String) -> String:
	return type_name.get_slice("[", 0)


static func _arguments(type_name: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var open: int = type_name.find("[")
	if open < 0 or not type_name.ends_with("]"):
		return out
	var depth: int = 0
	var start: int = open + 1
	for i in range(open + 1, type_name.length() - 1):
		var character: String = type_name[i]
		if character == "[":
			depth += 1
		elif character == "]":
			depth -= 1
		elif character == "," and depth == 0:
			out.append(type_name.substr(start, i - start).strip_edges())
			start = i + 1
	out.append(type_name.substr(start, type_name.length() - 1 - start).strip_edges())
	return out


static func _builtin(type_name: String) -> Dictionary:
	return _Builtins.TYPES.get(_container(type_name), {})


static func _element_of(type_name: String) -> String:
	var arguments: PackedStringArray = _arguments(type_name)
	match _container(type_name):
		"Array":
			return arguments[0] if arguments.size() == 1 else ""
		"Dictionary":
			return arguments[1] if arguments.size() == 2 else ""
	var index: String = String(_builtin(type_name).get("index", ""))
	return "" if index == "Variant" else index


static func _iterated_of(type_name: String) -> String:
	match _container(type_name):
		"Dictionary":
			var arguments: PackedStringArray = _arguments(type_name)
			return arguments[0] if arguments.size() == 2 else ""
		"int":
			return "int"
	return _element_of(type_name)


static func _builtin_member_type(owner: String, member: String) -> String:
	var api: Dictionary = _builtin(owner)
	var methods: Dictionary = api["methods"]
	if methods.has(member):
		var returns: String = String(methods[member])
		var arguments: PackedStringArray = _arguments(owner)
		match _container(owner):
			"Array":
				if arguments.size() == 1 and ARRAY_ELEMENT.has(member):
					return arguments[0]
			"Dictionary":
				if arguments.size() == 2:
					match member:
						"get", "get_or_add":
							return arguments[1]
						"find_key":
							return arguments[0]
						"keys":
							return "Array[%s]" % arguments[0]
						"values":
							return "Array[%s]" % arguments[1]
		return "" if returns == "Variant" else returns
	var properties: Dictionary = api["properties"]
	if properties.has(member):
		return String(properties[member])
	var constants: Dictionary = api["constants"]
	return String(constants.get(member, ""))


static func _from_builtin(type_name: String, out: Array, taken: Dictionary) -> void:
	var api: Dictionary = _builtin(type_name)
	for name in Dictionary(api["methods"]):
		_take(out, taken, option(KIND_FUNCTION, name + "(", name + "(", FAR))
	for name in Dictionary(api["properties"]):
		_take(out, taken, option(KIND_MEMBER, name, name, FAR))
	for name in Dictionary(api["constants"]):
		_take(out, taken, option(KIND_CONSTANT, name, name, FAR))
	for name in Array(api["enums"]):
		_take(out, taken, option(KIND_ENUM, name, name, FAR))


static func _declaration_of(name: String, reg: RefCounted) -> GateAST._ClassDecl:
	for table in ["structs", "classes", "interfaces", "traits", "namespaces", "generics"]:
		var declarations: Dictionary = reg.get(table)
		if declarations.has(name):
			return declarations[name]
	if reg.script_class_decls.has(name):
		return reg.script_class_decls[name]
	return null


static func _global_class(name: String) -> String:
	for entry in ProjectSettings.get_global_class_list():
		if String(entry["class"]) == name:
			return String(entry["path"])
	return ""


## The type of `owner.member`, or "".
static func _member_type(owner: String, member: String, reg: RefCounted,
		module: GateAST._Module = null) -> String:
	if not _builtin(owner).is_empty():
		return _builtin_member_type(owner, member)
	var seen: Dictionary = {}
	while owner != "" and not seen.has(owner):
		seen[owner] = true
		var declared: GateAST._ClassDecl = null
		if owner == THIS_FILE or _is_file(owner):
			declared = _as_decl(_file_module(owner, module, reg))
			if declared == null:
				return ""
		else:
			declared = _declaration_of(owner, reg)
		if declared != null:
			for entry in declared.members:
				if entry is GateAST._VarDecl and (entry as GateAST._VarDecl).name == member:
					var where: Array = _declaring(owner, declared, module, reg)
					return _var_type(entry, where[0], String(where[1]), reg)
				if entry is GateAST._FuncDecl and (entry as GateAST._FuncDecl).name == member:
					var fd: GateAST._FuncDecl = entry
					return _type_name(fd.return_type)
			owner = _base_of(owner, reg, module)
			continue
		# Off the end of what GATE compiled, into a `.gd` or the engine.
		var script_path: String = _global_class(owner)
		if script_path == "":
			break
		var script: Script = ResourceLoader.load(script_path, "", ResourceLoader.CACHE_MODE_REUSE) as Script
		if script == null:
			return ""
		for method in script.get_script_method_list():
			if String(method["name"]) == member:
				return _return_type_of(method)
		for property in script.get_script_property_list():
			if String(property["name"]) == member:
				return _type_of(property)
		owner = _script_base(script, reg)
	if owner == "" or not ClassDB.class_exists(owner):
		return ""
	for method in ClassDB.class_get_method_list(owner, false):
		if String(method["name"]) == member:
			return _return_type_of(method)
	for property in ClassDB.class_get_property_list(owner, false):
		if String(property["name"]) == member:
			return _type_of(property)
	return ""


static func _type_of(info: Dictionary) -> String:
	var held: String = String(info.get("hint_string", ""))
	var hint: int = int(info.get("hint", PROPERTY_HINT_NONE))
	if held != "" and hint == PROPERTY_HINT_ARRAY_TYPE:
		return "Array[%s]" % held.get_slice(":", held.get_slice_count(":") - 1)
	if held.contains(";") and hint == PROPERTY_HINT_DICTIONARY_TYPE:
		return "Dictionary[%s, %s]" % [held.get_slice(";", 0), held.get_slice(";", 1)]
	var class_name_: String = String(info.get("class_name", ""))
	if class_name_ != "":
		return class_name_
	var type: int = int(info.get("type", TYPE_NIL))
	return type_string(type) if type != TYPE_NIL else ""


static func _return_type_of(method: Dictionary) -> String:
	var returns: Variant = method.get("return", null)
	if returns is Dictionary:
		return _type_of(returns)
	return ""


# ───────────────────────── listing members ─────────────────────────

## Everything reachable on `type_name`, its bases, and whatever engine class the
## chain of bases finally reaches. Nothing is left out on the way: a list that
## stops at the first base GATE did not compile would look complete and be half.
static func _members_of(type_name: String, reg: RefCounted,
		module: GateAST._Module = null, outside: bool = false) -> Array:
	var out: Array = []
	var taken: Dictionary = {}
	if not _builtin(type_name).is_empty():
		_from_builtin(type_name, out, taken)
		return out

	var current: String = type_name
	var seen: Dictionary = {}
	var depth: int = 0
	while current != "" and not seen.has(current):
		seen[current] = true
		var location: int = HERE if depth == 0 else PARENT
		depth += 1
		var declared: GateAST._ClassDecl = null
		if current == THIS_FILE or _is_file(current):
			declared = _as_decl(_file_module(current, module, reg))
			if declared == null:
				return out
		else:
			declared = _declaration_of(current, reg)
		if declared != null:
			_from_decl(declared, out, taken, location, outside)
			current = _base_of(current, reg, module)
			continue
		# A `class_name` in a hand-written `.gd`, then whatever it extends.
		var script_path: String = _global_class(current)
		if script_path == "":
			break
		var script: Script = ResourceLoader.load(script_path, "", ResourceLoader.CACHE_MODE_REUSE) as Script
		if script == null:
			return out
		_from_script(script, out, taken)
		current = _script_base(script, reg)

	if current != "" and ClassDB.class_exists(current):
		_from_class_db(current, out, taken)
	return out


## The file being edited, as a class the rest of this can walk.
static func _as_decl(module: GateAST._Module) -> GateAST._ClassDecl:
	if module == null:
		return null
	var here: GateAST._ClassDecl = GateAST._ClassDecl.new()
	here.members = module.members
	here.extends_type = module.extends_type
	return here


static func _base_of(type_name: String, reg: RefCounted, module: GateAST._Module = null) -> String:
	if type_name == THIS_FILE or _is_file(type_name):
		var file: GateAST._Module = _file_module(type_name, module, reg)
		if file == null or file.extends_type == null:
			return ""
		var from: String = _editing if type_name == THIS_FILE else type_name
		return _extended(file.extends_type.name, from, reg)
	var declared_in: String = String(reg.script_class_names.get(type_name,
		reg.origin.get(type_name, "")))
	return _extended(String(reg.bases.get(type_name, "")), declared_in, reg)


static func _extended(written: String, from: String, reg: RefCounted) -> String:
	if not (written.begins_with("\"") or written.begins_with("'")):
		return _bare(written)
	var split: Array = GateChecker.split_extends_path(written)
	if String(split[1]) != "":
		return ""
	var path: String = String(split[0])
	if not path.begins_with("res://"):
		if from == "":
			return ""
		path = from.get_base_dir().path_join(path).simplify_path()
	return _script_type(path, reg)


static func _script_type(path: String, reg: RefCounted) -> String:
	var source: String = _Autoload.source_of(path)
	if source == "":
		return ""
	var file: GateAST._Module = _Autoload.module(source, reg)
	if file == null:
		return ""
	var own_class: String = file.class_name_decl
	if own_class != "" and String(reg.script_class_names.get(own_class, "")) == source:
		return own_class
	return source


static func _script_base(script: Script, reg: RefCounted) -> String:
	var base: Script = script.get_base_script()
	if base == null:
		return String(script.get_instance_base_type())
	var named: String = _script_class_name(base, reg)
	return named if named != "" else _script_type(base.resource_path, reg)


static func _script_class_name(script: Script, reg: RefCounted) -> String:
	for entry in ProjectSettings.get_global_class_list():
		if String(entry["path"]) == script.resource_path:
			return String(entry["class"])
	return ""


static func _from_decl(declared: GateAST._ClassDecl, out: Array, taken: Dictionary,
		location: int, outside: bool = false) -> void:
	for member in declared.members:
		if member is GateAST._FuncDecl:
			var fd: GateAST._FuncDecl = member
			if fd.accessor or fd.name.begins_with("__") or (outside and fd.name.begins_with("_")):
				continue
			_take(out, taken, option(KIND_FUNCTION, fd.name + "(", fd.name + "(", location))
		elif member is GateAST._VarDecl:
			var vd: GateAST._VarDecl = member
			_take(out, taken, option(KIND_CONSTANT if vd.is_const else KIND_MEMBER,
				vd.name, vd.name, location))
		elif member is GateAST._SignalDecl:
			var sd: GateAST._SignalDecl = member
			_take(out, taken, option(KIND_SIGNAL, sd.name, sd.name, location))
		elif member is GateAST._EnumDecl:
			var ed: GateAST._EnumDecl = member
			if ed.name != "":
				_take(out, taken, option(KIND_ENUM, ed.name, ed.name, location))
			for key in ed.keys:
				_take(out, taken, option(KIND_CONSTANT, String(key), String(key), location))
		elif member is GateAST._ClassDecl:
			var cd: GateAST._ClassDecl = member
			_take(out, taken, option(KIND_CLASS, cd.name, cd.name, location))


static func _from_script(script: Script, out: Array, taken: Dictionary) -> void:
	for method in script.get_script_method_list():
		var name: String = String(method["name"])
		if not name.begins_with("_"):
			_take(out, taken, option(KIND_FUNCTION, name + "(", name + "(", OTHER_USER_CODE))
	for property in script.get_script_property_list():
		var name: String = String(property["name"])
		if (int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			_take(out, taken, option(KIND_MEMBER, name, name, OTHER_USER_CODE))
	for signal_ in script.get_script_signal_list():
		var name: String = String(signal_["name"])
		_take(out, taken, option(KIND_SIGNAL, name, name, OTHER_USER_CODE))
	for name in script.get_script_constant_map():
		_take(out, taken, option(KIND_CONSTANT, String(name), String(name), OTHER_USER_CODE))


## `class_get_*_list(name, false)` already walks the engine's own inheritance, so one
## pass covers `Node2D` up through `CanvasItem`, `Node` and `Object`.
static func _from_class_db(class_name_: String, out: Array, taken: Dictionary) -> void:
	for method in ClassDB.class_get_method_list(class_name_, false):
		var name: String = String(method["name"])
		if not name.begins_with("_"):
			_take(out, taken, option(KIND_FUNCTION, name + "(", name + "(", FAR))
	for property in ClassDB.class_get_property_list(class_name_, false):
		var name: String = String(property["name"])
		if not name.begins_with("_") and not name.contains("/"):
			_take(out, taken, option(KIND_MEMBER, name, name, FAR))
	for signal_ in ClassDB.class_get_signal_list(class_name_, false):
		_take(out, taken, option(KIND_SIGNAL, String(signal_["name"]),
			String(signal_["name"]), FAR))
	for constant in ClassDB.class_get_integer_constant_list(class_name_, false):
		_take(out, taken, option(KIND_CONSTANT, String(constant), String(constant), FAR))
	for enum_ in ClassDB.class_get_enum_list(class_name_, false):
		_take(out, taken, option(KIND_ENUM, String(enum_), String(enum_), FAR))


static func _take(out: Array, taken: Dictionary, entry: Dictionary) -> void:
	var key: String = String(entry["display"])
	if taken.has(key):
		return
	taken[key] = true
	out.append(entry)


# ───────────────────────── a bare identifier ─────────────────────────

static func _in_scope(module: GateAST._Module, reg: RefCounted, line: int) -> Array:
	var out: Array = []
	var taken: Dictionary = {}

	if module != null:
		var locals: Dictionary = {}
		_locals(module.members, line, locals)
		for name in locals:
			_take(out, taken, option(KIND_VARIABLE, String(name), String(name), HERE))
		# Unqualified names in a script reach its own members and everything it
		# inherits, exactly as `self.` does.
		var owner: String = module.class_name_decl if module.class_name_decl != "" else THIS_FILE
		for entry in _members_of(owner, reg, module):
			_take(out, taken, entry)

	for table in ["structs", "classes", "interfaces", "traits", "namespaces", "generics"]:
		for name in reg.get(table):
			_take(out, taken, option(KIND_CLASS, String(name), String(name), OTHER_USER_CODE))
	for name in reg.alias_decls:
		_take(out, taken, option(KIND_CLASS, String(name), String(name), OTHER_USER_CODE))
	for name in reg.script_class_names:
		_take(out, taken, option(KIND_CLASS, String(name), String(name), OTHER_USER_CODE))
	for name in _Autoload.names():
		_take(out, taken, option(KIND_CONSTANT, name, name, OTHER_USER_CODE))
	for entry in ProjectSettings.get_global_class_list():
		_take(out, taken, option(KIND_CLASS, String(entry["class"]), String(entry["class"]),
			OTHER_USER_CODE))
	for name in SHORTHANDS:
		_take(out, taken, option(KIND_CLASS, name, name, OTHER_USER_CODE))
	for name in ClassDB.get_class_list():
		if not String(name).begins_with("_"):
			_take(out, taken, option(KIND_CLASS, String(name), String(name), FAR))
	for name in GATE_KEYWORDS:
		_take(out, taken, option(KIND_PLAIN_TEXT, name, name, FAR))
	return out


## Locals and parameters visible at `line`, as name -> line.
static func _locals(members: Array, line: int, out: Dictionary) -> void:
	for member in members:
		if member is GateAST._FuncDecl:
			var decl: GateAST._FuncDecl = member
			for parameter in decl.params:
				out[(parameter as GateAST._Param).name] = decl.line
			_locals(decl.body, line, out)
		elif member is GateAST._VarDecl and (member as GateAST._VarDecl).line <= line:
			out[(member as GateAST._VarDecl).name] = (member as GateAST._VarDecl).line
		elif member is GateAST._ClassDecl:
			_locals((member as GateAST._ClassDecl).members, line, out)
		elif member is GateAST._ASTNode and "body" in member:
			_locals(member.get("body"), line, out)

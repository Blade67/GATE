@tool
extends ScriptLanguageExtension

## GATE as a script language the editor knows about.
##
## Registering this is what makes a `.gate` a file Godot tracks: it appears in the
## FileSystem dock, opens in the real script editor, and can be created from the
## Script Create dialog. It does not make a `.gate` runnable. GATE compiles to a
## `.gd` beside it and that file is the one Godot loads, instances and debugs, so
## everything here that would claim to execute a `.gate` refuses instead.

const _Script: GDScript = preload("res://addons/gate/editor/script.gd")
const _Lookup: GDScript = preload("res://addons/gate/editor/lookup.gd")
const _Complete: GDScript = preload("res://addons/gate/editor/complete.gd")
const _Warnings: GDScript = preload("res://addons/gate/editor/warnings.gd")
const _Index: GDScript = preload("res://addons/gate/editor/index.gd")

const TYPE: String = "GATEScript"
const EXTENSION: String = "gate"

## GDScript's own reserved words plus GATE's. Used by the editor for word lookup
## and by the fallback highlighter when ours is not selected.
const RESERVED: Array[String] = [
	"if", "elif", "else", "for", "while", "match", "when", "break", "continue",
	"pass", "return", "class", "class_name", "extends", "is", "in", "as", "self",
	"super", "signal", "func", "static", "const", "enum", "var", "breakpoint",
	"preload", "await", "yield", "assert", "void", "PI", "TAU", "INF", "NAN",
	"true", "false", "null", "not", "and", "or",
	"struct", "trait", "interface", "namespace", "implements", "with",
	"pub", "priv", "final", "virtual", "override", "type", "enumerate",
]

const CONTROL_FLOW: Array[String] = [
	"if", "elif", "else", "for", "while", "match", "when", "break", "continue",
	"pass", "return", "await", "yield",
]


## The engine class a `.gate`'s `extends` chain finally reaches, or empty when the
## chain cannot be followed to one.
##
## Asked by `script.gd:_get_instance_base_type()`, which is the only caller. It lives
## here because `script.gd` is one of the four addon files an export ships, so it may
## not preload the editor integration or name a compiler type: doing either drags the
## whole compiler into every exported game.
func base_type_of(text: String, path: String) -> StringName:
	var reg: RefCounted = _Index.registry()
	var module: GateAST._Module = _Index.lexed_module_for(text, path, reg)
	if module == null:
		return &""
	if module.extends_type == null:
		return &"RefCounted"
	var current: String = _Complete._extended(module.extends_type.name, path, reg)
	var seen: Dictionary = {}
	while current != "" and not seen.has(current):
		seen[current] = true
		if ClassDB.class_exists(current):
			return StringName(current)
		current = _next_base(current, reg)
	return &""


## One step up the chain: another `.gate`, a `class_name` in a hand-written `.gd`, or
## a file a base was written as a path to. A link that extends nothing is RefCounted,
## which is where GDScript's own chain ends.
func _next_base(type_name: String, reg: RefCounted) -> String:
	if type_name.begins_with("res://") or _Complete._declaration_of(type_name, reg) != null:
		var up: String = _Complete._base_of(type_name, reg)
		return up if up != "" else "RefCounted"
	var script_path: String = _Complete._global_class(type_name)
	if script_path == "":
		return ""
	var script: Script = ResourceLoader.load(script_path, "",
		ResourceLoader.CACHE_MODE_REUSE) as Script
	if script == null:
		return ""
	return _Complete._script_base(script, reg)


func _get_name() -> String:
	return "GATE"


func _get_type() -> String:
	return TYPE


func _get_extension() -> String:
	return EXTENSION


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray([EXTENSION])


## `ScriptLanguage::init()`, not GDScript's constructor. Godot refuses to call an
## unimplemented required virtual and prints an error at registration without it.
func _init() -> void:
	pass


func _finish() -> void:
	pass


func _get_reserved_words() -> PackedStringArray:
	return PackedStringArray(RESERVED)


func _is_control_flow_keyword(keyword: String) -> bool:
	return CONTROL_FLOW.has(keyword)


func _get_comment_delimiters() -> PackedStringArray:
	return PackedStringArray(["#"])


func _get_doc_comment_delimiters() -> PackedStringArray:
	return PackedStringArray(["##"])


func _get_string_delimiters() -> PackedStringArray:
	return PackedStringArray(["\" \"", "' '"])


func _create_script() -> Object:
	return _Script.new()


func _make_template(template: String, class_name_: String, base_class_name: String) -> Script:
	var text: String = template
	if text.strip_edges() == "":
		text = _template_body()
	text = text.replace("_BASE_", base_class_name)
	text = text.replace("_CLASS_", class_name_)
	text = text.replace("_TS_", "\t")
	var made: Script = _Script.new()
	made.set_source_code(text)
	return made


func _template_body() -> String:
	return "extends _BASE_\n\n\nfunc _ready() -> void:\n_TS_pass\n"


func _is_using_templates() -> bool:
	return true


func _get_built_in_templates(object: StringName) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append({
		"inherit": String(object),
		"name": "Default",
		"description": "An empty GATE script. The compiled .gd appears beside it.",
		"content": _template_body(),
		"id": 0,
		"origin": 0,
	})
	out.append({
		"inherit": String(object),
		"name": "Typed fields",
		"description": "Shows GATE's type-first declarations.",
		"content": "extends _BASE_\n\nint hp = 100\nfloat speed = 240.0\n_BASE_? target\n\n"
			+ "func _ready() -> void:\n_TS_pass\n",
		"id": 1,
		"origin": 0,
	})
	return out


## Errors the editor underlines while you type. The lexer, and nothing after it.
##
## Running the parser here was tried and removed. The parser needs to know which
## names in the project are generics before it can tell `Pool<Bullet>.new()` from a
## comparison, and it gets that from the build's registry - which this does not have,
## because it is handed one file's text and nothing else. Without it, a correct file
## using a generic declared anywhere else reports "unexpected token '.'". A wrong
## squiggle on right code is worse than no squiggle, so the parser stays out.
##
## The lexer has no cross-file knowledge to be missing. What it reports - an
## unterminated string, inconsistent indentation, a character that cannot start a
## token - is true of the text in front of it or of nothing. The corpus sweep
## compiles 2,204 real scripts with zero failures, so it has no false positive to
## give on real code. It costs about 18 ms per thousand lines, once per typing pause.
##
## Everything past that - unknown types, null analysis, the superset checks - needs
## the whole project and is left to the build, which already pushes its errors to the
## Output panel with the `.gate` line on them.
func _validate(script: String, path: String, validate_functions: bool, validate_errors: bool,
		validate_warnings: bool, validate_safe_lines: bool) -> Dictionary:
	var text: String = script.replace("\r\n", "\n").replace("\r", "\n")
	var diagnostics: GateDiagnostics = GateDiagnostics.new()
	diagnostics.file = path
	var tokens: Array = GateLexer.new().tokenize(text, diagnostics)

	var errors: Array = []
	for item in diagnostics.items:
		if item.level != GateDiagnostics._Level.ERROR:
			continue
		errors.append({
			"line": item.line,
			"column": item.col,
			"message": item.message,
			"path": path,
		})
	if not errors.is_empty():
		var first: int = int(errors[0]["line"])
		for item in diagnostics.items:
			if item.level == GateDiagnostics._Level.WARNING and item.line < first 					and item.message.begins_with("string literal spans more than one line"):
				errors = [{
					"line": item.line,
					"column": item.col,
					"message": "string is not closed on this line",
					"path": path,
				}]
				break
	var warnings: Array = []
	if validate_warnings and errors.is_empty():
		warnings = _Warnings.new().collect(path, tokens)
	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"functions": _functions_in(tokens) if validate_functions else PackedStringArray(),
		"safe_lines": PackedInt32Array(),
	}


## Feeds the script editor's function list, from the tokens `_validate` has already
## lexed rather than from the lines.
##
## A line scan cannot see the modifiers GATE allows in front of `func`, and cannot
## tell a `func` written inside a block string from a declaration. The lexer settles
## both and has already run, so this is one pass over an array. The parser would
## settle them too and costs a parse, which is most of this callback's budget.
##
## The modifiers come from `GateParser.MEMBER_MODIFIERS` rather than a copy of it, so
## a modifier added to the language reaches this list without anyone remembering to.
func _functions_in(tokens: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var count: int = tokens.size()
	var i: int = 0
	var at_start: bool = true
	while i < count:
		var token: GateLexer._Token = tokens[i]
		i += 1
		if token.type == GateLexer._T.COMMENT:
			continue
		if token.type == GateLexer._T.NEWLINE or token.type == GateLexer._T.INDENT \
				or token.type == GateLexer._T.DEDENT:
			at_start = true
			continue
		if not at_start:
			continue
		if token.type == GateLexer._T.ANNOTATION:
			i = _past_arguments(tokens, i)
			continue
		if token.type != GateLexer._T.KEYWORD:
			at_start = false
			continue
		if GateParser.MEMBER_MODIFIERS.has(token.value):
			continue
		if token.value != "func" and token.value != "operator":
			at_start = false
			continue
		var name: String = _declared_name(tokens, i, token.value == "operator")
		if name != "":
			out.append("%s:%d" % [name, token.line])
		at_start = false
	return out


## Past an annotation's bracketed arguments, when it has any. What follows is still
## the start of the declaration the annotation is attached to.
func _past_arguments(tokens: Array, from: int) -> int:
	var i: int = _past_comments(tokens, from)
	if i >= tokens.size() or not (tokens[i] as GateLexer._Token).is_op("("):
		return from
	var depth: int = 0
	while i < tokens.size():
		var token: GateLexer._Token = tokens[i]
		i += 1
		if token.is_op("("):
			depth += 1
		elif token.is_op(")"):
			depth -= 1
			if depth == 0:
				break
	return i


## The name a `func` declares, or the symbol an `operator` overloads. Empty for
## `func (`, which is a lambda and has no name to list.
func _declared_name(tokens: Array, from: int, symbol: bool) -> String:
	var i: int = _past_comments(tokens, from)
	if i >= tokens.size():
		return ""
	var token: GateLexer._Token = tokens[i]
	if symbol:
		return token.value if token.type == GateLexer._T.OP else ""
	if token.type == GateLexer._T.IDENT or token.type == GateLexer._T.KEYWORD:
		return token.value
	return ""


func _past_comments(tokens: Array, from: int) -> int:
	var i: int = from
	while i < tokens.size() and (tokens[i] as GateLexer._Token).type == GateLexer._T.COMMENT:
		i += 1
	return i


## Where GATE used to say no.
##
## A `.gate` still cannot be the script on a node: it never instantiates, and Godot
## drops it. What changed is that the Scene dock's Attach Script dialog no longer
## has to be refused to keep that true. `create_dialog.gd` watches the dialog, has
## the `.gate` it writes compiled, and puts the generated `.gd` on the node, so the
## node runs the `.gd` exactly as it did before. Nothing else about a path is wrong,
## so nothing is refused here.
func _validate_path(path: String) -> String:
	return ""


func _find_function(function: String, code: String) -> int:
	var lines: PackedStringArray = code.split("\n")
	for i in lines.size():
		var text: String = lines[i].strip_edges()
		if text.begins_with("func " + function) or text.begins_with("static func " + function):
			return i + 1
	return -1


func _make_function(class_name_: String, function_name: String, function_args: PackedStringArray) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for arg in function_args:
		var split: PackedStringArray = arg.split(":")
		parts.append(split[0].strip_edges() if split.size() == 1
			else "%s: %s" % [split[0].strip_edges(), split[1].strip_edges()])
	return "\n\nfunc %s(%s) -> void:\n\tpass\n" % [function_name, ", ".join(parts)]


func _can_make_function() -> bool:
	return true


func _has_named_classes() -> bool:
	return false


func _supports_builtin_mode() -> bool:
	return false


func _supports_documentation() -> bool:
	return false


func _can_inherit_from_file() -> bool:
	return true


func _preferred_file_name_casing() -> int:
	return 2


func _open_in_external_editor(script: Script, line: int, column: int) -> Error:
	return ERR_UNAVAILABLE


func _overrides_external_editor() -> bool:
	return false


## Autocompletion. See `complete.gd`: it answers from GATE's registry, the parsed
## file and ClassDB, and returns nothing at all rather than a list about the wrong
## object when it cannot establish what is left of the dot.
func _complete_code(code: String, path: String, owner: Object) -> Dictionary:
	return _Complete.complete(code, path, owner)


## Ctrl-click and F1. See `lookup.gd` for what it can and cannot answer; a failed
## lookup is what stops the editor underlining the word, so returning nothing is a
## real answer rather than a gap.
func _lookup_code(code: String, symbol: String, path: String, owner: Object) -> Dictionary:
	return _Lookup.find(code, symbol, path)


func _auto_indent_code(code: String, from_line: int, to_line: int) -> String:
	return code


func _add_global_constant(name: StringName, value: Variant) -> void:
	pass


func _add_named_global_constant(name: StringName, value: Variant) -> void:
	pass


func _remove_named_global_constant(name: StringName) -> void:
	pass


func _thread_enter() -> void:
	pass


func _thread_exit() -> void:
	pass


func _debug_get_error() -> String:
	return ""


func _debug_get_stack_level_count() -> int:
	return 0


func _debug_get_stack_level_line(level: int) -> int:
	return 0


func _debug_get_stack_level_function(level: int) -> String:
	return ""


func _debug_get_stack_level_source(level: int) -> String:
	return ""


func _debug_get_stack_level_locals(level: int, max_subitems: int, max_depth: int) -> Dictionary:
	return {}


func _debug_get_stack_level_members(level: int, max_subitems: int, max_depth: int) -> Dictionary:
	return {}


func _debug_get_stack_level_instance(level: int) -> int:
	return 0


func _debug_get_globals(max_subitems: int, max_depth: int) -> Dictionary:
	return {}


func _debug_parse_stack_level_expression(level: int, expression: String, max_subitems: int,
		max_depth: int) -> String:
	return ""


func _debug_get_current_stack_info() -> Array[Dictionary]:
	return []


func _reload_all_scripts() -> void:
	pass


func _reload_scripts(scripts: Array, soft_reload: bool) -> void:
	pass


func _reload_tool_script(script: Script, soft_reload: bool) -> void:
	pass


func _get_public_functions() -> Array[Dictionary]:
	return []


func _get_public_constants() -> Dictionary:
	return {}


func _get_public_annotations() -> Array[Dictionary]:
	return []


func _profiling_start() -> void:
	pass


func _profiling_stop() -> void:
	pass


func _profiling_set_save_native_calls(enable: bool) -> void:
	pass


func _profiling_get_accumulated_data(info_array: int, info_max: int) -> int:
	return 0


func _profiling_get_frame_data(info_array: int, info_max: int) -> int:
	return 0


func _frame() -> void:
	pass


## False on purpose. A `.gate` that declares `class_name Foo` compiles to a `.gd`
## that declares it too, and that file is the one Godot must resolve the name to.
## Claiming it here would register the name twice, against two different files.
func _handles_global_class_type(type: String) -> bool:
	return false


func _get_global_class_name(path: String) -> Dictionary:
	return {"name": "", "base_type": "", "icon_path": "", "is_abstract": false, "is_tool": false}

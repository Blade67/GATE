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
const _Registry: GDScript = preload("res://addons/gate/editor/registry.gd")
const _Lookup: GDScript = preload("res://addons/gate/editor/lookup.gd")
const _Complete: GDScript = preload("res://addons/gate/editor/complete.gd")
const _Warnings: GDScript = preload("res://addons/gate/editor/warnings.gd")

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
		"functions": _functions_in(text) if validate_functions else PackedStringArray(),
		"safe_lines": PackedInt32Array(),
	}


## Feeds the script editor's function list. A line scan rather than the AST, for the
## same reason `_validate` does not parse.
func _functions_in(text: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var lines: PackedStringArray = text.split("\n")
	for i in lines.size():
		var line: String = lines[i].strip_edges()
		var body: String = line.trim_prefix("static ")
		if not body.begins_with("func "):
			continue
		var name: String = body.substr(5).get_slice("(", 0).strip_edges()
		if name != "":
			out.append("%s:%d" % [name, i + 1])
	return out


## The one place GATE says no.
##
## The Scene dock's Attach Script dialog puts the script it creates on a node, and a
## `.gate` cannot be that script: it never instantiates and has no methods, so the
## node would look right in the editor and do nothing at run time. The dialog asks
## here before enabling its OK button and shows what comes back, so refusing is both
## the block and the explanation.
func _validate_path(path: String) -> String:
	if _Registry.is_attaching():
		return ("GATE scripts cannot be attached to a node. Create the .gate first, "
			+ "then attach the .gd GATE compiles beside it.")
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

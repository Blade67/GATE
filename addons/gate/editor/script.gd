@tool
extends ScriptExtension

## A `.gate` file, as the editor sees it.
##
## It is a Script so the script editor will open it, and one question more: what its
## `extends` chain finally reaches. It still cannot instantiate and still reports no
## members. The runnable half of a `.gate` is the `.gd` GATE writes beside it, and
## that file is an ordinary GDScript.
##
## Godot never asks a `.gate` for its method list, its members, its constants, its
## properties, its signals or a member's line, so those answers stay empty. The
## script editor's method list comes from `language.gd:_validate` instead.

const _Registry: GDScript = preload("res://addons/gate/editor/registry.gd")

var _source: String = ""


func _init() -> void:
	_Registry.script_made()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_Registry.script_gone()


## Never returns null. Godot dereferences this without checking, so a GATEScript
## outliving the plugin - disable it with a `.gate` open, or reopen a project whose
## layout restores one - used to segfault the editor here.
func _get_language() -> ScriptLanguage:
	return _Registry.language()


func _has_source_code() -> bool:
	return true


func _get_source_code() -> String:
	return _source


func _set_source_code(code: String) -> void:
	_source = code


func _reload(keep_state: bool) -> Error:
	return OK


func _editor_can_reload_from_file() -> bool:
	return true


## False, whatever `_get_instance_base_type()` answers. Answering questions about a
## `.gate` must never make one runnable: the `.gd` beside it is the runnable half.
func _can_instantiate() -> bool:
	return false


func _is_valid() -> bool:
	return true


func _is_tool() -> bool:
	return false


func _is_abstract() -> bool:
	return false


func _get_base_script() -> Script:
	return null


## Empty even when the file declares a `class_name`. Godot resolves a global class
## before it asks the language, so a `.gate` holding the name would shadow the `.gd`
## that actually runs. That is what made Ctrl-click open the generated file once.
func _get_global_name() -> StringName:
	return &""


func _inherits_script(script: Script) -> bool:
	return false


## The engine class at the root of the `extends` chain.
##
## The Scene dock asks this and nothing else before it lets a node be dragged into
## the file: an empty answer fails `ClassDB.is_parent_class("", "Node")` and the drop
## is refused. The answer comes from the live buffer and the project's registry, the
## way completion and lookup answer.
##
## Empty whenever the chain cannot be followed all the way to an engine class, text
## the lexer refuses included. This fires while you type, so a half-typed file is the
## normal state, and a base type nothing can back up is worse than none.
func _get_instance_base_type() -> StringName:
	if not _Registry.is_active():
		return &""
	var language: ScriptLanguage = _Registry.language()
	if language == null:
		return &""
	var answer: Variant = language.call("base_type_of", _source, resource_path)
	return answer if answer is StringName else &""


func _instance_create(for_object: Object) -> int:
	return 0


func _placeholder_instance_create(for_object: Object) -> int:
	return 0


func _placeholder_erased(placeholder: int) -> void:
	pass


func _instance_has(object: Object) -> bool:
	return false


func _is_placeholder_fallback_enabled() -> bool:
	return false


func _get_doc_class_name() -> StringName:
	return &""


func _get_documentation() -> Array[Dictionary]:
	return []


func _get_class_icon_path() -> String:
	return ""


func _has_method(method: StringName) -> bool:
	return false


func _has_static_method(method: StringName) -> bool:
	return false


func _get_script_method_argument_count(method: StringName) -> Variant:
	return null


func _get_method_info(method: StringName) -> Dictionary:
	return {}


func _has_script_signal(signal_: StringName) -> bool:
	return false


func _get_script_signal_list() -> Array[Dictionary]:
	return []


func _has_property_default_value(property: StringName) -> bool:
	return false


func _get_property_default_value(property: StringName) -> Variant:
	return null


func _update_exports() -> void:
	pass


func _get_script_method_list() -> Array[Dictionary]:
	return []


func _get_script_property_list() -> Array[Dictionary]:
	return []


func _get_member_line(member: StringName) -> int:
	return -1


func _get_constants() -> Dictionary:
	return {}


func _get_members() -> Array[StringName]:
	return []


func _get_rpc_config() -> Variant:
	return {}

@tool
extends ScriptExtension

## A `.gate` file, as the editor sees it.
##
## It is a Script so the script editor will open it, and nothing more: it cannot
## instantiate, has no members and reports no methods. The runnable half of a `.gate`
## is the `.gd` GATE writes beside it, and that file is an ordinary GDScript.

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


func _get_global_name() -> StringName:
	return &""


func _inherits_script(script: Script) -> bool:
	return false


func _get_instance_base_type() -> StringName:
	return &""


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

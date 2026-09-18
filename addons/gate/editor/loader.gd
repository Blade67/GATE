@tool
extends ResourceFormatLoader
class_name GateScriptLoader

## Makes `res://x.gate` load as a script instead of failing.
##
## `class_name` is not decoration here. Godot rebuilds its custom loader list by
## dropping every script-backed loader and re-adding the ones it finds in the global
## class list, so a loader without a global name disappears the first time that
## happens. The cost is that this class is constructed even when the plugin is
## disabled and in an exported game, which is why every entry point below is inert
## until the plugin says otherwise.

const _Registry: GDScript = preload("res://addons/gate/editor/registry.gd")
const _Script: GDScript = preload("res://addons/gate/editor/script.gd")


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["gate"])


func _handles_type(type: StringName) -> bool:
	return _Registry.is_active() and (type == &"Script" or type == &"GATEScript" or type == &"Resource")


## The FileSystem dock takes the file's type from here. Reporting nothing while the
## plugin is off is what puts a `.gate` back where it was before GATE was installed:
## a file Godot does not track, rather than a broken script.
func _get_resource_type(path: String) -> String:
	if _Registry.is_active() and path.get_extension().to_lower() == "gate":
		return "GATEScript"
	return ""


func _get_resource_script_class(path: String) -> String:
	return ""


func _exists(path: String) -> bool:
	return _Registry.is_active() and FileAccess.file_exists(path)


func _get_dependencies(path: String, add_types: bool) -> PackedStringArray:
	return PackedStringArray()


func _load(path: String, original_path: String, use_sub_threads: bool, cache_mode: int) -> Variant:
	if not _Registry.is_active():
		return ERR_UNAVAILABLE
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ERR_FILE_CANT_OPEN
	var text: String = file.get_as_text()
	file.close()
	var made: ScriptExtension = _Script.new()
	made.set_source_code(text)
	made.take_over_path(path)
	return made

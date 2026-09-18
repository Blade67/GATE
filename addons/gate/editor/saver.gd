@tool
extends ResourceFormatSaver
class_name GateScriptSaver

## Writes a `.gate` back to disk when the script editor saves it.
##
## Like the loader, this needs `class_name` to survive Godot rebuilding its custom
## saver list, and is inert while the plugin is off for the same reason.

const _Registry: GDScript = preload("res://addons/gate/editor/registry.gd")
const _Script: GDScript = preload("res://addons/gate/editor/script.gd")


func _recognize(resource: Resource) -> bool:
	return _Registry.is_active() and resource != null and resource.get_script() == _Script


func _get_recognized_extensions(resource: Resource) -> PackedStringArray:
	if _recognize(resource):
		return PackedStringArray(["gate"])
	return PackedStringArray()


func _recognize_path(resource: Resource, path: String) -> bool:
	return _recognize(resource) and path.get_extension().to_lower() == "gate"


func _save(resource: Resource, path: String, flags: int) -> Error:
	if not _recognize(resource):
		return ERR_UNAVAILABLE
	var text: String = (resource as Script).source_code.replace("\r\n", "\n")
	if _uses_crlf(path):
		text = text.replace("\n", "\r\n")
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ERR_FILE_CANT_WRITE
	file.store_string(text)
	file.close()
	return OK


static func _uses_crlf(path: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var head: PackedByteArray = file.get_buffer(mini(file.get_length(), 65536))
	file.close()
	var at: int = head.find(10)
	return at > 0 and head[at - 1] == 13


func _set_uid(path: String, uid: int) -> Error:
	return ERR_UNAVAILABLE

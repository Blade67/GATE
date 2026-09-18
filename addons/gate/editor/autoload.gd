@tool
extends RefCounted

## What a global autoload's name stands for, read from the project settings.
##
## Completion and Ctrl-click treat a name they cannot type as unknown. An autoload
## is not unknown: `autoload/<name>` says which script or scene it is, so its
## members are as knowable as a declared type's.

const _Index: GDScript = preload("res://addons/gate/editor/index.gd")

const MAX_SCENE_DEPTH: int = 8

static var _parsed: Dictionary = {}


static func resolve(name: String) -> Dictionary:
	var key: String = "autoload/" + name
	if not name.is_valid_identifier() or not ProjectSettings.has_setting(key):
		return {}
	var value: String = String(ProjectSettings.get_setting(key))
	if not value.begins_with("*"):
		return {}
	var path: String = _path(value.substr(1))
	var extension: String = path.get_extension().to_lower()
	if extension == "gd" or extension == "gate":
		return {"script": source_of(path), "native": ""}
	if extension == "tscn" or extension == "scn":
		return _scene_root(path, 0)
	return {}


static func names() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for property in ProjectSettings.get_property_list():
		var key: String = String(property["name"])
		if key.begins_with("autoload/") and String(ProjectSettings.get_setting(key)).begins_with("*"):
			out.append(key.substr(9))
	return out


static func source_of(path: String) -> String:
	if path.get_extension().to_lower() == "gd":
		var gate: String = path.get_basename() + ".gate"
		if FileAccess.file_exists(gate):
			return gate
	return path if FileAccess.file_exists(path) else ""


static func module(path: String, reg: RefCounted) -> GateAST._Module:
	if not FileAccess.file_exists(path):
		return null
	var text: String = FileAccess.get_file_as_string(path)
	var hit: Array = _parsed.get(path, [])
	if not hit.is_empty() and int(hit[0]) == reg.get_instance_id() and String(hit[1]) == text:
		return hit[2]
	var parsed: GateAST._Module = _Index.module_for(text, path, reg)
	_parsed[path] = [reg.get_instance_id(), text, parsed]
	return parsed


static func _path(value: String) -> String:
	if not value.begins_with("uid://"):
		return value
	var id: int = ResourceUID.text_to_id(value)
	if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
		return ""
	return ResourceUID.get_id_path(id)


static func _scene_root(path: String, depth: int) -> Dictionary:
	if depth > MAX_SCENE_DEPTH or not FileAccess.file_exists(path):
		return {}
	if path.get_extension().to_lower() != "tscn":
		return _binary_scene_root(path)
	var resources: Dictionary = {}
	var native: String = ""
	var script_id: String = ""
	var instance_id: String = ""
	var in_root: bool = false
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var line: String = raw.strip_edges()
		if line.begins_with("["):
			if in_root:
				break
			if line.begins_with("[ext_resource "):
				var where: String = _attribute(line, "path")
				if where == "":
					where = _path(_attribute(line, "uid"))
				resources[_attribute(line, "id")] = where
			elif line.begins_with("[node ") and not line.contains(" parent="):
				in_root = true
				native = _attribute(line, "type")
				instance_id = _resource_id(line, "instance=")
		elif in_root and line.begins_with("script ="):
			script_id = _resource_id(line, "ExtResource(")
	if script_id != "":
		return {"script": source_of(String(resources.get(script_id, ""))), "native": native}
	if instance_id != "":
		return _scene_root(String(resources.get(instance_id, "")), depth + 1)
	if native != "":
		return {"script": "", "native": native}
	return {}


static func _binary_scene_root(path: String) -> Dictionary:
	var scene: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE) as PackedScene
	if scene == null or scene.get_state().get_node_count() == 0:
		return {}
	var state: SceneState = scene.get_state()
	for i in state.get_node_property_count(0):
		if state.get_node_property_name(0, i) == &"script":
			var script: Script = state.get_node_property_value(0, i) as Script
			if script != null:
				return {"script": source_of(script.resource_path), "native": String(state.get_node_type(0))}
	return {"script": "", "native": String(state.get_node_type(0))}


static func _attribute(line: String, key: String) -> String:
	var marker: String = " " + key + "=\""
	var at: int = line.find(marker)
	if at < 0:
		return ""
	var start: int = at + marker.length()
	var end: int = line.find("\"", start)
	return line.substr(start, end - start) if end >= 0 else ""


static func _resource_id(line: String, marker: String) -> String:
	var at: int = line.find(marker)
	if at < 0:
		return ""
	var open: int = line.find("\"", at)
	var close: int = line.find("\"", open + 1) if open >= 0 else -1
	return line.substr(open + 1, close - open - 1) if close > open else ""

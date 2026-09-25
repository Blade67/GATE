@tool
class_name GateFeatures
extends RefCounted

## Every GATE flag, in one table. Project Settings registration, the value the
## compiler reads, and the build-cache key all come from this - a new flag is one
## row here plus the code that checks it.

const GROUP_FEATURES := "gate/features"
const GROUP_EXPERIMENTS := "gate/experiments"

const ROWS := [
	{"id": "shorthand_types", "group": GROUP_FEATURES, "default": true},
	{"id": "type_names_as_values", "group": GROUP_FEATURES, "default": false},
	{"id": "type_first", "group": GROUP_FEATURES, "default": true},
]


static func _row(id: String) -> Dictionary:
	for row in ROWS:
		if row["id"] == id:
			return row
	return {}


static func setting_path(id: String) -> String:
	var row: Dictionary = _row(id)
	return "%s/%s" % [row["group"], id] if not row.is_empty() else ""


static func default_of(id: String) -> bool:
	return bool(_row(id).get("default", false))


## A default is never written to project.godot: set_initial_value only tells Godot
## what "unchanged" means, and this never calls ProjectSettings.save() itself.
static func register_settings() -> void:
	for row in ROWS:
		var key: String = setting_path(row["id"])
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, row["default"])
		ProjectSettings.set_initial_value(key, row["default"])
		ProjectSettings.add_property_info({"name": key, "type": TYPE_BOOL})
		ProjectSettings.set_as_basic(key, row["group"] == GROUP_FEATURES)


static var _current: Dictionary = {}


## Read once, at the start of a compile, so parsing, checking and emitting one
## file always agree, whatever else touches Project Settings in between.
static func snapshot() -> void:
	_current = {}
	for row in ROWS:
		var key: String = setting_path(row["id"])
		_current[row["id"]] = bool(ProjectSettings.get_setting(key, row["default"]))


static func enabled(id: String) -> bool:
	if _current.has(id):
		return bool(_current[id])
	return default_of(id)


## `id=1,id=2,...` in table order, read fresh: the build-cache key. Any flag
## flipping changes this string, so it invalidates every file's cache entry the
## same way a registry change does.
static func cache_key() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for row in ROWS:
		var key: String = setting_path(row["id"])
		var v: bool = bool(ProjectSettings.get_setting(key, row["default"]))
		parts.append("%s=%s" % [row["id"], "1" if v else "0"])
	return ",".join(parts)

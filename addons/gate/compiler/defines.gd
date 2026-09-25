@tool
class_name GateDefines
extends RefCounted

## The `@if` symbol table, read from Godot itself at compile time.

const DEFINES_SETTING: String = "gate/compiler/defines"

## Probed individually with OS.has_feature(), since Godot has no API that lists
## every active tag. DEBUG, RELEASE and EDITOR are computed separately below.
const TAGS: PackedStringArray = [
	"windows", "macos", "linux", "bsd", "android", "ios", "web", "uwp",
	"pc", "mobile",
	"x86_32", "x86_64", "arm32", "arm64", "rv64", "ppc32", "ppc64", "universal",
]


static func tag_symbol(tag: String) -> String:
	var up: String = tag.to_upper()
	var out: String = ""
	for i in up.length():
		var ch: String = up[i]
		var is_alnum: bool = (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9")
		out += ch if is_alnum else "_"
	return out


static func table(overrides: Dictionary = {}) -> Dictionary:
	var t: Dictionary = {}
	t["DEBUG"] = OS.is_debug_build()
	t["RELEASE"] = not OS.is_debug_build()
	t["EDITOR"] = Engine.is_editor_hint()
	t["EXPORT"] = false
	for tag in TAGS:
		var sym: String = tag_symbol(tag)
		if sym == "" or (sym[0] >= "0" and sym[0] <= "9"):
			continue
		t[sym] = OS.has_feature(tag)
	var vi: Dictionary = Engine.get_version_info()
	t["GODOT_VERSION"] = [int(vi.get("major", 0)), int(vi.get("minor", 0)), int(vi.get("patch", 0))]
	if ProjectSettings.has_setting(DEFINES_SETTING):
		var declared: PackedStringArray = ProjectSettings.get_setting(DEFINES_SETTING, PackedStringArray())
		for name in declared:
			if not t.has(String(name)):
				t[String(name)] = false
	for key in overrides:
		t[String(key)] = overrides[key]
	return t


static func overrides_from_features(features: PackedStringArray) -> Dictionary:
	var o: Dictionary = {}
	o["EXPORT"] = true
	o["EDITOR"] = false
	var is_debug: bool = features.has("debug")
	o["DEBUG"] = is_debug
	o["RELEASE"] = not is_debug
	for feat in features:
		var sym: String = tag_symbol(String(feat))
		if sym == "" or (sym[0] >= "0" and sym[0] <= "9"):
			continue
		o[sym] = true
	return o


static func snapshot_key(t: Dictionary) -> String:
	var names: Array = t.keys()
	names.sort()
	var parts: PackedStringArray = PackedStringArray()
	for name in names:
		var v = t[name]
		if name == "GODOT_VERSION":
			var strs: PackedStringArray = PackedStringArray()
			for n in (v as Array):
				strs.append(str(n))
			parts.append("GODOT_VERSION=" + ".".join(strs))
		else:
			parts.append("%s=%s" % [name, "1" if v else "0"])
	return ";".join(parts)

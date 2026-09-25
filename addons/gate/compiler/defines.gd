@tool
class_name GateDefines
extends RefCounted

## The `@if` symbol table, read from Godot itself at compile time.

const DEFINES_SETTING: String = "gate/compiler/defines"

## Where `table()` and `table_for_export()` stash a problem found while parsing
## `gate/compiler/defines`. `@@` can never start an identifier, so it cannot collide.
const ERRORS_KEY: String = "@@errors"

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


## Every TAGS symbol, set by asking `probe` about its lowercase name. Shared by
## `table()` and `table_for_export()`, so the two never disagree on which exist.
static func _tags(probe: Callable) -> Dictionary:
	var out: Dictionary = {}
	for tag in TAGS:
		var sym: String = tag_symbol(tag)
		if sym == "" or (sym[0] >= "0" and sym[0] <= "9"):
			continue
		out[sym] = bool(probe.call(tag))
	return out


## Reads `gate/compiler/defines` defensively: a hand-edited project.godot holding a
## String where a list belongs throws from a typed getter before the loud unknown-symbol
## error can fire. A wrong-typed setting is reported and treated as absent.
static func _read_declared_defines(errors: Array) -> PackedStringArray:
	if not ProjectSettings.has_setting(DEFINES_SETTING):
		return PackedStringArray()
	var raw = ProjectSettings.get_setting(DEFINES_SETTING)
	if raw is PackedStringArray:
		return raw
	if raw is Array:
		var out: PackedStringArray = PackedStringArray()
		for v in raw:
			out.append(str(v))
		return out
	errors.append(("gate/compiler/defines is set to something other than a list of names; "
		+ "it is being ignored"))
	return PackedStringArray()


## A plain identifier, the shape the condition tokenizer accepts for a symbol, so a
## declared name is always something a real `@if` could legally name.
static func _is_identifier(name: String) -> bool:
	if name == "":
		return false
	var c0: String = name[0]
	if not ((c0 >= "A" and c0 <= "Z") or (c0 >= "a" and c0 <= "z") or c0 == "_"):
		return false
	for i in range(1, name.length()):
		var c: String = name[i]
		var ok_char: bool = ((c >= "A" and c <= "Z") or (c >= "a" and c <= "z")
			or (c >= "0" and c <= "9") or c == "_")
		if not ok_char:
			return false
	return true


## Parses `gate/compiler/defines` into `table` and `errors`. An entry is `NAME` or
## `NAME=VALUE` with `VALUE` one of `1`, `true`, `0`, `false`. Anything else is an
## error rather than a guess, including a name already built in or declared twice by
## this same setting: a typo must not silently change what ships.
static func _parse_defines(table: Dictionary, errors: Array) -> void:
	var reserved: Dictionary = table.duplicate()
	var declared: Dictionary = {}
	for raw in _read_declared_defines(errors):
		var entry: String = String(raw).strip_edges()
		var eq: int = entry.find("=")
		var name: String
		var val_text: String
		if eq < 0:
			name = entry
			val_text = ""
		else:
			name = entry.substr(0, eq).strip_edges()
			val_text = entry.substr(eq + 1).strip_edges()
		if name == "":
			errors.append("gate/compiler/defines has an entry with no name: '%s'" % entry)
			continue
		if not _is_identifier(name):
			errors.append(("gate/compiler/defines entry '%s' names '%s', which is not a plain "
				+ "identifier") % [entry, name])
			continue
		if reserved.has(name):
			errors.append(("gate/compiler/defines entry '%s' names '%s', which is already a "
				+ "built-in symbol and cannot be redeclared") % [entry, name])
			continue
		if declared.has(name):
			errors.append(("gate/compiler/defines entry '%s' names '%s', which this same "
				+ "setting already declared once") % [entry, name])
			continue
		var val: bool = true
		if eq >= 0:
			if val_text == "1" or val_text == "true":
				val = true
			elif val_text == "0" or val_text == "false":
				val = false
			else:
				errors.append(("gate/compiler/defines entry '%s' has a value that is none of "
					+ "1, true, 0 or false: '%s'") % [entry, val_text])
				continue
		declared[name] = true
		table[name] = val


## `overrides` wins over everything, so the export hook can pin a value without
## depending on the machine. `gate/compiler/defines` sets the rest.
static func table(overrides: Dictionary = {}) -> Dictionary:
	var t: Dictionary = {}
	t["DEBUG"] = OS.is_debug_build()
	t["RELEASE"] = not OS.is_debug_build()
	t["EDITOR"] = Engine.is_editor_hint()
	t["EXPORT"] = false
	t.merge(_tags(func(tag: String) -> bool: return OS.has_feature(tag)), true)
	var vi: Dictionary = Engine.get_version_info()
	t["GODOT_VERSION"] = [int(vi.get("major", 0)), int(vi.get("minor", 0)), int(vi.get("patch", 0))]
	var errors: Array = []
	_parse_defines(t, errors)
	if not errors.is_empty():
		t[ERRORS_KEY] = errors
	for key in overrides:
		t[String(key)] = overrides[key]
	return t


## The table an export recompile judges every `@if` against. Built from scratch for the
## preset, never from `OS.has_feature()` on the exporting machine: composing overrides
## on the host's own table can only turn a tag ON, so a Windows host exporting for
## Android shipped its `@if WINDOWS` blocks.
static func table_for_export(features: PackedStringArray) -> Dictionary:
	var t: Dictionary = {}
	var is_debug: bool = features.has("debug")
	t["DEBUG"] = is_debug
	t["RELEASE"] = not is_debug
	t["EDITOR"] = false
	t["EXPORT"] = true
	t.merge(_tags(func(tag: String) -> bool: return features.has(tag)), true)
	var vi: Dictionary = Engine.get_version_info()
	t["GODOT_VERSION"] = [int(vi.get("major", 0)), int(vi.get("minor", 0)), int(vi.get("patch", 0))]
	var errors: Array = []
	_parse_defines(t, errors)
	if not errors.is_empty():
		t[ERRORS_KEY] = errors
	for feat in features:
		var sym: String = tag_symbol(String(feat))
		if sym == "" or (sym[0] >= "0" and sym[0] <= "9"):
			continue
		t[sym] = true
	return t


static func snapshot_key(t: Dictionary) -> String:
	var names: Array = t.keys()
	names.sort()
	var parts: PackedStringArray = PackedStringArray()
	for name in names:
		if name == ERRORS_KEY:
			continue
		var v = t[name]
		if name == "GODOT_VERSION":
			var strs: PackedStringArray = PackedStringArray()
			for n in (v as Array):
				strs.append(str(n))
			parts.append("GODOT_VERSION=" + ".".join(strs))
		else:
			parts.append("%s=%s" % [name, "1" if v else "0"])
	return ";".join(parts)

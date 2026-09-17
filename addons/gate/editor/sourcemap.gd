@tool
extends RefCounted

## The `.gd.map` GATE writes beside every output, read both ways.
##
## `source_follow.gd` already reads it one way, to name the `.gate` line behind a
## generated one in a toast. Breakpoints need the other way as well: the user points
## at a `.gate` line and the debugger only knows `.gd` lines.
##
## Both directions refuse a map they cannot prove current. The map records the
## `.gate` it came from and the SHA-256 of both files, so a build that failed, or an
## output edited by hand, leaves a map that no longer describes what is on disk - and
## a breakpoint placed from a stale map stops on the wrong line, which is worse than
## not stopping at all.

const NOTHING: Dictionary = {}


## The map for a generated `.gd`, or {} if it cannot be trusted.
static func read(gd_path: String) -> Dictionary:
	if gd_path.get_extension().to_lower() != "gd":
		return NOTHING
	var map_path: String = gd_path + ".map"
	if not FileAccess.file_exists(map_path) or not FileAccess.file_exists(gd_path):
		return NOTHING
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(map_path))
	if not (parsed is Dictionary):
		return NOTHING
	var map: Dictionary = parsed
	var lines: Variant = map.get("lines")
	if not (lines is Array):
		return NOTHING
	var gate_path: String = String(map.get("source", ""))
	if gate_path == "" or not FileAccess.file_exists(gate_path):
		return NOTHING
	var gd_text: String = FileAccess.get_file_as_string(gd_path)
	if (lines as Array).size() != gd_text.count("\n"):
		return NOTHING
	if String(map.get("source_sha256", "")) != FileAccess.get_file_as_string(gate_path).sha256_text():
		return NOTHING
	return {"gate": gate_path, "lines": lines as Array}


## The `.gd` GATE writes for a `.gate`, whether or not it exists yet.
static func output_for(gate_path: String) -> String:
	return gate_path.get_basename() + ".gd"


## Where a `.gate` line ends up in the generated file, as {gd, line}, or {}.
##
## The first generated line that came from it: one `.gate` line can produce several,
## and a breakpoint belongs on the first of them. A line that produced none - blank,
## a comment, a declaration that lowers away entirely - has no answer, and the caller
## must treat that as "no breakpoint here" rather than guessing at a nearby line.
static func to_output(gate_path: String, gate_line: int) -> Dictionary:
	var gd_path: String = output_for(gate_path)
	var map: Dictionary = read(gd_path)
	if map.is_empty() or String(map["gate"]) != gate_path:
		return NOTHING
	var lines: Array = map["lines"]
	for i in lines.size():
		if int(lines[i]) == gate_line:
			return {"gd": gd_path, "line": i + 1}
	return NOTHING


## Where a generated line came from, as {gate, line}, or {}.
static func to_source(gd_path: String, gd_line: int) -> Dictionary:
	var map: Dictionary = read(gd_path)
	if map.is_empty():
		return NOTHING
	var lines: Array = map["lines"]
	if gd_line < 1 or gd_line > lines.size():
		return NOTHING
	var source: int = int(lines[gd_line - 1])
	if source <= 0:
		return NOTHING
	return {"gate": String(map["gate"]), "line": source}

@tool
class_name GateDiagnostics
extends RefCounted

## Errors and warnings, with source positions.

enum _Level { ERROR, WARNING, INFO }


class _Diag extends RefCounted:
	var level: int
	var message: String
	var hint: String
	var file: String
	var line: int
	var col: int

	func _init(p_level: int, p_message: String, p_file: String, p_line: int, p_col: int, p_hint: String = "") -> void:
		level = p_level
		message = p_message
		file = p_file
		line = p_line
		col = p_col
		hint = p_hint

	func format() -> String:
		var tag: String = ["error", "warning", "info"][level]
		var s: String = "%s:%d:%d: %s: %s" % [file, line, col, tag, message]
		if hint != "":
			s += "\n    hint: " + hint
		return s

var items: Array[_Diag] = []
var file: String = "<unknown>"
var _seen: Dictionary = {}


func _record(level: int, msg: String, line: int, col: int, hint: String) -> void:
	var key: String = "%d|%d|%d|%s" % [level, line, col, msg]
	if _seen.has(key):
		return
	_seen[key] = true
	items.append(_Diag.new(level, msg, file, line, col, hint))

var sealed: bool = false


func seal() -> void:
	sealed = true


func error(msg: String, line: int, col: int, hint: String = "") -> void:
	if sealed:
		return
	_record(_Level.ERROR, msg, line, col, hint)


func warn(msg: String, line: int, col: int, hint: String = "") -> void:
	_record(_Level.WARNING, msg, line, col, hint)


func info(msg: String, line: int, col: int, hint: String = "") -> void:
	_record(_Level.INFO, msg, line, col, hint)


func has_errors() -> bool:
	for d in items:
		if d.level == _Level.ERROR:
			return true
	return false


func error_count() -> int:
	var n: int = 0
	for d in items:
		if d.level == _Level.ERROR:
			n += 1
	return n


func warning_count() -> int:
	var n: int = 0
	for d in items:
		if d.level == _Level.WARNING:
			n += 1
	return n


func sort_by_position() -> void:
	items.sort_custom(func(a: _Diag, b: _Diag) -> bool:
		if a.line != b.line:
			return a.line < b.line
		if a.col != b.col:
			return a.col < b.col
		return a.level < b.level)


func merge(other: GateDiagnostics) -> void:
	items.append_array(other.items)


func format_all() -> String:
	var out: PackedStringArray = PackedStringArray()
	for d in items:
		out.append(d.format())
	return "\n".join(out)


func print_all() -> void:
	for d in items:
		if d.level == _Level.ERROR:
			push_error("[GATE] " + d.format())
		elif d.level == _Level.WARNING:
			push_warning("[GATE] " + d.format())
		else:
			print("[GATE] " + d.format())

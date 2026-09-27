@tool
extends RefCounted

## GATE's errors and warnings in LSP's shape.

const _Positions: GDScript = preload("res://addons/gate/editor/lsp_positions.gd")
const _Language: GDScript = preload("res://addons/gate/editor/language.gd")

## Named on every diagnostic, so a client can tell GATE's from another server's.
const SOURCE: String = "gate"

const ERROR: int = 1
const WARNING: int = 2


## Every diagnostic one file's text earns.
##
## The problems come from `language.gd:problems()`, which is the pass the editor's
## own `_validate` runs, so a squiggle in Godot's script editor and one in an
## external editor cannot disagree.
static func of_text(text: String, path: String, uri: String, encoding: String) -> Array:
	var found: Dictionary = _Language.problems(text, path, true)
	var lines: PackedStringArray = _Positions.lines_of(_Language.normalized(text))
	var out: Array = []
	for item in found["errors"]:
		out.append(_error(item, lines, uri, encoding))
	for item in found["warnings"]:
		out.append(_warning(item, lines, encoding))
	return out


## An error carries a position and no extent: the lexer reports where the text
## stopped making sense, not a span. The range runs from there to the end of the
## line, which is the part of the file a reader has to look at.
static func _error(item: Dictionary, lines: PackedStringArray, uri: String,
		encoding: String) -> Dictionary:
	var line: int = int(item["line"])
	var span: Dictionary = {
		"start": _Positions.from_gate(lines, line, int(item["column"]), encoding),
		"end": _Positions.from_gate(lines, line, _line_end(lines, line), encoding),
	}
	var out: Dictionary = {
		"range": span,
		"severity": ERROR,
		"source": SOURCE,
		"message": String(item["message"]),
	}
	var hint: String = String(item.get("hint", ""))
	if hint != "":
		# The hint is its own entry rather than glued onto the message. A client
		# shows the message inline, where there is room for a line, and the related
		# information on demand; a message carrying both is unreadable in either
		# place.
		out["relatedInformation"] = [{
			"location": {"uri": uri, "range": span},
			"message": hint,
		}]
	return out


## A warning knows how wide it is: it is reported against one token.
static func _warning(item: Dictionary, lines: PackedStringArray,
		encoding: String) -> Dictionary:
	return {
		"range": {
			"start": _Positions.from_gate(lines, int(item["start_line"]),
				int(item["leftmost_column"]), encoding),
			"end": _Positions.from_gate(lines, int(item["end_line"]),
				int(item["rightmost_column"]), encoding),
		},
		"severity": WARNING,
		"source": SOURCE,
		"code": String(item["string_code"]),
		"message": String(item["message"]),
	}


## One past the last column of a line, in GATE's one-based counting.
static func _line_end(lines: PackedStringArray, line: int) -> int:
	if line < 1 or line > lines.size():
		return 1
	return lines[line - 1].length() + 1

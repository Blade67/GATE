@tool
extends RefCounted

## GATE's errors and warnings in LSP's shape.

const _Positions: GDScript = preload("res://addons/gate/editor/lsp_positions.gd")
const _Language: GDScript = preload("res://addons/gate/editor/language.gd")
const _Index: GDScript = preload("res://addons/gate/editor/index.gd")

## Named on every diagnostic, so a client can tell GATE's from another server's.
const SOURCE: String = "gate"

const ERROR: int = 1
const WARNING: int = 2
const INFORMATION: int = 3


## Every diagnostic one file's text earns.
##
## The fast tier comes from `language.gd:problems()`, which is the pass the
## editor's own `_validate` runs, so a squiggle in Godot's script editor and one in
## an external editor cannot disagree. `full` adds what a compile finds, which is
## everything the editor has no way to show.
static func of_text(text: String, path: String, uri: String, encoding: String,
		full: bool = false) -> Array:
	var found: Dictionary = _Language.problems(text, path, true)
	var lines: PackedStringArray = _Positions.lines_of(_Language.normalized(text))
	var out: Array = []
	var seen: Dictionary = {}
	for item in found["errors"]:
		_keep(out, seen, _positioned(item, lines, uri, encoding, ERROR))
	for item in found["warnings"]:
		_keep(out, seen, _warning(item, lines, encoding))
	# A file the lexer refused is not compiled. Every pass after it would report
	# cascades off the same broken token stream, and the first of those cascades is
	# usually the lexer error again, one line and one wording apart, which is two
	# squiggles on one quote.
	if full and found["errors"].is_empty():
		for item in compiled(text, path):
			_keep(out, seen, _positioned(item, lines, uri, encoding,
				_severity(int(item["level"]))))
	return out


## The same parse and check the builder runs for one file.
##
## `GateCompiler.compile` is the object `builder.gd` calls, with the registry the
## editor already holds and the same defines, so what comes back is what a build
## would report about this text rather than a second opinion about it. The registry
## is read from disk, so a type another file declares resolves and an unsaved
## change in that other file does not.
static func compiled(text: String, path: String) -> Array:
	var result: GateCompiler._Result = GateCompiler.new().compile(
		_Language.normalized(text), path, _Index.registry(), GateDefines.table())
	# `compile` leaves behind the shorthand names it shadowed, the way a parse does.
	# `index.gd` clears them after its own parse for the same reason.
	GateTypes.shadowed.clear()
	var out: Array = []
	for entry in result.diagnostics.items:
		out.append({
			"level": entry.level,
			"line": entry.line,
			"column": entry.col,
			"message": entry.message,
			"hint": entry.hint,
		})
	return out


static func _severity(level: int) -> int:
	if level == GateDiagnostics._Level.ERROR:
		return ERROR
	return WARNING if level == GateDiagnostics._Level.WARNING else INFORMATION


## One diagnostic, unless the same thing has already been reported at the same
## place. Both tiers run the same lexer, so the one that speaks first wins.
static func _keep(out: Array, seen: Dictionary, item: Dictionary) -> void:
	var start: Dictionary = Dictionary(item["range"])["start"]
	var key: String = "%d|%d|%d|%s" % [int(item["severity"]), int(start["line"]),
		int(start["character"]), String(item["message"])]
	if seen.has(key):
		return
	seen[key] = true
	out.append(item)


## A problem that carries a position and no extent: the lexer and the compiler both
## report where the text stopped making sense, not a span. The range runs from
## there to the end of the line, which is the part of the file a reader has to
## look at.
static func _positioned(item: Dictionary, lines: PackedStringArray, uri: String,
		encoding: String, severity: int) -> Dictionary:
	var line: int = int(item["line"])
	var span: Dictionary = {
		"start": _Positions.from_gate(lines, line, int(item["column"]), encoding),
		"end": _Positions.from_gate(lines, line, _line_end(lines, line), encoding),
	}
	var out: Dictionary = {
		"range": span,
		"severity": severity,
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

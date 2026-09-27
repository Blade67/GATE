@tool
extends RefCounted

## The one conversion between LSP positions and GATE's.
##
## LSP counts lines and characters from zero, and counts a character in UTF-16
## code units unless the client asks for something else. GATE counts lines and
## columns from one, and counts a character the way Godot's String does, which is
## by code point. Every position that crosses the protocol goes through here.

const UTF16: String = "utf-16"
const UTF8: String = "utf-8"


## The document's lines, with the carriage return of a CRLF file dropped: the
## compiler normalises those away before it lexes, so a column it reports is a
## column of the line without it.
static func lines_of(text: String) -> PackedStringArray:
	var out: PackedStringArray = text.split("\n")
	for i in out.size():
		if out[i].ends_with("\r"):
			out[i] = out[i].substr(0, out[i].length() - 1)
	return out


## UTF-16 unless the client offers UTF-8 in `general.positionEncodings`. UTF-32
## is not offered: GATE would have to answer in it, and nothing asks for it.
static func choose_encoding(offered: Variant) -> String:
	if offered is Array or offered is PackedStringArray:
		for name in Array(offered):
			if String(name) == UTF8:
				return UTF8
	return UTF16


## How many code units the first `chars` characters of `line` take.
static func units_of(line: String, chars: int, encoding: String) -> int:
	var limit: int = clampi(chars, 0, line.length())
	var units: int = 0
	for i in range(limit):
		units += _width(line.unicode_at(i), encoding)
	return units


## How many characters `units` code units cover. A position inside a character
## rounds down to its start, and one past the end of the line clamps to the end.
static func chars_of(line: String, units: int, encoding: String) -> int:
	if units <= 0:
		return 0
	var seen: int = 0
	for i in range(line.length()):
		var width: int = _width(line.unicode_at(i), encoding)
		if seen + width > units:
			return i
		seen += width
		if seen == units:
			return i + 1
	return line.length()


## An LSP position as GATE's one-based line and column.
static func to_gate(lines: PackedStringArray, line: int, character: int, encoding: String) -> Dictionary:
	var row: int = _row(lines, line)
	return {"line": row + 1, "col": chars_of(_line_at(lines, row), character, encoding) + 1}


## GATE's one-based line and column as an LSP position.
static func from_gate(lines: PackedStringArray, gate_line: int, gate_col: int, encoding: String) -> Dictionary:
	var row: int = _row(lines, gate_line - 1)
	return {"line": row, "character": units_of(_line_at(lines, row), maxi(0, gate_col - 1), encoding)}


static func _row(lines: PackedStringArray, line: int) -> int:
	return clampi(line, 0, maxi(0, lines.size() - 1))


static func _line_at(lines: PackedStringArray, row: int) -> String:
	return lines[row] if row >= 0 and row < lines.size() else ""


static func _width(code: int, encoding: String) -> int:
	if encoding == UTF8:
		if code < 0x80:
			return 1
		if code < 0x800:
			return 2
		if code < 0x10000:
			return 3
		return 4
	return 2 if code > 0xFFFF else 1

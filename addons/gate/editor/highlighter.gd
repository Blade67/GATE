@tool
extends EditorSyntaxHighlighter

## Syntax colours for `.gate`, in the user's own editor theme.
##
## Two layers. A `CodeHighlighter` on a detached `CodeEdit` does the work GDScript's
## own colours do - keywords, numbers, symbols, functions, members. The
## `CodeHighlighter` is never handed to the editor's own `CodeEdit`: doing that
## segfaults on shutdown. Strings and comments are not its job: it has no colour
## region that both honours an end key and understands a backslash, so `_scan`
## finds those and layer two paints them.
##
## The proxy holds one line at a time. Holding the whole text is simpler and is what
## a `CodeHighlighter` wants, but `TextEdit.text =` shapes every line through the
## text server, and the editor asks for a resync on every keystroke: 13 ms on a
## thousand-line file and 78 ms on five thousand, measured. So the one thing a single
## line cannot know - whether it is inside a `"""` block that opened earlier - is
## tracked separately, by a scan that only looks closely at lines containing a triple
## quote. That leaves a keystroke at well under a millisecond on the same files.
##
## On top of that, a pass of GATE's own forms, which no keyword list can express:
## type-first declarations, `T?`, `T[]`, f-strings, annotations, the names a file
## declares and the generic parameters they open. Those rewrite spans of the first
## layer's answer, and a leading-underscore name is dimmed towards the comment
## colour. A string or a comment is a span like any other, first in the list and
## wider than anything inside it, so nothing in one ever colours.
##
## Every colour comes from `text_editor/theme/highlighting/*`. Nothing is hard-coded,
## and `generation` is bumped when the settings change so live instances rebuild.

## GATE's own keywords. The same set the Prism grammar on the website uses, plus the
## three it does not need: `final`, `when` and `enumerate`.
const GATE_KEYWORDS: Array[String] = [
	"struct", "trait", "interface", "namespace", "implements", "with",
	"pub", "priv", "override", "virtual", "final", "enumerate",
]

## GATE's lowercase type shorthands, exactly the set in SYNTAX.md section 2.
const SHORTHANDS: String = ("int|float|bool|str|i32|i64|f32|f64"
	+ "|vec2i|vec2|vec3i|vec3|vec4i|vec4|rect2i|rect2|quat|xform2d|xform3d"
	+ "|color|aabb|plane|basis|proj|nodepath|rid|sname|any")

## The keywords a name is declared after. `class_name` before `class`, or the
## alternation takes the shorter one and the name comes out as `name`.
const DECLARES: String = "class_name|class|struct|interface|trait|namespace|type"

## How far a leading-underscore name is pulled towards the comment colour.
const DIM_TOWARDS_COMMENT: float = 0.55

const GDSCRIPT_KEYWORDS: Array[String] = [
	"class", "class_name", "extends", "is", "in", "as", "self", "super", "signal",
	"func", "static", "const", "enum", "var", "preload", "assert", "void",
	"true", "false", "null", "not", "and", "or", "breakpoint", "type",
]

const CONTROL_KEYWORDS: Array[String] = [
	"if", "elif", "else", "for", "while", "match", "when", "break", "continue",
	"pass", "return", "await", "yield",
]

## Bumped by the plugin when the editor settings change. Every live instance
## notices on its next line and rebuilds, so a theme change follows immediately.
static var generation: int = 0

## What `_state` holds per line: what a line is already inside when it starts.
enum { CODE, IN_DOUBLE, IN_SINGLE }

## What `_scan` reports a stretch of a line as.
enum { AS_STRING, AS_COMMENT, AS_DOC }

const DELIMITERS: Array[String] = ["", "\"\"\"", "'''"]

const QUOTE: int = 34
const APOSTROPHE: int = 39
const HASH: int = 35
const BACKSLASH: int = 92

var _highlighter: CodeHighlighter = null
var _proxy: CodeEdit = null
var _built: int = -1
var _synced_id: int = 0
var _synced_version: int = -1
var _lines: PackedStringArray = PackedStringArray()
var _state: PackedByteArray = PackedByteArray()

var _comment_color: Color = Color.WHITE
var _doc_color: Color = Color.WHITE
var _string_color: Color = Color.WHITE
var _keyword_color: Color = Color.WHITE
var _control_color: Color = Color.WHITE
var _base_type_color: Color = Color.WHITE
var _engine_type_color: Color = Color.WHITE
var _user_type_color: Color = Color.WHITE
var _function_color: Color = Color.WHITE
var _member_color: Color = Color.WHITE
var _text_color: Color = Color.WHITE
var _dim_color: Color = Color.WHITE

var _re_annotation: RegEx = null
var _re_fstring: RegEx = null
var _re_shorthand: RegEx = null
var _re_capitalised: RegEx = null
var _re_gate_keyword: RegEx = null
var _re_dim: RegEx = null
var _re_declares: RegEx = null
var _user_types: Dictionary = {}
var _file_types: Dictionary = {}
var _builtin_types: Dictionary = {}
var _scratch: Array = []


## A `const`-preloaded script cannot be assigned through, only called.
static func invalidate() -> void:
	generation += 1


func _get_name() -> String:
	return "GATE"


func _get_supported_languages() -> PackedStringArray:
	return PackedStringArray(["GATE"])


## The editor asks for one of these per open file.
func _create() -> EditorSyntaxHighlighter:
	return (get_script() as GDScript).new()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _proxy != null:
		_proxy.free()
		_proxy = null


func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var edit: TextEdit = get_text_edit()
	if edit == null:
		return {}
	if _built != generation:
		_rebuild()
	_sync(edit)
	if _proxy == null or line < 0 or line >= _lines.size():
		return {}
	var text: String = _lines[line]
	var prose: Array = []
	_scan(text, _state[line], prose)
	return _overlay(text, _line_colours(text), prose)


# ───────────────────────── layer one ─────────────────────────

func _color(key: String, fallback: Color) -> Color:
	var settings: EditorSettings = EditorInterface.get_editor_settings()
	var name: String = "text_editor/theme/highlighting/" + key
	if settings == null or not settings.has_setting(name):
		return fallback
	var value: Variant = settings.get_setting(name)
	if value is Color:
		return value
	return fallback


func _rebuild() -> void:
	_built = generation
	_text_color = _color("text_color", Color(0.9, 0.9, 0.9))
	_comment_color = _color("comment_color", Color(0.5, 0.5, 0.5))
	_doc_color = _color("doc_comment_color", _comment_color)
	_string_color = _color("string_color", Color(1.0, 0.93, 0.63))
	_keyword_color = _color("keyword_color", Color(1.0, 0.44, 0.52))
	_control_color = _color("control_flow_keyword_color", _keyword_color)
	_base_type_color = _color("base_type_color", Color(0.65, 0.92, 0.79))
	_engine_type_color = _color("engine_type_color", Color(0.51, 0.83, 1.0))
	_user_type_color = _color("user_type_color", Color(0.76, 0.9, 1.0))
	_function_color = _color("function_color", Color(0.34, 0.7, 1.0))
	_member_color = _color("member_variable_color", Color(0.74, 0.48, 0.95))
	_dim_color = _text_color.lerp(_comment_color, DIM_TOWARDS_COMMENT)

	var made: CodeHighlighter = CodeHighlighter.new()
	made.number_color = _color("number_color", Color(0.63, 1.0, 0.88))
	made.symbol_color = _color("symbol_color", Color(0.67, 0.79, 1.0))
	made.function_color = _function_color
	made.member_variable_color = _member_color
	for word in GDSCRIPT_KEYWORDS:
		made.add_keyword_color(word, _keyword_color)
	for word in CONTROL_KEYWORDS:
		made.add_keyword_color(word, _control_color)
	for word in GATE_KEYWORDS:
		made.add_keyword_color(word, _keyword_color)
	_highlighter = made

	if _proxy == null:
		_proxy = CodeEdit.new()
	_proxy.syntax_highlighter = _highlighter
	_synced_version = -1

	_re_annotation = RegEx.create_from_string("@[A-Za-z_][A-Za-z_0-9]*")
	_re_fstring = RegEx.create_from_string("\\bf(?=[\"'])")
	_re_shorthand = RegEx.create_from_string("\\b(?:%s)\\b(?:\\[\\])*\\??" % SHORTHANDS)
	_re_capitalised = RegEx.create_from_string("\\b[A-Z][A-Za-z_0-9]*(?:\\[\\])*\\??")
	_re_gate_keyword = RegEx.create_from_string("\\b(?:%s)\\b" % "|".join(GATE_KEYWORDS))
	_re_dim = RegEx.create_from_string("\\b_[A-Za-z_0-9]*")
	_re_declares = RegEx.create_from_string(
		"(?m)^[ \\t]*(?:%s)[ \\t]+([A-Za-z_][A-Za-z_0-9]*)[ \\t]*(?:<([^>\\n]*)>)?" % DECLARES)

	_user_types.clear()
	for entry in ProjectSettings.get_global_class_list():
		_user_types[String(entry["class"])] = true

	_builtin_types.clear()
	for i in range(1, TYPE_MAX):
		_builtin_types[type_string(i)] = true
	_builtin_types["Variant"] = true


## Layer one's answer for one line of code, via the proxy.
func _line_colours(text: String) -> Dictionary:
	_proxy.text = text
	_highlighter.clear_highlighting_cache()
	return _highlighter.get_line_syntax_highlighting(0)


func _sync(edit: TextEdit) -> void:
	if _proxy == null:
		return
	var id: int = edit.get_instance_id()
	var version: int = edit.get_version()
	if id == _synced_id and version == _synced_version:
		return
	_synced_id = id
	_synced_version = version
	var source: String = edit.text
	_lines = source.split("\n")
	_scan_declared(source)
	_state.resize(_lines.size())
	var state: int = CODE
	for i in _lines.size():
		_state[i] = state
		var text: String = _lines[i]
		# Two engine-side searches for the common line, and the slow walk only for
		# the rare one that could change the answer.
		if text.contains("\"\"\"") or text.contains("'''"):
			_scratch.clear()
			state = _scan(text, state, _scratch)


## The type names this file declares itself, and the generic parameters they open.
## One pass over the whole text, not a regex per line: 0.55 ms on a 5,000-line file
## against 2.5 ms for the cheapest per-line test that would find the same lines.
func _scan_declared(source: String) -> void:
	_file_types.clear()
	for match_ in _re_declares.search_all(source):
		_file_types[match_.get_string(1)] = true
		var parameters: String = match_.get_string(2)
		if parameters == "":
			continue
		for name in parameters.split(",", false):
			var bare: String = name.strip_edges()
			if bare != "":
				_file_types[bare] = true


## The first quote or `#` at or after `from`, or -1. Nothing before one of those can
## be a string or a comment, so the walk below never looks at the rest.
static func _first_prose(text: String, from: int) -> int:
	var best: int = text.find("\"", from)
	var found: int = text.find("'", from)
	if found >= 0 and (best < 0 or found < best):
		best = found
	found = text.find("#", from)
	if found >= 0 and (best < 0 or found < best):
		best = found
	return best


## Where a `"""` or `'''` block closes at or after `from`, or -1.
static func _closes(text: String, from: int, code: int) -> int:
	var block: int = IN_SINGLE if code == APOSTROPHE else IN_DOUBLE
	if text.find(DELIMITERS[block], from) < 0:
		return -1
	var size: int = text.length()
	var at: int = from
	while at < size:
		var here: int = text.unicode_at(at)
		if here == BACKSLASH:
			at += 2
			continue
		if (here == code and at + 2 < size and text.unicode_at(at + 1) == code
				and text.unicode_at(at + 2) == code):
			return at
		at += 1
	return -1


## Every stretch of one line that is a string or a comment, appended to `out` as
## `[start, end, kind]`, and what the line leaves the next one inside.
static func _scan(text: String, state: int, out: Array) -> int:
	var size: int = text.length()
	var at: int = 0
	if state != CODE:
		var opened: int = _closes(text, 0, APOSTROPHE if state == IN_SINGLE else QUOTE)
		if opened < 0:
			out.append([0, size, AS_STRING])
			return state
		at = opened + 3
		out.append([0, at, AS_STRING])
	var found: int = _first_prose(text, at)
	while found >= 0:
		var code: int = text.unicode_at(found)
		if code == HASH:
			var kind: int = AS_COMMENT
			if found + 1 < size and text.unicode_at(found + 1) == HASH:
				kind = AS_DOC
			out.append([found, size, kind])
			return CODE
		if (found + 2 < size and text.unicode_at(found + 1) == code
				and text.unicode_at(found + 2) == code):
			var block: int = IN_SINGLE if code == APOSTROPHE else IN_DOUBLE
			var closes: int = _closes(text, found + 3, code)
			if closes < 0:
				out.append([found, size, AS_STRING])
				return block
			at = closes + 3
		else:
			at = found + 1
			while at < size:
				var inner: int = text.unicode_at(at)
				at += 1
				if inner == BACKSLASH:
					at += 1
					continue
				if inner == code:
					break
			at = mini(at, size)
		out.append([found, at, AS_STRING])
		found = _first_prose(text, at)
	return CODE


# ───────────────────────── layer two ─────────────────────────

## The colour layer one gave column `at`, which is what a span must be restored to
## when it ends.
static func _at(columns: Array, base: Dictionary, at: int, fallback: Color) -> Color:
	var found: Color = fallback
	for column in columns:
		if int(column) > at:
			break
		var entry: Variant = base[column]
		if entry is Dictionary and (entry as Dictionary).has("color"):
			found = (entry as Dictionary)["color"]
	return found


func _prose_color(kind: int) -> Color:
	if kind == AS_COMMENT:
		return _comment_color
	if kind == AS_DOC:
		return _doc_color
	return _string_color


## Spans of `[start, end, colour, over_member]`. The last flag is false where layer
## one calling the word a member access wins instead, which is what keeps
## `xform.basis` and `pool._items` in the member colour.
func _spans(text: String, prose: Array) -> Array:
	var out: Array = []
	for span in prose:
		out.append([int(span[0]), int(span[1]), _prose_color(int(span[2])), true])
	for match_ in _re_annotation.search_all(text):
		out.append([match_.get_start(), match_.get_end(), _function_color, true])
	for match_ in _re_fstring.search_all(text):
		out.append([match_.get_start(), match_.get_end(), _string_color, true])
	for match_ in _re_shorthand.search_all(text):
		out.append([match_.get_start(), match_.get_end(), _base_type_color, false])
	for match_ in _re_gate_keyword.search_all(text):
		out.append([match_.get_start(), match_.get_end(), _keyword_color, true])
	for match_ in _re_dim.search_all(text):
		out.append([match_.get_start(), match_.get_end(), _dim_color, false])
	for match_ in _re_capitalised.search_all(text):
		var word: String = match_.get_string()
		var bare: String = word.trim_suffix("?").replace("[]", "")
		var decorated: bool = word != bare
		if ClassDB.class_exists(bare):
			out.append([match_.get_start(), match_.get_end(), _engine_type_color, true])
		elif _builtin_types.has(bare):
			# The canonical column of SYNTAX.md's type table, and what Godot does
			# with it in a `.gd`: `Vector2`, `Array[String]` and `Vector2(1, 2)` are
			# all the base type colour. `Object` is a class first, so it is above.
			out.append([match_.get_start(), match_.get_end(), _base_type_color, true])
		elif _user_types.has(bare) or _file_types.has(bare):
			out.append([match_.get_start(), match_.get_end(), _user_type_color, true])
		elif decorated:
			# `Thing?` and `Thing[]` are types wherever they appear; a bare `THING`
			# is far more often a constant, so it is left alone.
			out.append([match_.get_start(), match_.get_end(), _user_type_color, true])
	out.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	return out


func _overlay(text: String, base: Dictionary, prose: Array) -> Dictionary:
	var spans: Array = _spans(text, prose)
	if spans.is_empty():
		return base
	var size: int = text.length()
	var columns: Array = base.keys()
	columns.sort()

	var points: Dictionary = {}
	for column in columns:
		points[int(column)] = _at(columns, base, int(column), _text_color)

	var last_end: int = -1
	for span in spans:
		var start: int = int(span[0])
		var end: int = int(span[1])
		# A string or a comment comes first in this list and reaches further than
		# anything inside it, so this one test is what keeps a type or an underscore
		# name in a comment from colouring.
		if start < last_end:
			continue
		var before: Color = _at(columns, base, start, _text_color)
		if not bool(span[3]) and before == _member_color:
			continue
		var after: Color = _at(columns, base, end, _text_color)
		for column in points.keys():
			if int(column) > start and int(column) < end:
				points.erase(column)
		points[start] = span[2]
		if end < size:
			points[end] = after
		last_end = end

	var ordered: Array = points.keys()
	ordered.sort()
	var out: Dictionary = {}
	for column in ordered:
		out[column] = {"color": points[column]}
	return out

@tool
extends RefCounted

## `textDocument/completion` and `textDocument/signatureHelp`, from `complete.gd`.
##
## Both answers are the ones Godot's own script editor gets. This translates a
## position into the caret mark `complete.gd` expects, and translates its answer
## into LSP's shapes. It decides nothing about what is offered.

const _Positions: GDScript = preload("res://addons/gate/editor/lsp_positions.gd")
const _Documents: GDScript = preload("res://addons/gate/editor/lsp_documents.gd")
const _Protocol: GDScript = preload("res://addons/gate/editor/lsp_protocol.gd")
const _Complete: GDScript = preload("res://addons/gate/editor/complete.gd")
const _Language: GDScript = preload("res://addons/gate/editor/language.gd")

const COMPLETION: String = "textDocument/completion"
const SIGNATURE_HELP: String = "textDocument/signatureHelp"

## What makes a client ask without being typed at. A dot opens a member list and
## an at sign opens the annotations, which are the two lists `complete.gd` answers
## from a single character.
const COMPLETION_TRIGGERS: Array[String] = [".", "@"]

## An opening parenthesis starts an argument list and a comma moves to the next.
const SIGNATURE_TRIGGERS: Array[String] = ["(", ","]

## `ScriptLanguage.CodeCompletionKind` to LSP's `CompletionItemKind`.
const KINDS: Dictionary = {
	0: 7,
	1: 3,
	2: 23,
	3: 6,
	4: 5,
	5: 13,
	6: 21,
	7: 1,
	8: 17,
	9: 1,
}

## LSP's CompletionItemKind.Text, for a kind nothing maps to.
const TEXT_KIND: int = 1


## One request, answered or refused. A URI GATE does not serve is refused rather
## than answered with an empty list: a client told there are no completions
## believes GATE has none.
static func answer(method: String, id: Variant, params: Dictionary, docs: RefCounted,
		encoding: String) -> Dictionary:
	var document: Dictionary = params["textDocument"] if params.get("textDocument", null) is Dictionary else {}
	var found: Dictionary = _Documents.path_of(String(document.get("uri", "")))
	if String(found["fault"]) != "":
		return _Protocol.failure(id, _Protocol.INVALID_PARAMS, String(found["fault"]))
	var position: Dictionary = params["position"] if params.get("position", null) is Dictionary else {}
	var path: String = String(found["path"])
	var code: String = with_caret(docs.text_of(path), int(position.get("line", 0)),
		int(position.get("character", 0)), encoding)
	var got: Dictionary = _Complete.complete(code, path, null)
	if method == SIGNATURE_HELP:
		var signature: Dictionary = signature_of(String(got.get("call_hint", "")), encoding)
		if signature.is_empty():
			return _Protocol.result(id, null)
		var info: Dictionary = {
			"label": signature["label"],
			"parameters": signature["parameters"],
		}
		var doc: String = String(got.get("call_doc", ""))
		if doc != "":
			info["documentation"] = {"kind": "markdown", "value": doc}
		return _Protocol.result(id, {
			"signatures": [info],
			"activeSignature": 0,
			"activeParameter": signature["activeParameter"],
		})
	# isIncomplete is false: GATE builds the whole list in one pass, so a client
	# that filters it as the user types is filtering everything there is.
	return _Protocol.result(id, {
		"isIncomplete": false,
		"items": items_of(Array(got.get("options", []))),
	})


## The text a request is about, with the caret mark `complete.gd` reads put where
## the client's position says.
##
## The text is normalised first, because that is what the compiler lexes and what
## the position conversion splits into lines. Reaching into the raw text with an
## offset counted from normalised lines puts the caret one character early per
## carriage return above it.
static func with_caret(text: String, line: int, character: int, encoding: String) -> String:
	var source: String = _Language.normalized(text)
	var lines: PackedStringArray = _Positions.lines_of(source)
	var at: Dictionary = _Positions.to_gate(lines, line, character, encoding)
	var offset: int = 0
	for i in range(int(at["line"]) - 1):
		offset += lines[i].length() + 1
	offset += int(at["col"]) - 1
	return source.substr(0, offset) + _Complete.CURSOR + source.substr(offset)


## `complete.gd`'s options as LSP completion items.
##
## Its sort locations become `sortText`, because a client sorts by that and
## nothing else, so without it the order a user sees is not the order the Godot
## editor gives. The index breaks ties, which keeps the list in the order
## `complete.gd` built it.
static func items_of(options: Array) -> Array:
	var out: Array = []
	for i in options.size():
		var option: Dictionary = options[i]
		var display: String = String(option.get("display", ""))
		var label: String = display.trim_suffix("(")
		out.append({
			"label": label,
			"kind": int(KINDS.get(int(option.get("kind", 9)), TEXT_KIND)),
			"insertText": String(option.get("insert_text", display)),
			"filterText": label,
			"sortText": sort_key(int(option.get("location", 0)), i),
		})
	return out


## Fixed width, because sortText is compared as a string.
static func sort_key(location: int, index: int) -> String:
	return "%06d%05d" % [maxi(0, location), maxi(0, index)]


## A call hint as a signature, or {} when there is no hint to turn into one.
##
## The hint is the string the Godot editor shows, with the argument being written
## wrapped in U+FFFF. The label is that string without the marks, and the marks
## say which parameter is active.
##
## A Variant built-in's methods carry no argument list in `builtin_api.gd`, so
## `complete.gd` answers no hint for one at all and this answers {} in turn. A
## signature with an empty parameter list would say the method takes none.
static func signature_of(hint: String, encoding: String) -> Dictionary:
	if hint == "":
		return {}
	var open: int = hint.find("(")
	var close: int = hint.rfind(")")
	if open < 0 or close < open:
		return {}
	var label: String = hint.replace(_Complete.CURSOR, "")
	var inner: String = hint.substr(open + 1, close - open - 1)
	if inner.replace(_Complete.CURSOR, "").strip_edges() == "":
		return {"label": label, "parameters": [], "activeParameter": 0}
	var parameters: Array = []
	var active: int = -1
	var at: int = open + 1
	var parts: PackedStringArray = _arguments(inner)
	for i in parts.size():
		var raw: String = parts[i]
		var clean: String = raw.replace(_Complete.CURSOR, "")
		if raw != clean:
			active = i
		var lead: int = clean.length() - clean.lstrip(" ").length()
		var body: String = clean.strip_edges()
		# Offsets into the label rather than a copy of the text: two parameters
		# whose text is a prefix of each other, `a: int` and `ab: int`, would have
		# a client highlight the first for both.
		parameters.append({"label": [
			_Positions.units_of(label, at + lead, encoding),
			_Positions.units_of(label, at + lead + body.length(), encoding),
		]})
		at += clean.length() + 1
	# Nothing is marked when the caret is past the last argument. LSP 3.17 has no
	# way to say "none", so the index goes out of range rather than being left off,
	# which is the nearest thing a client acts on.
	return {
		"label": label,
		"parameters": parameters,
		"activeParameter": active if active >= 0 else parameters.size(),
	}


## An argument list split at its own commas. A comma inside a nested call, a
## container or a string belongs to that, not to the list.
static func _arguments(text: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var depth: int = 0
	var quote: String = ""
	var from: int = 0
	var i: int = 0
	while i < text.length():
		var character: String = text[i]
		if quote != "":
			if character == "\\":
				i += 2
				continue
			if character == quote:
				quote = ""
		elif character == "\"" or character == "'":
			quote = character
		elif character == "(" or character == "[" or character == "{":
			depth += 1
		elif character == ")" or character == "]" or character == "}":
			depth -= 1
		elif character == "," and depth == 0:
			out.append(text.substr(from, i - from))
			from = i + 1
		i += 1
	out.append(text.substr(from))
	return out

@tool
extends RefCounted

## `textDocument/definition`, `textDocument/hover` and `textDocument/documentSymbol`,
## answered from `lookup.gd` and the parsed module.

const _Lookup: GDScript = preload("res://addons/gate/editor/lookup.gd")
const _Index: GDScript = preload("res://addons/gate/editor/index.gd")
const _Language: GDScript = preload("res://addons/gate/editor/language.gd")
const _Positions: GDScript = preload("res://addons/gate/editor/lsp_positions.gd")
const _Documents: GDScript = preload("res://addons/gate/editor/lsp_documents.gd")
const _Sourcemap: GDScript = preload("res://addons/gate/editor/sourcemap.gd")

const DEFINITION: String = "textDocument/definition"
const HOVER: String = "textDocument/hover"
const DOCUMENT_SYMBOL: String = "textDocument/documentSymbol"

## LSP's SymbolKind, which is a numbered enum in the specification.
const KIND_NAMESPACE: int = 3
const KIND_CLASS: int = 5
const KIND_METHOD: int = 6
const KIND_FIELD: int = 8
const KIND_ENUM: int = 10
const KIND_INTERFACE: int = 11
const KIND_FUNCTION: int = 12
const KIND_CONSTANT: int = 14
const KIND_ENUM_MEMBER: int = 22
const KIND_STRUCT: int = 23
const KIND_EVENT: int = 24
const KIND_OPERATOR: int = 25
const KIND_TYPE_PARAMETER: int = 26

## `ScriptLanguage.LookupResultType`, the two values `lookup.gd` answers with.
const RESULT_SCRIPT_LOCATION: int = 0
const RESULT_CLASS: int = 1

## How far an enum's opening brace is followed looking for its closing one.
const MAX_ENUM_LINES: int = 500


## The one entry point. `method` is one of the three constants above.
static func answer(method: String, text: String, path: String, params: Dictionary,
		encoding: String) -> Variant:
	if method == DOCUMENT_SYMBOL:
		return symbols(text, path, encoding)
	var position: Dictionary = params["position"] if params.get("position", null) is Dictionary else {}
	if method == DEFINITION:
		return definition(text, path, position, encoding)
	return hover(text, path, position, encoding)


## The location that declares the word under the caret, or null.
##
## Null wherever Ctrl-click draws no underline, and null again wherever the only
## answer would be a generated `.gd`.
static func definition(text: String, path: String, position: Dictionary,
		encoding: String) -> Variant:
	var found: Dictionary = _resolve(text, path, position, encoding)
	if found.is_empty() or String(found["path"]) == "":
		return null
	var target: String = String(found["path"])
	var word: String = String(found["word"])
	var file: String = _text_of(target, path, text)
	var lines: PackedStringArray = _Positions.lines_of(_Language.normalized(file))
	return {"uri": _Documents.uri_of_path(target),
		"range": _name_range(lines, int(found["line"]), word, encoding)}


## The declaration as it was written and the type it declares, as markdown, or null.
static func hover(text: String, path: String, position: Dictionary,
		encoding: String) -> Variant:
	var found: Dictionary = _resolve(text, path, position, encoding)
	if found.is_empty():
		return null
	var markdown: String = ""
	if String(found["engine"]) != "":
		markdown = _engine_markdown(String(found["engine"]))
	else:
		markdown = _declaration_markdown(String(found["path"]), int(found["line"]),
			String(found["word"]), path, text)
	if markdown == "":
		return null
	var lines: PackedStringArray = found["lines"]
	var at: Dictionary = found["at"]
	return {
		"contents": {"kind": "markdown", "value": markdown},
		"range": {
			"start": _Positions.from_gate(lines, int(at["line"]), int(at["from"]), encoding),
			"end": _Positions.from_gate(lines, int(at["line"]), int(at["to"]), encoding),
		},
	}


## The file's declarations as a tree.
static func symbols(text: String, path: String, encoding: String) -> Array:
	var source: String = _Language.normalized(text)
	var lines: PackedStringArray = _Positions.lines_of(source)
	var module: GateAST._Module = _Index.module_for(source, path, _Index.registry())
	if module == null:
		return []
	return _symbols_of(module.members, lines, false, encoding)


## The word under an LSP position and where GATE's own lookup places it.
static func _resolve(text: String, path: String, position: Dictionary,
		encoding: String) -> Dictionary:
	var source: String = _Language.normalized(text)
	var lines: PackedStringArray = _Positions.lines_of(source)
	var at: Dictionary = _word_at(lines, position, encoding)
	if at.is_empty():
		return {}
	var code: String = _with_cursor(source, lines, int(at["line"]), int(at["after"]))
	var got: Dictionary = _Lookup.find(code, String(at["word"]), path)
	if int(got["result"]) != OK:
		return {}
	if int(got["type"]) == RESULT_CLASS:
		return {"path": "", "line": 0, "engine": String(got["class_name"]),
			"word": String(at["word"]), "at": at, "lines": lines}
	var where: Dictionary = _in_source(String(got["class_path"]), int(got["location"]))
	if where.is_empty():
		return {}
	return {"path": String(where["path"]), "line": int(where["line"]), "engine": "",
		"word": String(at["word"]), "at": at, "lines": lines}


## A location in a `.gd` as one in the `.gate` it was generated from.
##
## Three cases and they are not the same. A `.gd` with a current sourcemap is
## GATE's own output and the map says which `.gate` line it came from. A `.gd` that
## a `.gate` sits beside, with no map or a stale one, is also GATE's output and
## there is nothing trustworthy to translate with, so it is refused. Anything else
## is a file a person wrote and is answered as it stands.
static func _in_source(target: String, line: int) -> Dictionary:
	if target == "" or line <= 0:
		return {}
	if target.get_extension().to_lower() != "gd":
		return {"path": target, "line": line}
	var mapped: Dictionary = _Sourcemap.to_source(target, line)
	if not mapped.is_empty():
		return {"path": String(mapped["gate"]), "line": int(mapped["line"])}
	if _generated(target):
		return {}
	return {"path": target, "line": line}


static func _generated(gd_path: String) -> bool:
	if FileAccess.file_exists(gd_path + ".map"):
		return true
	return _gate_beside(gd_path) != ""


## The `.gate` that writes this `.gd`, or "". `x.gate` writes `x.gd`, and a
## `@global class Foo` in `x.gate` writes `x.Foo.gd` as well.
static func _gate_beside(gd_path: String) -> String:
	var base: String = gd_path.get_basename()
	if FileAccess.file_exists(base + ".gate"):
		return base + ".gate"
	var dot: int = base.rfind(".")
	if dot > base.rfind("/"):
		var outer: String = base.substr(0, dot) + ".gate"
		if FileAccess.file_exists(outer):
			return outer
	return ""


## The identifier an LSP position is on, as
## `{word, line, from, to, after}` in GATE's one-based counting, or `{}`.
##
## A caret sitting just past the end of a word is on that word, which is where a
## client leaves it when the user double-clicks or presses F12 at the end of a
## name. A caret on a number, on punctuation or on a blank line is on nothing, and
## nothing is the answer rather than the nearest word along.
static func _word_at(lines: PackedStringArray, position: Dictionary,
		encoding: String) -> Dictionary:
	var gate: Dictionary = _Positions.to_gate(lines, int(position.get("line", 0)),
		int(position.get("character", 0)), encoding)
	var row: int = int(gate["line"]) - 1
	if row < 0 or row >= lines.size():
		return {}
	var line: String = lines[row]
	var index: int = int(gate["col"]) - 1
	if index >= line.length() or index < 0 or not _is_word(line[index]):
		index -= 1
	if index < 0 or index >= line.length() or not _is_word(line[index]):
		return {}
	var from: int = index
	while from > 0 and _is_word(line[from - 1]):
		from -= 1
	var to: int = index
	while to + 1 < line.length() and _is_word(line[to + 1]):
		to += 1
	if line[from].is_valid_int():
		return {}
	return {"word": line.substr(from, to - from + 1), "line": row + 1,
		"from": from + 1, "to": to + 2, "after": to + 2}


static func _is_word(character: String) -> bool:
	return character == "_" or character.is_valid_identifier() or character.is_valid_int()


## The text `lookup.gd` wants: the file with U+FFFF at the caret.
##
## The offset is counted over the normalised text, which is the same text the lines
## were split from. Counting it over what arrived would put every position in a
## CRLF file one character out per line above it.
static func _with_cursor(source: String, lines: PackedStringArray, line: int, col: int) -> String:
	var at: int = 0
	for i in range(mini(line - 1, lines.size())):
		at += lines[i].length() + 1
	at += col - 1
	at = clampi(at, 0, source.length())
	return source.substr(0, at) + _Lookup.CURSOR + source.substr(at)


## The range covering `word` on `line`, or a zero-width range at the start of the
## line when the name is not written there.
static func _name_range(lines: PackedStringArray, line: int, word: String,
		encoding: String) -> Dictionary:
	var col: int = _word_column(lines, line, word, 1)
	if col <= 0:
		var start: Dictionary = {"line": maxi(0, line - 1), "character": 0}
		return {"start": start, "end": start}
	return {
		"start": _Positions.from_gate(lines, line, col, encoding),
		"end": _Positions.from_gate(lines, line, col + word.length(), encoding),
	}


## The one-based column `word` stands at on `line` as a whole word, at or after
## `from_col`, or 0. A substring of a longer name is not the name.
static func _word_column(lines: PackedStringArray, line: int, word: String,
		from_col: int) -> int:
	if word == "" or line < 1 or line > lines.size():
		return 0
	var text: String = lines[line - 1]
	var at: int = text.find(word, maxi(0, from_col - 1))
	while at >= 0:
		var after: int = at + word.length()
		if (at == 0 or not _is_word(text[at - 1])) \
				and (after >= text.length() or not _is_word(text[after])):
			return at + 1
		at = text.find(word, at + 1)
	return 0


## `word` as a whole word somewhere between two lines, as `[line, col]`, or `[]`.
static func _find_word(lines: PackedStringArray, word: String, from_line: int,
		from_col: int, to_line: int) -> Array:
	var line: int = maxi(1, from_line)
	var col: int = from_col
	while line <= mini(to_line, lines.size()):
		var found: int = _word_column(lines, line, word, col)
		if found > 0:
			return [line, found]
		line += 1
		col = 1
	return []


## The text an answer is read back out of: the client's for the file it asked
## about, the file on disk for any other. That is the overlay's documented edge.
static func _text_of(target: String, current: String, text: String) -> String:
	if target == current:
		return text
	if not FileAccess.file_exists(target):
		return ""
	return FileAccess.get_file_as_string(target)


static func _engine_markdown(name: String) -> String:
	var parent: String = ClassDB.get_parent_class(name)
	var head: String = "```gate\nclass %s\n```" % name
	if parent == "":
		return head + "\n\nA Godot engine class."
	return head + "\n\nA Godot engine class, extends `%s`." % parent


static func _declaration_markdown(target: String, line: int, word: String,
		current: String, text: String) -> String:
	var file: String = _text_of(target, current, text)
	if file == "":
		return ""
	var lines: PackedStringArray = _Positions.lines_of(_Language.normalized(file))
	if line < 1 or line > lines.size():
		return ""
	var written: String = lines[line - 1].strip_edges()
	if written == "":
		return ""
	var out: String = "```gate\n" + written + "\n```"
	var described: String = _type_markdown(file, target, line, word)
	if described != "":
		out += "\n\n`" + described + "`"
	if target != current:
		out += "\n\nDeclared in `" + target + "`."
	return out


## The type the declaration on `line` declares, from the AST rather than from the
## text. Empty when GATE has no declared type to report, which is the honest
## answer for a `var` with no type on it.
static func _type_markdown(file: String, target: String, line: int, word: String) -> String:
	var source: String = _Language.normalized(file)
	var module: GateAST._Module = _Index.module_for(source, target, _Index.registry())
	if module == null:
		return ""
	var node: Object = _declared_at(module.members, line, word)
	if node == null:
		return ""
	return describe(node)


## The declaration of `word` on `line`, at any depth, or null.
static func _declared_at(nodes: Array, line: int, word: String) -> Object:
	for item in nodes:
		if not (item is GateAST._ASTNode):
			continue
		var node: GateAST._ASTNode = item
		if node.line == line and _named(node) == word:
			return node
		if node is GateAST._EnumDecl and node.line == line \
				and (node as GateAST._EnumDecl).keys.has(word):
			return node
		var deeper: Object = _declared_at(_children(node), line, word)
		if deeper != null:
			return deeper
	return null


static func _named(node: Object) -> String:
	if "name" in node and typeof(node.get("name")) == TYPE_STRING:
		return String(node.get("name"))
	return ""


## Every AST node one node holds, one level down. Lines are the only positions the
## AST carries, so every walk over it has to be written this way.
static func _children(node: Object) -> Array:
	var out: Array = []
	for property in node.get_property_list():
		if (int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var value: Variant = node.get(property["name"])
		if value is Array:
			for entry in value:
				if entry is GateAST._ASTNode:
					out.append(entry)
				elif entry is Array:
					for deeper in entry:
						if deeper is GateAST._ASTNode:
							out.append(deeper)
		elif value is GateAST._ASTNode:
			out.append(value)
	return out


static func describe(node: Object) -> String:
	if node is GateAST._Param:
		var parameter: GateAST._Param = node
		return parameter.type.describe() if parameter.type != null else ""
	if node is GateAST._VarDecl:
		var field: GateAST._VarDecl = node
		return field.type.describe() if field.type != null else ""
	if node is GateAST._FuncDecl:
		var method: GateAST._FuncDecl = node
		var out: String = "func %s(%s)" % [method.name, _describe_params(method.params)]
		if method.return_type != null:
			out += " -> %s" % method.return_type.describe()
		return out
	if node is GateAST._SignalDecl:
		var event: GateAST._SignalDecl = node
		return "signal %s(%s)" % [event.name, _describe_params(event.params)]
	if node is GateAST._EnumDecl:
		return "enum %s" % (node as GateAST._EnumDecl).name
	if node is GateAST._ClassDecl:
		var declared: GateAST._ClassDecl = node
		var head: String = "%s %s" % [declared.form, declared.name]
		if declared.extends_type != null:
			head += " extends %s" % declared.extends_type.describe()
		return head
	if node is GateAST._TypeAliasDecl:
		var alias: GateAST._TypeAliasDecl = node
		return "type %s = %s" % [alias.name,
			alias.target.describe() if alias.target != null else ""]
	return ""


static func _describe_params(params: Array) -> String:
	var out: PackedStringArray = PackedStringArray()
	for item in params:
		var parameter: GateAST._Param = item
		if parameter.type != null:
			out.append("%s: %s" % [parameter.name, parameter.type.describe()])
		else:
			out.append(parameter.name)
	return ", ".join(out)


static func _symbols_of(members: Array, lines: PackedStringArray, inside_class: bool,
		encoding: String) -> Array:
	var out: Array = []
	for item in members:
		var node: Variant = item
		if node is GateAST._AnnotatedStmt:
			node = (node as GateAST._AnnotatedStmt).stmt
		if not (node is GateAST._ASTNode):
			continue
		var entry: Dictionary = _symbol_of(node, lines, inside_class, encoding)
		if not entry.is_empty():
			out.append(entry)
	return out


static func _symbol_of(node: Object, lines: PackedStringArray, inside_class: bool,
		encoding: String) -> Dictionary:
	if node is GateAST._ClassDecl:
		var declared: GateAST._ClassDecl = node
		if declared.name == "":
			return {}
		return _entry(declared.name, _class_kind(declared.form), declared, lines,
			_last_line(declared),
			_symbols_of(declared.members, lines, declared.form != "namespace", encoding),
			encoding)
	if node is GateAST._EnumDecl:
		var declared_enum: GateAST._EnumDecl = node
		if declared_enum.name == "":
			return {}
		var closed: int = _enum_end(lines, declared_enum.line)
		return _entry(declared_enum.name, KIND_ENUM, declared_enum, lines, closed,
			_enum_members(declared_enum, lines, closed, encoding), encoding)
	if node is GateAST._FuncDecl:
		var method: GateAST._FuncDecl = node
		if method.name == "" or method.accessor:
			return {}
		var kind: int = KIND_FUNCTION
		if method.is_operator:
			kind = KIND_OPERATOR
		elif inside_class:
			kind = KIND_METHOD
		return _entry(method.name, kind, method, lines, _last_line(method), [], encoding)
	if node is GateAST._SignalDecl:
		var event: GateAST._SignalDecl = node
		if event.name == "":
			return {}
		return _entry(event.name, KIND_EVENT, event, lines, _last_line(event), [], encoding)
	if node is GateAST._VarDecl:
		var field: GateAST._VarDecl = node
		if field.name == "":
			return {}
		return _entry(field.name, KIND_CONSTANT if field.is_const else KIND_FIELD, field,
			lines, _last_line(field), [], encoding)
	if node is GateAST._TypeAliasDecl:
		var alias: GateAST._TypeAliasDecl = node
		if alias.name == "":
			return {}
		return _entry(alias.name, KIND_TYPE_PARAMETER, alias, lines, _last_line(alias),
			[], encoding)
	return {}


static func _class_kind(form: String) -> int:
	if form == "struct":
		return KIND_STRUCT
	if form == "interface" or form == "trait":
		return KIND_INTERFACE
	if form == "namespace":
		return KIND_NAMESPACE
	return KIND_CLASS


## `range` is the whole declaration, from its own keyword to the end of the last
## line anything under it occupies. `selectionRange` is the name and nothing else.
## Clients place the caret with the second and highlight the block with the first,
## so the two the wrong way round still draws an outline and still misbehaves on
## every click.
static func _entry(name: String, kind: int, node: GateAST._ASTNode,
		lines: PackedStringArray, end_line: int, children: Array,
		encoding: String) -> Dictionary:
	var last: int = clampi(end_line, node.line, maxi(1, lines.size()))
	var whole: Dictionary = {
		"start": _Positions.from_gate(lines, node.line, maxi(1, node.col), encoding),
		"end": _Positions.from_gate(lines, last, _line_length(lines, last) + 1, encoding),
	}
	var entry: Dictionary = {"name": name, "kind": kind, "range": whole,
		"selectionRange": _name_span(lines, node.line, name, maxi(1, node.col), whole, encoding)}
	var detail: String = describe(node)
	if detail != "":
		entry["detail"] = detail
	if not children.is_empty():
		entry["children"] = children
	return entry


static func _name_span(lines: PackedStringArray, line: int, name: String, from_col: int,
		whole: Dictionary, encoding: String) -> Dictionary:
	var col: int = _word_column(lines, line, name, from_col)
	if col <= 0:
		return {"start": whole["start"], "end": whole["start"]}
	return {
		"start": _Positions.from_gate(lines, line, col, encoding),
		"end": _Positions.from_gate(lines, line, col + name.length(), encoding),
	}


static func _line_length(lines: PackedStringArray, line: int) -> int:
	if line < 1 or line > lines.size():
		return 0
	return lines[line - 1].length()


## The last line anything under this node occupies.
static func _last_line(node: GateAST._ASTNode) -> int:
	return maxi(node.line, _Lookup._extent(node))


## An enum's body is braces rather than indentation, and its keys carry no line at
## all, so its extent is read off the text instead of off the AST. Without this the
## range of a multi-line enum stops on its first line.
static func _enum_end(lines: PackedStringArray, start: int) -> int:
	var depth: int = 0
	var opened: bool = false
	var line: int = start
	while line <= lines.size() and line - start < MAX_ENUM_LINES:
		var text: String = lines[line - 1]
		for i in range(text.length()):
			if text[i] == "{":
				depth += 1
				opened = true
			elif text[i] == "}":
				depth -= 1
				if opened and depth <= 0:
					return line
		line += 1
	return start


static func _enum_members(declared: GateAST._EnumDecl, lines: PackedStringArray,
		end_line: int, encoding: String) -> Array:
	var out: Array = []
	var line: int = declared.line
	var col: int = maxi(1, declared.col)
	for item in declared.keys:
		var key: String = String(item)
		var found: Array = _find_word(lines, key, line, col, end_line)
		if found.is_empty():
			continue
		line = int(found[0])
		col = int(found[1]) + key.length()
		var span: Dictionary = {
			"start": _Positions.from_gate(lines, line, int(found[1]), encoding),
			"end": _Positions.from_gate(lines, line, col, encoding),
		}
		out.append({"name": key, "kind": KIND_ENUM_MEMBER, "range": span,
			"selectionRange": span})
	return out

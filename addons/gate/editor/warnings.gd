@tool
extends RefCounted

const _Autoload: GDScript = preload("res://addons/gate/editor/autoload.gd")

const NEWLINE: int = GateLexer._T.NEWLINE
const INDENT: int = GateLexer._T.INDENT
const DEDENT: int = GateLexer._T.DEDENT
const EOF: int = GateLexer._T.EOF
const IDENT: int = GateLexer._T.IDENT
const KEYWORD: int = GateLexer._T.KEYWORD
const STRING: int = GateLexer._T.STRING
const FSTRING: int = GateLexer._T.FSTRING
const ANNOTATION: int = GateLexer._T.ANNOTATION
const COMMENT: int = GateLexer._T.COMMENT
const OP: int = GateLexer._T.OP

const UNUSED_VARIABLE: int = 2
const UNUSED_LOCAL_CONSTANT: int = 3
const UNUSED_PARAMETER: int = 5
const UNUSED_SIGNAL: int = 6
const SHADOWED_VARIABLE: int = 7
const SHADOWED_VARIABLE_BASE_CLASS: int = 8

const NAMES: Dictionary = {
	UNUSED_VARIABLE: "UNUSED_VARIABLE",
	UNUSED_LOCAL_CONSTANT: "UNUSED_LOCAL_CONSTANT",
	UNUSED_PARAMETER: "UNUSED_PARAMETER",
	UNUSED_SIGNAL: "UNUSED_SIGNAL",
	SHADOWED_VARIABLE: "SHADOWED_VARIABLE",
	SHADOWED_VARIABLE_BASE_CLASS: "SHADOWED_VARIABLE_BASE_CLASS",
}

const SETTING: String = "debug/gdscript/warnings/"

const MODIFIERS: Dictionary = {
	"static": true, "pub": true, "priv": true, "final": true, "virtual": true,
	"override": true, "abstract": true,
}
const CLASS_FORMS: Dictionary = {
	"class": true, "struct": true, "interface": true, "trait": true, "namespace": true,
}
const ASSIGN_OPS: Dictionary = {
	"=": true, "+=": true, "-=": true, "*=": true, "/=": true, "%=": true,
	"**=": true, "<<=": true, ">>=": true, "&=": true, "|=": true, "^=": true,
}
const TYPE_PUNCTUATION: Dictionary = {
	"[": true, "]": true, "?": true, "!": true, "{": true, "}": true, ",": true,
}
const OPENERS: Dictionary = {"(": true, "[": true, "{": true}
const CLOSERS: Dictionary = {")": true, "]": true, "}": true}

const LOCAL_KINDS: Dictionary = {
	"variable": "variable", "constant": "constant",
	"parameter": "function parameter", "iterator": "\"for\" iterator variable",
}

const MAX_BASES: int = 16

static var _members_cache: Dictionary = {}
static var _native_cache: Dictionary = {}
static var _file_cache: Dictionary = {}

var t: Array = []
var n: int = 0
var classes: Array = []
var funcs: Array = []
var sigs: Array = []
var decls: Array = []
var named: Dictionary = {}
var ignores: Array = []
var opened: Dictionary = {}


## Every warning this file earns, as the dictionaries `_validate` hands the editor.
func collect(path: String, tokens: Array) -> Array:
	var allowed: Dictionary = _allowed(path)
	if allowed.is_empty():
		return []
	read(tokens)
	return report(allowed, path)


## Which warnings this project asks for, from the settings GDScript itself reads.
static func _allowed(path: String) -> Dictionary:
	var out: Dictionary = {}
	if not bool(ProjectSettings.get_setting(SETTING + "enable", true)):
		return out
	var rules: Variant = ProjectSettings.get_setting(SETTING + "directory_rules", {})
	if rules is Dictionary:
		var longest: int = -1
		var decision: int = -1
		for key in rules:
			var dir: String = String(key)
			if path.begins_with(dir) and dir.length() > longest:
				longest = dir.length()
				decision = int((rules as Dictionary)[key])
		if decision == 0:
			return out
	for code in NAMES:
		var name: String = String(NAMES[code])
		if int(ProjectSettings.get_setting(SETTING + name.to_lower(), 1)) != 0:
			out[name] = true
	return out


## A base class may have moved or changed; the engine's own members cannot.
static func forget() -> void:
	_members_cache.clear()
	_file_cache.clear()


# ───────────────────────── the walk ─────────────────────────

func read(tokens: Array) -> void:
	for tok in tokens:
		if tok.type != COMMENT:
			t.append(tok)
	n = t.size()
	classes.append({"members": {}, "base": "", "line": 1, "parent": -1})
	if n > 0:
		_block(0, 0, -1)
	for code in opened:
		ignores.append({"code": String(code), "from": int(opened[code]), "to": 1 << 30})


## Statements until this block's DEDENT; returns the index of that DEDENT.
func _block(start: int, cls: int, fn: int) -> int:
	var i: int = start
	var carried: Array = []
	while i < n:
		var kind: int = t[i].type
		if kind == DEDENT or kind == EOF:
			return i
		if kind == NEWLINE or kind == INDENT:
			i += 1
			continue
		var stop: int = _stmt_end(i)
		var k: int = _annotations(i, stop, carried)
		if k >= stop:
			i = stop + 1
			continue
		var silenced: Array = carried.duplicate()
		carried.clear()
		var head: int = k
		while k < stop and t[k].type == KEYWORD and MODIFIERS.has(t[k].value):
			k += 1
		var opens: int = _body_of(stop)
		var sub_cls: int = cls
		var sub_fn: int = fn
		if k < stop:
			var made: Array = _statement(k, stop, cls, fn, opens >= 0)
			sub_cls = int(made[0])
			sub_fn = int(made[1])
		var last: int = t[mini(stop, n - 1)].line
		if opens >= 0:
			i = _block(opens + 1, sub_cls, sub_fn)
			if sub_fn != fn and sub_fn >= 0:
				funcs[sub_fn]["to"] = i
			i += 1
		else:
			i = stop + 1
		# `@warning_ignore` covers the statement it is written on and not the
		# block under it: GDScript still warns inside a function whose `func`
		# line carries one. Only `@warning_ignore_start` silences a region.
		for code in silenced:
			ignores.append({"code": String(code), "from": t[head].line, "to": last})
	return i


## The annotations a statement opens with, and the index past them. A statement
## that is nothing else carries its `@warning_ignore` to the next one.
func _annotations(from: int, stop: int, carried: Array) -> int:
	var k: int = from
	while k < stop and t[k].type == ANNOTATION:
		var name: String = t[k].value
		var args: Array = []
		var j: int = k + 1
		if j < stop and t[j].type == OP and t[j].value == "(":
			var depth: int = 0
			while j < stop:
				if t[j].type == OP and t[j].value == "(":
					depth += 1
				elif t[j].type == OP and t[j].value == ")":
					depth -= 1
					if depth <= 0:
						j += 1
						break
				elif t[j].type == STRING:
					args.append(t[j].value)
				j += 1
		if name == "@warning_ignore":
			for arg in args:
				carried.append(String(arg).to_upper())
		elif name == "@warning_ignore_start":
			for arg in args:
				opened[String(arg).to_upper()] = t[k].line
		elif name == "@warning_ignore_restore":
			for arg in args:
				var code: String = String(arg).to_upper()
				if opened.has(code):
					ignores.append({"code": code, "from": int(opened[code]), "to": t[k].line})
					opened.erase(code)
		k = j
	return k


## What a statement declares, and the scope its own block belongs to.
func _statement(k: int, stop: int, cls: int, fn: int, opens: bool) -> Array:
	var tok: Object = t[k]
	if tok.type == KEYWORD:
		var word: String = tok.value
		if word == "func":
			return [cls, _function(k, stop, cls, opens)]
		if CLASS_FORMS.has(word):
			return [_class(k, stop, cls), fn]
		if word == "extends":
			classes[cls]["base"] = _base_name(k + 1, stop)
			return [cls, fn]
		if word == "signal":
			if k + 1 < stop and t[k + 1].type == IDENT:
				_declare(cls, t[k + 1].value, "signal", t[k + 1].line, k + 1)
				sigs.append({"name": t[k + 1].value, "at": k + 1})
			return [cls, fn]
		if word == "enum":
			_enum(k, stop, cls)
			return [cls, fn]
		if word == "var" or word == "const":
			if k + 1 < stop and t[k + 1].type == IDENT:
				_name(cls, fn, "constant" if word == "const" else "variable", k + 1)
			return [cls, fn]
		if word == "for":
			_loop(k, stop, fn)
			return [cls, fn]
		return [cls, fn]
	if fn < 0 and opens and tok.type == IDENT and (tok.value == "set" or tok.value == "get"):
		return [cls, _accessor(k, cls)]
	if tok.type == IDENT and tok.value == "type" and k + 1 < stop and t[k + 1].type == IDENT:
		_declare(cls, t[k + 1].value, "alias", t[k + 1].line, k + 1)
		return [cls, fn]
	for at in _type_first(k, stop):
		_name(cls, fn, "variable", int(at))
	return [cls, fn]


## A declaration belongs to the function it is written in, or to the class.
func _name(cls: int, fn: int, kind: String, at: int) -> void:
	if fn < 0:
		_declare(cls, t[at].value, kind, t[at].line, at)
		return
	named[at] = true
	decls.append({"name": t[at].value, "kind": kind, "at": at, "fn": fn, "cls": cls})


func _declare(cls: int, name: String, kind: String, line: int, at: int) -> void:
	named[at] = true
	if not classes[cls]["members"].has(name):
		classes[cls]["members"][name] = {"kind": kind, "line": line}


func _class(k: int, stop: int, cls: int) -> int:
	var made: int = classes.size()
	classes.append({"members": {}, "base": "", "line": t[k].line, "parent": cls})
	if k + 1 < stop and t[k + 1].type == IDENT:
		_declare(cls, t[k + 1].value, "constant", t[k + 1].line, k + 1)
	var j: int = k + 1
	while j < stop:
		if t[j].type == KEYWORD and t[j].value == "extends":
			classes[made]["base"] = _base_name(j + 1, stop)
			break
		j += 1
	return made


func _base_name(k: int, stop: int) -> String:
	if k >= stop:
		return ""
	if t[k].type == IDENT:
		return t[k].value
	if t[k].type == STRING:
		return "\"%s\"" % t[k].value
	return ""


func _enum(k: int, stop: int, cls: int) -> void:
	var j: int = k + 1
	if j < stop and t[j].type == IDENT:
		_declare(cls, t[j].value, "enum", t[j].line, j)
		return
	var expect: bool = true
	while j < stop:
		if t[j].type == IDENT and expect:
			_declare(cls, t[j].value, "constant", t[j].line, j)
			expect = false
		elif t[j].type == OP and t[j].value == ",":
			expect = true
		j += 1


## `for i in`, `for i: T in`, `for T i in` and `for k, v in`, which name their
## variable in three different places.
func _loop(k: int, stop: int, fn: int) -> void:
	if fn < 0:
		return
	var chunk: Array = []
	var depth: int = 0
	var j: int = k + 1
	while j < stop:
		var tok: Object = t[j]
		if tok.type == KEYWORD and tok.value == "in" and depth == 0:
			break
		if tok.type == OP and OPENERS.has(tok.value):
			depth += 1
		elif tok.type == OP and CLOSERS.has(tok.value):
			depth -= 1
		elif tok.type == OP and tok.value == "," and depth == 0:
			var got: int = _parameter(chunk)
			if got >= 0:
				_iterator(fn, got)
			chunk = []
			j += 1
			continue
		chunk.append(j)
		j += 1
	var last: int = _parameter(chunk)
	if last >= 0:
		_iterator(fn, last)


func _iterator(fn: int, at: int) -> void:
	named[at] = true
	decls.append({"name": t[at].value, "kind": "iterator", "at": at, "fn": fn,
		"cls": int(funcs[fn]["cls"])})


## A `set:` or `get:` block is a function body written inside a declaration.
func _accessor(k: int, cls: int) -> int:
	var made: int = funcs.size()
	funcs.append({"name": "", "cls": cls, "from": k, "to": k})
	return made


func _function(k: int, stop: int, cls: int, opens: bool) -> int:
	var made: int = funcs.size()
	var name: String = ""
	var j: int = k + 1
	if j < stop and t[j].type == IDENT:
		name = t[j].value
		_declare(cls, name, "function", t[j].line, j)
		j += 1
	funcs.append({"name": name, "cls": cls, "from": stop, "to": stop})
	if not opens or name == "":
		return made
	while j < stop and not (t[j].type == OP and t[j].value == "("):
		j += 1
	for at in _parameters(j, stop):
		named[int(at)] = true
		decls.append({"name": t[int(at)].value, "kind": "parameter", "at": int(at),
			"fn": made, "cls": cls})
	return made


## Every parameter name in the list opening at `k`, as token indexes. A list with
## one parameter this cannot place gives none at all.
func _parameters(k: int, stop: int) -> Array:
	var depth: int = 0
	var chunk: Array = []
	var out: Array = []
	var j: int = k
	while j < stop:
		var tok: Object = t[j]
		if tok.type == OP and OPENERS.has(tok.value):
			depth += 1
			if depth == 1:
				j += 1
				continue
		elif tok.type == OP and CLOSERS.has(tok.value):
			depth -= 1
			if depth == 0:
				if chunk.is_empty():
					return out
				var done: int = _parameter(chunk)
				if done < 0:
					return []
				out.append(done)
				return out
		if depth == 1 and tok.type == OP and tok.value == ",":
			var got: int = _parameter(chunk)
			if got < 0:
				return []
			out.append(got)
			chunk = []
			j += 1
			continue
		if depth >= 1:
			chunk.append(j)
		j += 1
	return []


## The name in one parameter, whichever of the three spellings it is written in.
func _parameter(chunk: Array) -> int:
	var span: Array = chunk.duplicate()
	while not span.is_empty() and t[int(span[0])].type == OP and t[int(span[0])].value == "...":
		span.remove_at(0)
	if span.is_empty():
		return -1
	var depth: int = 0
	var head: int = span.size()
	for i in span.size():
		var tok: Object = t[int(span[i])]
		if tok.type != OP:
			continue
		if OPENERS.has(tok.value):
			depth += 1
		elif CLOSERS.has(tok.value):
			depth -= 1
		elif depth == 0 and tok.value == ":":
			return int(span[0]) if t[int(span[0])].type == IDENT else -1
		elif depth == 0 and (ASSIGN_OPS.has(tok.value) or tok.value == ":="):
			head = i
			break
	for i in range(head - 1, -1, -1):
		if t[int(span[i])].type == IDENT:
			return int(span[i])
	return -1


## A type-first declaration, `int hp = 100`, and the shapes that are not one.
## Anything the token stream cannot place on its own - a dotted type, a generic,
## a call - declares nothing rather than guessing at a name.
func _type_first(k: int, stop: int) -> Array:
	var depth: int = 0
	var head: int = stop
	var inferred: bool = false
	var j: int = k
	while j < stop:
		var tok: Object = t[j]
		if tok.type == OP:
			if OPENERS.has(tok.value):
				depth += 1
			elif CLOSERS.has(tok.value):
				depth -= 1
			elif depth == 0 and (ASSIGN_OPS.has(tok.value) or tok.value == ":="):
				head = j
				inferred = tok.value == ":="
				break
		j += 1
	if head - k == 1 and inferred and t[k].type == IDENT:
		return [k]
	if head - k < 2:
		return []
	var names: Array = []
	var size: int = 0
	var last: int = -1
	depth = 0
	for i in range(k, head):
		var tok: Object = t[i]
		if tok.type == IDENT:
			last = i
			size += 1
			continue
		if tok.type == KEYWORD and tok.value == "void":
			last = -1
			size += 1
			continue
		if tok.type != OP or not TYPE_PUNCTUATION.has(tok.value):
			return []
		if OPENERS.has(tok.value):
			depth += 1
		elif CLOSERS.has(tok.value):
			depth -= 1
		elif tok.value == "," and depth == 0:
			if last < 0 or size < 2:
				return []
			names.append(last)
			last = -1
			size = 0
			continue
		size += 1
		last = -1
	if last < 0 or size < 2:
		return []
	names.append(last)
	return names


func _stmt_end(from: int) -> int:
	var depth: int = 0
	var j: int = from
	while j < n:
		var tok: Object = t[j]
		if tok.type == NEWLINE or tok.type == EOF:
			return j
		if tok.type == OP:
			if OPENERS.has(tok.value):
				depth += 1
			elif CLOSERS.has(tok.value):
				depth -= 1
			elif tok.value == ";" and depth <= 0:
				return j
		j += 1
	return n - 1


## The INDENT that opens this statement's block, or -1. A blank line between the
## header and the body is a newline of its own.
func _body_of(stop: int) -> int:
	var j: int = stop
	while j < n and t[j].type == NEWLINE:
		j += 1
	return j if j < n and t[j].type == INDENT else -1


# ───────────────────────── names written again ─────────────────────────

## Every name read between two tokens.
##
## Two rules here are GDScript's own, kept so a `.gate` and the `.gd` beside it
## say the same thing. A name that is only assigned to is not read. A name written
## after a dot belongs to something else, but GDScript counts it as a use of a
## local of that name anyway, so a parameter called `button_pressed` in a function
## that reads `button.button_pressed` is left alone. A signal is the exception:
## there Godot counts only the class's own, so the dot has to follow `self`.
func _used(from: int, to: int, attributes: bool) -> Dictionary:
	var out: Dictionary = {}
	for i in range(maxi(from, 0), mini(to, n)):
		var tok: Object = t[i]
		if tok.type == FSTRING:
			for word in _words(tok.value):
				out[word] = true
			continue
		if tok.type != IDENT or named.has(i):
			continue
		if i > 0 and t[i - 1].type == OP and (t[i - 1].value == "." or t[i - 1].value == "?."):
			if not attributes and not (i > 1 and t[i - 2].type == KEYWORD
					and (t[i - 2].value == "self" or t[i - 2].value == "super")):
				continue
		elif i > 0 and _starts_statement(i) and i + 1 < n and t[i + 1].type == OP \
				and ASSIGN_OPS.has(t[i + 1].value):
			continue
		out[tok.value] = true
	return out


func _starts_statement(i: int) -> bool:
	var kind: int = t[i - 1].type
	if kind == NEWLINE or kind == INDENT or kind == DEDENT:
		return true
	return kind == OP and t[i - 1].value == ";"


## The identifiers inside an f-string, which the lexer keeps as one token.
func _words(text: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var word: String = ""
	for i in text.length():
		var c: String = text[i]
		if c == "_" or c.is_valid_identifier() or (word != "" and c.is_valid_int()):
			word += c
		else:
			if word != "":
				out.append(word)
			word = ""
	if word != "":
		out.append(word)
	return out


# ───────────────────────── the answer ─────────────────────────

func report(allowed: Dictionary, path: String) -> Array:
	var out: Array = []
	_unused(allowed, out)
	_signals(allowed, out)
	_shadowed(allowed, path, out)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["start_line"]) < int(b["start_line"]))
	return out


func _unused(allowed: Dictionary, out: Array) -> void:
	var reads: Array = []
	for fn in funcs.size():
		reads.append(_used(int(funcs[fn]["from"]), int(funcs[fn]["to"]), true))
	for decl in decls:
		var name: String = String(decl["name"])
		var kind: String = String(decl["kind"])
		if name.begins_with("_") or kind == "iterator":
			continue
		var fn: int = int(decl["fn"])
		if fn < 0 or fn >= reads.size() or Dictionary(reads[fn]).has(name):
			continue
		if int(funcs[fn]["to"]) <= int(funcs[fn]["from"]):
			continue
		if kind == "parameter":
			_add(allowed, out, UNUSED_PARAMETER, int(decl["at"]),
				("The parameter \"%s\" is never used in the function \"%s()\". "
					+ "If this is intended, prefix it with an underscore: \"_%s\".")
					% [name, String(funcs[fn]["name"]), name])
		elif kind == "constant":
			_add(allowed, out, UNUSED_LOCAL_CONSTANT, int(decl["at"]),
				("The local constant \"%s\" is declared but never used in the block. "
					+ "If this is intended, prefix it with an underscore: \"_%s\".")
					% [name, name])
		else:
			_add(allowed, out, UNUSED_VARIABLE, int(decl["at"]),
				("The local variable \"%s\" is declared but never used in the block. "
					+ "If this is intended, prefix it with an underscore: \"_%s\".")
					% [name, name])


## A signal counts as used anywhere in the file, including by name in a string,
## which is how `connect("hit", ...)` names one.
func _signals(allowed: Dictionary, out: Array) -> void:
	if sigs.is_empty():
		return
	var reads: Dictionary = _used(0, n, false)
	for i in n:
		if t[i].type == STRING:
			reads[t[i].value] = true
	for sig in sigs:
		if reads.has(String(sig["name"])):
			continue
		_add(allowed, out, UNUSED_SIGNAL, int(sig["at"]),
			"The signal \"%s\" is declared but never explicitly used in the class."
				% String(sig["name"]))


func _shadowed(allowed: Dictionary, path: String, out: Array) -> void:
	for decl in decls:
		var name: String = String(decl["name"])
		var cls: int = int(decl["cls"])
		var kind: String = String(LOCAL_KINDS.get(String(decl["kind"]), "variable"))
		var here: Dictionary = classes[cls]["members"]
		if here.has(name):
			var member: Dictionary = here[name]
			if String(member["kind"]) == "alias":
				continue
			_add(allowed, out, SHADOWED_VARIABLE, int(decl["at"]),
				("The local %s \"%s\" is shadowing an already-declared %s at line %d "
					+ "in the current class.")
					% [kind, name, String(member["kind"]), int(member["line"])])
			continue
		var found: Dictionary = _in_bases(String(classes[cls]["base"]), path, name)
		if found.is_empty():
			continue
		if bool(found["native"]):
			_add(allowed, out, SHADOWED_VARIABLE_BASE_CLASS, int(decl["at"]),
				("The local %s \"%s\" is shadowing an already-declared %s "
					+ "in the base class \"%s\".")
					% [kind, name, String(found["kind"]), String(found["class"])])
		else:
			_add(allowed, out, SHADOWED_VARIABLE_BASE_CLASS, int(decl["at"]),
				("The local %s \"%s\" is shadowing an already-declared %s at line %d "
					+ "in the base class \"%s\".")
					% [kind, name, String(found["kind"]), int(found["line"]),
						String(found["class"])])


func _in_bases(base: String, path: String, name: String) -> Dictionary:
	if base == "":
		return {}
	for entry in _bases_of(base, path):
		var step: Dictionary = entry
		if not bool(step["native"]):
			var members: Dictionary = step["members"]
			if not members.has(name):
				continue
			var member: Dictionary = members[name]
			if String(member["kind"]) == "alias":
				continue
			return {"native": false, "class": String(step["class"]),
				"kind": String(member["kind"]), "line": int(member["line"])}
		var native: String = String(step["class"])
		while native != "":
			var members: Dictionary = _native_members(native)
			if members.has(name):
				return {"native": true, "class": native, "kind": String(members[name]),
					"line": 0}
			native = ClassDB.get_parent_class(native)
	return {}


## What one engine class declares itself, as name -> the word Godot's own warning
## uses for it. Built once per class and kept, because ClassDB never changes.
func _native_members(cls: String) -> Dictionary:
	if _native_cache.has(cls):
		return _native_cache[cls]
	var out: Dictionary = {}
	for name in ClassDB.class_get_integer_constant_list(cls, true):
		out[String(name)] = "constant"
	for entry in ClassDB.class_get_signal_list(cls, true):
		out[String(entry["name"])] = "signal"
	for entry in ClassDB.class_get_method_list(cls, true):
		out[String(entry["name"])] = "method"
	for entry in ClassDB.class_get_property_list(cls, true):
		if (int(entry["usage"]) & PROPERTY_USAGE_GROUP) != 0 				or (int(entry["usage"]) & PROPERTY_USAGE_SUBGROUP) != 0 				or (int(entry["usage"]) & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		out[String(entry["name"])] = "property"
	_native_cache[cls] = out
	return out


## `type_name` and each of its bases, nearest first. A native class carries no
## lines, so its members are asked of ClassDB rather than listed here.
func _bases_of(type_name: String, from: String) -> Array:
	var key: String = type_name + "|" + from
	if _members_cache.has(key):
		return _members_cache[key]
	var out: Array = []
	var name: String = type_name
	var origin: String = from
	var seen: Dictionary = {}
	for step in MAX_BASES:
		if name == "" or seen.has(name):
			break
		seen[name] = true
		if ClassDB.class_exists(name):
			out.append({"class": name, "members": {}, "native": true})
			break
		var file: String = _file_of(name, origin)
		if file == "":
			break
		var read_back: Dictionary = _members_in(file)
		out.append({"class": name, "members": read_back["members"], "native": false})
		name = String(read_back["base"])
		origin = file
	_members_cache[key] = out
	return out


## The file a base is written in, whether it was named or written as a path.
func _file_of(name: String, from: String) -> String:
	if name.begins_with("\"") or name.begins_with("'"):
		var path: String = name.substr(1, name.length() - 2)
		if not path.begins_with("res://"):
			if from == "":
				return ""
			path = from.get_base_dir().path_join(path).simplify_path()
		return _Autoload.source_of(path)
	for entry in ProjectSettings.get_global_class_list():
		if String(entry["class"]) == name:
			return _Autoload.source_of(String(entry["path"]))
	return ""


## One other file, read for its declarations only, and kept: a base class is read
## once per session however many files extend it.
func _members_in(file: String) -> Dictionary:
	if _file_cache.has(file):
		return _file_cache[file]
	var found: Dictionary = _read_file(file)
	_file_cache[file] = found
	return found


func _read_file(file: String) -> Dictionary:
	if not FileAccess.file_exists(file):
		return {"members": {}, "base": ""}
	var text: String = FileAccess.get_file_as_string(file)
	var diagnostics: GateDiagnostics = GateDiagnostics.new()
	diagnostics.file = file
	var tokens: Array = GateLexer.new().tokenize(text, diagnostics)
	for item in diagnostics.items:
		if item.level == GateDiagnostics._Level.ERROR:
			return {"members": {}, "base": ""}
	var scan: RefCounted = (get_script() as GDScript).new()
	scan.call("read", tokens)
	var top: Dictionary = scan.get("classes")[0]
	return {"members": top["members"], "base": String(top["base"])}


func _add(allowed: Dictionary, out: Array, code: int, at: int, message: String) -> void:
	var name: String = String(NAMES[code])
	if not allowed.has(name):
		return
	var line: int = t[at].line
	for rule in ignores:
		if String(rule["code"]) == name and line >= int(rule["from"]) \
				and line <= int(rule["to"]):
			return
	out.append({
		"start_line": line,
		"end_line": line,
		"leftmost_column": t[at].col,
		"rightmost_column": t[at].col + t[at].value.length(),
		"code": code,
		"string_code": name,
		"message": message,
	})

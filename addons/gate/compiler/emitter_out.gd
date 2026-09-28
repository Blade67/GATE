@tool
extends RefCounted

## Emitter layer 1: the output buffer, the sourcemap, and all mutable state.

var diagnostics: GateDiagnostics

var source_path: String = ""

var _out: PackedStringArray = []

var _map: Array[int] = []          ## output line -> source line

## One entry per `@global` class emitted this compile: its own script, beside the
## source. {"path", "class_name", "source", "map", "deps"}.
var _extra_outputs: Array = []

var _indent: int = 0

## Source lines with at least one blank above them. A presence flag, not a count:
## a function trailer already emits one blank, so "at least one here, never two" is
## the only rule stable in both directions.
var _blank_before: Dictionary = {}

var _src_lines: PackedStringArray = []

var _leading_comment: Dictionary = {}   ## source line -> text, comment alone on its line

var _trailing_comment: Dictionary = {}   ## source line -> the gap and text to append

var _claimed_comment: Dictionary = {}   ## source lines already put back, never twice

var _run_stopped_at_claimed: bool = false

var _pending_line_src: Array = []

var _coll_depth: int = 0


func set_source(src: String) -> void:
	_src_text = src
	_blank_before.clear()
	var lines: PackedStringArray = src.split("\n")
	_src_lines = lines
	for i in range(lines.size()):
		var j: int = i - 1
		var saw_blank: bool = false
		while j >= 0:
			var t: String = lines[j].strip_edges()
			if t == "":
				saw_blank = true
				j -= 1
				continue
			if t.begins_with("#"):
				j -= 1
				continue
			if _is_annotation_only_line(t):
				j -= 1
				continue
			break
		if saw_blank and j >= 0:
			_blank_before[i + 1] = true


static func _after_annotation(t: String) -> int:
	var i: int = 1
	while i < t.length() and _is_name_char_out(t[i]):
		i += 1
	if i < t.length() and t[i] == "(":
		var depth: int = 0
		var quote: String = ""
		while i < t.length():
			if quote != "":
				if t[i] == "\\":
					i += 2
					continue
				if t[i] == quote:
					quote = ""
			elif t[i] == '"' or t[i] == "'":
				quote = t[i]
			elif t[i] == "(":
				depth += 1
			elif t[i] == ")":
				depth -= 1
				if depth == 0:
					i += 1
					break
			i += 1
	return i


static func _is_annotation_only_line(t: String) -> bool:
	if not t.begins_with("@"):
		return false
	return t.substr(_after_annotation(t)).strip_edges() == ""


## The same, but a trailing comment does not disqualify the line: `@warning_ignore(...)
## # why` above a `##` block is still the declaration's own annotation, and stopping
## there orphaned the whole doc block on the second compile.
static func _is_annotation_line_above(t: String) -> bool:
	if not t.begins_with("@"):
		return false
	var rest: String = t.substr(_after_annotation(t)).strip_edges()
	return rest == "" or rest.begins_with("#")


static func _is_name_char_out(c: String) -> bool:
	return ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
		or (c >= "0" and c <= "9") or c == "_")


func set_comments(tokens: Array) -> void:
	_leading_comment.clear()
	_trailing_comment.clear()
	_claimed_comment.clear()
	# Output opens with the generated banner, which is comments. Reading GATE's own output
	# back must not take that in as the file's own, or every compile reprints it.
	var skip_to: int = HEADER_LINES.size() if _src_text.begins_with(HEADER_MARKER) else 0
	var code_on: Dictionary = {}
	for t in tokens:
		var tok: GateLexer._Token = t
		if tok.type == GateLexer._T.COMMENT or tok.type == GateLexer._T.NEWLINE \
				or tok.type == GateLexer._T.INDENT or tok.type == GateLexer._T.DEDENT \
				or tok.type == GateLexer._T.EOF:
			continue
		code_on[tok.line] = true
	for t in tokens:
		var tok2: GateLexer._Token = t
		if tok2.type != GateLexer._T.COMMENT or tok2.line <= skip_to:
			continue
		if code_on.has(tok2.line):
			_trailing_comment[tok2.line] = _gap_before(tok2.line, tok2.col) + tok2.value
		else:
			_leading_comment[tok2.line] = tok2.value


## The whitespace the author left between the code and the `#`, so a trailing comment
## keeps its own spacing rather than a house style GATE does not otherwise impose.
func _gap_before(line: int, col: int) -> String:
	if line < 1 or line > _src_lines.size():
		return "  "
	var text: String = _src_lines[line - 1]
	var at: int = mini(col - 1, text.length())
	var start: int = at
	while start > 0 and (text[start - 1] == " " or text[start - 1] == "\t"):
		start -= 1
	var gap: String = text.substr(start, at - start)
	return gap if gap != "" else " "


## Puts a trailing comment back on the line it was written on.
##
## Only where one source line produced exactly one real output line. A source
## line can become several - `@rpc func f()` on one line comes out on two - or
## none at all, and there is then no single right place for the comment, so it is
## dropped rather than guessed at. Trailing comments are about 5% of the
## comments in real code, and the part of that dropped here is smaller again.
func emit_inline_comments() -> void:
	if _trailing_comment.is_empty():
		return
	var real: Dictionary = {}
	for i in range(mini(_out.size(), _map.size())):
		var t: String = _out[i].strip_edges()
		# Blank and comment lines do not count, or the eight-line banner - all of
		# which map to source line 1 - would stop line 1 ever qualifying.
		if t == "" or t.begins_with("#"):
			continue
		real[_map[i]] = int(real.get(_map[i], 0)) + 1
	var inside: Dictionary = GateCompiler.lines_inside_strings("\n".join(_out))
	for i in range(mini(_out.size(), _map.size())):
		var src_line: int = _map[i]
		if not _trailing_comment.has(src_line) or int(real.get(src_line, 0)) != 1:
			continue
		# A region copied out as written already carries its own trailing comment. Appending
		# again doubled it, and the lexer reads everything after the first `#` as one comment,
		# so the next compile doubled the doubled one.
		if _claimed_comment.has(src_line):
			continue
		# A line that opens a multi-line string is not itself marked as inside one,
		# but anything appended to it lands in the string.
		if inside.has(i) or inside.has(i + 1):
			continue
		var text: String = _out[i]
		var stripped: String = text.strip_edges()
		if stripped == "" or stripped.begins_with("#") or text.ends_with("\\"):
			continue
		_out[i] = text + String(_trailing_comment[src_line])


func first_code_line() -> int:
	for i in range(_src_lines.size()):
		var t: String = _src_lines[i].strip_edges()
		if t != "" and not t.begins_with("#"):
			return i + 1
	return 0


func emit_trailing_comments() -> void:
	var last_code: int = 0
	for i in range(_src_lines.size()):
		var t: String = _src_lines[i].strip_edges()
		if t != "" and not t.begins_with("#"):
			last_code = i + 1
	var run: Array = []
	for line in range(last_code + 1, _src_lines.size() + 1):
		if _leading_comment.has(line) and not _claimed_comment.has(line):
			run.append(line)
	_emit_comment_run(run)


func _blank_gap(src_line: int) -> void:
	var run: Array = _comment_run_above(src_line)
	if run.is_empty():
		# An annotated statement gaps twice, once for itself and once for what it wraps, and
		# `_blank_before` reads a blank straight through the comments above it.
		if _run_stopped_at_claimed:
			return
		if _blank_before.has(src_line):
			_blank_line(src_line)
		return
	var prev: int = _emit_comment_run(run)
	if _blank_between(prev, src_line):
		_blank_line(src_line)


## Emits a block of comment lines as one unit. Asking `_blank_before` per line instead
## reads a blank through the comments above and separates every line of a block.
func _emit_comment_run(run: Array) -> int:
	if run.is_empty():
		return 0
	if _blank_before.has(int(run[0])):
		_blank_line(int(run[0]))
	var prev: int = 0
	for entry in run:
		var line: int = int(entry)
		if prev > 0 and _blank_between(prev, line):
			_blank_line(line)
		_claimed_comment[line] = true
		_line(String(_leading_comment[line]), line)
		prev = line
	return prev


func _comment_run_above(src_line: int) -> Array:
	var out: Array = []
	_run_stopped_at_claimed = false
	var i: int = src_line - 1
	while i >= 1 and i <= _src_lines.size():
		if _leading_comment.has(i):
			if _claimed_comment.has(i):
				_run_stopped_at_claimed = true
				break
			out.push_front(i)
			i -= 1
			continue
		var t: String = _src_lines[i - 1].strip_edges()
		# An annotation on its own line belongs to the declaration below it, so a
		# doc comment above `@export` documents the `var`, not the annotation.
		if t == "" or _is_annotation_line_above(t):
			i -= 1
			continue
		break
	return out


func _claim_lines(from_line: int, to_line: int) -> void:
	for i in range(from_line, to_line + 1):
		_claimed_comment[i] = true


func _blank_between(after: int, before: int) -> bool:
	for i in range(after + 1, before):
		if i >= 1 and i <= _src_lines.size() and _src_lines[i - 1].strip_edges() == "":
			return true
	return false


func _blank_line(src_line: int) -> void:
	if _out.is_empty() or _out[_out.size() - 1].strip_edges() == "":
		return
	if not _code_emitted():
		return   # as `set_source` reads it back: no blank above the first line of code
	_out.append("")
	_map.append(src_line)


func _code_emitted() -> bool:
	for l in _out:
		var t: String = String(l).strip_edges()
		if t != "" and not t.begins_with("#") and not _is_annotation_only_line(t):
			return true
	return false

var _tmp: int = 0

var _pending: PackedStringArray = []

var _structs: Dictionary = {}

var _var_types: Dictionary = {}
var _var_depths: Dictionary = {}
var _typed_aliases: Dictionary = {}   ## destructured name -> its typed-container _TypeRef

var _struct_ops: Dictionary = {}
var _class_op_fds: Dictionary = {}   ## class name -> {operator symbol: _FuncDecl}, for a class's operators

var _soa: Dictionary = {}

var _soa_cursors: Dictionary = {}
var _soa_fields: Dictionary = {}   ## "class key#field" -> the field is an @soa array
var _stmt_expr = null   ## the expression being emitted as a whole statement

var _external_structs: Dictionary = {}

var _generics: Dictionary = {}          ## name -> _ClassDecl with generic_params

var _mono_template: Dictionary = {}   ## monomorphised class name -> its template's name
var _instantiations: Dictionary = {}    ## mangled name -> [_ClassDecl, {param: argname}]

var _subst: Dictionary = {}
var _subst_depth: Dictionary = {}
var _enum_names: Dictionary = {}   ## bare enum name -> true, declared anywhere in this file
## "Container.EnumName" -> true, for an enum declared inside a same-file nested class,
## so a dotted reference only means that enum when the qualifier names its own class.
var _qualified_enum_names: Dictionary = {}
var _extern_enum_names: Dictionary = {}    ## leaf enum name -> true, top-level in another file
## leaf enum name -> Array[.gate path], every file declaring a top-level enum
## of that name - two files can validly share one (`enum State`, `enum Mode`).
var _extern_enum_origin: Dictionary = {}
## leaf enum name -> Array[.gate path], for a bare (unqualified) name that names a
## top-level enum in more than one other file - there is no qualifier at a bare use
## site to pick a candidate by, so a bare reference to one of these is a compile
## error instead of a silent guess. A name with exactly one candidate origin is not
## here - it is folded into `_extern_origin` instead, so it resolves through the
## same silent-import machinery a bare cross-file class or struct already uses.
var _ambiguous_bare_enums: Dictionary = {}
var _subst_types: Dictionary = {}
var _subst_nullable: Dictionary = {}   ## generic param name -> its bound argument's own `?`
## True while emitting an `is`/`as`/match type-pattern test of a substituted generic
## param. Those test the substituted type itself, not a declaration, so `_subst_nullable`
## must not collapse `T` to Variant there - `x is T` with `T = int?` must still test
## `int`, or every value would match.
var _type_test: bool = false

var _pending_generic: Dictionary = {}

var _declared_funcs: Dictionary = {}
var _func_returns: Dictionary = {}
var _cur_base: String = ""
var _cur_class: String = ""
var _class_bases: Dictionary = {}

var _needs_iface_helper: bool = false
var _iface_scopes: Array = []

var _interface_names: Dictionary = {}

var _overloads: Dictionary = {}   ## base name -> { arity -> mangled }
var _overload_owners: Dictionary = {}   ## base name -> { owning class name -> true }
var _erased_types: Dictionary = {}      ## interface/trait names, which have no runtime type

var _extern_origin: Dictionary = {}   ## declared name -> origin .gate path
var _extern_generics: Dictionary = {} ## generic name -> origin .gate path
var _used_origins: Dictionary = {}    ## origin .gate path -> const alias
var _self_path: String = ""       ## the file being compiled, which needs no preload
var _local_types: Dictionary = {}     ## type names this module declares itself
var _bound_names: Dictionary = {}     ## names that are a value in scope in this module
var _base_names: Dictionary = {}      ## names the base chain defines
var _base_chain: Dictionary = {}
var _const_exprs: Dictionary = {}     ## `const` values, for folding a tuple index
var _base_via_gate: bool = false      ## a link of the base chain is a script GATE builds
var _field_types: Dictionary = {}
var _var_dict_values: Dictionary = {}
var _project_generic_uses: Array = []
var _generic_renames: Dictionary = {}

var _in_namespace: bool = false

var _warned_narrow: bool = false
var _warned_packed: bool = false

var _in_func_body: bool = false

var _scalar_repl: Dictionary = {}
var _scalar_names: Dictionary = {}
var _ident_renames: Dictionary = {}     ## a struct default's field name -> the text holding its value
var _bare_fields: bool = false          ## emitting a struct's fields, which _init fills in

var _preload_targets: Dictionary = {}

var _fn_locals: Dictionary = {}
var _tmp_names: Dictionary = {}
var _plain_fields: Dictionary = {}

var _class_decls: Dictionary = {}       ## key -> _ClassDecl (null for ".")
var _class_parent: Dictionary = {}      ## key -> enclosing key
var _class_base: Dictionary = {}        ## key -> extends _TypeRef, or null
var _class_funcs: Dictionary = {}       ## key -> {name: [_FuncDecl]}
var _class_fields: Dictionary = {}      ## key -> {field: true}, constants excluded
var _class_field_types: Dictionary = {} ## "key#field" -> _TypeRef
var _class_inits: Dictionary = {}       ## key -> _init parameter count, -1 if none
var _class_priv: Dictionary = {}        ## key -> {name: true} for `priv` members
var _observable_fields: Dictionary = {} ## "key#field" -> the @observable field's type name
var _mutators: Dictionary = {}          ## struct name -> {method: true} for methods that assign a field
var _scope_class: String = "."
var _mono_scope: String = ""            ## the generic's key while one of its instantiations emits
var _self_class_name: String = ""

var _assigned_names = null
var _cur_fn_body = null

var _swizzle_exempt = null
var _bare_shorthand_exempt = null

var _reg_classes: Dictionary = {}
var _reg_whole = null         ## the registry, for another file's class_name
var _reg_bases: Dictionary = {}
var _reg_script_classes: Dictionary = {}
var _reg_origin: Dictionary = {}
var _reg_namespaces: Dictionary = {}
var _reg_module_names: Dictionary = {}
var _module_members: Array = []
var _scope_names: Dictionary = {}       ## class key -> GateChecker.scope_names of its body
var _engine_props: Dictionary = {}
var _engine_prop_cache: Dictionary = {}
var _func_reach: Dictionary = {}        ## "scope|name" -> whether a bare call reaches a function
var _field_reach: Dictionary = {}       ## "scope|name" -> whether a bare name reaches a field

var _init_helper_scopes: Dictionary = {}

var _no_hoist: String = ""

var _in_lvalue: int = 0

var _key_errors: Dictionary = {}   ## "line:col" of a struct-key error already reported
var _copy_arms_node = null     ## a ternary whose arms are each bound as a copy
var _in_gate_helper: bool = false   ## inside a generated _gate_ function: it copies for itself
var _struct_user: bool = false   ## this file declares or names a class-lowered struct
var _src_text: String = ""
var _fn_params: Dictionary = {}   ## parameters of the function being emitted
var _demangled: Dictionary = {}   ## another file's generic instance name -> the use it came from
var _null_locals: Dictionary = {}   ## untyped locals set from a value that may be null
var _rename_prec: Dictionary = {}   ## a renamed name -> the precedence of the text it stands for

## The first line of every generated file. The builder refuses to overwrite a `.gd`
## that does not carry it, so keep it first and keep its prefix stable.
const HEADER_MARKER := "# Generated by GATE"

const HEADER_LINES := [
	"# Generated by GATE from %s - do not edit.",
	"#",
	"# This file is transpiled output, not source. For as long as GATE is used in",
	"# this project, anything you change here is overwritten the next time",
	"# %s is compiled - edit that file instead.",
	"#",
	"# To stop using GATE for this script, delete this header first, then the .gate",
	"# file; what remains is ordinary GDScript you can maintain by hand.",
]


func _line(text: String, src_line: int) -> void:
	if text == "":
		_out.append("")
		_map.append(src_line)
		return
	if text.contains("\n"):
		var parts: PackedStringArray = text.split("\n")
		var srcs: Array = _pending_line_src
		_pending_line_src = []
		var use_srcs: bool = srcs.size() == parts.size() - 1
		_out.append("\t".repeat(_indent) + parts[0])
		_map.append(src_line)
		for i in range(1, parts.size()):
			_out.append(parts[i])
			_map.append(int(srcs[i - 1]) if use_srcs else src_line)
		return
	_pending_line_src = []
	_out.append("\t".repeat(_indent) + text)
	_map.append(src_line)


func _flush_pending(src_line: int) -> void:
	if _pending.is_empty():
		return
	var p: PackedStringArray = _pending
	_pending = PackedStringArray()
	for s in p:
		_line(s, src_line)


func _hoist(text: String) -> void:
	_pending.append(_deeper(text, -_coll_depth) if _coll_depth > 0 else text)


func _hoist_at(at: int, text: String) -> void:
	_pending.insert(at, _deeper(text, -_coll_depth) if _coll_depth > 0 else text)


func _rehoist(lines: PackedStringArray) -> void:
	_pending.append_array(lines)


func _hoist_nested(lines: PackedStringArray) -> void:
	for h in lines:
		_pending.append("\t" + _deeper(h, 1))


func _hoist_in_block(text: String) -> void:
	_pending.append("\t" + _deeper(text, 1 - _coll_depth))


static func _deeper(text: String, by: int) -> String:
	if by == 0 or not text.contains("\n"):
		return text
	var out: String = ""
	var quote: String = ""
	var i: int = 0
	var n: int = text.length()
	while i < n:
		var ch: String = text[i]
		if quote != "":
			if ch == "\\":
				out += text.substr(i, 2)
				i += 2
				continue
			if text.substr(i, quote.length()) == quote:
				out += quote
				i += quote.length()
				quote = ""
				continue
			out += ch
			i += 1
			continue
		if ch == "#":
			var eol: int = text.find("\n", i)
			if eol < 0:
				eol = n
			out += text.substr(i, eol - i)
			i = eol
			continue
		if ch == "\"" or ch == "'":
			quote = ch.repeat(3) if text.substr(i, 3) == ch.repeat(3) else ch
			out += quote
			i += quote.length()
			continue
		out += ch
		i += 1
		if ch == "\n":
			if by > 0:
				out += "\t".repeat(by)
			else:
				var k: int = 0
				while k < -by and i < n and text[i] == "\t":
					i += 1
					k += 1
	return out


func _new_tmp() -> String:
	while true:
		_tmp += 1
		var n: String = "__g%d" % _tmp if _in_func_body else "__g%d_%s" % [_tmp, _file_tag()]
		if not _bound_names.has(n):
			_tmp_names[n] = true
			return n
	return ""


func _file_tag() -> String:
	var base: String = ""
	for ch in String(source_path).get_file().get_basename():
		base += ch if _is_name_char_out(ch) else "_"
	return "%s_%x" % [base, String(source_path).hash() & 0xffffff]


## For initialisers where nothing can be hoisted. Each class gets its own copy.
func _emit_init_helper(at: int = 0) -> void:
	var saved: int = _indent
	_indent = at
	_blank_line(1)
	_line("static func __gate_init(o: Object, props: Dictionary) -> Object:", 1)
	_indent = at + 1
	_line("for k in props:", 1)
	_indent = at + 2
	_line("o.set(k, props[k])", 1)
	_indent = at + 1
	_line("return o", 1)
	_indent = saved


## At the current indent: an inner class cannot call its module's static functions,
## so every class that tests an interface gets its own copy.
func _emit_iface_helper() -> void:
	var saved: int = _indent
	_blank_line(1)
	_line("static func __gate_is(o, iface: String) -> bool:", 1)
	_indent = saved + 1
	_line("if typeof(o) != TYPE_OBJECT or o == null:", 1)
	_indent = saved + 2
	_line("return false", 1)
	_indent = saved + 1
	_line("var m = o.get(\"__gate_impl\")", 1)
	_line("return m != null and iface in m", 1)
	_indent = saved


func _want_iface_helper() -> void:
	if _iface_scopes.is_empty():
		_needs_iface_helper = true
	else:
		_iface_scopes[_iface_scopes.size() - 1] = true


func _close_class_scope() -> void:
	if _iface_scopes.pop_back():
		_emit_iface_helper()

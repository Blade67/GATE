@tool
extends RefCounted

## Emitter layer 1: the output buffer, the sourcemap, and all mutable state.

var diagnostics: GateDiagnostics

var source_path: String = ""

var _out: PackedStringArray = []

var _map: Array[int] = []          ## output line -> source line

var _indent: int = 0

## Source lines with at least one blank above them. A presence flag, not a count:
## a function trailer already emits one blank, so "at least one here, never two" is
## the only rule stable in both directions.
var _blank_before: Dictionary = {}

var _pending_line_src: Array = []

var _coll_depth: int = 0


func set_source(src: String) -> void:
	_src_text = src
	_blank_before.clear()
	var lines: PackedStringArray = src.split("\n")
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


static func _is_annotation_only_line(t: String) -> bool:
	if not t.begins_with("@"):
		return false
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
	return t.substr(i).strip_edges() == ""


static func _is_name_char_out(c: String) -> bool:
	return ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
		or (c >= "0" and c <= "9") or c == "_")


func _blank_gap(src_line: int) -> void:
	if not _blank_before.has(src_line):
		return
	_blank_line(src_line)


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
var _enum_names: Dictionary = {}
var _subst_types: Dictionary = {}

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

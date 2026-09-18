@tool
class_name GateAST
extends RefCounted

## AST node definitions. Every node carries a line and column.


static var _walk_names: Dictionary = {}


static func walk_names(o: Object) -> PackedStringArray:
	var sc: Variant = o.get_script()
	if sc != null and _walk_names.has(sc):
		return _walk_names[sc]
	var out: PackedStringArray = PackedStringArray()
	for prop in o.get_property_list():
		var pn: String = prop["name"]
		if not (pn in ["script", "Built-in script", "RefCounted", "Object"]):
			out.append(pn)
	if sc != null:
		_walk_names[sc] = out
	return out


static var _child_names: Dictionary = {}


static func child_names(o: Object) -> PackedStringArray:
	var sc: Variant = o.get_script()
	if sc != null and _child_names.has(sc):
		return _child_names[sc]
	var out: PackedStringArray = PackedStringArray()
	for prop in o.get_property_list():
		var pn: String = prop["name"]
		var ty: int = int(prop.get("type", TYPE_NIL))
		if (int(prop.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		if ty == TYPE_OBJECT or ty == TYPE_ARRAY or ty == TYPE_NIL:
			out.append(pn)
	if sc != null:
		_child_names[sc] = out
	return out


class _ASTNode extends RefCounted:
	var line: int = 0
	var col: int = 0
	func at(l: int, c: int) -> _ASTNode:
		line = l
		col = c
		return self


class _TypeShape extends RefCounted:
	var union_members: Array = []      ## `<int | str>` -> [int, str]
	var tuple_elems: Array = []        ## `<int, str>` -> [int, str]
	var is_func_type: bool = false
	var sig_known: bool = false
	var callable_params: Array = []    ## Array[_TypeRef]; null for an untyped parameter
	var callable_optional: int = 0     ## trailing parameters that have defaults
	var callable_rest: bool = false


class _TypeRef extends _ASTNode:
	var name: String = ""              ## canonical or shorthand base name
	var array_depth: int = 0           ## `int[][]` -> 2
	var dict_key: _TypeRef = null      ## `{str, int}` -> key/value set
	var dict_value: _TypeRef = null
	var set_elem: _TypeRef = null      ## `{T}` reserved
	var nullable: bool = false
	var strict: bool = false
	var is_path_literal: bool = false
	var elem_nullable: bool = false
	var generic_args: Array = []       ## Array[_TypeRef]
	var callable_return: _TypeRef = null
	var shape: _TypeShape = null       ## null for every plain type

	func shaped() -> _TypeShape:
		if shape == null:
			shape = _TypeShape.new()
		return shape

	var union_members:
		get:
			return shape.union_members if shape != null else []
		set(value):
			if shape != null or not value.is_empty():
				shaped().union_members = value
	var tuple_elems:
		get:
			return shape.tuple_elems if shape != null else []
		set(value):
			if shape != null or not value.is_empty():
				shaped().tuple_elems = value
	var callable_params:
		get:
			return shape.callable_params if shape != null else []
		set(value):
			if shape != null or not value.is_empty():
				shaped().callable_params = value
	var is_func_type:
		get:
			return shape != null and shape.is_func_type
		set(value):
			if shape != null or value:
				shaped().is_func_type = value
	var sig_known:
		get:
			return shape != null and shape.sig_known
		set(value):
			if shape != null or value:
				shaped().sig_known = value
	var callable_optional:
		get:
			return shape.callable_optional if shape != null else 0
		set(value):
			if shape != null or value != 0:
				shaped().callable_optional = value
	var callable_rest:
		get:
			return shape != null and shape.callable_rest
		set(value):
			if shape != null or value:
				shaped().callable_rest = value

	func is_dict() -> bool: return dict_key != null
	func is_set() -> bool: return set_elem != null
	func is_array() -> bool: return array_depth > 0
	func is_union() -> bool: return shape != null and not shape.union_members.is_empty()
	func is_tuple() -> bool: return shape != null and not shape.tuple_elems.is_empty()

	func describe() -> String:
		if is_dict(): return "{%s, %s}" % [dict_key.describe(), dict_value.describe()]
		if is_set(): return "{%s}" % set_elem.describe()
		if is_union() or is_tuple():
			var members: PackedStringArray = PackedStringArray()
			for m in (union_members if is_union() else tuple_elems):
				members.append(m.describe())
			var list: String = "<%s>" % (" | " if is_union() else ", ").join(members)
			if elem_nullable: list += "?"
			return list + "[]".repeat(array_depth) + ("?" if nullable else "")
		if is_func_type or sig_known:
			var ps: PackedStringArray = PackedStringArray()
			for p in callable_params:
				ps.append(p.describe() if p != null else "Variant")
			return "func(%s) -> %s" % [", ".join(ps),
				callable_return.describe() if callable_return != null else "Variant"]
		var s: String = name
		if not generic_args.is_empty():
			var parts: PackedStringArray = PackedStringArray()
			for g in generic_args: parts.append(g.describe())
			if name == "Array" and parts.size() == 1:
				s = parts[0] + "[]"
			elif name == "Dictionary" and parts.size() == 2:
				s = "{%s, %s}" % [parts[0], parts[1]]
			else:
				s += "<" + ", ".join(parts) + ">"
		if elem_nullable: s += "?"
		s += "[]".repeat(array_depth)
		if nullable: s += "?"
		return s


class _Expr extends _ASTNode:
	var flow_type: _TypeRef = null
	var narrowed_vector: String = ""   ## an untyped value `is` narrowed to a vector type, for swizzles


class _Literal extends _Expr:
	var raw: String = ""
	var kind: String = ""              ## "number" | "string" | "bool" | "null"


class _Ident extends _Expr:
	var generic_base: String = ""
	var generic_type: _TypeRef = null  ## `Box<T>` in `Box<T>.new()`, re-mangled per instantiation
	var name: String = ""


class _NodePathExpr extends _Expr:
	var raw: String = ""


class _SelfExpr extends _Expr:
	pass


class _Unary extends _Expr:
	var tight: bool = false
	var op: String = ""
	var operand: _Expr = null


class _Binary extends _Expr:
	var op: String = ""
	var left: _Expr = null
	var right: _Expr = null


class _NullCoalesce extends _Expr:
	var left: _Expr = null
	var right: _Expr = null


class _Ternary extends _Expr:
	var cond: _Expr = null
	var if_true: _Expr = null
	var if_false: _Expr = null


class _Member extends _Expr:
	var target: _Expr = null
	var name: String = ""
	var safe: bool = false             ## `?.`
	var member_class: String = ""      ## on a union or a join: the class whose name every type prints


class _Index extends _Expr:
	var target: _Expr = null
	var index: _Expr = null
	var safe: bool = false             ## `?[`


class _Call extends _Expr:
	var callee: _Expr = null
	var args: Array = []               ## Array[_Expr]


class _Widen extends _Call:
	var guards: Array = []


class _ArrayLit extends _Expr:
	var elements: Array = []           ## Array[_Expr]


class _DictLit extends _Expr:
	var keys: Array = []               ## Array[_Expr]
	var values: Array = []             ## Array[_Expr]
	var lua_keys: Array = []           ## Array[bool]


class _Lambda extends _Expr:
	var name: String = ""
	var params: Array = []             ## Array[_Param]
	var return_type: _TypeRef = null
	var body: Array = []               ## Array[Node] (statements)
	var is_expression_body: bool = false
	var expr_body: _Expr = null
	var block_body: bool = false


class _AwaitExpr extends _Expr:
	var operand: _Expr = null


class _CastExpr extends _Expr:
	var operand: _Expr = null
	var type: _TypeRef = null


class _IsExpr extends _Expr:
	var operand: _Expr = null
	var type: _TypeRef = null
	var negated: bool = false


class _FString extends _Expr:
	var parts: Array = []              ## alternating: String literals and _Expr
	var quote: String = "\""


class _ObjectInit extends _Expr:
	var type: _TypeRef = null
	var keys: Array = []               ## Array[String]
	var values: Array = []             ## Array[_Expr]


class _RawExpr extends _Expr:
	var text: String = ""


class _TypePattern extends _RawExpr:
	var bind_name: String = ""
	var type: _TypeRef = null


class _Stmt extends _ASTNode:
	var injected: bool = false         ## generated by GateInject, not written by the user


class _Param extends _ASTNode:
	var name: String = ""
	var type: _TypeRef = null
	var default: _Expr = null
	var is_rest: bool = false
	var inferred: bool = false        ## declared with `:=`


class _VarDecl extends _Stmt:
	var name: String = ""
	var type: _TypeRef = null
	var value: _Expr = null
	var is_const: bool = false
	var is_static: bool = false
	var is_onready: bool = false
	var inferred: bool = false         ## declared with `:=`
	var visibility: String = ""        ## "" | "pub" | "priv"
	var annotations: Array = []        ## Array[_Annotation]
	var setter: String = ""
	var setter_line: int = 0
	var inline_accessors: String = ""
	var getter: String = ""
	var accessor_requirement: Array = []
	var notify_line: int = 0
	var set_ast: _FuncDecl = null
	var set_span: Array = []
	var get_ast: _FuncDecl = null      ## a `get:` block, parsed as a function body
	var get_span: Array = []
	var set_forced: bool = false       ## the setter was changed (a notification), so it is compiled


class _Annotation extends _ASTNode:
	var name: String = ""              ## without the '@'
	var args: Array = []               ## Array[_Expr]


class _FuncDecl extends _Stmt:
	var name: String = ""
	var params: Array = []             ## Array[_Param]
	var return_type: _TypeRef = null
	var body: Array = []               ## Array[_Stmt]
	var is_static: bool = false
	var is_abstract: bool = false
	var is_virtual: bool = false
	var is_override: bool = false
	var is_final: bool = false
	var is_operator: bool = false
	var operator_symbol: String = ""
	var visibility: String = ""
	var annotations: Array = []
	var mangled_name: String = ""
	var accessor: bool = false         ## a property's get/set block, printed inside the property


class _TypeAliasDecl extends _Stmt:
	var name: String = ""
	var target: _TypeRef = null


class _SignalDecl extends _Stmt:
	var name: String = ""
	var params: Array = []
	var annotations: Array = []


class _EnumDecl extends _Stmt:
	var name: String = ""
	var keys: Array = []               ## Array[String]
	var values: Array = []             ## Array[_Expr] (may hold nulls)
	var annotations: Array = []


class _ClassDecl extends _Stmt:
	var form: String = "class"
	var name: String = ""
	var extends_type: _TypeRef = null
	var implements: Array = []         ## Array[String]
	var traits: Array = []             ## Array[String]
	var requires: Array = []           ## Array[String] (traits only)
	var generic_params: Array = []     ## Array[String]
	var members: Array = []            ## Array[_Stmt]
	var is_abstract: bool = false
	var annotations: Array = []
	var lowering: String = ""          ## structs: "vector"|"soa"|"scalar"|"class"
	var vector_type: String = ""       ## e.g. "Vector4"
	var interface_names: Array = []    ## flattened


class _IfStmt extends _Stmt:
	var cond: _Expr = null
	var then_body: Array = []
	var elifs: Array = []              ## Array[[_Expr, Array]]
	var else_body: Array = []
	var else_line: int = 0                 ## the `else` keyword's own line


class _ForStmt extends _Stmt:
	var var_names: Array = []          ## 1 = normal, 2 = `for k, v in dict`
	var var_type: _TypeRef = null
	var iterable: _Expr = null
	var body: Array = []
	var is_enumerate: bool = false     ## `for i, x in enumerate(y)`


class _WhileStmt extends _Stmt:
	var cond: _Expr = null
	var body: Array = []


class _MatchStmt extends _Stmt:
	var subject: _Expr = null
	var branches: Array = []           ## Array[[Array patterns, _Expr guard, Array body]]


class _AnnotatedStmt extends _Stmt:
	var annotations: Array = []        ## Array[_Annotation]
	var stmt: _Stmt = null


class _ReturnStmt extends _Stmt:
	var value: _Expr = null


class _SimpleStmt extends _Stmt:
	var keyword: String = ""           ## "pass" | "break" | "continue" | "breakpoint"


class _ExprStmt extends _Stmt:
	var expr: _Expr = null


class _AssignStmt extends _Stmt:
	var target: _Expr = null
	var op: String = "="               ## "=", "+=", ...
	var value: _Expr = null


class _MultiAssign extends _Stmt:
	var targets: Array = []            ## Array[_Expr] or names when declaring
	var values: Array = []             ## Array[_Expr]; single value = destructure
	var declares: bool = false
	var destructure: bool = false


class _RawStmt extends _Stmt:
	var text: String = ""


class _CommentStmt extends _Stmt:
	var text: String = ""


class _Module extends _ASTNode:
	var path: String = ""
	var class_name_decl: String = ""
	var class_name_line: int = 1
	var extends_line: int = 1
	var extends_type: _TypeRef = null
	var icon: String = ""
	var is_tool: bool = false
	var members: Array = []            ## Array[_Stmt]
	var header_annotations: Array = []
	var uses_nullable: bool = false
	var generic_uses: Array = []       ## Array[_TypeRef]
	var has_aliases: bool = false      ## any `type X = ...`, at any depth
	var uses_gate_types: bool = false  ## any union, tuple or `func(...)` type

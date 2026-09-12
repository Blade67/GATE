@tool
class_name GateAST
extends RefCounted

## AST node definitions. Every node carries a line and column.


class ASTNode extends RefCounted:
	var line: int = 0
	var col: int = 0
	func at(l: int, c: int) -> ASTNode:
		line = l
		col = c
		return self


class TypeShape extends RefCounted:
	var union_members: Array = []      ## `<int | str>` -> [int, str]
	var tuple_elems: Array = []        ## `<int, str>` -> [int, str]
	var is_func_type: bool = false
	var sig_known: bool = false
	var callable_params: Array = []    ## Array[TypeRef]; null for an untyped parameter
	var callable_optional: int = 0     ## trailing parameters that have defaults
	var callable_rest: bool = false


class TypeRef extends ASTNode:
	var name: String = ""              ## canonical or shorthand base name
	var array_depth: int = 0           ## `int[][]` -> 2
	var dict_key: TypeRef = null       ## `{str, int}` -> key/value set
	var dict_value: TypeRef = null
	var set_elem: TypeRef = null       ## `{T}` reserved
	var nullable: bool = false
	var strict: bool = false
	var is_path_literal: bool = false
	var elem_nullable: bool = false
	var generic_args: Array = []       ## Array[TypeRef]
	var callable_return: TypeRef = null
	var shape: TypeShape = null        ## null for every plain type

	func shaped() -> TypeShape:
		if shape == null:
			shape = TypeShape.new()
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


class Expr extends ASTNode:
	pass


class Literal extends Expr:
	var raw: String = ""
	var kind: String = ""              ## "number" | "string" | "bool" | "null"


class Ident extends Expr:
	var generic_base: String = ""
	var name: String = ""


class NodePathExpr extends Expr:
	var raw: String = ""


class SelfExpr extends Expr:
	pass


class Unary extends Expr:
	var tight: bool = false
	var op: String = ""
	var operand: Expr = null


class Binary extends Expr:
	var op: String = ""
	var left: Expr = null
	var right: Expr = null


class NullCoalesce extends Expr:
	var left: Expr = null
	var right: Expr = null


class Ternary extends Expr:
	var cond: Expr = null
	var if_true: Expr = null
	var if_false: Expr = null


class Member extends Expr:
	var target: Expr = null
	var name: String = ""
	var safe: bool = false             ## `?.`
	var member_class: String = ""      ## on a union or a join: the class whose name every type prints


class Index extends Expr:
	var target: Expr = null
	var index: Expr = null
	var safe: bool = false             ## `?[`


class Call extends Expr:
	var callee: Expr = null
	var args: Array = []               ## Array[Expr]


class Widen extends Call:
	var guards: Array = []


class ArrayLit extends Expr:
	var elements: Array = []           ## Array[Expr]


class DictLit extends Expr:
	var keys: Array = []               ## Array[Expr]
	var values: Array = []             ## Array[Expr]
	var lua_keys: Array = []           ## Array[bool]


class Lambda extends Expr:
	var name: String = ""
	var params: Array = []             ## Array[Param]
	var return_type: TypeRef = null
	var body: Array = []               ## Array[Node] (statements)
	var is_expression_body: bool = false
	var expr_body: Expr = null
	var block_body: bool = false


class AwaitExpr extends Expr:
	var operand: Expr = null


class CastExpr extends Expr:
	var operand: Expr = null
	var type: TypeRef = null


class IsExpr extends Expr:
	var operand: Expr = null
	var type: TypeRef = null
	var negated: bool = false


class FString extends Expr:
	var parts: Array = []              ## alternating: String literals and Expr
	var quote: String = "\""


class ObjectInit extends Expr:
	var type: TypeRef = null
	var keys: Array = []               ## Array[String]
	var values: Array = []             ## Array[Expr]


class RawExpr extends Expr:
	var text: String = ""


class Stmt extends ASTNode:
	pass


class Param extends ASTNode:
	var name: String = ""
	var type: TypeRef = null
	var default: Expr = null
	var is_rest: bool = false
	var inferred: bool = false        ## declared with `:=`


class VarDecl extends Stmt:
	var name: String = ""
	var type: TypeRef = null
	var value: Expr = null
	var is_const: bool = false
	var is_static: bool = false
	var is_onready: bool = false
	var inferred: bool = false         ## declared with `:=`
	var visibility: String = ""        ## "" | "pub" | "priv"
	var annotations: Array = []        ## Array[Annotation]
	var setter: String = ""
	var setter_line: int = 0
	var inline_accessors: String = ""
	var getter: String = ""
	var accessor_requirement: Array = []


class Annotation extends ASTNode:
	var name: String = ""              ## without the '@'
	var args: Array = []               ## Array[Expr]


class FuncDecl extends Stmt:
	var name: String = ""
	var params: Array = []             ## Array[Param]
	var return_type: TypeRef = null
	var body: Array = []               ## Array[Stmt]
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


class TypeAliasDecl extends Stmt:
	var name: String = ""
	var target: TypeRef = null


class SignalDecl extends Stmt:
	var name: String = ""
	var params: Array = []
	var annotations: Array = []


class EnumDecl extends Stmt:
	var name: String = ""
	var keys: Array = []               ## Array[String]
	var values: Array = []             ## Array[Expr] (may hold nulls)
	var annotations: Array = []


class ClassDecl extends Stmt:
	var form: String = "class"
	var name: String = ""
	var extends_type: TypeRef = null
	var implements: Array = []         ## Array[String]
	var traits: Array = []             ## Array[String]
	var requires: Array = []           ## Array[String] (traits only)
	var generic_params: Array = []     ## Array[String]
	var members: Array = []            ## Array[Stmt]
	var is_abstract: bool = false
	var annotations: Array = []
	var lowering: String = ""          ## structs: "vector"|"soa"|"scalar"|"class"
	var vector_type: String = ""       ## e.g. "Vector4"
	var interface_names: Array = []    ## flattened


class IfStmt extends Stmt:
	var cond: Expr = null
	var then_body: Array = []
	var elifs: Array = []              ## Array[[Expr, Array]]
	var else_body: Array = []
	var else_line: int = 0                 ## the `else` keyword's own line


class ForStmt extends Stmt:
	var var_names: Array = []          ## 1 = normal, 2 = `for k, v in dict`
	var var_type: TypeRef = null
	var iterable: Expr = null
	var body: Array = []
	var is_enumerate: bool = false     ## `for i, x in enumerate(y)`


class WhileStmt extends Stmt:
	var cond: Expr = null
	var body: Array = []


class MatchStmt extends Stmt:
	var subject: Expr = null
	var branches: Array = []           ## Array[[Array patterns, Expr guard, Array body]]


class AnnotatedStmt extends Stmt:
	var annotations: Array = []        ## Array[Annotation]
	var stmt: Stmt = null


class ReturnStmt extends Stmt:
	var value: Expr = null


class SimpleStmt extends Stmt:
	var keyword: String = ""           ## "pass" | "break" | "continue" | "breakpoint"


class ExprStmt extends Stmt:
	var expr: Expr = null


class AssignStmt extends Stmt:
	var target: Expr = null
	var op: String = "="               ## "=", "+=", ...
	var value: Expr = null


class MultiAssign extends Stmt:
	var targets: Array = []            ## Array[Expr] or names when declaring
	var values: Array = []             ## Array[Expr]; single value = destructure
	var declares: bool = false
	var destructure: bool = false


class RawStmt extends Stmt:
	var text: String = ""


class CommentStmt extends Stmt:
	var text: String = ""


class Module extends ASTNode:
	var path: String = ""
	var class_name_decl: String = ""
	var class_name_line: int = 1
	var extends_line: int = 1
	var extends_type: TypeRef = null
	var icon: String = ""
	var is_tool: bool = false
	var members: Array = []            ## Array[Stmt]
	var header_annotations: Array = []
	var uses_nullable: bool = false
	var generic_uses: Array = []       ## Array[TypeRef]
	var has_aliases: bool = false      ## any `type X = ...`, at any depth
	var uses_gate_types: bool = false  ## any union, tuple or `func(...)` type

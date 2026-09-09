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

	func is_dict() -> bool: return dict_key != null
	func is_set() -> bool: return set_elem != null
	func is_array() -> bool: return array_depth > 0

	func describe() -> String:
		if is_dict(): return "{%s, %s}" % [dict_key.describe(), dict_value.describe()]
		if is_set(): return "{%s}" % set_elem.describe()
		var s: String = name
		if not generic_args.is_empty():
			var parts: PackedStringArray = PackedStringArray()
			for g in generic_args: parts.append(g.describe())
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


class Index extends Expr:
	var target: Expr = null
	var index: Expr = null
	var safe: bool = false             ## `?[`


class Call extends Expr:
	var callee: Expr = null
	var args: Array = []               ## Array[Expr]


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

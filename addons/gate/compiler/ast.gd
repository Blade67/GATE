@tool
class_name GateAST
extends RefCounted

## AST node definitions. Every node carries a line and column.


class GateASTNode extends RefCounted:
	var line: int = 0
	var col: int = 0
	func at(l: int, c: int) -> GateASTNode:
		line = l
		col = c
		return self


class GateTypeRef extends GateASTNode:
	var name: String = ""              ## canonical or shorthand base name
	var array_depth: int = 0           ## `int[][]` -> 2
	var dict_key: GateTypeRef = null       ## `{str, int}` -> key/value set
	var dict_value: GateTypeRef = null
	var set_elem: GateTypeRef = null       ## `{T}` reserved
	var nullable: bool = false
	var strict: bool = false
	var is_path_literal: bool = false
	var elem_nullable: bool = false
	var generic_args: Array = []       ## Array[TypeRef]
	var callable_return: GateTypeRef = null

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


class GateExpr extends GateASTNode:
	pass


class GateLiteral extends GateExpr:
	var raw: String = ""
	var kind: String = ""              ## "number" | "string" | "bool" | "null"


class GateIdent extends GateExpr:
	var generic_base: String = ""
	var name: String = ""


class GateNodePathExpr extends GateExpr:
	var raw: String = ""


class GateSelfExpr extends GateExpr:
	pass


class GateUnary extends GateExpr:
	var tight: bool = false
	var op: String = ""
	var operand: GateExpr = null


class GateBinary extends GateExpr:
	var op: String = ""
	var left: GateExpr = null
	var right: GateExpr = null


class GateNullCoalesce extends GateExpr:
	var left: GateExpr = null
	var right: GateExpr = null


class GateTernary extends GateExpr:
	var cond: GateExpr = null
	var if_true: GateExpr = null
	var if_false: GateExpr = null


class GateMember extends GateExpr:
	var target: GateExpr = null
	var name: String = ""
	var safe: bool = false             ## `?.`


class GateIndex extends GateExpr:
	var target: GateExpr = null
	var index: GateExpr = null
	var safe: bool = false             ## `?[`


class GateCall extends GateExpr:
	var callee: GateExpr = null
	var args: Array = []               ## Array[Expr]


class GateArrayLit extends GateExpr:
	var elements: Array = []           ## Array[Expr]


class GateDictLit extends GateExpr:
	var keys: Array = []               ## Array[Expr]
	var values: Array = []             ## Array[Expr]
	var lua_keys: Array = []           ## Array[bool]


class GateLambda extends GateExpr:
	var name: String = ""
	var params: Array = []             ## Array[Param]
	var return_type: GateTypeRef = null
	var body: Array = []               ## Array[Node] (statements)
	var is_expression_body: bool = false
	var expr_body: GateExpr = null
	var block_body: bool = false


class GateAwaitExpr extends GateExpr:
	var operand: GateExpr = null


class GateCastExpr extends GateExpr:
	var operand: GateExpr = null
	var type: GateTypeRef = null


class GateIsExpr extends GateExpr:
	var operand: GateExpr = null
	var type: GateTypeRef = null
	var negated: bool = false


class GateFString extends GateExpr:
	var parts: Array = []              ## alternating: String literals and Expr
	var quote: String = "\""


class GateObjectInit extends GateExpr:
	var type: GateTypeRef = null
	var keys: Array = []               ## Array[String]
	var values: Array = []             ## Array[Expr]


class GateRawExpr extends GateExpr:
	var text: String = ""


class GateStmt extends GateASTNode:
	pass


class GateParam extends GateASTNode:
	var name: String = ""
	var type: GateTypeRef = null
	var default: GateExpr = null
	var is_rest: bool = false
	var inferred: bool = false        ## declared with `:=`


class GateVarDecl extends GateStmt:
	var name: String = ""
	var type: GateTypeRef = null
	var value: GateExpr = null
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


class GateAnnotation extends GateASTNode:
	var name: String = ""              ## without the '@'
	var args: Array = []               ## Array[Expr]


class GateFuncDecl extends GateStmt:
	var name: String = ""
	var params: Array = []             ## Array[Param]
	var return_type: GateTypeRef = null
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


class GateSignalDecl extends GateStmt:
	var name: String = ""
	var params: Array = []
	var annotations: Array = []


class GateEnumDecl extends GateStmt:
	var name: String = ""
	var keys: Array = []               ## Array[String]
	var values: Array = []             ## Array[Expr] (may hold nulls)
	var annotations: Array = []


class GateClassDecl extends GateStmt:
	var form: String = "class"
	var name: String = ""
	var extends_type: GateTypeRef = null
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


class GateIfStmt extends GateStmt:
	var cond: GateExpr = null
	var then_body: Array = []
	var elifs: Array = []              ## Array[[Expr, Array]]
	var else_body: Array = []
	var else_line: int = 0                 ## the `else` keyword's own line


class GateForStmt extends GateStmt:
	var var_names: Array = []          ## 1 = normal, 2 = `for k, v in dict`
	var var_type: GateTypeRef = null
	var iterable: GateExpr = null
	var body: Array = []
	var is_enumerate: bool = false     ## `for i, x in enumerate(y)`


class GateWhileStmt extends GateStmt:
	var cond: GateExpr = null
	var body: Array = []


class GateMatchStmt extends GateStmt:
	var subject: GateExpr = null
	var branches: Array = []           ## Array[[Array patterns, Expr guard, Array body]]


class GateAnnotatedStmt extends GateStmt:
	var annotations: Array = []        ## Array[Annotation]
	var stmt: GateStmt = null


class GateReturnStmt extends GateStmt:
	var value: GateExpr = null


class GateSimpleStmt extends GateStmt:
	var keyword: String = ""           ## "pass" | "break" | "continue" | "breakpoint"


class GateExprStmt extends GateStmt:
	var expr: GateExpr = null


class GateAssignStmt extends GateStmt:
	var target: GateExpr = null
	var op: String = "="               ## "=", "+=", ...
	var value: GateExpr = null


class GateMultiAssign extends GateStmt:
	var targets: Array = []            ## Array[Expr] or names when declaring
	var values: Array = []             ## Array[Expr]; single value = destructure
	var declares: bool = false
	var destructure: bool = false


class GateRawStmt extends GateStmt:
	var text: String = ""


class GateCommentStmt extends GateStmt:
	var text: String = ""


class GateModule extends GateASTNode:
	var path: String = ""
	var class_name_decl: String = ""
	var class_name_line: int = 1
	var extends_line: int = 1
	var extends_type: GateTypeRef = null
	var icon: String = ""
	var is_tool: bool = false
	var members: Array = []            ## Array[Stmt]
	var header_annotations: Array = []
	var uses_nullable: bool = false
	var generic_uses: Array = []       ## Array[TypeRef]

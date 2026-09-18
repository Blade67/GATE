@tool
extends RefCounted

## The project's declarations, kept for the editor rather than for a build.
##
## `GateProject.index()` lexes and parses every `.gate` in the project and returns
## the same registry the compiler resolves cross-file types against: where each
## class, struct, interface, trait, namespace, generic and alias is declared, and
## the AST node for each, with its line. Everything Ctrl-click and completion need
## is already in there, so this keeps one and hands it out.
##
## It is built on the first question asked after a change, not on the change, so a
## project that is being edited and not asked about pays nothing. The plugin calls

static var _registry: RefCounted = null


static func invalidate() -> void:
	_registry = null


## Null only if a project has no `.gate` files at all and `index()` refuses.
static func registry() -> RefCounted:
	if _registry == null:
		_registry = GateBuilder.current_registry()
	if _registry == null:
		_registry = GateProject.new().index("res://")
	return _registry


## The parser the compiler would use for this file: without the project's generics
## and aliases it reads `Pool<Bullet>` as two comparisons.
static func parser_for(reg: RefCounted) -> GateParser:
	var parser: GateParser = GateParser.new()
	if reg == null:
		return parser
	for name in reg.generics:
		parser.known_generics[name] = true
	for name in reg.aliases:
		parser.known_aliases[name] = true
	return parser


## The file as the compiler sees it, or null if it will not lex.
static func module_for(text: String, path: String, reg: RefCounted) -> GateAST._Module:
	var diagnostics: GateDiagnostics = GateDiagnostics.new()
	diagnostics.file = path
	var tokens: Array[GateLexer._Token] = GateLexer.new().tokenize(text, diagnostics)
	GateTypes.shadow_declared(tokens, reg.script_class_names if reg != null else {})
	var module: GateAST._Module = parser_for(reg).parse(tokens, text, diagnostics)
	GateTypes.shadowed.clear()
	return module

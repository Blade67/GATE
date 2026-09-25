@tool
extends EditorExportPlugin

## Keeps GATE out of the game you ship.
##
## Once `.gate` is a script Godot tracks it is a resource, and a resource goes into
## the PCK - so an exported game carried the whole GATE source of every file beside
## the compiled `.gd` it actually runs. Measured on 4.7.2: with the language
## registered and this plugin removed, `res://sample.gate` is stored in the pack;
## with it, the pack holds `sample.gdc` and nothing else of GATE's.
##
## Dropped from the pack:
##
##   *.gate           the source. The `.gd` beside it is what the game loads.
##   *.gate.uid       the id Godot mints for a `.gate`.
##   *.gd.map         the sourcemap, read only by the editor to name a `.gate` line.
##   addons/gate/     the compiler and the editor integration - except the four
##                    files below.
##
## Kept, because an exported game cannot start silently without them:
##
##   editor/loader.gd, editor/saver.gd   `class_name GateScriptLoader` and
##                                       `GateScriptSaver` are in the global class
##                                       cache the export bakes into the pack, and
##                                       at start-up Godot instances every
##                                       script-backed loader and saver named there.
##                                       With the files gone that is three engine
##                                       errors each, in every exported game.
##   editor/registry.gd, editor/script.gd what those two preload.
##
## All four are inert in a game: the loader and saver do nothing unless the editor
## plugin set `GateRegistry.active`, and nothing in a game ever does. The language,
## which is the one that would load the compiler, is not among them - `registry.gd`
## only loads it on demand, and nothing in a game makes that demand.
##
## Measured by running the exported pack as a game, with its main scene, not with
## `--script`: an earlier version of this check ran the pack through `--script`,
## which skips custom loader registration entirely, and so reported a clean start
## for a pack that printed six errors when actually played.

const ADDON_PREFIX: String = "res://addons/gate/"

const SKIPPED_SUFFIXES: Array[String] = [".gate", ".gate.uid", ".gd.map"]

## The only part of the addon a game needs. See above for why each is here.
const RUNTIME: Array[String] = [
	"res://addons/gate/editor/loader.gd",
	"res://addons/gate/editor/saver.gd",
	"res://addons/gate/editor/registry.gd",
	"res://addons/gate/editor/script.gd",
]


func _get_name() -> String:
	return "GATE"


static func is_editor_only(path: String) -> bool:
	if path.begins_with(ADDON_PREFIX):
		return not RUNTIME.has(path)
	for suffix in SKIPPED_SUFFIXES:
		if path.ends_with(suffix):
			return true
	return false


## Rebuilt once per export, not once per file: cross-file features (structs,
## namespaces, generics) still need to resolve during the recompile below.
var _export_registry = null

## Every `.gd` this export overwrote on disk, with its original text, so
## `_export_end()` can put it back once Godot has packed the replacement.
## `skip()` plus `add_file()` ships the replacement as raw source under the
## `.gd` name, not Godot's own compiled `.gdc` - measured against the pack
## produced with this plugin removed. Writing the file and letting Godot's own
## default export path (never skipped) read and compile it is what makes the
## packed file match: still `.gdc`, still whatever `script_export_mode` asks
## for, and never Godot's default source-visible-in-the-pack request.
var _export_restore: Dictionary = {}


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_export_registry = null
	_export_restore = {}


func _export_end() -> void:
	for path in _export_restore:
		var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(String(_export_restore[path]))
			f.close()
	_export_restore = {}


## `.gate` files never reach the pack (skipped above), so an exported `.gd`
## still carries every `@if` block as ordinary code unless this recompiles it
## with the preset's own symbols. `features` is the same set Godot resolved
## for this file: the platform, "debug" or "release", and the preset's own
## custom_features - GateDefines.overrides_from_features() turns it into the
## table an `@if` is judged against, so a release export genuinely lacks a
## `@if DEBUG` block rather than merely not running it.
func _recompile_for_export(path: String, gate_path: String, features: PackedStringArray) -> void:
	var f: FileAccess = FileAccess.open(gate_path, FileAccess.READ)
	if f == null:
		return
	var src: String = f.get_as_text()
	f.close()
	if _export_registry == null:
		var project: GateProject = GateProject.new()
		_export_registry = project.index("res://")
	var overrides: Dictionary = GateDefines.overrides_from_features(features)
	var defines: Dictionary = GateDefines.table(overrides)
	var compiler: GateCompiler = GateCompiler.new()
	var res: GateCompiler._Result = compiler.compile(src, gate_path, _export_registry, defines)
	if not res.ok:
		return
	var gf: FileAccess = FileAccess.open(path, FileAccess.READ)
	if gf == null:
		return
	var original: String = gf.get_as_text()
	gf.close()
	if original == res.source:
		return
	_export_restore[path] = original
	var wf: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if wf == null:
		_export_restore.erase(path)
		return
	wf.store_string(res.source)
	wf.close()


func _export_file(path: String, type: String, features: PackedStringArray) -> void:
	if is_editor_only(path):
		skip()
		return
	if path.ends_with(".gd"):
		var gate_path: String = path.get_basename() + ".gate"
		if FileAccess.file_exists(gate_path):
			_recompile_for_export(path, gate_path, features)

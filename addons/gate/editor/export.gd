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


func _export_file(path: String, type: String, features: PackedStringArray) -> void:
	if is_editor_only(path):
		skip()

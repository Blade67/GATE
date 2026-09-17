@tool
extends RefCounted

## The one place that knows whether GATE's editor integration is live.
##
## Godot re-registers every script-backed ResourceFormatLoader from the global class
## list whenever that list is rebuilt, so `loader.gd` and `saver.gd` come back even
## with the plugin disabled and in an exported game. They ask here before doing
## anything, and do nothing when `is_active()` is false. The state lives on `Engine`
## rather than in static vars, which Godot can fail to free at exit.

const LANGUAGE_PATH: String = "res://addons/gate/editor/language.gd"

const ACTIVE: StringName = &"gate_active"
const ATTACHING: StringName = &"gate_attaching"
const LANGUAGE: StringName = &"gate_language"
const SCRIPTS: StringName = &"gate_scripts"
const RETIRED: StringName = &"gate_retired"


static func is_active() -> bool:
	return bool(Engine.get_meta(ACTIVE, false))


static func set_active(value: bool) -> void:
	Engine.set_meta(ACTIVE, value)
	if value:
		Engine.set_meta(RETIRED, false)


## True only while the Scene dock's Attach Script dialog is on screen. The language
## refuses a path while it is, which is how GATE stays out of the one flow that would
## put a `.gate` on a node.
static func is_attaching() -> bool:
	return bool(Engine.get_meta(ATTACHING, false))


static func set_attaching(value: bool) -> void:
	Engine.set_meta(ATTACHING, value)


## Never null. A GATEScript whose language is null crashes the editor, and the one
## that mattered was built by a loader running with the plugin disabled. Building the
## language on demand rather than holding the registered one means there is no moment
## where a script can be asked for a language and answer nothing.
static func language() -> ScriptLanguageExtension:
	# `get_meta(key, null)` still reports a missing key as an engine error in 4.7.2;
	# only a non-null default is silent. So ask first.
	if Engine.has_meta(LANGUAGE):
		var held: Object = Engine.get_meta(LANGUAGE)
		if held != null:
			return held as ScriptLanguageExtension
	var script: GDScript = load(LANGUAGE_PATH) as GDScript
	if script == null:
		return null
	var made: ScriptLanguageExtension = script.new() as ScriptLanguageExtension
	Engine.set_meta(LANGUAGE, made)
	return made


static func release() -> void:
	Engine.set_meta(RETIRED, true)
	if int(Engine.get_meta(SCRIPTS, 0)) > 0:
		return
	if not Engine.has_meta(LANGUAGE):
		return
	var held: Object = Engine.get_meta(LANGUAGE)
	Engine.remove_meta(LANGUAGE)
	if held != null:
		held.free()


static func script_made() -> void:
	Engine.set_meta(SCRIPTS, int(Engine.get_meta(SCRIPTS, 0)) + 1)


static func script_gone() -> void:
	var left: int = int(Engine.get_meta(SCRIPTS, 0)) - 1
	Engine.set_meta(SCRIPTS, maxi(left, 0))
	if left <= 0 and bool(Engine.get_meta(RETIRED, false)) and not is_active():
		release()

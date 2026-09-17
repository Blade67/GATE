@tool
extends RefCounted

## Keeps `.gate` tabs out of any editor session that runs without GATE.
##
## The editor saves the open script tabs in `.godot/editor/editor_layout.cfg` and
## reopens them next time. Without GATE a `.gate` is not a script, so it reopens as a
## plain text tab, and on the way out Godot applies "convert indent on save" to every
## open tab and writes the ones it changed. A plain text tab does not know `#` starts a
## comment and takes `'` for a string delimiter, so an apostrophe in a comment switches
## the conversion off until the next one: the file is written back half tabs and half
## spaces, and GATE refuses to compile it. No GATE code runs in that session to stop
## it. The session before it can, by never leaving a `.gate` tab in the layout:
##
##   saving the layout   `.gate` tabs are moved out of the ScriptEditor section into
##                       a GATE section that Godot does not read
##   GATE starting       the tabs in the GATE section are opened again
##   GATE switched off   open `.gate` tabs are closed, unsaved edits saved first
##
## A session without GATE therefore finds no `.gate` to reopen, and the user's tabs
## come back the next time GATE is on.

const SECTION: String = "GATE"
const EDITOR_SECTION: String = "ScriptEditor"


static func is_gate(path: String) -> bool:
	return path.get_extension().to_lower() == "gate"


## Called from `EditorPlugin._get_window_layout`, which runs after the script editor
## has written its own section into the same file.
static func hide_from_layout(config: ConfigFile) -> void:
	var open: Array = config.get_value(EDITOR_SECTION, "open_scripts", [])
	var kept: Array = []
	var gates: Array = []
	for entry in open:
		if is_gate(String(entry)):
			gates.append(String(entry))
		else:
			kept.append(entry)
	config.set_value(SECTION, "open_scripts", gates)
	config.set_value(EDITOR_SECTION, "open_scripts", kept)
	var selected: String = String(config.get_value(EDITOR_SECTION, "selected_script", ""))
	if is_gate(selected):
		config.set_value(SECTION, "selected_script", selected)
		config.set_value(EDITOR_SECTION, "selected_script", String(kept[0]) if not kept.is_empty() else "")
	else:
		config.set_value(SECTION, "selected_script", "")


## Called from `EditorPlugin._set_window_layout`. Deferred, because the script editor
## is still restoring its own tabs when the layout is handed out.
static func restore_from_layout(config: ConfigFile) -> void:
	var gates: Array = config.get_value(SECTION, "open_scripts", [])
	var selected: String = String(config.get_value(SECTION, "selected_script", ""))
	if gates.is_empty():
		return
	_reopen.call_deferred(gates, selected)


static func _reopen(gates: Array, selected: String) -> void:
	var editor: ScriptEditor = EditorInterface.get_script_editor()
	var already: Array = editor.get_open_scripts().map(func(s: Script) -> String: return s.resource_path)
	for entry in gates:
		var path: String = String(entry)
		if already.has(path) or not FileAccess.file_exists(path):
			continue
		var script: Script = ResourceLoader.load(path) as Script
		if script != null:
			EditorInterface.edit_script(script)
	if selected != "" and FileAccess.file_exists(selected):
		var chosen: Script = ResourceLoader.load(selected) as Script
		if chosen != null:
			EditorInterface.edit_script(chosen)


## Called from `EditorPlugin._disable_plugin`, while GATE's saver still works. An open
## tab with unsaved edits is saved as it stands - no indentation conversion - so
## nothing the user typed is lost, and every `.gate` tab is then closed.
static func close_all(save_edits: bool = true) -> void:
	var editor: ScriptEditor = EditorInterface.get_script_editor()
	var scripts: Array[Script] = editor.get_open_scripts()
	var panes: Array[ScriptEditorBase] = editor.get_open_script_editors()
	var closing: PackedStringArray = PackedStringArray()
	for i in mini(scripts.size(), panes.size()):
		var script: Script = scripts[i]
		if script == null or not is_gate(script.resource_path):
			continue
		var edit: Control = panes[i].get_base_editor()
		var unsaved: bool = edit is TextEdit and (edit as TextEdit).get_version() != (edit as TextEdit).get_saved_version()
		if unsaved and not save_edits:
			continue
		if unsaved:
			script.source_code = (edit as TextEdit).text
			ResourceSaver.save(script, script.resource_path)
			(edit as TextEdit).tag_saved_version()
		closing.append(script.resource_path)
	for path in closing:
		editor.close_file(path)

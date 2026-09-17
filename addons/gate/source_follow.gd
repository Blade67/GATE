@tool
extends RefCounted

## When the editor shows a generated .gd, which is where a runtime error takes you,
## a toast names the .gate line it came from. Only listens; never edits or writes,
## and never opens anything. Each file and line is reported once per session:
## returning to Godot reloads the tab and fires the same signals again.

const INPUT_MS: int = 300

var _reported: Dictionary = {}
var _pending: bool = false
var _input_at: Dictionary = {}
var _watched: Array[WeakRef] = []


## {} unless the banner and the .gd.map agree on a .gate that still exists, and the
## map was written for this .gd and for the .gate as it is now. A rebuild that
## failed leaves the old pair behind; better silent than the wrong line.
static func source_line(gd_path: String, gd_line: int) -> Dictionary:
	if gd_path.get_extension().to_lower() != "gd" or not FileAccess.file_exists(gd_path + ".map"):
		return {}
	var text: String = FileAccess.get_file_as_string(gd_path)
	if not text.begins_with(GateEmitter.HEADER_MARKER):
		return {}
	var gate: String = GateBuilder._banner_source(text.get_slice("\n", 0))
	if gate == "" or not FileAccess.file_exists(gate):
		return {}
	var parsed: Variant = GateBuilder._read_json(gd_path + ".map")
	if not (parsed is Dictionary):
		return {}
	var map: Dictionary = parsed
	if (String(map.get("source", "")) != gate
			or String(map.get("source_sha256", "")) != FileAccess.get_file_as_string(gate).sha256_text()):
		return {}
	var lines: Variant = map.get("lines")
	if not (lines is Array) or (lines as Array).size() != text.count("\n"):
		return {}
	if gd_line <= GateEmitter.HEADER_LINES.size() or gd_line > (lines as Array).size():
		return {}
	var src: int = int(lines[gd_line - 1])
	return {"gate": gate, "line": src} if src > 0 else {}


static func toast_text(gd_path: String, gd_line: int, hit: Dictionary) -> String:
	return "%s:%d comes from %s:%d" % [gd_path.get_file(), gd_line,
		String(hit["gate"]).get_file(), hit["line"]]


func should_report(key: String) -> bool:
	if _reported.has(key):
		return false
	_reported[key] = true
	return true


func attach() -> void:
	var se: ScriptEditor = EditorInterface.get_script_editor()
	if not se.editor_script_changed.is_connected(_on_script_changed):
		se.editor_script_changed.connect(_on_script_changed)


func detach() -> void:
	var se: ScriptEditor = EditorInterface.get_script_editor()
	if se != null and se.editor_script_changed.is_connected(_on_script_changed):
		se.editor_script_changed.disconnect(_on_script_changed)
	for w in _watched:
		var ce: CodeEdit = w.get_ref() as CodeEdit
		if ce != null and ce.caret_changed.is_connected(_on_caret):
			ce.caret_changed.disconnect(_on_caret)
			ce.gui_input.disconnect(_on_input)
	_watched.clear()


func _on_script_changed(_script: Script) -> void:
	_queue()


## The signal fires before the caret reaches its line.
func _queue() -> void:
	if not _pending:
		_pending = true
		_check.call_deferred()


func _check() -> void:
	_pending = false
	var se: ScriptEditor = EditorInterface.get_script_editor()
	var script: Script = se.get_current_script()
	var ed: ScriptEditorBase = se.get_current_editor()
	if script == null or ed == null or not (ed.get_base_editor() is CodeEdit):
		return
	var ce: CodeEdit = ed.get_base_editor() as CodeEdit
	var gd_line: int = ce.get_caret_line() + 1
	var hit: Dictionary = source_line(script.resource_path, gd_line)
	if hit.is_empty():
		return
	_watch(ce)
	if should_report("%s:%d" % [script.resource_path, gd_line]):
		EditorInterface.get_editor_toaster().push_toast("GATE: " + toast_text(script.resource_path, gd_line, hit),
			EditorToaster.SEVERITY_INFO,
			"%s is generated; the line to fix is %s:%d." % [script.resource_path, hit["gate"], hit["line"]])


## A second error in the same tab only moves the caret. Ignored when the user moved it.
func _watch(ce: CodeEdit) -> void:
	if ce.caret_changed.is_connected(_on_caret):
		return
	ce.caret_changed.connect(_on_caret.bind(ce))
	ce.gui_input.connect(_on_input.bind(ce))
	_watched.append(weakref(ce))


func _on_input(_event: InputEvent, ce: CodeEdit) -> void:
	_input_at[ce.get_instance_id()] = Time.get_ticks_msec()


func _on_caret(ce: CodeEdit) -> void:
	var at: int = _input_at.get(ce.get_instance_id(), -INPUT_MS)
	if Time.get_ticks_msec() - at >= INPUT_MS:
		_queue()

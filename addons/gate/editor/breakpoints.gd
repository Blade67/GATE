@tool
extends EditorDebuggerPlugin

## Breakpoints set in a `.gate`, made to actually stop the game.
##
## Godot's debugger knows nothing about `.gate`. The editor sends the running game
## `res://foo.gate:12`, the game only ever asks about `res://foo.gd:34`, and the two
## never meet - so before this, a breakpoint dot in a `.gate` sat there and nothing
## happened. Everything needed to fix that is reachable from a plugin, and each part
## was checked on 4.7.2 before it was written:
##
##   out   `EditorDebuggerSession.set_breakpoint(path, line, enabled)` reaches the
##         running game directly. Sending the translated `.gd` line makes the game
##         break where the user pointed. Verified: the session reports `is_breaked`.
##   back  `EditorDebuggerPlugin._goto_script_line(script, line)` is called on every
##         plugin each time the debugger wants to show a stop, including each step.
##         The editor still opens the generated `.gd` itself; this then opens the
##         `.gate` over it and marks the same line as executing.
##
## What is NOT redirected, on purpose: a stop on a generated line the map cannot
## trace back to a `.gate` line - the header, a helper the emitter wrote, a line from
## a build whose map is stale. The editor is left showing the `.gd`, because moving
## the user to a `.gate` line that is not the one running is a lie the debugger would
## then keep telling on every step.

const _Sourcemap: GDScript = preload("res://addons/gate/editor/sourcemap.gd")

var _watched: Array[WeakRef] = []
var _executing: Array = []
var _refused: Dictionary = {}


# ───────────────────────── out: to the running game ─────────────────────────

func _setup_session(session_id: int) -> void:
	var session: EditorDebuggerSession = get_session(session_id)
	if session == null:
		return
	# On `started`, not here: the game has to be listening before a breakpoint can
	# reach it, and a session exists before that.
	session.started.connect(_send_all.bind(session_id))
	session.stopped.connect(_clear_executing)
	session.continued.connect(_clear_executing)


func _send_all(session_id: int) -> void:
	var session: EditorDebuggerSession = get_session(session_id)
	if session == null:
		return
	for gate_path in collect():
		for line in collect()[gate_path]:
			var where: Dictionary = _Sourcemap.to_output(gate_path, int(line))
			if not where.is_empty():
				session.set_breakpoint(String(where["gd"]), int(where["line"]), true)


func _send_one(gate_path: String, gate_line: int, enabled: bool) -> void:
	var where: Dictionary = _Sourcemap.to_output(gate_path, gate_line)
	if where.is_empty():
		return
	for session in get_sessions():
		if (session as EditorDebuggerSession).is_active():
			(session as EditorDebuggerSession).set_breakpoint(
				String(where["gd"]), int(where["line"]), enabled)


## Every `.gate` breakpoint in the project, as path -> lines (1-based).
##
## `ScriptEditor.get_breakpoints()` is the editor's own answer and covers a script
## whose tab is closed as well as one on screen - it reads back from the same state
## `.godot/editor/script_editor_cache.cfg` is written from. Walking open editors
## instead would quietly miss every breakpoint in a file the user had closed.
func collect() -> Dictionary:
	var out: Dictionary = {}
	for entry in EditorInterface.get_script_editor().get_breakpoints():
		var text: String = String(entry)
		var at: int = text.rfind(":")
		if at < 0:
			continue
		var path: String = text.substr(0, at)
		if path.get_extension().to_lower() != "gate":
			continue
		_add(out, path, int(text.substr(at + 1)))
	return out


static func _add(out: Dictionary, path: String, line: int) -> void:
	if not out.has(path):
		out[path] = []
	if not (out[path] as Array).has(line):
		(out[path] as Array).append(line)


# ───────────────────────── back: showing the stop ─────────────────────────

## `line` is 0-based, and the editor has already opened the generated `.gd`.
func _goto_script_line(script: Script, line: int) -> void:
	if script == null:
		return
	var hit: Dictionary = _Sourcemap.to_source(script.resource_path, line + 1)
	if hit.is_empty():
		return
	_show.call_deferred(String(hit["gate"]), int(hit["line"]))


func _show(gate_path: String, gate_line: int) -> void:
	var loaded: Resource = ResourceLoader.load(gate_path, "", ResourceLoader.CACHE_MODE_REUSE)
	if not (loaded is Script):
		return
	# `edit_script` takes a 1-based line and subtracts one itself; `set_line_as_executing`
	# in `_mark` takes the 0-based index. Measured, not assumed: passing `gate_line - 1`
	# here leaves the caret one line above the breakpoint.
	EditorInterface.edit_script(loaded as Script, gate_line, 0, true)
	_mark.call_deferred(gate_line)


func _mark(gate_line: int) -> void:
	_clear_executing()
	var editor: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if editor == null or not (editor.get_base_editor() is CodeEdit):
		return
	var edit: CodeEdit = editor.get_base_editor()
	if gate_line - 1 >= edit.get_line_count():
		return
	edit.set_line_as_executing(gate_line - 1, true)
	_executing = [weakref(edit), gate_line - 1]


func _clear_executing() -> void:
	if _executing.is_empty():
		return
	var edit: CodeEdit = (_executing[0] as WeakRef).get_ref() as CodeEdit
	if edit != null and int(_executing[1]) < edit.get_line_count():
		edit.set_line_as_executing(int(_executing[1]), false)
	_executing = []


# ───────────────────── a breakpoint that cannot work ─────────────────────

## Watches every open `.gate`, so a toggle reaches a running game and a breakpoint
## on a line that generated nothing is taken back rather than left to look armed.
##
## `ScriptEditorBase` exposes `get_base_editor()` and nothing that names the script
## it holds, so the two lists are paired by index - which is how the editor builds
## them, one entry per open tab.
func watch() -> void:
	var editors: ScriptEditor = EditorInterface.get_script_editor()
	var open: Array[Script] = editors.get_open_scripts()
	var panes: Array[ScriptEditorBase] = editors.get_open_script_editors()
	for i in mini(open.size(), panes.size()):
		var script: Script = open[i]
		if script == null or script.resource_path.get_extension().to_lower() != "gate":
			continue
		if not (panes[i].get_base_editor() is CodeEdit):
			continue
		var edit: CodeEdit = panes[i].get_base_editor()
		var handler: Callable = _on_toggled.bind(edit, script.resource_path)
		if edit.breakpoint_toggled.is_connected(handler):
			continue
		edit.breakpoint_toggled.connect(handler)
		_watched.append(weakref(edit))


func unwatch() -> void:
	for reference in _watched:
		var edit: CodeEdit = reference.get_ref() as CodeEdit
		if edit == null:
			continue
		for connection in edit.breakpoint_toggled.get_connections():
			if (connection["callable"] as Callable).get_object() == self:
				edit.breakpoint_toggled.disconnect(connection["callable"])
	_watched.clear()
	_clear_executing()


## Whether a `.gate` line can carry a breakpoint, and why not when it cannot.
##
## A line that generated nothing never stops the game, and neither does one that
## generated only a comment. Comments are carried into the output now, so a
## comment line does have a mapping - and sending a breakpoint there would leave
## exactly the armed-but-never-firing dot this refusal exists to prevent.
static func breakable(gate_path: String, gate_line: int) -> Dictionary:
	var out_path: String = _Sourcemap.output_for(gate_path)
	var mapped: Dictionary = _Sourcemap.to_output(gate_path, gate_line)
	if mapped.is_empty():
		if not FileAccess.file_exists(out_path):
			return {"ok": false, "reason": "%s has not been compiled yet" % out_path.get_file()}
		if _Sourcemap.read(out_path).is_empty():
			return {"ok": false, "reason": "the sourcemap beside %s is out of date" % out_path.get_file()}
		return {"ok": false, "reason": "nothing is generated from that line"}
	var gd: String = String(mapped.get("gd", ""))
	var at: int = int(mapped.get("line", 0))
	if gd != "" and at > 0 and FileAccess.file_exists(gd):
		var lines: PackedStringArray = FileAccess.get_file_as_string(gd).split("\n")
		if at <= lines.size():
			var text: String = lines[at - 1].strip_edges()
			if text == "" or text.begins_with("#"):
				return {"ok": false, "reason": "that line is a comment"}
	return {"ok": true, "reason": ""}


func _on_toggled(line: int, edit: CodeEdit, gate_path: String) -> void:
	var enabled: bool = edit.is_line_breakpointed(line)
	if not enabled:
		_refused.erase("%s:%d" % [gate_path, line])
		_send_one(gate_path, line + 1, false)
		return
	var verdict: Dictionary = breakable(gate_path, line + 1)
	if bool(verdict["ok"]):
		_send_one(gate_path, line + 1, true)
		return
	# Nothing the game can stop on came from this line - it generated nothing, or
	# only a comment. Taking the dot straight back is the only honest answer;
	# leaving it would be a breakpoint that looks set and never fires.
	edit.set_line_as_breakpoint(line, false)
	var key: String = "%s:%d" % [gate_path, line]
	if _refused.has(key):
		return
	_refused[key] = true
	var reason: String = String(verdict["reason"])
	EditorInterface.get_editor_toaster().push_toast(
		"GATE: no breakpoint on %s:%d - %s" % [gate_path.get_file(), line + 1, reason],
		EditorToaster.SEVERITY_WARNING,
		"A breakpoint only stops the game on a line GATE compiled into the .gd beside it.")

@tool
extends RefCounted

## Puts GATE in the Script Create dialog's language list, and finishes what the
## Scene dock's Attach Script dialog starts.
##
## The three dialogs - Scene dock, FileSystem dock, Script editor - are built before
## any plugin loads, so their language list is already final by the time GATE
## registers. The dialog resolves the choice by position against the engine's
## registered languages and GATE registers last, so appending one item lines up.
## Appending is also what silences an engine error: on every theme change the dialog
## walks the languages and sets an icon per index, which is out of bounds while the
## list is one item short. All three get the item for that reason.
##
## The Scene dock's dialog needs one thing more. It writes the `.gate` and hands the
## script object to the dock, which puts it on the node - and Godot drops it, because
## a `.gate` cannot instantiate. So GATE listens on the same signal, has the file
## compiled, and puts the generated `.gd` on the node instead. The node runs the
## `.gd`, which is the same place the old refusal was protecting.

const _Tabs: GDScript = preload("res://addons/gate/editor/tabs.gd")

const LABEL: String = "GATE"

var integration: RefCounted = null


static func find_all(from: Node, cls: String, out: Array) -> void:
	if from.is_class(cls):
		out.append(from)
	for child in from.get_children(true):
		find_all(child, cls, out)


static func dialogs() -> Array:
	var out: Array = []
	var base: Control = EditorInterface.get_base_control()
	if base == null or base.get_window() == null:
		return out
	find_all(base.get_window(), "ScriptCreateDialog", out)
	return out


## True for the dialog the Scene dock opens from "Attach Script" and "Extend Script".
static func is_attach_dialog(dialog: Node) -> bool:
	var node: Node = dialog
	while node != null:
		if node.is_class("SceneTreeDock"):
			return true
		node = node.get_parent()
	return false


## The language list, told apart from the dialog's other OptionButtons by the fact
## that it is the one already offering GDScript.
static func language_menu(dialog: Node) -> OptionButton:
	var found: Array = []
	find_all(dialog, "OptionButton", found)
	for option in found:
		var menu: OptionButton = option
		for i in menu.item_count:
			if menu.get_item_text(i) == "GDScript":
				return menu
	return null


static func index_of(menu: OptionButton, text: String) -> int:
	for i in menu.item_count:
		if menu.get_item_text(i) == text:
			return i
	return -1


func add_language() -> void:
	for dialog in dialogs():
		var menu: OptionButton = language_menu(dialog)
		if menu == null:
			continue
		if index_of(menu, LABEL) < 0:
			menu.add_item(LABEL)
		if is_attach_dialog(dialog):
			_watch(dialog as Window)


func remove_language() -> void:
	for dialog in dialogs():
		if is_attach_dialog(dialog):
			_unwatch(dialog as Window)
		var menu: OptionButton = language_menu(dialog)
		if menu == null:
			continue
		var at: int = index_of(menu, LABEL)
		if at >= 0:
			menu.remove_item(at)


## The dock's icon, once the theme carries it. Called after the icon is installed.
func apply_icon() -> void:
	var theme: Theme = EditorInterface.get_editor_theme()
	if theme == null or not theme.has_icon(&"GATEScript", &"EditorIcons"):
		return
	var texture: Texture2D = theme.get_icon(&"GATEScript", &"EditorIcons")
	for dialog in dialogs():
		var menu: OptionButton = language_menu(dialog)
		if menu == null:
			continue
		var at: int = index_of(menu, LABEL)
		if at >= 0:
			menu.set_item_icon(at, texture)


## Opens the dialog on a new `.gate` in `directory`. The dialog picks the language
## from the extension, so GATE is already selected when it appears.
func open_new(directory: String) -> void:
	for dialog in dialogs():
		if is_attach_dialog(dialog):
			continue
		var menu: OptionButton = language_menu(dialog)
		if menu == null:
			continue
		var at: int = index_of(menu, LABEL)
		if at < 0:
			continue
		menu.select(at)
		menu.item_selected.emit(at)
		dialog.call("config", "Node", directory.path_join("new_script.gate"), false, false)
		(dialog as Window).popup_centered()
		return
	push_warning("[GATE] no Script Create dialog was available")


## `add_language` runs again on every theme change, so this has to recognise its own
## earlier connection or the second `connect` is an engine error.
func _watch(dialog: Window) -> void:
	if not dialog.is_connected("script_created", _on_script_created):
		dialog.connect("script_created", _on_script_created)


func _unwatch(dialog: Window) -> void:
	if dialog.is_connected("script_created", _on_script_created):
		dialog.disconnect("script_created", _on_script_created)


## Deferred, not immediate. The Scene dock connects its own handler to this signal
## when the command is chosen, and Godot does not emit connections in the order they
## were made, so the dock's own attach could otherwise land after this one and undo
## it. A deferred call runs after the whole emission either way.
func _on_script_created(created: Script) -> void:
	if created == null or not _Tabs.is_gate(created.resource_path):
		return
	_finish.call_deferred(created)


func _finish(created: Script) -> void:
	var gate_path: String = created.resource_path
	var nodes: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	var problem: String = _compiled(gate_path)
	if problem != "":
		_say(problem)
		return
	var out: String = gate_path.get_basename() + ".gd"
	var made: Script = ResourceLoader.load(out, "", ResourceLoader.CACHE_MODE_REPLACE) as Script
	if made == null:
		_say("GATE compiled %s, but %s would not load, so nothing was attached to the node."
			% [gate_path, out])
		return
	if nodes.is_empty():
		_say("%s was created and compiled, but no node was selected, so %s was not attached."
			% [gate_path, out])
		return
	_attach(nodes, made)
	EditorInterface.edit_script(created)


## The build, now rather than on the next filesystem scan, and what it said about
## this file. The `.gate` is left on disk whatever comes back: it is the user's file,
## it is already open in the script editor, and the message names it.
func _compiled(gate_path: String) -> String:
	if integration == null:
		return "%s was written, but GATE is not running, so it was not compiled." % gate_path
	var said: PackedStringArray = integration.compile_now(gate_path)
	if not said.is_empty():
		return "\n".join(said)
	if not FileAccess.file_exists(gate_path.get_basename() + ".gd"):
		return "%s was written, but GATE produced no .gd beside it." % gate_path
	return ""


func _attach(nodes: Array[Node], made: Script) -> void:
	var undo: EditorUndoRedoManager = null
	if integration != null:
		undo = integration.undo_redo()
	if undo == null:
		for node in nodes:
			node.set_script(made)
		return
	undo.create_action("Attach GATE Script", UndoRedo.MERGE_DISABLE, nodes[0])
	for node in nodes:
		undo.add_do_method(node, "set_script", made)
		undo.add_undo_method(node, "set_script", node.get_script())
	undo.commit_action()


## The dialog has already hidden by the time any of this is known, and a Window
## child of a hidden Window is not a place to show anything, so this is GATE's own
## dialog on the editor's base control. The Output panel gets it too.
func _say(text: String) -> void:
	push_error("[GATE] " + text)
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		return
	var alert: AcceptDialog = AcceptDialog.new()
	alert.title = "GATE"
	alert.dialog_text = text
	base.add_child(alert)
	alert.confirmed.connect(alert.queue_free)
	alert.canceled.connect(alert.queue_free)
	alert.popup_centered()

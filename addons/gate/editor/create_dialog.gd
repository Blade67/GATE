@tool
extends RefCounted

## Puts GATE in the Script Create dialog's language list, and keeps it out of the
## one flow that would misuse it.
##
## The three dialogs - Scene dock, FileSystem dock, Script editor - are built before
## any plugin loads, so their language list is already final by the time GATE
## registers. The dialog resolves the choice by position against the engine's
## registered languages and GATE registers last, so appending one item lines up.
## Appending is also what silences an engine error: on every theme change the dialog
## walks the languages and sets an icon per index, which is out of bounds while the
## list is one item short. All three get the item for that reason.
##
## Attaching is blocked instead, and by the language rather than by the menu. While
## `_validate_path` refuses with a sentence the dialog puts on screen. A greyed-out
## item would only leave the user guessing.

const _Registry: GDScript = preload("res://addons/gate/editor/registry.gd")

const LABEL: String = "GATE"


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
	_Registry.set_attaching(false)
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
## earlier connection or the second `connect` is an engine error. Godot matches a
## connection by its method and ignores what is bound to it - checked: after
## `connect(f.bind(w))`, `is_connected(f)` is true - so either form answers
## correctly. The bound one is written out because `disconnect` has to name it.
func _watch(dialog: Window) -> void:
	var handler: Callable = _on_attach_visibility.bind(dialog)
	if not dialog.visibility_changed.is_connected(handler):
		dialog.visibility_changed.connect(handler)


func _unwatch(dialog: Window) -> void:
	var handler: Callable = _on_attach_visibility.bind(dialog)
	if dialog.visibility_changed.is_connected(handler):
		dialog.visibility_changed.disconnect(handler)


func _on_attach_visibility(dialog: Window) -> void:
	_Registry.set_attaching(dialog.visible)

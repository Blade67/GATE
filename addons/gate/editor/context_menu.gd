@tool
extends EditorContextMenuPlugin

## "New GATE Script..." in the FileSystem dock's right-click Create submenu.

var integration: RefCounted = null


func _popup_menu(paths: PackedStringArray) -> void:
	var texture: Texture2D = null
	var theme: Theme = EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon(&"GATEScript", &"EditorIcons"):
		texture = theme.get_icon(&"GATEScript", &"EditorIcons")
	add_context_menu_item("New GATE Script...", _on_selected, texture)


func _on_selected(paths: Variant) -> void:
	var target: String = "res://"
	var list: Array = paths if paths is Array else Array(paths as PackedStringArray)
	if not list.is_empty():
		var first: String = String(list[0])
		target = first if first.ends_with("/") else first.get_base_dir()
	if integration != null:
		integration.new_script_in(target)

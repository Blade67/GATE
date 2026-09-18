@tool
extends RefCounted

## Everything that makes a `.gate` a file the editor knows about, in one place so
## `plugin.gd` stays the build pipeline it has always been.
##
## What is set up here, and what each part buys:
##
##   the script language   the file appears in the FileSystem dock and opens in the
##                         real script editor instead of being invisible
##   the theme icon        the dock, the script tab and the create dialog show it
##   the highlighter       GATE's colours, taken from the user's editor theme
##   the create dialog     GATE is offered as a language when making a new script
##   the context menu      "New GATE Script..." in the dock's Create submenu
##   the export plugin     `.gate` sources stay out of the shipped PCK
##
## The loader and saver are NOT added here. They carry `class_name`, and Godot
## registers every script-backed loader it finds in the global class list by itself;
## adding them a second time only produces a duplicate that cannot be removed
## cleanly. `registry.gd` explains what that costs and how it is contained.

const _Registry: GDScript = preload("res://addons/gate/editor/registry.gd")
const _Highlighter: GDScript = preload("res://addons/gate/editor/highlighter.gd")
const _Icon: GDScript = preload("res://addons/gate/editor/icon.gd")
const _Export: GDScript = preload("res://addons/gate/editor/export.gd")
const _CreateDialog: GDScript = preload("res://addons/gate/editor/create_dialog.gd")
const _ContextMenu: GDScript = preload("res://addons/gate/editor/context_menu.gd")
const _Index: GDScript = preload("res://addons/gate/editor/index.gd")
const _Complete: GDScript = preload("res://addons/gate/editor/complete.gd")
const _Breakpoints: GDScript = preload("res://addons/gate/editor/breakpoints.gd")
const _Lookup: GDScript = preload("res://addons/gate/editor/lookup.gd")
const _Tabs: GDScript = preload("res://addons/gate/editor/tabs.gd")
const _Warnings: GDScript = preload("res://addons/gate/editor/warnings.gd")

const ICON_KEY: StringName = &"GATEScript"
const ICON_TYPE: StringName = &"EditorIcons"

var _plugin: EditorPlugin = null
var _language: ScriptLanguageExtension = null
var _highlighter: EditorSyntaxHighlighter = null
var _export: EditorExportPlugin = null
var _context: EditorContextMenuPlugin = null
var _dialogs: RefCounted = null
var _breakpoints: EditorDebuggerPlugin = null
var _attached: bool = false
var _refresh_pending: bool = false
var _open_at_hover: PackedStringArray = PackedStringArray()
var _hovered: bool = false


func attach(plugin: EditorPlugin) -> void:
	if _attached:
		return
	_plugin = plugin
	_language = _Registry.language()
	if _language == null:
		push_error("[GATE] the script language failed to load; .gate files stay invisible")
		return
	if Engine.register_script_language(_language) != OK:
		push_error("[GATE] Godot refused to register the GATE script language")
		return
	_attached = true
	_Registry.set_active(true)

	_highlighter = _Highlighter.new()
	EditorInterface.get_script_editor().register_syntax_highlighter(_highlighter)

	_export = _Export.new()
	_plugin.add_export_plugin(_export)

	_context = _ContextMenu.new()
	_context.integration = self
	_plugin.add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM_CREATE, _context)

	_dialogs = _CreateDialog.new()

	_breakpoints = _Breakpoints.new()
	_plugin.add_debugger_plugin(_breakpoints)
	var editors: ScriptEditor = EditorInterface.get_script_editor()
	if not editors.editor_script_changed.is_connected(_on_script_changed):
		editors.editor_script_changed.connect(_on_script_changed)

	var settings: EditorSettings = EditorInterface.get_editor_settings()
	if settings != null and not settings.settings_changed.is_connected(_on_settings_changed):
		settings.settings_changed.connect(_on_settings_changed)

	# What Ctrl-click and completion read is the project as it was, so it is dropped
	# whenever the project changes and rebuilt by whichever of them asks first.
	var filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if filesystem != null and not filesystem.filesystem_changed.is_connected(_on_filesystem_changed):
		filesystem.filesystem_changed.connect(_on_filesystem_changed)

	var base: Control = EditorInterface.get_base_control()
	if base != null and not base.theme_changed.is_connected(_on_theme_changed):
		base.theme_changed.connect(_on_theme_changed)

	# The dock and the create dialogs are built before plugins load, so the whole of
	# `_refresh` runs once the editor has finished coming up rather than now.
	_queue_refresh()


func detach() -> void:
	if not _attached:
		return
	_attached = false
	_Registry.set_active(false)

	var settings: EditorSettings = EditorInterface.get_editor_settings()
	if settings != null and settings.settings_changed.is_connected(_on_settings_changed):
		settings.settings_changed.disconnect(_on_settings_changed)

	var filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if filesystem != null and filesystem.filesystem_changed.is_connected(_on_filesystem_changed):
		filesystem.filesystem_changed.disconnect(_on_filesystem_changed)
	var base: Control = EditorInterface.get_base_control()
	if base != null and base.theme_changed.is_connected(_on_theme_changed):
		base.theme_changed.disconnect(_on_theme_changed)
	_Index.invalidate()
	_Complete.forget()
	_Warnings.forget()

	var editors: ScriptEditor = EditorInterface.get_script_editor()
	if editors != null and editors.editor_script_changed.is_connected(_on_script_changed):
		editors.editor_script_changed.disconnect(_on_script_changed)
	if editors != null:
		for pane in editors.get_open_script_editors():
			var edit: CodeEdit = pane.get_base_editor() as CodeEdit
			if edit != null and edit.symbol_lookup.is_connected(_on_symbol_lookup):
				edit.symbol_lookup.disconnect(_on_symbol_lookup)
				edit.symbol_validate.disconnect(_on_symbol_validate)
	if _breakpoints != null:
		_breakpoints.unwatch()
		_plugin.remove_debugger_plugin(_breakpoints)
		_breakpoints = null

	if _dialogs != null:
		_dialogs.remove_language()
		_dialogs = null
	if _context != null:
		_plugin.remove_context_menu_plugin(_context)
		_context = null
	if _export != null:
		_plugin.remove_export_plugin(_export)
		_export = null
	if _highlighter != null:
		EditorInterface.get_script_editor().unregister_syntax_highlighter(_highlighter)
		_highlighter = null

	# Unregister before clearing the icon, for the reason `_refresh` adds the language
	# item before installing it: clearing an icon is a theme change too, and the
	# dialogs must not be one item short of the language count while it happens.
	if _language != null:
		Engine.unregister_script_language(_language)
	_language = null
	_Registry.release()

	var theme: Theme = EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon(ICON_KEY, ICON_TYPE):
		theme.clear_icon(ICON_KEY, ICON_TYPE)
	_plugin = null
	EditorInterface.get_resource_filesystem().scan.call_deferred()


## Called once at startup and again whenever the editor rebuilds its theme. Walking
## the editor's node tree for the create dialogs is not free and `settings_changed`
## can arrive several times for one change, so repeats inside a frame collapse.
func _refresh() -> void:
	_refresh_pending = false
	if not _attached:
		return
	# The language item first: the dialogs set one icon per registered language on
	# every theme change, and installing the icon is a theme change, so a list that
	# is still one item short at that moment reports an out-of-bounds index.
	if _dialogs != null:
		_dialogs.add_language()
	_apply_icon()
	if _dialogs != null:
		_dialogs.apply_icon()


func _apply_icon() -> void:
	var theme: Theme = EditorInterface.get_editor_theme()
	if theme == null:
		return
	var texture: ImageTexture = _Icon.texture(EditorInterface.get_editor_scale())
	if texture == null:
		push_warning("[GATE] the file icon could not be rendered")
		return
	theme.set_icon(ICON_KEY, ICON_TYPE, texture)


## Reached from the dock's "New GATE Script..." entry.
func new_script_in(directory: String) -> void:
	if _dialogs != null:
		_dialogs.open_new(directory)


func _queue_refresh() -> void:
	if _refresh_pending:
		return
	_refresh_pending = true
	_refresh.call_deferred()


## A `.gate` becoming the edited script is the first moment its `CodeEdit` exists.
func _on_script_changed(script: Script) -> void:
	if _breakpoints != null:
		_breakpoints.watch()
	var editors: ScriptEditor = EditorInterface.get_script_editor()
	if script == null or not _Tabs.is_gate(script.resource_path) or editors.get_current_editor() == null:
		return
	var edit: CodeEdit = editors.get_current_editor().get_base_editor() as CodeEdit
	if edit != null and not edit.symbol_lookup.is_connected(_on_symbol_lookup):
		edit.symbol_lookup.connect(_on_symbol_lookup)
		edit.symbol_validate.connect(_on_symbol_validate)

func _open_paths() -> PackedStringArray:
	return PackedStringArray(EditorInterface.get_script_editor().get_open_scripts().map(
		func(open: Script) -> String: return open.resource_path if open != null else ""))


func _on_symbol_validate(_symbol: String) -> void:
	_open_at_hover = _open_paths()
	_hovered = true


func _on_symbol_lookup(symbol: String, _line: int, _column: int) -> void:
	var hovered: bool = _hovered
	_hovered = false
	var generated: String = _Lookup._global_class_path(symbol)
	if generated.get_extension().to_lower() != "gd":
		return
	var source: String = generated.get_basename() + ".gate"
	if not FileAccess.file_exists(source) or not FileAccess.file_exists(generated + ".map"):
		return
	var current: Script = EditorInterface.get_script_editor().get_current_script()
	var opened_by_click: bool = hovered and current != null and current.resource_path == generated 		and not _open_at_hover.has(generated)
	_open_source.call_deferred(source, symbol, generated if opened_by_click else "")


func _open_source(source: String, symbol: String, close: String) -> void:
	var script: Script = ResourceLoader.load(source) as Script
	if script == null:
		return
	EditorInterface.edit_script(script, _Lookup._class_name_line(source, symbol))
	if close == "":
		return
	var editors: ScriptEditor = EditorInterface.get_script_editor()
	var scripts: Array[Script] = editors.get_open_scripts()
	var panes: Array[ScriptEditorBase] = editors.get_open_script_editors()
	for i in mini(scripts.size(), panes.size()):
		if scripts[i] == null or scripts[i].resource_path != close:
			continue
		var edit: TextEdit = panes[i].get_base_editor() as TextEdit
		if edit != null and edit.get_version() != edit.get_saved_version():
			return
	editors.close_file(close)


func _on_theme_changed() -> void:
	var theme: Theme = EditorInterface.get_editor_theme()
	if _attached and theme != null and not theme.has_icon(ICON_KEY, ICON_TYPE):
		_queue_refresh()


func _on_filesystem_changed() -> void:
	_Index.invalidate()
	_Complete.forget()
	_Warnings.forget()


func _on_settings_changed() -> void:
	_Highlighter.invalidate()
	_queue_refresh()

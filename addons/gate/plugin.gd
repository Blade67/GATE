@tool
extends EditorPlugin

## GATE - compiles .gate files to .gd on save.

const _SourceFollow := preload("res://addons/gate/source_follow.gd")
const _Integration := preload("res://addons/gate/editor/integration.gd")
const _Tabs := preload("res://addons/gate/editor/tabs.gd")

const RECOMPILE_ITEM: String = "Recompile all GATE files"

var _builder: GateBuilder = GateBuilder.new()
var _integration: _Integration = _Integration.new()
var _compiling: bool = false
var _fs: EditorFileSystem
var _follow: _SourceFollow = _SourceFollow.new()
var _swept_after_scan: bool = false
var _rescan_pending: bool = false
var _removed: PackedStringArray = PackedStringArray()
var _told: Dictionary = {}


func _enter_tree() -> void:
	# A build before the resource_path fix left probe files behind whenever a scene
	# was saved. Swept again after the first scan, and after every build.
	GateBuilder.remove_stale_probes("res://")
	_builder.cache_path = GateBuilder.CACHE_FILE
	_fs = EditorInterface.get_resource_filesystem()
	if not _fs.filesystem_changed.is_connected(_on_fs_changed):
		_fs.filesystem_changed.connect(_on_fs_changed)
	_follow.attach()
	_integration.attach(self)
	add_tool_menu_item(RECOMPILE_ITEM, _recompile_all)
	compile_all.call_deferred()


## `.gate` tabs never stay in the saved layout, so a session without GATE cannot
## reopen one as plain text and rewrite it on exit. See editor/tabs.gd.
func _get_window_layout(configuration: ConfigFile) -> void:
	_Tabs.hide_from_layout(configuration)


func _set_window_layout(configuration: ConfigFile) -> void:
	_Tabs.restore_from_layout(configuration)


## Switched off from the Plugins tab, not at shutdown: the next layout save happens
## without this plugin, so the tabs are closed now instead.
func _disable_plugin() -> void:
	_Tabs.close_all()
	queue_save_layout()


func _exit_tree() -> void:
	remove_tool_menu_item(RECOMPILE_ITEM)
	# Before GATE's saver goes inactive. On the way out Godot converts each open tab's
	# indentation and saves the tabs that changed; a `.gate` tab it cannot save makes it
	# open an error dialog while the tree shuts down, twice per tab. The layout already
	# holds these tabs in GATE's section, so they come back next session.
	_Tabs.close_all(false)
	_integration.detach()
	if _fs and _fs.filesystem_changed.is_connected(_on_fs_changed):
		_fs.filesystem_changed.disconnect(_on_fs_changed)
	_follow.detach()
	GateBuilder.release_caches()


## Project > Tools. A build normally only visits what changed, in this session or an
## earlier one; this forgets both and looks at every `.gate` again.
func _recompile_all() -> void:
	_builder = GateBuilder.new()
	_builder.cache_path = GateBuilder.CACHE_FILE
	_builder.trust_cache = false
	compile_all()


func _on_fs_changed() -> void:
	if not _swept_after_scan:
		_swept_after_scan = true
		GateBuilder.remove_stale_probes("res://")
	# Files written while a scan ran may have been missed by it.
	if _rescan_pending and _fs and not _fs.is_scanning():
		_rescan_pending = false
		_fs.scan.call_deferred()
	_forget_removed.call_deferred()
	if _compiling:
		return
	compile_all()


func compile_all() -> void:
	if _compiling:
		return
	_compiling = true
	var r: Dictionary = _builder.build("res://")
	_compiling = false

	# Probes from a build that ran before the fix, in this same session, are still
	# in the resource cache and a scene save writes them: upgrading GATE without
	# restarting the editor is exactly that. The sweep costs one walk of a tree the
	# build just walked anyway.
	GateBuilder.remove_stale_probes("res://")

	# The editor builds several times while it comes up, and until Godot's class list
	# catches up each build finds the same files it cannot verify yet. Once per session
	# is enough to be told.
	for w in _builder.warnings:
		if not _told.has(w):
			_told[w] = true
			push_warning(w)
	for e in _builder.errors:
		push_error(e)

	_removed.append_array(_builder.removed_paths)
	_forget_removed.call_deferred()
	if r["changed"] > 0 and _fs:
		if _fs.is_scanning():
			_rescan_pending = true
		else:
			_fs.scan.call_deferred()
	if r["changed"] > 0 or r["failed"] > 0:
		print("[GATE] compiled %d file(s), %d failed" % [r["changed"], r["failed"]])
	# A start with nothing to build read no file; completion and the next real build
	# would each read the whole project at once. Read it a little per frame instead.
	set_process(_builder.indexed == 0)


func _process(_delta: float) -> void:
	if _compiling or _builder.indexed > 0:
		set_process(false)
	elif GateProject.warm_step("res://", 8000) and _builder.warm_mentions("res://", 8000):
		set_process(false)
		_builder.share_index("res://")


## A scan does not notice a file deleted while it ran, so a removed output would
## keep its class_name registered. Told directly, the editor drops both.
func _forget_removed() -> void:
	if _removed.is_empty() or _fs == null or _fs.is_scanning():
		return
	for p in _removed:
		_fs.update_file(p)
	_removed.clear()

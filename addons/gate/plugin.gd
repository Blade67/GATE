@tool
extends EditorPlugin

## GATE - compiles .gate files to .gd on save.

var _builder: GateBuilder = GateBuilder.new()
var _compiling: bool = false
var _fs: EditorFileSystem


func _enter_tree() -> void:
	_fs = EditorInterface.get_resource_filesystem()
	if not _fs.filesystem_changed.is_connected(_on_fs_changed):
		_fs.filesystem_changed.connect(_on_fs_changed)
	compile_all.call_deferred()


func _exit_tree() -> void:
	if _fs and _fs.filesystem_changed.is_connected(_on_fs_changed):
		_fs.filesystem_changed.disconnect(_on_fs_changed)


func _on_fs_changed() -> void:
	if _compiling:
		return
	compile_all()


func compile_all() -> void:
	if _compiling:
		return
	_compiling = true
	var r: Dictionary = _builder.build("res://")
	_compiling = false

	for w in _builder.warnings:
		push_warning(w)
	for e in _builder.errors:
		push_error(e)

	if r["changed"] > 0:
		if _fs and not _fs.is_scanning():
			_fs.scan.call_deferred()
	if r["changed"] > 0 or r["failed"] > 0:
		print("[GATE] compiled %d file(s), %d failed" % [r["changed"], r["failed"]])

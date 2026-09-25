@tool
extends EditorExportPlugin

## Keeps GATE out of the game you ship.
##
## Once `.gate` is a script Godot tracks it is a resource, and a resource goes into
## the PCK - so an exported game carried the whole GATE source of every file beside
## the compiled `.gd` it actually runs. Measured on 4.7.2: with the language
## registered and this plugin removed, `res://sample.gate` is stored in the pack;
## with it, the pack holds `sample.gdc` and nothing else of GATE's.
##
## Dropped from the pack:
##
##   *.gate           the source. The `.gd` beside it is what the game loads.
##   *.gate.uid       the id Godot mints for a `.gate`.
##   *.gd.map         the sourcemap, read only by the editor to name a `.gate` line.
##   addons/gate/     the compiler and the editor integration - except the four
##                    files below.
##
## Kept, because an exported game cannot start silently without them:
##
##   editor/loader.gd, editor/saver.gd   `class_name GateScriptLoader` and
##                                       `GateScriptSaver` are in the global class
##                                       cache the export bakes into the pack, and
##                                       at start-up Godot instances every
##                                       script-backed loader and saver named there.
##                                       With the files gone that is three engine
##                                       errors each, in every exported game.
##   editor/registry.gd, editor/script.gd what those two preload.
##
## All four are inert in a game: the loader and saver do nothing unless the editor
## plugin set `GateRegistry.active`, and nothing in a game ever does. The language,
## which is the one that would load the compiler, is not among them - `registry.gd`
## only loads it on demand, and nothing in a game makes that demand.
##
## Measured by running the exported pack as a game, with its main scene, not with
## `--script`: an earlier version of this check ran the pack through `--script`,
## which skips custom loader registration entirely, and so reported a clean start
## for a pack that printed six errors when actually played.

const ADDON_PREFIX: String = "res://addons/gate/"

## The export swap's own sibling file, holding a `.gd`'s pre-swap content while
## an export is in progress - never a project file, and never packed.
const BACKUP_SUFFIX: String = ".gate_export_bak"

const SKIPPED_SUFFIXES: Array[String] = [".gate", ".gate.uid", ".gd.map", BACKUP_SUFFIX]

## The only part of the addon a game needs. See above for why each is here.
const RUNTIME: Array[String] = [
	"res://addons/gate/editor/loader.gd",
	"res://addons/gate/editor/saver.gd",
	"res://addons/gate/editor/registry.gd",
	"res://addons/gate/editor/script.gd",
]


func _get_name() -> String:
	return "GATE"


static func is_editor_only(path: String) -> bool:
	if path.begins_with(ADDON_PREFIX):
		return not RUNTIME.has(path)
	for suffix in SKIPPED_SUFFIXES:
		if path.ends_with(suffix):
			return true
	return false


## Rebuilt once per export, not once per file: cross-file features (structs,
## namespaces, generics) still need to resolve during the recompile below.
var _export_registry = null

## Every `.gd` this export swapped, with the sibling backup path holding its
## original text - `_export_end()` restores from there and deletes it. Kept as
## a real file, not just memory, so a crash between the swap and `_export_end()`
## still leaves something `restore_leftover_backups()` can find and fix next
## time the editor opens, rather than a working file stuck holding export-time
## content forever.
var _export_backups: PackedStringArray = PackedStringArray()

## How many files this export could not recompile. `EditorExportPlugin` has no
## call that aborts the export outright, so a broken `@if RELEASE` branch -
## never parsed during ordinary editor use, since `DEBUG` is true there - used
## to surface only as `if not res.ok: return`: the editor's own build shipped
## silently, exit code 0, wrong branch and all. Now the file is skip()'d
## instead of packed wrong, every error is push_error'd, and _export_end()
## says how many files this happened to.
var _export_failures: int = 0

## Godot 4.7 offers no way to export a compiled `.gd` without the right source
## being on disk first. `EditorExportPlugin.add_file()` stores the exact bytes
## given under the exact path given, so pairing it with `skip()` on a `.gd`
## ships raw source under the `.gd` name rather than Godot's own `.gdc`, and
## `GDScript` exposes no `get_as_byte_code()`. Resource customization
## (`_begin_customize_resources()` / `_customize_resource(resource, path)` /
## `_get_customization_configuration_hash()`) reads like the answer and is not:
## the hash callback fires with the right per-export value, but
## `_customize_resource()` is never called for a `.gd` at all, on either
## `--export-debug` or `--export-release`.
##
## So the working file is swapped, and the swap is made crash-safe. Only a `.gd`
## whose `.gate` source actually has a directive in it is ever opened for
## writing (`GatePreprocess.has_directive()`, the same cheap check the
## preprocessor's own fast path and the build cache use), the original text is
## saved to a sibling `.gate_export_bak` before the write, and `_export_end()`
## restores from that file and deletes it. Godot runs export in-process, so a
## crash between the write and `_export_end()` is a real path, not a theoretical
## one: `restore_leftover_backups()` runs once, when the plugin attaches, so a
## backup an earlier session left behind is put back and reported the next time
## the editor opens, not left silently wrong.
func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_export_registry = null
	_export_backups = PackedStringArray()
	_export_failures = 0


func _export_end() -> void:
	for path in _export_backups:
		_restore_one(path)
	_export_backups = PackedStringArray()
	if _export_failures > 0:
		push_error(("[GATE] export finished with %d file(s) that failed to recompile with "
			+ "this preset's own compile-time symbols (see the errors above) and were left "
			+ "out of the pack rather than shipped with the wrong branch.") % _export_failures)


## Writes `path`'s current bytes to `path + BACKUP_SUFFIX`, returning false (and
## touching nothing) if either read fails, so a swap is only ever recorded once
## it is actually safe to undo.
func _backup(path: String) -> bool:
	var text: String = FileAccess.get_file_as_string(path)
	if text == "" and not FileAccess.file_exists(path):
		return false
	var bak: FileAccess = FileAccess.open(path + BACKUP_SUFFIX, FileAccess.WRITE)
	if bak == null:
		return false
	bak.store_string(text)
	bak.close()
	return true


static func _restore_one(path: String) -> void:
	var bak_path: String = path + BACKUP_SUFFIX
	if not FileAccess.file_exists(bak_path):
		return
	var text: String = FileAccess.get_file_as_string(bak_path)
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(bak_path))


## Called once, when the plugin attaches (`editor/integration.gd`'s `attach()`),
## well before any export could run: an export that started and never finished
## leaves its swapped file's real content sitting in a `.gate_export_bak`
## sibling, so this puts it back and says so, rather than leaving a working
## file silently holding export-time content indefinitely.
static func restore_leftover_backups(root: String) -> void:
	var found: Array[String] = []
	_scan_for_backups(root, found)
	for bak_path in found:
		var real_path: String = bak_path.substr(0, bak_path.length() - BACKUP_SUFFIX.length())
		_restore_one(real_path)
		push_warning(("[GATE] %s was left holding export-time content by an export that did not "
			+ "finish; restored from %s.") % [real_path, bak_path])


## Not `GateProject.walks_into()`: that rule skips any directory literally
## named `addons`, which is right for GateProject's own file discovery (an
## `addons/` folder holds other plugins' code, not project `.gate` sources to
## compile) but wrong here. `_recompile_for_export()` swaps any `.gd` with a
## directive-bearing `.gate` sibling with no such exclusion - a user's own
## `.gate` under `res://addons/their_plugin/` swaps exactly like any other -
## so scanning for a leftover backup skipped the one place it could most
## plausibly be, and stranded it there forever.
static func _walks_into_for_backups(d: DirAccess, n: String, p: String) -> bool:
	return not n.begins_with(".") and not d.is_link(p) and not FileAccess.file_exists(p.path_join("project.godot"))


static func _scan_for_backups(dir: String, found: Array[String]) -> void:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		var p: String = dir.path_join(n)
		if d.current_is_dir():
			if _walks_into_for_backups(d, n, p):
				_scan_for_backups(p, found)
		elif n.ends_with(BACKUP_SUFFIX):
			found.append(p)
		n = d.get_next()
	d.list_dir_end()


## `.gate` files never reach the pack (skipped in `_export_file()` below), so an
## exported `.gd` still carries every `@if` block as ordinary code unless this
## recompiles it with the preset's own symbols. `features` is the same set
## Godot resolved for this file: the platform, "debug" or "release", and the
## preset's own custom_features. `GateDefines.table_for_export()` builds the
## table an `@if` is judged against entirely from `features`, never from this
## machine's own platform, so a release export genuinely lacks a `@if DEBUG`
## block, and an Android export never inherits `WINDOWS` from the host doing
## the exporting.
func _recompile_for_export(path: String, gate_path: String, features: PackedStringArray) -> void:
	var f: FileAccess = FileAccess.open(gate_path, FileAccess.READ)
	if f == null:
		return
	var src: String = f.get_as_text()
	f.close()
	if not GatePreprocess.has_directive(src):
		return
	if _export_registry == null:
		var project: GateProject = GateProject.new()
		_export_registry = project.index("res://")
	var defines: Dictionary = GateDefines.table_for_export(features)
	var compiler: GateCompiler = GateCompiler.new()
	var res: GateCompiler._Result = compiler.compile(src, gate_path, _export_registry, defines)
	if not res.ok:
		_export_failures += 1
		for d in res.diagnostics.items:
			if d.level == GateDiagnostics._Level.ERROR:
				push_error("[GATE] %s: %s" % [gate_path, d.format()])
		push_error(("[GATE] %s failed to recompile with this export preset's symbols; left out "
			+ "of the pack rather than shipped as the editor's own build.") % gate_path)
		# Nothing available makes a CLI export's own exit code non-zero for
		# this, checked by experiment - but the editor's own export dialog
		# has a message list, and this is the call that reaches it.
		var platform: EditorExportPlatform = get_export_platform()
		if platform != null:
			platform.add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "GATE",
				"%s failed to recompile with this export preset's symbols" % gate_path)
		skip()
		return
	# An earlier export that swapped this file and never reached _export_end()
	# leaves its backup sitting here with the true original, and `path` itself
	# holding THAT export's content, not the source. Put it back before reading
	# `path` as "the original" for anything below, or a second swap in the same
	# process bases its own backup on already-stripped content and the real
	# original is gone for good.
	if FileAccess.file_exists(path + BACKUP_SUFFIX):
		_restore_one(path)
	var original: String = FileAccess.get_file_as_string(path)
	if original == res.source:
		return
	if not _backup(path):
		return
	var wf: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if wf == null:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + BACKUP_SUFFIX))
		return
	wf.store_string(res.source)
	wf.close()
	_export_backups.append(path)


func _export_file(path: String, type: String, features: PackedStringArray) -> void:
	if is_editor_only(path):
		skip()
		return
	if path.ends_with(".gd"):
		var gate_path: String = path.get_basename() + ".gate"
		if FileAccess.file_exists(gate_path):
			_recompile_for_export(path, gate_path, features)

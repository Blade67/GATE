@tool
class_name GateBuilder
extends RefCounted

## Everything the editor plugin does, minus the editor.
##
## Writes every output first and validates afterwards: a file that references
## another preloads it, so in a cycle neither can go first.

const TAB: String = "\t"

const RESULT_UNLINKED := -2

const RESULT_SETTLED := -3

const IGNORE_DIRS := ["addons", ".godot", ".git", ".import"]

var hashes: Dictionary = {}

var out_hashes: Dictionary = {}

var unverified: Dictionary = {}

var _last_good: Dictionary = {}

static var _probe_seq: int = 0

static var _probe_stem: int = -1

const PROBE_PREFIX := "__gate_probe_"

const PROBE_SUFFIX := ".temp.gd"

const BASE36 := "0123456789abcdefghijklmnopqrstuvwxyz"

const BASE36_5 := 60466176   ## 36 ** 5

enum { VERIFIED, ALIASED, FAILED, UNVERIFIED_OTHER, UNVERIFIED_SELF, FAILED_SAID, UNVERIFIED_DEEP }

const DEEP_CLASSES := 16

var errors: PackedStringArray = []
var warnings: PackedStringArray = []

var changed: int = 0
var failed: int = 0
var unchanged: int = 0
var removed: int = 0
var removed_paths: PackedStringArray = PackedStringArray()

var _said: Dictionary = {}

var _heard: Dictionary = {}

var _failed_at: Dictionary = {}
var _failed_msg: Dictionary = {}

var _rejects: Dictionary = {}

var _deep: Dictionary = {}

var _skipped_now: Array = []

var _globals_seen: String = ""

const CACHE_FILE: String = "res://.godot/gate/build_cache.json"

const CACHE_FORMAT: int = 1

var cache_path: String = ""

var trust_cache: bool = true

var compiled_log: PackedStringArray = PackedStringArray()

var _saved: Dictionary = {}
var _settled_world: Dictionary = {}
var _fx_memo: Dictionary = {}
var _fx_fn_hash: Dictionary = {}
var _world_now: Dictionary = {}
var _orphans_looked: String = ""
var _refused: Dictionary = {}
var _fx_texts: Dictionary = {}
var _fx_signature: String = ""
var _reached: Dictionary = {}       ## hand-written script -> its surface, for every one a .gate reaches
var _settled_replay: Dictionary = {}
var _godot_said: Array = []

var indexed: int = 0
var probed: int = 0
var _dep_keys: Dictionary = {}
var _mentions_memo: Dictionary = {}
var _saved_loaded: bool = false
var _saved_text: String = ""
var _proof: Dictionary = {}
var _outside: String = ""


class _Heard extends Logger:
	var path: String = ""
	var heard: Array = []
	var _lock: Mutex = Mutex.new()

	func _log_error(_function: String, file: String, line: int, code: String,
			_rationale: String, _editor_notify: bool, _error_type: int,
			_script_backtraces: Array[ScriptBacktrace]) -> void:
		if file != path:
			return
		_lock.lock()
		heard.append({"line": line, "code": code})
		_lock.unlock()


func _clear() -> void:
	errors = PackedStringArray()
	warnings = PackedStringArray()
	changed = 0
	failed = 0
	unchanged = 0
	removed = 0
	removed_paths = PackedStringArray()
	_heard = {}
	_refreshed = {}
	_godot_said = []


func _warn_once(key: String, message: String) -> void:
	if not _said.has(key):
		_said[key] = true
		warnings.append(message)


var indent: String = ""


func _indent_for(src: String) -> String:
	if indent != "":
		return indent
	if _editor_unit == "?":
		_editor_unit = _editor_indent()   # once a build: asking the editor is slow
	return _editor_unit if _editor_unit != "" else GateCompiler.indent_of(src)


var _editor_unit: String = "?"


static func _editor_indent() -> String:
	if not Engine.has_singleton("EditorInterface"):
		return ""
	var es: Object = Engine.get_singleton("EditorInterface").call("get_editor_settings")
	if es == null or not es.call("has_setting", "text_editor/behavior/indent/type"):
		return ""
	if int(es.call("get_setting", "text_editor/behavior/indent/type")) == 0:
		return "\t"
	var size: int = 4
	if es.call("has_setting", "text_editor/behavior/indent/size"):
		size = int(es.call("get_setting", "text_editor/behavior/indent/size"))
	return " ".repeat(maxi(size, 1))


func build(root: String = "res://") -> Dictionary:
	_clear()
	_editor_unit = "?"
	var world: Dictionary = {}
	if cache_path != "":
		if not _saved_loaded:
			_saved_loaded = true
			_load_saved(root)
		world = _world(root)
		if _nothing_to_do(world):
			return _replay()
	_world_now = world
	var globals_now: String = _globals_fingerprint()
	var globals_moved: bool = globals_now != _globals_seen
	if globals_moved:
		_globals_seen = globals_now
		GateChecker.forget_global_identifiers()
	var project: GateProject = GateProject.new()
	var registry = project.index(root)
	indexed += 1
	_outside = _outside_globals(registry, root)
	if cache_path != "" and not _saved_loaded:
		_saved_loaded = true
		_load_saved(root)

	var files_key: String = ""
	if not world.is_empty():
		files_key = str([(world["gate"] as Dictionary).keys(), (world["scripts"] as Dictionary).keys(),
			(world["hand"] as Dictionary).keys()]).md5_text()
	if files_key == "" or files_key != _orphans_looked:
		_remove_orphans(root)
		_orphans_looked = files_key if removed == 0 else ""
	var gate_files: Array[String] = find_gate_files(root)

	var sources: Dictionary = {}
	var ambiguous: Dictionary = {}
	for dname in registry.declared_in:
		var where: Array = registry.declared_in[dname]
		if where.size() < 2:
			continue
		var users: PackedStringArray = PackedStringArray()
		for gp in gate_files:
			if where.has(gp):
				continue
			if not sources.has(gp):
				sources[gp] = _code_of(gp)
			if _uses_word(sources[gp], String(dname)):
				users.append(gp)
		if not users.is_empty():
			ambiguous[dname] = users

	for cname in registry.class_name_declared_in:
		var decls: Array = registry.class_name_declared_in[cname]
		if decls.size() < 2:
			continue
		var sorted_cn: Array = decls.duplicate()
		sorted_cn.sort()
		errors.append(("[GATE] class_name '%s' is declared by more than one file: %s. Godot "
			+ "registers one of them, and the other will not load. Rename one.")
			% [cname, ", ".join(PackedStringArray(sorted_cn))])
		failed += 1

	_note_skipped(root, root)
	var reached_before: Dictionary = _reached
	_dep_keys = _dependency_keys(gate_files, registry, root)

	var sig: String = registry.signature()
	var reg_sig: String = "%d:%d:%s" % [sig.hash(), sig.length(), _shadowing_globals(registry)]

	var deferred: Dictionary = {}
	_skipped_now = []
	for path in gate_files:
		match compile_file(path, registry, deferred, reg_sig):
			1: changed += 1
			0: unchanged += 1
			-1: failed += 1
	if changed > 0 and not _skipped_now.is_empty():
		var again: Array = _skipped_now.duplicate()
		_skipped_now = []
		for path2 in again:
			_failed_at.erase(path2)
			match compile_file(path2, registry, deferred, reg_sig):
				1: changed += 1
				0: unchanged += 1
				-1: failed += 1
	for path3 in _skipped_now:
		errors.append(String(_failed_msg.get(path3, "[GATE] %s: Godot will not load its output." % path3)))
		failed += 1

	for dname3 in ambiguous:
		var where3: Array = registry.declared_in[dname3]
		var real_users: PackedStringArray = PackedStringArray()
		for up in ambiguous[dname3]:
			var up_out: String = String(up).get_basename() + ".gd"
			var text: String = String(deferred[up_out]["source"]) if deferred.has(up_out) else _read_text(up_out)
			if text == "" or _uses_extern(text, String(dname3), where3):
				real_users.append(up)
		if real_users.is_empty():
			continue
		var sorted: Array = where3.duplicate()
		sorted.sort()
		errors.append(("[GATE] '%s' is declared at the top level of more than one file: "
			+ "%s, and %s uses it. The project index is flat, so GATE cannot tell which "
			+ "one it means. Rename one, or move it inside a class or namespace.")
			% [dname3, ", ".join(PackedStringArray(sorted)), ", ".join(real_users)])
		failed += 1

	var dependents: Dictionary = {}
	for out_path in deferred:
		for dep in deferred[out_path]["deps"]:
			var abs_dep: String = _resolve_dep(String(dep), out_path)
			if abs_dep == "":
				continue
			if not dependents.has(abs_dep):
				dependents[abs_dep] = []
			(dependents[abs_dep] as Array).append(out_path)

	var declared_here: Dictionary = {}
	for dname2 in registry.script_class_names:
		declared_here[dname2] = String(registry.script_class_names[dname2]).get_basename() + ".gd"

	var pending: Dictionary = _unregistered(declared_here)
	_start_reach(deferred, declared_here, pending)
	for out_path1 in deferred:
		_refresh_handwritten(out_path1)

	var verdicts: Dictionary = {}
	var todo: Array = deferred.keys()
	if _nothing_godot_sees_moved(deferred, pending, globals_moved, reached_before):
		var fresh: Array = []
		for o0 in todo:
			if int(deferred[o0]["was"]) == 0 and not unverified.has(String(deferred[o0]["gate"])):
				verdicts[o0] = VERIFIED
			else:
				fresh.append(o0)
		todo = fresh
	while not todo.is_empty():
		for out_path2 in todo:
			verdicts[out_path2] = _validate(deferred[out_path2]["source"], out_path2, declared_here,
				pending, deferred)
		var still: Dictionary = {}
		for pn in pending:
			var pv: int = int(verdicts.get(pending[pn], VERIFIED))
			if pv != FAILED and pv != FAILED_SAID:
				still[pn] = pending[pn]
		todo = []
		if still.size() < pending.size():
			pending = still
			for o in verdicts:
				if int(verdicts[o]) in [ALIASED, UNVERIFIED_OTHER, UNVERIFIED_SELF]:
					todo.append(o)

	var failed_outputs: Dictionary = {}
	var unsaid: Dictionary = {}           ## failed, and nothing has shown Godot's message yet
	var because: Dictionary = {}          ## failed only through the rejected output it loads
	var unverified_now: Dictionary = {}   ## output -> UNVERIFIED_OTHER / UNVERIFIED_SELF
	var recheck: Dictionary = {}          ## output passed only with aliases
	var queue: Array = []
	for out_path3 in deferred:
		var info3: Dictionary = deferred[out_path3]
		var verdict: int = verdicts[out_path3]
		if verdict == VERIFIED:
			_last_good.erase(out_path3)
			continue
		if verdict == FAILED or verdict == FAILED_SAID:
			failed_outputs[out_path3] = true
			if verdict == FAILED:
				unsaid[out_path3] = true
			queue.append(out_path3)
			continue
		if verdict == ALIASED:
			recheck[out_path3] = true
		else:
			unverified_now[out_path3] = verdict
		if int(info3["was"]) != 0 and not _last_good.has(out_path3):
			_last_good[out_path3] = {"prev": info3["prev"], "prev_map": info3["prev_map"],
				"prev_map_existed": info3["prev_map_existed"], "existed": info3["existed"]}
	while not queue.is_empty():
		var bad: String = queue.pop_back()
		for d in dependents.get(bad, []):
			if not failed_outputs.has(d) and _refs(d).has(bad):
				failed_outputs[d] = true
				because[d] = bad
				queue.append(d)

	unverified = {}
	for uv in unverified_now:
		if unverified_now[uv] == UNVERIFIED_DEEP:
			warnings.append(("[GATE] %s nests classes %d deep, and Godot's own parser takes "
				+ "minutes at that depth, so its output was written without being loaded to "
				+ "check it. It is compiled and will load as usual; only GATE's own check was "
				+ "skipped, to keep the editor responsive.")
				% [deferred[uv]["gate"], int(_deep.get(uv, 0))])
		elif unverified_now[uv] == UNVERIFIED_SELF:
			warnings.append(("[GATE] %s refers to its own class_name, which Godot's class "
				+ "list does not have yet, so its output could not be verified yet. It will "
				+ "be checked on the next build.") % deferred[uv]["gate"])
		else:
			warnings.append(("[GATE] %s could not be verified yet: Godot will not load its "
				+ "output now, but that may be because of a class_name this build wrote, "
				+ "directly or through what it loads - Godot resolves a global class name "
				+ "from the editor's class list, which is updated after the file is written. "
				+ "It will be checked on the next build.") % deferred[uv]["gate"])
		unverified[String(deferred[uv]["gate"])] = true
	for rc in recheck:
		unverified[String(deferred[rc]["gate"])] = true

	for out_path in deferred:
		var info: Dictionary = deferred[out_path]
		if not failed_outputs.has(out_path):
			continue
		var back: Dictionary = _last_good.get(out_path, info)
		_last_good.erase(out_path)
		if back["existed"]:
			var rf: FileAccess = FileAccess.open(out_path + ".rejected", FileAccess.WRITE)
			if rf != null:
				rf.store_string(info["source"])
				rf.close()
		var heard: Array = _heard.get(out_path, [])
		if unsaid.has(out_path):
			heard = _say_why(info["source"], out_path + (".rejected" if back["existed"] else ""))
		_godot_said.append(out_path + (".rejected" if back["existed"] else ""))
		if back["existed"]:
			var w: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
			if w != null:
				w.store_string(back["prev"])
				w.close()
			if back.get("prev_map_existed", false):
				var mw: FileAccess = FileAccess.open(out_path + ".map", FileAccess.WRITE)
				if mw != null:
					mw.store_string(back["prev_map"])
					mw.close()
			elif FileAccess.file_exists(out_path + ".map"):
				DirAccess.remove_absolute(
					ProjectSettings.globalize_path(out_path + ".map"))
			_resync(out_path, back["prev"])
			out_hashes[info["gate"]] = String(back["prev"]).md5_text()
		if info["was"] == 1:
			changed -= 1
		else:
			unchanged -= 1
		failed += 1
		var why: String = _users_error(heard, info["source"], _read_text(info["gate"]), info.get("map", []))
		var kept: String = ("the previous %s has been put back, and the output that does not "
			+ "load is saved as %s") % [out_path, out_path + ".rejected"] if back["existed"] \
			else ("%s is left as GATE wrote it, so nothing of yours is lost" % out_path)
		var told: String = ""
		if because.has(out_path):
			told = "[GATE] %s: not updated, because it loads %s, which Godot will not load; %s." \
				% [info["gate"], because[out_path], kept]
		elif why != "":
			told = "[GATE] %s:%s. Godot will not load the script, so %s." \
				% [info["gate"], why.trim_suffix("."), kept]
		else:
			told = ("[GATE] %s: GATE compiled this without errors, but Godot will not load the "
				+ "GDScript it produced, so %s. Godot's own parse error is printed above. This "
				+ "is usually a GATE bug, but check first that any preload() and class_name it "
				+ "names really exist; keep the .gate and the output together if you report it.") \
				% [info["gate"], kept]
		errors.append(told)
		_failed_at[info["gate"]] = info.get("h", "")
		_failed_msg[info["gate"]] = told

	var result: Dictionary = {"changed": changed, "failed": failed, "unchanged": unchanged, "removed": removed}
	if cache_path != "":
		_settle(root, world, result, registry, deferred)
		_save_proof(root, gate_files)
	return result


func _world(root: String) -> Dictionary:
	var gates: Dictionary = {}
	for g in find_gate_files(root):
		gates[g] = FileAccess.get_md5(g)
	var scripts: Dictionary = {}
	var hand: Dictionary = {}
	for gd in GateProject.find_gd_files(root):
		if gates.has(gd.get_basename() + ".gate") or FileAccess.file_exists(gd.get_basename() + ".GATE"):
			scripts[gd] = FileAccess.get_md5(gd)
			if FileAccess.file_exists(gd + ".map"):
				scripts[gd + ".map"] = FileAccess.get_md5(gd + ".map")
		elif not gd.begins_with(root.path_join("addons/gate/")):
			hand[gd] = [FileAccess.get_md5(gd), GateProject.gd_class_name_of(gd)]
	return {"env": _cache_env(root), "indent": "%s|%s" % [indent, _editor_indent()],
		"project": _settings_read(), "classes": _classes_key(), "gate": gates,
		"scripts": scripts, "hand": hand}


func _sum_at_start(path: String) -> String:
	var seen: Dictionary = _world_now.get("scripts", {})
	if seen.has(path):
		return String(seen[path])
	return _file_hash(path)


static func _classes_key() -> String:
	var classes: PackedStringArray = PackedStringArray()
	for c in ProjectSettings.get_global_class_list():
		classes.append("%s=%s" % [c["class"], c["path"]])
	classes.sort()
	return ",".join(classes).md5_text()


static func _settings_read() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for prop in ProjectSettings.get_property_list():
		var key: String = String(prop["name"])
		if key.begins_with("autoload/") or key.begins_with("debug/gdscript/"):
			parts.append("%s=%s" % [key, var_to_str(ProjectSettings.get_setting(key))])
	parts.sort()
	return "\n".join(parts).md5_text()


func _nothing_to_do(world: Dictionary) -> bool:
	if not _same_world(world, _settled_world):
		return false
	_settled_world["hand"] = (world["hand"] as Dictionary).duplicate(true)
	_reached = (_settled_world.get("reached", {}) as Dictionary).duplicate()
	if _globals_seen == "":
		_globals_seen = _globals_fingerprint()
	return true


func _same_world(world: Dictionary, settled: Dictionary) -> bool:
	if settled.is_empty():
		return false
	for part in ["env", "indent", "project", "classes", "gate", "scripts"]:
		if typeof(world.get(part)) != typeof(settled.get(part)) or world[part] != settled[part]:
			return false
	var was: Dictionary = settled.get("hand", {})
	var now: Dictionary = world["hand"]
	if was.size() != now.size():
		return false
	var reached: Dictionary = settled.get("reached", {})
	for gd in now:
		if not was.has(gd):
			return false
		var a: Array = was[gd]
		var b: Array = now[gd]
		if a[0] == b[0]:
			continue
		if a[1] != b[1]:
			return false
		if reached.has(gd) and GateProject.gd_surface(_read_text(gd)) != String(reached[gd]):
			return false
	return true


func _settle(root: String, before: Dictionary, result: Dictionary, registry, deferred: Dictionary) -> void:
	_settled_world = {}
	_settled_replay = {}
	var deep_only: bool = true
	for g in unverified:
		if not _deep.has(String(g).get_basename() + ".gd"):
			deep_only = false
	if before.is_empty() or removed != 0 or not deep_only:
		return
	var after: Dictionary = before.duplicate(true)
	after["indent"] = "%s|%s" % [indent, _editor_indent()]
	after["project"] = _settings_read()
	after["classes"] = _classes_key()
	for part in ["indent", "project", "classes"]:
		if after[part] != before[part]:
			return
	var was: Dictionary = before["scripts"]
	var now: Dictionary = after["scripts"]
	var touched: Array = []
	for o in deferred:
		for f1 in [String(o), String(o) + ".map"]:
			touched.append(f1)
			if FileAccess.file_exists(f1):
				now[f1] = FileAccess.get_md5(f1)
			elif now.has(f1):
				return
	for f in touched:
		if was.get(f, "") == now.get(f, ""):
			continue
		var gd: String = String(f).trim_suffix(".map")
		var gate: String = gd.get_basename() + ".gate"
		var proof: Dictionary = _proof.get(gate, {})
		var h: String = String(hashes.get(gate, ""))
		if proof.is_empty() or h == "" or String(proof["h"]) != h or String(_failed_at.get(gate, "")) == h:
			return
		if String(f).ends_with(".map"):
			if String(proof["map"]) != String(now[f]):
				return
		elif _file_hash(gd) != String(out_hashes.get(gate, "")):
			return
	_settled_world = after
	_settled_world["reached"] = _reached.duplicate()
	var said: Array = Array(warnings)
	for g in after["gate"]:
		for w in (_proof.get(g, {}) as Dictionary).get("warnings", []):
			if not said.has(String(w)):
				said.append(String(w))
	_settled_replay = {"errors": Array(errors), "warnings": said, "result": result.duplicate(),
		"godot": _godot_said.duplicate()}
	_share(registry, after)


func _replay() -> Dictionary:
	for at in _settled_replay.get("godot", []):
		if FileAccess.file_exists(String(at)):
			_say_why(_read_text(String(at)), String(at))
	for e in _settled_replay.get("errors", []):
		errors.append(String(e))
	for w in _settled_replay.get("warnings", []):
		warnings.append(String(w))
	var r: Dictionary = _settled_replay.get("result", {})
	changed = 0
	removed = 0
	failed = int(r.get("failed", 0))
	unchanged = int(r.get("unchanged", 0))
	return {"changed": 0, "failed": failed, "unchanged": unchanged, "removed": 0}


static var _shared_registry: RefCounted = null
static var _shared_world: Dictionary = {}
static var _shared_root: String = ""
static var _sharing: GateBuilder = null


func _share(registry, world: Dictionary) -> void:
	_shared_registry = registry
	_shared_world = world
	_shared_root = "res://"
	_sharing = self


func share_index(root: String) -> void:
	if _settled_world.is_empty() or (_shared_registry != null and _sharing == self):
		return
	if not _same_world(_world(root), _settled_world):
		return
	_share(GateProject.new().index(root), _settled_world)


var _warm_mentions: Array = []
var _warm_mentions_at: int = -1


func warm_mentions(root: String, budget_usec: int) -> bool:
	var until: int = Time.get_ticks_usec() + budget_usec
	if _warm_mentions_at < 0:
		_warm_mentions = find_gate_files(root)
		_warm_mentions_at = 0
	while _warm_mentions_at < _warm_mentions.size() and Time.get_ticks_usec() < until:
		var at: String = _warm_mentions[_warm_mentions_at]
		_warm_mentions_at += 1
		var text: String = _read_text(at)
		var sum: String = text.md5_text()
		var hit: Array = _mentions_memo.get(at, [])
		if hit.is_empty() or String(hit[0]) != sum:
			_mentions_memo[at] = [sum, _mentions(text, at)]
	return _warm_mentions_at >= _warm_mentions.size()


static func current_registry() -> RefCounted:
	if _shared_registry == null or _sharing == null:
		return null
	if not _sharing._same_world(_sharing._world(_shared_root), _shared_world):
		_shared_registry = null
		return null
	return _shared_registry


static func _outside_globals(registry, root: String) -> String:
	var names: PackedStringArray = PackedStringArray()
	for c in ProjectSettings.get_global_class_list():
		var n: String = String(c["class"])
		var at: String = String(c["path"])
		if String(registry.gd_class_names.get(n, "")) == at:
			continue
		if registry.script_class_names.has(n) and String(registry.script_class_names[n]).get_basename() + ".gd" == at:
			continue
		names.append(n + "=" + at)
	for prop in ProjectSettings.get_property_list():
		var key: String = String(prop["name"])
		if key.begins_with("autoload/"):
			names.append(key + "=" + String(ProjectSettings.get_setting(key)))
	names.sort()
	return ",".join(names).md5_text()


func _cache_env(root: String) -> String:
	var info: Dictionary = Engine.get_version_info()
	var parts: PackedStringArray = PackedStringArray([str(CACHE_FORMAT), root,
		String(info.get("string", "")), String(info.get("hash", ""))])
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	var names: PackedStringArray = DirAccess.get_files_at(dir)
	names.sort()
	for n in names:
		if n.get_extension() == "gd":
			parts.append(n + ":" + FileAccess.get_md5(dir.path_join(n)))
	return "|".join(parts).md5_text()


func _load_saved(root: String) -> void:
	_saved = {}
	if not trust_cache or not FileAccess.file_exists(cache_path):
		return
	var data: Variant = _read_json(cache_path)
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	if String(d.get("env", "")) == _cache_env(root) and d.get("files") is Dictionary:
		_saved = (d["files"] as Dictionary).duplicate(true)
		var kept: Variant = d.get("summaries")
		if kept is Dictionary and (kept as Dictionary).get("memo") is Dictionary and (kept as Dictionary).get("texts") is Dictionary:
			_fx_signature = String(kept.get("signature", ""))
			_fx_texts = (kept["texts"] as Dictionary).duplicate()
			_fx_memo = (kept["memo"] as Dictionary).duplicate(true)
			if kept.get("functions") is Dictionary:
				_fx_fn_hash = (kept["functions"] as Dictionary).duplicate(true)
		var refused: Variant = d.get("refused")
		if refused is Dictionary:
			_refused = (refused as Dictionary).duplicate(true)
		var settled: Variant = d.get("settled")
		if settled is Dictionary and (settled as Dictionary).get("world") is Dictionary:
			_settled_world = (settled["world"] as Dictionary).duplicate(true)
			_settled_replay = (settled.get("replay", {}) as Dictionary).duplicate(true)


func _saved_holds(gate_path: String, src: String, h: String, out_path: String, map_path: String) -> bool:
	var entry: Variant = _saved.get(gate_path)
	_saved.erase(gate_path)
	if not (entry is Dictionary):
		return false
	var e: Dictionary = entry
	if (String(e.get("h", "")) != h or String(e.get("src", "")) != src.md5_text()
			or String(e.get("g", "")) != _outside or unverified.has(gate_path)
			or _sum_at_start(out_path) != String(e.get("gd", ""))
			or _sum_at_start(map_path) != String(e.get("map", ""))):
		return false
	var said: PackedStringArray = PackedStringArray()
	if e.get("warnings") is Array:
		for w in e["warnings"]:
			said.append(String(w))
	warnings.append_array(said)
	hashes[gate_path] = h
	out_hashes[gate_path] = String(e.get("gd", ""))
	_proof[gate_path] = {"h": h, "src": String(e["src"]), "g": _outside, "map": String(e["map"]), "gd": String(e.get("gd", "")),
		"warnings": said}
	return true


func _save_proof(root: String, gate_files: Array[String]) -> void:
	var seen: Dictionary = _settled_world.get("scripts", {})
	var files: Dictionary = {}
	for g in gate_files:
		var proof: Dictionary = _proof.get(g, {})
		var h: String = String(hashes.get(g, ""))
		if (proof.is_empty() or h == "" or String(proof["h"]) != h or unverified.has(g)
				or String(_failed_at.get(g, "")) == h):
			continue
		var out_path: String = g.get_basename() + ".gd"
		var map_path: String = out_path + ".map"
		var out_sum: String = String(seen.get(out_path, "")) if seen.has(out_path) else _file_hash(out_path)
		if out_sum == "" or out_sum != String(out_hashes.get(g, "")):
			continue
		var map_sum: String = String(seen.get(map_path, "")) if seen.has(map_path) else _file_hash(map_path)
		if map_sum != String(proof["map"]):
			continue
		files[g] = {"h": h, "src": proof["src"], "g": proof["g"],
			"gd": out_sum,
			"map": map_sum, "warnings": Array(proof["warnings"])}
	var data: Dictionary = {"format": CACHE_FORMAT, "env": _cache_env(root), "files": files}
	if not _settled_world.is_empty():
		data["settled"] = {"world": _settled_world, "replay": _settled_replay}
	if not _fx_memo.is_empty():
		data["summaries"] = {"signature": _fx_signature, "texts": _fx_texts, "memo": _fx_memo, "functions": _fx_fn_hash}
	if not _refused.is_empty():
		data["refused"] = _refused
	var text: String = JSON.stringify(data, "\t", true)
	if text == _saved_text:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache_path.get_base_dir()))
	var f: FileAccess = FileAccess.open(cache_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
	_saved_text = text


func _dependency_keys(gate_files: Array[String], registry, root: String = "res://") -> Dictionary:
	_reached = {}
	var owners: Dictionary = _name_owners(gate_files, registry, root)
	var visible: Dictionary = _visible_parts(gate_files, registry)
	var sums: Dictionary = {}
	var edges: Dictionary = {}
	var todo: Array = gate_files.duplicate()
	while not todo.is_empty():
		var at: String = todo.pop_back()
		if sums.has(at):
			continue
		var text: String = _read_text(at)
		var text_sum: String = text.md5_text()
		if at.get_extension() == "gate":
			sums[at] = String(visible.get(at, ""))
		else:
			sums[at] = GateProject.gd_surface(text)
			_reached[at] = sums[at]
		var hit: Array = _mentions_memo.get(at, [])
		if hit.is_empty() or String(hit[0]) != text_sum:
			hit = [text_sum, _mentions(text, at)]
			_mentions_memo[at] = hit
		var to: Dictionary = {}
		for w in hit[1]:
			for o in owners.get(w, []):
				if o != at:
					to[o] = true
		edges[at] = to
		for o2 in to:
			if not sums.has(o2):
				todo.append(o2)
	var out: Dictionary = {}
	for g in gate_files:
		var seen: Dictionary = {g: true}
		var walk: Array = [g]
		while not walk.is_empty():
			for n in edges.get(walk.pop_back(), {}):
				if not seen.has(n):
					seen[n] = true
					walk.append(n)
		seen.erase(g)
		var parts: PackedStringArray = PackedStringArray()
		for n2 in seen:
			parts.append("%s=%s" % [n2, sums[n2]])
		parts.sort()
		out[g] = ",".join(parts).md5_text()
	return out


func _visible_parts(gate_files: Array[String], registry) -> Dictionary:
	var parts: Dictionary = {}
	for g in gate_files:
		parts[g] = []
	var tables: Array = [registry.classes, registry.structs, registry.namespaces, registry.generics,
		registry.traits, registry.interfaces]
	for table in tables:
		for cname in table:
			var at: String = String(registry.origin.get(cname, ""))
			if parts.has(at):
				_note_visible(parts[at], String(cname), table[cname])
	for cn in registry.script_class_decls:
		var at2: String = String(registry.script_class_names.get(cn, ""))
		if parts.has(at2):
			_note_visible(parts[at2], String(cn), registry.script_class_decls[cn])
	var summaries: Dictionary = _summaries_by_file(gate_files, registry)
	for g3 in summaries:
		if parts.has(g3):
			(parts[g3] as Array).append_array(summaries[g3])
	var out: Dictionary = {}
	for g2 in parts:
		var list: Array = parts[g2]
		list.sort()
		out[g2] = "\n".join(PackedStringArray(list)).md5_text()
	return out


func _summaries_by_file(gate_files: Array[String], registry) -> Dictionary:
	var texts: Dictionary = {}
	for g in gate_files:
		var said: String = GateProject.token_hash(g)
		texts[g] = said if said != "" else FileAccess.get_md5(g)
	var signature: String = String(registry.signature()).md5_text()
	var infer: GateInfer = GateInfer.new()
	infer.build(GateAST._Module.new(), registry)
	if signature == _fx_signature and texts.size() == _fx_texts.size():
		var changed: Dictionary = {}
		var same_files: bool = true
		for g2 in texts:
			if not _fx_texts.has(g2):
				same_files = false
			elif _fx_texts[g2] != texts[g2]:
				changed[g2] = true
		if same_files:
			if changed.is_empty():
				return _fx_memo
			var bodies: Dictionary = _function_hashes(infer, registry, changed)
			var roots: Array = []
			var keys: Dictionary = {}
			var moved: bool = false
			for g5 in changed:
				var was: Dictionary = _fx_fn_hash.get(g5, {})
				var now: Dictionary = bodies.get(g5, {})
				if was.size() != now.size():
					moved = true
				for key in now:
					if not was.has(key) or key == "<overloads>":
						moved = true
					elif was[key] != (now[key] as Array)[0]:
						roots.append((now[key] as Array)[1])
						keys[key] = true
			if not moved:
				var same: bool = true
				if not roots.is_empty():
					var partial: Dictionary = _summary_texts(infer, infer.summarise(roots), registry, changed)
					for g3 in changed:
						var had: Dictionary = _by_key(_fx_memo.get(g3, []))
						var got: Dictionary = _by_key(partial.get(g3, []))
						for key2 in keys:
							if had.get(key2, "") != got.get(key2, "<none>"):
								same = false
				if same:
					_fx_texts = texts
					for g6 in changed:
						_fx_fn_hash[g6] = _hash_only(bodies.get(g6, {}))
					return _fx_memo
			infer = GateInfer.new()
			infer.build(GateAST._Module.new(), registry)
	var every: Dictionary = {}
	for g4 in gate_files:
		every[g4] = true
	_fx_memo = _summary_texts(infer, infer.summarise_all(), registry, every)
	_fx_texts = texts
	_fx_signature = signature
	_fx_fn_hash = {}
	var all_bodies: Dictionary = _function_hashes(infer, registry, every)
	for g7 in all_bodies:
		_fx_fn_hash[g7] = _hash_only(all_bodies[g7])
	return _fx_memo


func _function_hashes(infer: GateInfer, registry, files: Dictionary) -> Dictionary:
	var starts: Dictionary = {}
	var out_overloaded: Dictionary = {}
	for k in infer.methods:
		var cls: String = String(k).substr(0, String(k).rfind("."))
		var at: String = String(registry.origin.get(cls, registry.script_class_names.get(cls, "")))
		if not files.has(at):
			continue
		var fns: Array = infer.methods[k]
		if fns.size() > 1:
			out_overloaded[at] = true
		for i in fns.size():
			if not starts.has(at):
				starts[at] = []
			(starts[at] as Array).append([int((fns[i] as GateAST._FuncDecl).line), "%s#%d" % [k, i], fns[i]])
	var out: Dictionary = {}
	for at2 in starts:
		var list: Array = starts[at2]
		list.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
		var lexed: Array = GateProject._lexed_memo.get(at2, [])
		var tokens: Array = lexed[1] if lexed.size() > 1 else []
		var parts: Array = []
		for _i in list.size():
			parts.append([])
		var j: int = -1
		for t in tokens:
			var tk: GateLexer._Token = t
			while j + 1 < list.size() and tk.line >= int(list[j + 1][0]):
				j += 1
			if j < 0 or tk.type == GateLexer._T.COMMENT or tk.type == GateLexer._T.NEWLINE:
				continue
			(parts[j] as Array).append("%d|%s|%s" % [tk.type, tk.value, tk.extra])
		var fns2: Dictionary = {}
		for n in list.size():
			fns2[String(list[n][1])] = ["~".join(PackedStringArray(parts[n])).md5_text(), list[n][2]]
		if out_overloaded.has(at2):
			fns2["<overloads>"] = [str(Time.get_ticks_usec()), null]
		out[at2] = fns2
	return out


static func _hash_only(bodies: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in bodies:
		out[key] = String((bodies[key] as Array)[0])
	return out


static func _by_key(texts: Array) -> Dictionary:
	var out: Dictionary = {}
	for t in texts:
		var line: String = String(t)
		out[line.get_slice("|", 1)] = line
	return out


static func _summary_texts(infer: GateInfer, fx: Dictionary, registry, files: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var seq: Dictionary = {}
	for f in fx:
		var cls: String = String(infer._fx_owner.get(f, ""))
		var at: String = String(registry.origin.get(cls, registry.script_class_names.get(cls, "")))
		if not files.has(at):
			continue
		var key: String = "%s.%s" % [cls, (f as GateAST._FuncDecl).name]
		seq[key] = int(seq.get(key, -1)) + 1
		var e: GateInfer._Effects = fx[f]
		var params: Array = e.param_paths.keys()
		params.sort()
		var by_param: PackedStringArray = PackedStringArray()
		for i in params:
			var sfx: Array = (e.param_paths[i] as Array).duplicate()
			sfx.sort()
			by_param.append("%d=%s" % [i, str(sfx)])
		var own: Array = e.self_paths.duplicate()
		own.sort()
		var st: Array = e.statics.duplicate()
		st.sort()
		if not out.has(at):
			out[at] = []
		(out[at] as Array).append("fx|%s#%d|%s|%s|%s|%s|%s" % [key, seq[key], str(own),
			",".join(by_param), str(st), str(e.returns), e.opaque])
	for at2 in out:
		(out[at2] as Array).sort()
	return out


static func _note_visible(into: Array, cname: String, cd: GateAST._ClassDecl) -> void:
	for m in cd.members:
		if m is GateAST._VarDecl and cd.form == "struct":
			into.append("default|%s.%s|%s" % [cname, (m as GateAST._VarDecl).name, _shape((m as GateAST._VarDecl).value)])
		elif m is GateAST._SignalDecl:
			into.append("signal|%s.%s|%s" % [cname, (m as GateAST._SignalDecl).name, _shape((m as GateAST._SignalDecl).params)])


static func _shape(v: Variant, depth: int = 0) -> String:
	if depth > 48:
		return "..."
	if v is Array:
		var items: PackedStringArray = PackedStringArray()
		for x in v:
			items.append(_shape(x, depth + 1))
		return "[" + ",".join(items) + "]"
	if v is Dictionary:
		var keys: Array = (v as Dictionary).keys()
		keys.sort()
		var pairs: PackedStringArray = PackedStringArray()
		for k in keys:
			pairs.append("%s:%s" % [str(k), _shape(v[k], depth + 1)])
		return "{" + ",".join(pairs) + "}"
	if v is Object:
		var o: Object = v
		var fields: PackedStringArray = PackedStringArray()
		for prop in o.get_property_list():
			var pn: String = String(prop["name"])
			if (int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0 or pn in ["line", "col"] \
					or pn.ends_with("_line") or pn.ends_with("_col"):
				continue
			fields.append("%s=%s" % [pn, _shape(o.get(pn), depth + 1)])
		return "(" + ",".join(fields) + ")"
	return var_to_str(v)


func _name_owners(gate_files: Array[String], registry, root: String = "res://") -> Dictionary:
	var owners: Dictionary = {}
	for g in gate_files:
		_own(owners, g, g)
		_own(owners, g.get_basename() + ".gd", g)
	for n in registry.origin:
		_own(owners, String(n), String(registry.origin[n]))
	for n2 in registry.declared_in:
		for at in registry.declared_in[n2]:
			_own(owners, String(n2), String(at))
	for n3 in registry.script_class_names:
		_own(owners, String(n3), String(registry.script_class_names[n3]))
	for n4 in registry.alias_files:
		for at2 in registry.alias_files[n4]:
			_own(owners, String(n4), String(at2))
	for k in registry.kind_files:
		for at3 in registry.kind_files[k]:
			_own(owners, String(k).get_slice("|", 1), String(at3))
	for n5 in registry.gd_class_names:
		var gd: String = String(registry.gd_class_names[n5])
		if gate_files.has(gd.get_basename() + ".gate"):
			continue   # an output: its .gate stands for it, and the output's text changes on every body edit
		_own(owners, String(n5), gd)
		_own(owners, gd, gd)
	for gd2 in GateProject.find_gd_files(root):
		if not gate_files.has(gd2.get_basename() + ".gate"):
			_own(owners, gd2, gd2)
	for prop in ProjectSettings.get_property_list():
		var key: String = String(prop["name"])
		if not key.begins_with("autoload/"):
			continue
		var target: String = _resolve_ref(String(ProjectSettings.get_setting(key)).trim_prefix("*"), "res://")
		if target == "":
			continue
		var gate: String = target.get_basename() + ".gate"
		_own(owners, key.substr(9), gate if gate_files.has(gate) else target)
	return owners


static func _own(owners: Dictionary, word: String, path: String) -> void:
	if not owners.has(word):
		owners[word] = []
	if not (owners[word] as Array).has(path):
		(owners[word] as Array).append(path)


func _mentions(text: String, from: String) -> Array:
	var seen: Dictionary = {}
	var lexed: Array = GateProject._lexed_memo.get(from, []) if from.get_extension() == "gate" else []
	if lexed.size() > 1 and String(lexed[0]) == text.md5_text():
		for t in lexed[1]:
			var tk: GateLexer._Token = t
			match tk.type:
				GateLexer._T.IDENT, GateLexer._T.KEYWORD:
					seen[tk.value] = true
				GateLexer._T.FSTRING:
					for m0 in _word_re.search_all(tk.value):
						seen[m0.get_string()] = true
				GateLexer._T.STRING:
					var r0: String = _resolve_ref(tk.value, from) if tk.value.get_extension().to_lower() in ["gd", "gate", "tscn", "scn", "tres", "res"] else ""
					if r0 != "":
						seen[r0] = true
		return seen.keys()
	for m in _word_re.search_all(text):
		seen[m.get_string()] = true
	for m2 in _path_re.search_all(text):
		var r: String = _resolve_ref(m2.get_string(1), from)
		if r != "":
			seen[r] = true
	return seen.keys()


static func _globals_fingerprint() -> String:
	var names: PackedStringArray = PackedStringArray()
	for c in ProjectSettings.get_global_class_list():
		names.append(String(c["class"]))
	for prop in ProjectSettings.get_property_list():
		if String(prop["name"]).begins_with("autoload/"):
			names.append(String(prop["name"]))
	names.sort()
	return ",".join(names)


static func _shadowing_globals(registry) -> String:
	var out: PackedStringArray = PackedStringArray()
	for c in ProjectSettings.get_global_class_list():
		var n: String = String(c["class"])
		if registry.top_level.has(n) or registry.aliases.has(n):
			out.append(n)
	out.sort()
	return ",".join(out)


func compile_file(gate_path: String, registry = null, deferred = null, reg_sig: String = "") -> int:
	var f: FileAccess = FileAccess.open(gate_path, FileAccess.READ)
	if f == null:
		errors.append("[GATE] cannot read %s" % gate_path)
		return -1
	var src: String = f.get_as_text()
	f.close()
	var out_path: String = gate_path.get_basename() + ".gd"
	var map_path: String = out_path + ".map"
	var chain: String = String(registry.gd_chain.get(gate_path, "")) if registry != null else ""
	var unit: String = _indent_for(src)
	var h: String = "%d:%d:%s:%s:%s%d:%s" % [src.hash(), src.length(), reg_sig, chain,
		"t" if unit.begins_with(TAB) else "s", unit.length(), String(_dep_keys.get(gate_path, ""))]
	if hashes.get(gate_path) == h and not unverified.has(gate_path) and _failed_at.get(gate_path, "") != h:
		var seen: Dictionary = _world_now.get("scripts", {})
		var proof: Dictionary = _proof.get(gate_path, {})
		if seen.has(out_path) and seen.has(map_path) and String(proof.get("h", "")) == h:
			if String(seen[out_path]) == String(proof.get("gd", "")) and String(seen[map_path]) == String(proof.get("map", "")):
				return 0
		elif (FileAccess.file_exists(out_path) and FileAccess.file_exists(map_path)
				and _file_hash(out_path) == out_hashes.get(gate_path)):
			return 0
	if not GateProject.is_utf8(gate_path):
		errors.append(("[GATE] %s is not valid UTF-8, so it was not compiled: Godot reads "
			+ "scripts as UTF-8 and would refuse the output too. Save the file as UTF-8 "
			+ "(a byte order mark is fine).") % gate_path)
		return -1

	# Never write over a file GATE did not generate. The banner is the only marker.
	if FileAccess.file_exists(out_path) and not _is_generated(out_path, gate_path):
		var named: String = _banner_of(out_path)
		if named != "":
			errors.append(("[GATE] %s would overwrite %s, which is %s's output: its first line "
				+ "names that file, so this looks like a copy of it, from a duplicated folder "
				+ "or a copied file. Delete %s and GATE will write this file's own output.")
				% [gate_path, out_path, named, out_path])
		elif _was_ours(out_path, gate_path):
			_warn_once("header gone " + out_path, ("[GATE] the GATE header is gone from %s, so "
				+ "it is yours now and GATE leaves it alone. Delete %s when you are done; "
				+ "until then its output is not updated.") % [out_path, gate_path])
			return 0
		else:
			errors.append(("[GATE] %s would overwrite %s, which was not generated by GATE. "
				+ "Rename the .gate file, or move the existing .gd out of the way - "
				+ "GATE will not replace a file it did not write.") % [gate_path, out_path])
		return -1
	var adopted: String = _adopted_banner(out_path, gate_path)
	if adopted != "":
		warnings.append(("[GATE] %s carries a GATE banner naming %s, which no longer "
			+ "exists, so it is being treated as this file's output and overwritten. If "
			+ "you meant to keep it as hand-written GDScript, delete the banner from it.")
			% [out_path, adopted])

	if _failed_at.get(gate_path, "") == h:
		_skipped_now.append(gate_path)
		return RESULT_SETTLED
	var refused: Array = _refused.get(gate_path, [])
	if not refused.is_empty() and String(refused[0]) == h + _globals_seen:
		for e in refused[1]:
			errors.append(String(e))
		return -1
	if (hashes.get(gate_path) == h and not unverified.has(gate_path)
			and FileAccess.file_exists(out_path)
				and FileAccess.file_exists(map_path)
				and _file_hash(out_path) == out_hashes.get(gate_path)):
		return 0
	if _saved.has(gate_path) and _saved_holds(gate_path, src, h, out_path, map_path):
		return 0

	compiled_log.append(gate_path)
	var compiler: GateCompiler = GateCompiler.new()
	compiler.indent = unit
	var res: GateCompiler._Result = compiler.compile(src, gate_path, registry)

	if not res.ok:
		var told: PackedStringArray = PackedStringArray()
		for d in res.diagnostics.items:
			if d.level == GateDiagnostics._Level.ERROR:
				told.append("[GATE] " + d.format())
		told.append("[GATE] %s: %d error(s); %s not updated"
			% [gate_path, res.diagnostics.error_count(), out_path])
		errors.append_array(told)
		_refused[gate_path] = [h + _globals_seen, told]
		return -1

	_refused.erase(gate_path)
	var said: PackedStringArray = PackedStringArray()
	for d in res.diagnostics.items:
		if d.level == GateDiagnostics._Level.WARNING:
			said.append("[GATE] " + d.format())
	warnings.append_array(said)

	if deferred == null and not output_parses(res.source, out_path):
		var rej: String = out_path + ".rejected"
		var rf: FileAccess = FileAccess.open(rej, FileAccess.WRITE)
		if rf != null:
			rf.store_string(res.source)
			rf.close()
		_say_why(res.source, rej)
		errors.append(("[GATE] %s: GATE compiled this without errors, but Godot will not "
			+ "load the GDScript it produced, so %s was left as it was. The rejected "
			+ "output is saved as %s - Godot's own parse error is printed above this "
			+ "message and its line number refers to that file. This is a GATE bug; "
			+ "keep the .gate and .rejected files together if you report it.")
			% [gate_path, out_path, rej])
		return RESULT_UNLINKED

	hashes[gate_path] = h
	out_hashes[gate_path] = res.source.md5_text()
	_proof[gate_path] = {"h": h, "src": src.md5_text(), "g": _outside, "map": "", "warnings": said}

	var had_output: bool = FileAccess.file_exists(out_path)
	var prev_text: String = ""
	if had_output:
		var prev: FileAccess = FileAccess.open(out_path, FileAccess.READ)
		if prev == null:
			errors.append("[GATE] cannot read the existing %s; %s not updated"
				% [out_path, gate_path])
			hashes.erase(gate_path)
			return -1
		if prev != null:
			var existing: String = prev.get_as_text()
			prev_text = existing
			prev.close()
			if existing == res.source or _same_but_indent(existing, res.source):
				if existing != res.source:
					out_hashes[gate_path] = existing.md5_text()
				if not _map_matches(map_path, gate_path, res.map, existing, src):
					_write_map(out_path, gate_path, res.map, existing, src)
				_proof[gate_path]["map"] = FileAccess.get_md5(map_path)
				_proof[gate_path]["gd"] = FileAccess.get_md5(out_path)
				_clear_rejected(out_path)
				if deferred != null:
					deferred[out_path] = {
						"gate": gate_path, "source": existing, "deps": res.deps,
						"prev": existing, "prev_map": _read_text(map_path),
						"prev_map_existed": FileAccess.file_exists(map_path), "map": res.map, "h": h,
						"existed": true, "was": 0,
					}
				return 0

	var o: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	if o == null:
		errors.append("[GATE] cannot write %s" % out_path)
		hashes.erase(gate_path)
		return -1
	if deferred != null:
		deferred[out_path] = {
			"gate": gate_path, "source": res.source, "deps": res.deps,
			"prev": prev_text, "prev_map": _read_text(map_path),
			"prev_map_existed": FileAccess.file_exists(map_path), "map": res.map, "h": h,
			"existed": had_output, "was": 1,
		}
	o.store_string(res.source)
	o.close()
	_wrote_session[out_path] = true
	_write_map(out_path, gate_path, res.map, res.source, src)
	_proof[gate_path]["map"] = FileAccess.get_md5(map_path)
	_proof[gate_path]["gd"] = FileAccess.get_md5(out_path)
	_clear_rejected(out_path)
	return 1


static func _same_but_indent(disk: String, ours: String) -> bool:
	var a: PackedStringArray = disk.split("\n")
	var b: PackedStringArray = ours.split("\n")
	if a.size() != b.size():
		return false
	var in_string: Dictionary = GateCompiler.lines_inside_strings(ours)
	var width: int = 0
	for i in a.size():
		var mine: String = b[i]
		var theirs: String = a[i]
		if mine.ends_with("\\"):
			return false
		if theirs == mine:
			continue
		if in_string.has(i):
			return false
		var tabs: int = 0
		while tabs < mine.length() and mine[tabs] == "\t":
			tabs += 1
		var body: String = mine.substr(tabs)
		if body.strip_edges() == "" and theirs.strip_edges() == "":
			continue
		if body.begins_with(" ") or not theirs.ends_with(body):
			return false
		var lead: String = theirs.substr(0, theirs.length() - body.length())
		if tabs == 0 or lead == "":
			return false
		if lead == " ".repeat(lead.length()):
			if lead.length() % tabs != 0 or (width != 0 and lead.length() / tabs != width):
				return false
			width = lead.length() / tabs
		elif lead != "\t".repeat(tabs):
			return false
	return true


static func _uses_extern(out_text: String, name: String, decl_gates: Array) -> bool:
	var targets: Dictionary = {}
	for g in decl_gates:
		targets[String(g).get_basename() + ".gd"] = true
	var code: String = _code_only(out_text)
	var consts: RegEx = RegEx.create_from_string("(?m)^const (\\w+) = preload\\(\"([^\"]+)\"\\)")
	for m in consts.search_all(out_text):
		if targets.has(m.get_string(2)) and RegEx.create_from_string(
				"\\b" + m.get_string(1) + "\\." + name + "\\b").search(code) != null:
			return true
	return false


func _remove_orphans(root: String) -> void:
	_orphans_in(root, root)


func _orphans_in(dir: String, root: String) -> void:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		var p: String = dir.path_join(n)
		if d.current_is_dir():
			if GateProject.walks_into(d, n, p):
				_orphans_in(p, root)
		elif n.get_extension().to_lower() == "gd" and not d.is_link(p):
			var gate: String = _banner_of(p)
			if (gate != "" and same_path(gate.get_basename() + ".gd", p)
					and not FileAccess.file_exists(gate)):
				if _as_written(p) and _inside(p, root) and _trash(p):
					removed += 1
					removed_paths.append(p)
					warnings.append(("[GATE] moved %s to the trash, with its map and .uid: it was "
						+ "generated from %s, which is gone, and was unchanged since.") % [p, gate])
				else:
					_warn_once("orphan " + p, ("[GATE] %s was generated from %s, which is gone; "
						+ "delete it if you no longer need it.") % [p, gate])
		n = d.get_next()
	d.list_dir_end()


static func _was_ours(out_path: String, gate_path: String) -> bool:
	var m: Variant = _read_json(out_path + ".map")
	return (m is Dictionary and same_path(String((m as Dictionary).get("generated", "")), out_path)
		and same_path(String((m as Dictionary).get("source", "")), gate_path))


static func _banner_of(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var first: String = f.get_line()
	f.close()
	return _banner_source(first) if first.begins_with(GateEmitter.HEADER_MARKER) else ""


static func _as_written(gd: String) -> bool:
	var m: Variant = _read_json(gd + ".map")
	if not (m is Dictionary):
		return false
	var want: String = String(m.get("gd_sha256", ""))
	return (want != "" and same_path(String(m.get("generated", "")), gd)
		and FileAccess.get_sha256(gd) == want)


static func _inside(path: String, root: String) -> bool:
	var p: String = ProjectSettings.globalize_path(path).simplify_path()
	var r: String = ProjectSettings.globalize_path(root).simplify_path().trim_suffix("/") + "/"
	return p.to_lower().begins_with(r.to_lower()) if _windows() else p.begins_with(r)


static func _trash(gd: String) -> bool:
	if OS.move_to_trash(ProjectSettings.globalize_path(gd)) != OK:
		return false
	for extra in [gd + ".map", gd + ".uid"]:
		if FileAccess.file_exists(extra):
			OS.move_to_trash(ProjectSettings.globalize_path(extra))
	return true


static func _windows() -> bool:
	return OS.get_name() == "Windows"


static func same_path(a: String, b: String) -> bool:
	return a.to_lower() == b.to_lower() if _windows() else a == b


static func _write_map(out_path: String, gate_path: String, lines: Array[int], gd_text: String,
		gate_text: String) -> void:
	var f: FileAccess = FileAccess.open(out_path + ".map", FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"version": 1,
		"source": gate_path,
		"generated": out_path,
		"lines": lines,
		"source_sha256": gate_text.sha256_text(),
		"gd_sha256": gd_text.sha256_text(),
	}))
	f.close()


static func _map_matches(map_path: String, gate_path: String, lines: Array[int], gd_text: String,
		gate_text: String) -> bool:
	if not FileAccess.file_exists(map_path):
		return false
	var m: Variant = _read_json(map_path)
	if not (m is Dictionary) or String(m.get("source", "")) != gate_path:
		return false
	if (String(m.get("gd_sha256", "")) != gd_text.sha256_text()
			or String(m.get("source_sha256", "")) != gate_text.sha256_text()
			or String(m.get("generated", "")) != map_path.trim_suffix(".map")):
		return false
	var have: Variant = m.get("lines")
	if not (have is Array) or (have as Array).size() != lines.size():
		return false
	for i in lines.size():
		if int(have[i]) != lines[i]:
			return false
	return true


static func _resolve_dep(dep: String, from_out: String) -> String:
	if dep.begins_with("res://"):
		return dep.simplify_path()
	if dep.begins_with("uid://") or dep.begins_with("user://"):
		return ""
	return from_out.get_base_dir().path_join(dep).simplify_path()


static var _code_memo: Dictionary = {}
static var _words_memo: Dictionary = {}


static func _code_of(path: String) -> String:
	var text: String = _read_text(path)
	var key: String = "%d:%d" % [text.hash(), text.length()]
	var kept: Array = _code_memo.get(path, [])
	if kept.is_empty() or String(kept[0]) != key:
		kept = [key, _code_only(text)]
		_code_memo[path] = kept
	return kept[1]


static func _code_only(source: String) -> String:
	var out: PackedStringArray = PackedStringArray()
	var i: int = 0
	var n: int = source.length()
	while i < n:
		var hit: RegExMatch = _code_stop_re.search(source, i)
		var k: int = hit.get_start() if hit != null else n
		if k > i:
			out.append(source.substr(i, k - i))
		if k >= n:
			break
		var ch: String = source[k]
		if ch == "#":
			var eol: int = source.find("\n", k)
			if eol < 0:
				eol = n
			out.append(" ".repeat(eol - k))
			i = eol
			continue
		var quote: String = ch
		if source.substr(k, 3) == ch.repeat(3):
			quote = ch.repeat(3)
		out.append(" ".repeat(quote.length()))
		i = k + quote.length()
		while i < n:
			var at: int = -1
			var escape: bool = false
			if quote.length() == 1:
				var stop: RegExMatch = (_in_double_re if quote == '"' else _in_single_re).search(source, i)
				if stop != null:
					at = stop.get_start()
					escape = source[at] == "\\"
			else:
				at = source.find(quote, i)
			if at < 0:
				out.append(_blank_re.sub(source.substr(i), " ", true))
				i = n
				break
			if at > i:
				out.append(_blank_re.sub(source.substr(i, at - i), " ", true))
			if escape:
				out.append("  ")
				i = at + 2
				continue
			out.append(" ".repeat(quote.length()))
			i = at + quote.length()
			break
	return "".join(out)


static var _code_stop_re: RegEx = RegEx.create_from_string("[#\"']")
static var _in_double_re: RegEx = RegEx.create_from_string("[\\\\\"]")
static var _in_single_re: RegEx = RegEx.create_from_string("[\\\\']")
static var _blank_re: RegEx = RegEx.create_from_string("[^\n]")


static func _unregistered(declared_here: Dictionary) -> Dictionary:
	var known: Dictionary = {}
	for c in ProjectSettings.get_global_class_list():
		known[String(c["class"])] = String(c["path"])
	var out: Dictionary = {}
	for n in declared_here:
		if known.get(n, "") != declared_here[n]:
			out[n] = declared_here[n]
	return out


## A probe that fails only because of a class this build has not registered yet
## leaves the file written and warned, never withheld. A probe can only upgrade it.
##
func _validate(source: String, out_path: String, declared_here: Dictionary,
		pending: Dictionary, deferred: Dictionary) -> int:
	var deep: int = _class_depth(source)
	if deep >= DEEP_CLASSES:
		_deep[out_path] = deep
		return UNVERIFIED_DEEP
	if _probe(source, out_path):
		return VERIFIED
	if _in_cycle(out_path):
		# a probe under another path loads its own copy of the class, while the cycle
		# comes back to the file on disk: two scripts for one class. Check it in place.
		return _check_registered(out_path, source)
	var own: String = _own_class_name(source)
	var self_named: bool = own != "" and _names_itself(source, own)
	if _settled(out_path, pending):
		if _autoloads.has(out_path):
			return _check_registered(out_path, source)
		if own == "":
			return FAILED
		if pending.has(own):
			return UNVERIFIED_SELF if self_named or _named_by_what_it_loads(out_path) else FAILED
		if declared_here.get(own, "") == out_path:
			return _check_registered(out_path, source)
	var aliased: String = _with_aliases(source, out_path, pending)
	if aliased != source and _probe(aliased, out_path):
		return ALIASED
	return UNVERIFIED_SELF if own != "" and pending.has(own) and self_named else UNVERIFIED_OTHER


## Whether the scripts this output preloads, followed through what those preload, come
## back to it. Only paths count: a global class_name resolves through the editor's
## class list, and a name that is not registered yet has its own verdict.
func _in_cycle(out_path: String) -> bool:
	var seen: Dictionary = {}
	var todo: Array = _preloads(out_path)
	while not todo.is_empty():
		var p: String = String(todo.pop_back())
		if p == out_path:
			return true
		if seen.has(p):
			continue
		seen[p] = true
		todo.append_array(_preloads(p))
	return false


func _preloads(path: String) -> Array:
	var out: Array = []
	if path.get_extension().to_lower() != "gd":
		return out
	var text: String = String(_deferred[path]["source"]) if _deferred.has(path) else _read_text(path)
	for m in _path_re.search_all(text):
		var r: String = _resolve_ref(m.get_string(1), path)
		if r != "":
			out.append(r)
	return out


func _check_registered(out_path: String, source: String) -> int:
	var printing: bool = Engine.print_error_messages
	Engine.print_error_messages = false
	var s: GDScript = load(out_path) as GDScript
	Engine.print_error_messages = printing
	if s == null:
		return UNVERIFIED_OTHER
	if s.source_code != source:
		s.source_code = source
	var listen: _Heard = _Heard.new()
	listen.path = out_path
	OS.add_logger(listen)
	var ok: bool = s.reload(true) == OK
	OS.remove_logger(listen)
	if ok:
		return VERIFIED
	_heard[out_path] = listen.heard
	return FAILED_SAID


var _refreshed: Dictionary = {}


func _refresh_handwritten(from: String) -> void:
	var seen: Dictionary = {from: true}
	var todo: Array = [from]
	while not todo.is_empty():
		for r in _refs(todo.pop_back()):
			var p: String = String(r)
			if seen.has(p) or p.begins_with("res://addons/"):
				continue
			seen[p] = true
			todo.append(p)
			if (_refreshed.has(p) or p.get_extension().to_lower() != "gd" or _deferred.has(p)
					or FileAccess.file_exists(p.get_basename() + ".gate")
					or FileAccess.file_exists(p.get_basename() + ".GATE")):
				continue
			_refreshed[p] = true
			if ResourceLoader.has_cached(p) and not _open_in_editor(p):
				_resync(p, _read_text(p))


static func _open_in_editor(path: String) -> bool:
	if not Engine.has_singleton("EditorInterface"):
		return false
	var se: Object = Engine.get_singleton("EditorInterface").call("get_script_editor")
	if se == null:
		return false
	for s in se.call("get_open_scripts"):
		if s is Script and (s as Script).resource_path == path:
			return true
	return false


static func _resync(out_path: String, text: String) -> void:
	if not ResourceLoader.has_cached(out_path):
		return
	var s: GDScript = ResourceLoader.get_cached_ref(out_path) as GDScript
	if s == null or s.source_code == text:
		return
	var printing: bool = Engine.print_error_messages
	Engine.print_error_messages = false
	s.source_code = text
	s.reload(true)
	Engine.print_error_messages = printing


static func _class_depth(source: String) -> int:
	var open_at: Array = []
	var most: int = 0
	for line in _code_only(source).split("\n"):
		var text: String = String(line)
		var indent: int = 0
		while indent < text.length() and (text[indent] == "\t" or text[indent] == " "):
			indent += 1
		if not text.substr(indent).begins_with("class "):
			continue
		while not open_at.is_empty() and int(open_at[open_at.size() - 1]) >= indent:
			open_at.pop_back()
		open_at.append(indent)
		most = maxi(most, open_at.size())
	return most


static func _own_class_name(source: String) -> String:
	for line in _code_only(source).split("\n"):
		if String(line).begins_with("class_name "):
			return String(line).substr(11).strip_edges().split(" ")[0]
	return ""


static func _names_itself(source: String, own: String) -> bool:
	var code: String = _code_only(source)
	var at: int = code.find("class_name " + own)
	if at >= 0:
		code = code.substr(0, at) + code.substr(at + 11 + own.length())
	return _uses_word(code, own)


func _settled(self_out: String, pending: Dictionary) -> bool:
	for name in pending:
		var target: String = pending[name]
		if target != self_out and FileAccess.file_exists(target):
			return false
	return not _reaches(self_out)


var _rewritten: Dictionary = {}   ## outputs this build wrote
var _wrote_session: Dictionary = {}  ## outputs this builder wrote at all
var _autoloads: Dictionary = {}   ## script paths the project autoloads
var _shaky: Dictionary = {}       ## autoload scripts written since the editor started
var _deferred: Dictionary = {}
var _names: Dictionary = {}       ## a global name -> the script it resolves to
var _refs_memo: Dictionary = {}
var _word_re: RegEx = RegEx.create_from_string("[A-Za-z_][A-Za-z_0-9]*")
var _path_re: RegEx = RegEx.create_from_string(
	"[\"']([^\"'\\n]+\\.(?:gd|tscn|scn|tres|res))[\"']")


func _nothing_godot_sees_moved(deferred: Dictionary, pending: Dictionary, globals_moved: bool,
		reached_before: Dictionary) -> bool:
	if globals_moved or not pending.is_empty() or reached_before != _reached:
		return false
	for o in deferred:
		var info: Dictionary = deferred[o]
		if int(info["was"]) == 0:
			continue
		if not bool(info["existed"]):
			return false
		if GateProject.gd_surface(String(info["prev"])) != GateProject.gd_surface(String(info["source"])):
			return false
	return true


func _start_reach(deferred: Dictionary, declared_here: Dictionary, pending: Dictionary = {}) -> void:
	_deferred = deferred
	_refs_memo = {}
	_rewritten = {}
	for p in deferred:
		if int(deferred[p]["was"]) == 0:
			continue
		var own: String = _own_class_name(String(deferred[p]["source"]))
		if own != "" and pending.has(own):
			_rewritten[p] = true
		else:
			_resync(p, String(deferred[p]["source"]))
	_names = {}
	_autoloads = {}
	for c in ProjectSettings.get_global_class_list():
		_names[String(c["class"])] = String(c["path"])
	for prop in ProjectSettings.get_property_list():
		var key: String = String(prop["name"])
		if key.begins_with("autoload/"):
			var target: String = _resolve_ref(String(ProjectSettings.get_setting(key)).trim_prefix("*"), "res://")
			_names[key.substr(9)] = target
			if target != "":
				_autoloads[target] = true
	_shaky = {}
	for a in _autoloads:
		if _wrote_session.has(a):
			_shaky[a] = true
	for n in declared_here:
		_names[n] = declared_here[n]


func _reaches(from: String) -> bool:
	if _shaky.is_empty() and (_rewritten.is_empty() or (_rewritten.size() == 1 and _rewritten.has(from))):
		return false
	var seen: Dictionary = {from: true}
	var todo: Array = [from]
	while not todo.is_empty():
		for r in _refs(todo.pop_back()):
			if seen.has(r):
				continue
			if _rewritten.has(r) or _shaky.has(r):
				return true
			seen[r] = true
			todo.append(r)
	return false


func _named_by_what_it_loads(from: String) -> bool:
	var seen: Dictionary = {from: true}
	var todo: Array = [from]
	while not todo.is_empty():
		var at: String = todo.pop_back()
		for r in _refs(at):
			if r == from and at != from:
				return true
			if not seen.has(r):
				seen[r] = true
				todo.append(r)
	return false


func _refs(path: String) -> Array:
	if _refs_memo.has(path):
		return _refs_memo[path]
	var out: Array = []
	_refs_memo[path] = out
	var text: String = String(_deferred[path]["source"]) if _deferred.has(path) else _read_text(path)
	var ext: String = path.get_extension().to_lower()
	var key: String = "%d:%d" % [text.hash(), text.length()]
	var kept: Array = _words_memo.get(path, [])
	if kept.is_empty() or String(kept[0]) != key:
		var words: Array = []
		if ext == "gd":
			var seen_words: Dictionary = {}
			for m in _word_re.search_all(_code_only(text)):
				seen_words[m.get_string()] = true
			words = seen_words.keys()
		var paths: Array = []
		if ext in ["gd", "tscn", "tres"]:
			for m2 in _path_re.search_all(text):
				paths.append(m2.get_string(1))
		kept = [key, words, paths]
		_words_memo[path] = kept
	for w in kept[1]:
		if _names.has(w):
			out.append(_names[w])
	for ref in kept[2]:
		var r: String = _resolve_ref(String(ref), path)
		if r != "":
			out.append(r)
	return out


static func _resolve_ref(ref: String, from: String) -> String:
	if ref.begins_with("uid://"):
		var id: int = ResourceUID.text_to_id(ref)
		return ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
	return _resolve_dep(ref, from)


func _probe(source: String, out_path: String) -> bool:
	probed += 1
	var probe: GDScript = GDScript.new()
	if out_path != "":
		# `path_join`, not "%s/%s": at the project root `get_base_dir()` is already
		# "res://", and "res:///x.gd" is a path Godot cannot resolve a script by.
		probe.resource_path = _free_probe_path(out_path.get_base_dir())
	probe.source_code = _renamed(source)["source"]
	var printing: bool = Engine.print_error_messages
	Engine.print_error_messages = false
	var ok: bool = probe.reload() == OK
	Engine.print_error_messages = printing
	probe.resource_path = ""
	return ok


static func _free_probe_path(dir: String) -> String:
	var p: String = dir.path_join(_probe_name())
	while ResourceLoader.has_cached(p) or FileAccess.file_exists(p):
		p = dir.path_join(_probe_name())
	return p


static func _probe_name() -> String:
	if _probe_stem < 0:
		_probe_stem = absi(int(Time.get_unix_time_from_system() * 1000.0)) % BASE36_5
	_probe_seq += 1
	var v: int = (_probe_stem + _probe_seq) % BASE36_5
	var token: String = ""
	for _i in 5:
		token = BASE36[v % 36] + token
		v /= 36
	return PROBE_PREFIX + token + PROBE_SUFFIX


func _say_why(source: String, rejected: String) -> Array:
	var s: GDScript = _rejects.get(rejected)
	if s == null:
		s = GDScript.new()
		if not ResourceLoader.has_cached(rejected):
			s.resource_path = rejected
		_rejects[rejected] = s
	s.source_code = _renamed(source)["source"]
	var listen: _Heard = _Heard.new()
	listen.path = s.resource_path
	OS.add_logger(listen)
	s.reload()
	OS.remove_logger(listen)
	return listen.heard


func _with_aliases(source: String, self_out: String, pending: Dictionary) -> String:
	var code: String = _code_only(source)
	var consts: PackedStringArray = PackedStringArray()
	for name in pending:
		var n: String = String(name)
		var target: String = pending[name]
		if (target == self_out or not FileAccess.file_exists(target)
				or not _uses_word(code, n) or _declares_member(code, n)):
			continue
		consts.append("const %s = preload(\"%s\")" % [n, target])
	if consts.is_empty():
		return source
	return source + ("" if source.ends_with("\n") else "\n") + "\n".join(consts) + "\n"


static func release_caches() -> void:
	_code_memo.clear()
	_words_memo.clear()
	_shared_registry = null
	_sharing = null
	GateProject.forget_parsed()
	GateAST._walk_names.clear()
	GateAST._child_names.clear()
	_type_names.clear()
	_ident_re = null
	GateChecker._engine_props.clear()
	GateChecker.forget_global_identifiers()
	GateChecker._script_cache.clear()
	GateChecker.release_statics()
	GateChecker._ast_props.clear()
	GateChecker._engine_func_cache.clear()
	GateInfer._shared_types.clear()
	GateNullCheck._accepts_cache.clear()
	GateProject._gd_name_cache.clear()
	GateProject.release_statics()
	GateTypeCompat._op_cache.clear()
	GateTypeCompat._op_exprs.clear()
	GateTypeCompat.release_statics()
	GateTypes.shadowed.clear()


static func remove_stale_probes(root: String) -> void:
	var d: DirAccess = DirAccess.open(root)
	if d == null:
		return
	d.include_hidden = true
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		var p: String = root.path_join(n)
		if d.current_is_dir():
			if not (n in [".godot", ".git", ".import"]) and not d.is_link(p):
				remove_stale_probes(p)
		elif _is_probe_debris(n) and _holds_probe(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
		n = d.get_next()
	d.list_dir_end()


static func _is_probe_debris(n: String) -> bool:
	var s: String = n.substr(1) if n.begins_with(".") else n
	if not s.begins_with(PROBE_PREFIX):
		return false
	if s.ends_with(".uid"):
		s = s.substr(0, s.length() - 4)
	var token: String = ""
	if s.ends_with(PROBE_SUFFIX):
		token = s.substr(PROBE_PREFIX.length(), s.length() - PROBE_PREFIX.length() - PROBE_SUFFIX.length())
		if token.length() != 5:
			return false
		for i in token.length():
			if BASE36.find(token[i]) < 0:
				return false
		return true
	if s.ends_with(".gd"):
		token = s.substr(PROBE_PREFIX.length(), s.length() - PROBE_PREFIX.length() - 3)
		return token != "" and token.is_valid_int()
	return false


static func _holds_probe(p: String) -> bool:
	if p.ends_with(".gd.uid"):
		var gd: String = p.substr(0, p.length() - 4)
		return not FileAccess.file_exists(gd) or _holds_probe(gd)
	var f: FileAccess = FileAccess.open(p, FileAccess.READ)
	if f == null:
		return false
	var first: String = f.get_line()
	var empty: bool = f.get_length() == 0
	f.close()
	return empty or first.begins_with(GateEmitter.HEADER_MARKER)


static func _uses_word(code: String, n: String) -> bool:
	var i: int = code.find(n)
	while i >= 0:
		var before: String = code[i - 1] if i > 0 else " "
		var after_i: int = i + n.length()
		var after: String = code[after_i] if after_i < code.length() else " "
		if not _is_word_char(before) and before != "." and not _is_word_char(after):
			return true
		i = code.find(n, i + 1)
	return false


static func _declares_member(code: String, n: String) -> bool:
	var re: RegEx = RegEx.create_from_string(
		"(?m)^(?:@\\w+(?:\\([^)]*\\))?\\s+)*(?:static\\s+)?(?:var|const|func|signal|enum|class)\\s+"
		+ n + "\\b")
	if re.search(code) != null:
		return true
	var enums: RegEx = RegEx.create_from_string("(?m)^enum\\s*\\w*\\s*\\{([^}]*)\\}")
	for m in enums.search_all(code):
		for key in m.get_string(1).split(","):
			if key.get_slice("=", 0).strip_edges() == n:
				return true
	return false


static func _is_word_char(c: String) -> bool:
	return ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
		or (c >= "0" and c <= "9") or c == "_")


func _clear_rejected(out_path: String) -> void:
	var stale: String = out_path + ".rejected"
	if FileAccess.file_exists(stale):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))


static func _rename_in_code(source: String, old: String, new_name: String) -> String:
	var code: String = _code_only(source)
	var out: String = ""
	var at: int = 0
	var i: int = code.find(old)
	while i >= 0:
		var before: String = code[i - 1] if i > 0 else " "
		var after_i: int = i + old.length()
		var after: String = code[after_i] if after_i < code.length() else " "
		if not _is_word_char(before) and before != "." and not _is_word_char(after):
			out += source.substr(at, i - at) + new_name
			at = after_i
		i = code.find(old, after_i)
	return out + source.substr(at)


static func _renamed(source: String) -> Dictionary:
	_probe_seq += 1
	var alias: String = "__GateProbeCN%d" % _probe_seq
	var lines: PackedStringArray = source.split("\n")
	var code: PackedStringArray = _code_only(source).split("\n")
	var declared: String = ""
	for i in lines.size():
		var cl: String = String(code[i])
		if cl.begins_with("class_name "):
			declared = cl.substr(11).strip_edges().split(" ")[0]
			lines[i] = "class_name " + alias + String(lines[i]).substr(11 + declared.length())
			break
	var stripped: String = "\n".join(lines)
	if declared == "":
		return {"source": stripped, "own": "", "alias": ""}
	return {"source": _rename_in_code(stripped, declared, alias), "own": declared, "alias": alias}


func output_parses(source: String, out_path: String = "") -> bool:
	return _probe(source, out_path)


static func _is_generated(path: String, from_gate: String = "") -> bool:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var first: String = f.get_line()
	var empty: bool = f.get_length() == 0
	f.close()
	if empty:
		return true
	if not first.begins_with(GateEmitter.HEADER_MARKER):
		return false
	var named: String = _banner_source(first)
	if named == "":
		return false
	return from_gate == "" or same_path(named, from_gate) or not FileAccess.file_exists(named)


static func _adopted_banner(path: String, gate_path: String) -> String:
	var named: String = _banner_of(path)
	return named if named != "" and not same_path(named, gate_path) and not FileAccess.file_exists(named) else ""


static func _banner_source(first_line: String) -> String:
	var exact: RegExMatch = RegEx.create_from_string("(?i)res://.*\\.gate(?= - do not edit\\.)").search(first_line)
	if exact != null:
		return exact.get_string()
	var m: RegExMatch = RegEx.create_from_string("(?i)res://.*?\\.gate(?![A-Za-z0-9_])").search(first_line)
	return m.get_string() if m != null else ""


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var j: JSON = JSON.new()
	return j.data if j.parse(_read_text(path)) == OK else null


const ORDINARY_ERRORS := ["Cannot assign ", "Cannot include ", "Cannot have ", "Cannot pass ",
	"Cannot convert ", "Cannot infer ", "Invalid index type", "Invalid argument for",
	"Invalid operands", "Value of type ", "Expression is of type ", "already exists",
	"is not a subtype of", "is not compatible with"]


static func _ordinary_error(code: String) -> bool:
	var text: String = code.trim_prefix("Parse Error: ").trim_prefix("Compile Error: ")
	for shape in ORDINARY_ERRORS:
		if text.begins_with(shape) or text.contains(shape):
			return true
	return false


static var _type_names: Dictionary = {}


static func _is_type_name(word: String) -> bool:
	if _type_names.is_empty():
		for i in TYPE_MAX:
			_type_names[type_string(i)] = true
		for c in ClassDB.get_class_list():
			_type_names[c] = true
		for e in ProjectSettings.get_global_class_list():
			_type_names[String(e["class"])] = true
		_type_names["Variant"] = true
	return _type_names.has(word)


const GDSCRIPT_WORDS := ["var", "const", "func", "static", "class", "class_name", "extends",
	"enum", "signal", "return", "if", "elif", "else", "for", "while", "match", "break",
	"continue", "pass", "await", "self", "super", "null", "true", "false", "and", "or", "not",
	"in", "is", "as", "void", "breakpoint", "assert", "when", "abstract", "set", "get"]


static var _ident_re: RegEx = null


static func _renders(out_line: String, gate_line: String) -> bool:
	var wrote: String = _code_only(gate_line)
	var shared: bool = false
	if _ident_re == null:
		_ident_re = RegEx.create_from_string("[A-Za-z_][A-Za-z_0-9]*")
	for m in _ident_re.search_all(_code_only(out_line)):
		var w: String = m.get_string()
		if GDSCRIPT_WORDS.has(w) or _is_type_name(w):
			continue
		if not _uses_word(wrote, w):
			return false
		shared = true
	return shared


static func _users_error(heard: Array, out_text: String, gate_text: String, map: Array) -> String:
	if heard.is_empty():
		return ""
	var out_lines: PackedStringArray = out_text.split("\n")
	var gate_lines: PackedStringArray = gate_text.split("\n")
	var gate_code: String = _code_only(gate_text)
	var undeclared: RegEx = RegEx.create_from_string("Identifier \"([A-Za-z_]\\w*)\" not declared")
	var first: String = ""
	for h in heard:
		var line: int = int(h["line"])
		var code: String = String(h["code"])
		var at: int = int(map[line - 1]) if line >= 1 and line <= map.size() else 0
		var named: RegExMatch = undeclared.search(code)
		var theirs: bool = named != null and _uses_word(gate_code, named.get_string(1))
		if not theirs and at > 0 and line <= out_lines.size() and at <= gate_lines.size():
			var mine: String = out_lines[line - 1]
			var wrote: String = gate_lines[at - 1]
			theirs = (mine.strip_edges() == wrote.strip_edges()
				or (_ordinary_error(code) and _renders(mine, wrote)))
		if not theirs:
			return ""
		if first == "":
			var text: String = code.trim_prefix("Parse Error: ").trim_prefix("Compile Error: ")
			first = ("%d: %s" % [at, text]) if at > 0 else " " + text
	return first


static func _read_text(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t: String = f.get_as_text()
	f.close()
	return t


static func _file_hash(path: String) -> String:
	return FileAccess.get_md5(path) if FileAccess.file_exists(path) else ""


func _note_skipped(dir: String, root: String) -> void:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return
	for n in d.get_directories():
		var p: String = dir.path_join(n)
		if (n.begins_with(".") or _is_gdignored(p) or FileAccess.file_exists(p.path_join("project.godot"))
				or _said.has("skip " + p)):
			continue
		if d.is_link(p):
			if not _all_gate_under(p).is_empty():
				_warn_once("skip " + p, ("[GATE] %s is a link (a junction or symlink), and GATE "
					+ "does not follow links, so the .gate files behind it were not compiled. "
					+ "Put them in a real folder of the project to compile them.") % p)
		elif n == "addons":
			var found: Array[String] = []
			for g in _all_gate_under(p):
				if not g.begins_with(root.path_join("addons/gate/")):
					found.append(g)
			if not found.is_empty():
				_warn_once("skip " + p, ("[GATE] %d .gate file(s) under %s/ were not compiled, "
					+ "starting with %s: GATE skips every addons/ folder, so it never rebuilds itself "
					+ "or another plugin. Move them out of it to compile them.") % [found.size(), p, found[0]])
		elif not IGNORE_DIRS.has(n):
			_note_skipped(p, root)


static func _is_gdignored(dir: String) -> bool:
	return FileAccess.file_exists(dir.path_join(".gdignore"))


static func _all_gate_under(dir: String) -> Array[String]:
	var out: Array[String] = []
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		var p: String = dir.path_join(n)
		if d.current_is_dir():
			if (not n.begins_with(".") and not d.is_link(p) and not _is_gdignored(p)
					and not FileAccess.file_exists(p.path_join("project.godot"))):
				out.append_array(_all_gate_under(p))
		elif n.get_extension().to_lower() == "gate":
			out.append(p)
		n = d.get_next()
	d.list_dir_end()
	return out


static func find_gate_files(root: String) -> Array[String]:
	return GateProject.find_gate_files(root)

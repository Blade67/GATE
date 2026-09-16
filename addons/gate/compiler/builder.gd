@tool
class_name GateBuilder
extends RefCounted

## Everything the editor plugin does, minus the editor.
##
## Writes every output first and validates afterwards: a file that references
## another preloads it, so in a cycle neither can go first.

const RESULT_UNLINKED := -2

const IGNORE_DIRS := ["addons", ".godot", ".git", ".import"]

var hashes: Dictionary = {}

var out_hashes: Dictionary = {}

var unverified: Dictionary = {}

static var _probe_seq: int = 0

var errors: PackedStringArray = []
var warnings: PackedStringArray = []

var changed: int = 0
var failed: int = 0
var unchanged: int = 0


func _clear() -> void:
	errors = PackedStringArray()
	warnings = PackedStringArray()
	changed = 0
	failed = 0
	unchanged = 0


func build(root: String = "res://") -> Dictionary:
	_clear()
	var project: GateProject = GateProject.new()
	var registry = project.index(root)

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

	for skipped in _gate_files_under_addons(root):
		warnings.append(("[GATE] %s is under addons/ and was not compiled. GATE skips "
			+ "addons/ so it never rebuilds itself; move the file outside addons/, or "
			+ "compile it yourself with GateCompiler.") % skipped)

	var sig: String = registry.signature()
	var reg_sig: String = "%d:%d" % [sig.hash(), sig.length()]

	var deferred: Dictionary = {}
	for path in find_gate_files(root):
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

	var failed_outputs: Dictionary = {}
	var unverified_now: Dictionary = {}
	var queue: Array = []
	for out_path3 in deferred:
		var info3: Dictionary = deferred[out_path3]
		if output_parses(info3["source"], out_path3):
			continue
		if _references_other_class(info3["source"], declared_here, out_path3):
			unverified_now[out_path3] = true
			continue
		failed_outputs[out_path3] = true
		queue.append(out_path3)
	while not queue.is_empty():
		var bad: String = queue.pop_back()
		for d in dependents.get(bad, []):
			if not failed_outputs.has(d):
				failed_outputs[d] = true
				queue.append(d)

	unverified = {}
	for uv in unverified_now:
		warnings.append(("[GATE] %s references a class_name declared by another file "
			+ "in this build, so its output could not be verified yet - Godot resolves "
			+ "a global class name from the editor's class list, which is updated after "
			+ "the file is written. It will be checked on the next build.")
			% deferred[uv]["gate"])
		unverified[String(deferred[uv]["gate"])] = true

	for out_path in deferred:
		var info: Dictionary = deferred[out_path]
		if not failed_outputs.has(out_path):
			continue
		var rf: FileAccess = FileAccess.open(out_path + ".rejected", FileAccess.WRITE)
		if rf != null:
			rf.store_string(info["source"])
			rf.close()
		if info["existed"]:
			var w: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
			if w != null:
				w.store_string(info["prev"])
				w.close()
			if info.get("prev_map_existed", false):
				var mw: FileAccess = FileAccess.open(out_path + ".map", FileAccess.WRITE)
				if mw != null:
					mw.store_string(info["prev_map"])
					mw.close()
			elif FileAccess.file_exists(out_path + ".map"):
				DirAccess.remove_absolute(
					ProjectSettings.globalize_path(out_path + ".map"))
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
			if FileAccess.file_exists(out_path + ".map"):
				DirAccess.remove_absolute(
					ProjectSettings.globalize_path(out_path + ".map"))
		hashes.erase(info["gate"])
		if info["was"] == 1:
			changed -= 1
		else:
			unchanged -= 1
		failed += 1
		errors.append(("[GATE] %s: GATE compiled this without errors, but Godot will not "
			+ "load the GDScript it produced. The previous %s has been put back - if a "
			+ "file this one depends on changed, that older output may itself no longer "
			+ "be correct. The rejected output is saved as %s; Godot's own parse error "
			+ "is printed above and its line number refers to that file. This is "
			+ "usually a GATE bug, but check first that any preload() and class_name it "
			+ "names really exist; keep the .gate and .rejected files together if you "
			+ "report it.")
			% [info["gate"], out_path, out_path + ".rejected"])

	return {"changed": changed, "failed": failed, "unchanged": unchanged}


func compile_file(gate_path: String, registry = null, deferred = null, reg_sig: String = "") -> int:
	var f: FileAccess = FileAccess.open(gate_path, FileAccess.READ)
	if f == null:
		errors.append("[GATE] cannot read %s" % gate_path)
		return -1
	var src: String = f.get_as_text()
	f.close()

	var out_path: String = gate_path.get_basename() + ".gd"
	var map_path: String = out_path + ".map"

	# Never write over a file GATE did not generate. The banner is the only marker.
	if FileAccess.file_exists(out_path) and not _is_generated(out_path, gate_path):
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

	var h: String = "%d:%d:%s" % [src.hash(), src.length(), reg_sig]
	if (hashes.get(gate_path) == h and not unverified.has(gate_path)
			and FileAccess.file_exists(out_path)
				and FileAccess.file_exists(map_path)
				and _file_hash(out_path) == out_hashes.get(gate_path)):
		return 0

	var compiler: GateCompiler = GateCompiler.new()
	var res: GateCompiler.Result = compiler.compile(src, gate_path, registry)

	if not res.ok:
		for d in res.diagnostics.items:
			if d.level == GateDiagnostics.Level.ERROR:
				errors.append("[GATE] " + d.format())
		errors.append("[GATE] %s: %d error(s); %s not updated"
			% [gate_path, res.diagnostics.error_count(), out_path])
		return -1

	for d in res.diagnostics.items:
		if d.level == GateDiagnostics.Level.WARNING:
			warnings.append("[GATE] " + d.format())

	if deferred == null and not output_parses(res.source, out_path):
		var rej: String = out_path + ".rejected"
		var rf: FileAccess = FileAccess.open(rej, FileAccess.WRITE)
		if rf != null:
			rf.store_string(res.source)
			rf.close()
		errors.append(("[GATE] %s: GATE compiled this without errors, but Godot will not "
			+ "load the GDScript it produced, so %s was left as it was. The rejected "
			+ "output is saved as %s - Godot's own parse error is printed above this "
			+ "message and its line number refers to that file. This is a GATE bug; "
			+ "keep the .gate and .rejected files together if you report it.")
			% [gate_path, out_path, rej])
		return RESULT_UNLINKED

	hashes[gate_path] = h
	out_hashes[gate_path] = "%d:%d" % [res.source.hash(), res.source.length()]

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
			if existing == res.source:
				if not FileAccess.file_exists(map_path):
					GateCompiler.write_sourcemap(out_path, gate_path, res.map)
				_clear_rejected(out_path)
				if deferred != null:
					deferred[out_path] = {
						"gate": gate_path, "source": res.source, "deps": res.deps,
						"prev": existing, "prev_map": _read_text(map_path),
						"prev_map_existed": FileAccess.file_exists(map_path),
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
			"prev_map_existed": FileAccess.file_exists(map_path),
			"existed": had_output, "was": 1,
		}
	o.store_string(res.source)
	o.close()
	GateCompiler.write_sourcemap(out_path, gate_path, res.map)
	_clear_rejected(out_path)
	return 1


static func _resolve_dep(dep: String, from_out: String) -> String:
	if dep.begins_with("res://"):
		return dep.simplify_path()
	if dep.begins_with("uid://") or dep.begins_with("user://"):
		return ""
	return from_out.get_base_dir().path_join(dep).simplify_path()


static func _code_only(source: String) -> String:
	var out: String = ""
	var i: int = 0
	var quote: String = ""     # the delimiter of the literal we are inside, or ""
	var n: int = source.length()
	while i < n:
		var ch: String = source[i]
		if quote != "":
			if ch == "\\" and quote.length() == 1:
				out += "  "
				i += 2
				continue
			if source.substr(i, quote.length()) == quote:
				out += " ".repeat(quote.length())
				i += quote.length()
				quote = ""
				continue
			out += ch if ch == "\n" else " "
			i += 1
			continue
		if ch == "#":
			while i < n and source[i] != "\n":
				out += " "
				i += 1
			continue
		var three: String = source.substr(i, 3)
		if three == '"""' or three == "'''":
			quote = three
			out += "   "
			i += 3
			continue
		if ch == '"' or ch == "'":
			quote = ch
			out += " "
			i += 1
			continue
		out += ch
		i += 1
	return out


static func _references_other_class(source: String, declared: Dictionary, self_out: String) -> bool:
	var code: String = _code_only(source)
	for name in declared:
		if declared[name] == self_out:
			continue
		var n: String = String(name)
		var i: int = code.find(n)
		while i >= 0:
			var before: String = code[i - 1] if i > 0 else " "
			var after_i: int = i + n.length()
			var after: String = code[after_i] if after_i < code.length() else " "
			if not _is_word_char(before) and before != "." and not _is_word_char(after):
				return true
			i = code.find(n, i + 1)
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


func output_parses(source: String, out_path: String = "") -> bool:
	_probe_seq += 1
	# The `class_name` is renamed, not blanked. Blanking it breaks a file that refers
	# to its own class qualified, and orphans a preceding `@abstract`.
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
	if declared != "":
		stripped = _rename_in_code(stripped, declared, alias)
	var probe: GDScript = GDScript.new()
	if out_path != "":
		_probe_seq += 1
		# `path_join`, not "%s/%s": at the project root `get_base_dir()` is already
		# "res://", and "res:///x.gd" is a path Godot cannot resolve a script by.
		probe.resource_path = out_path.get_base_dir().path_join(
			"__gate_probe_%d.gd" % _probe_seq)
	probe.source_code = stripped
	return probe.reload() == OK


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
	if _banner_source(first) == "":
		return false
	if from_gate != "" and not first.contains(from_gate):
		var named: String = _banner_source(first)
		if named != "" and FileAccess.file_exists(named):
			return false
	return true


static func _adopted_banner(path: String, gate_path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var first: String = f.get_line()
	f.close()
	if not first.begins_with(GateEmitter.HEADER_MARKER) or first.contains(gate_path):
		return ""
	var named: String = _banner_source(first)
	return named if named != "" and not FileAccess.file_exists(named) else ""


static func _banner_source(first_line: String) -> String:
	var i: int = first_line.find("res://")
	if i < 0:
		return ""
	var rest: String = first_line.substr(i)
	var end: int = rest.find(".gate")
	if end < 0:
		return ""
	return rest.substr(0, end + 5)


static func _read_text(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t: String = f.get_as_text()
	f.close()
	return t


static func _file_hash(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t: String = f.get_as_text()
	f.close()
	return "%d:%d" % [t.hash(), t.length()]


static func _gate_files_under_addons(root: String) -> Array[String]:
	var out: Array[String] = []
	var addons: String = root.path_join("addons")
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(addons)):
		return out
	var d: DirAccess = DirAccess.open(addons)
	if d == null:
		return out
	for sub in d.get_directories():
		if sub == "gate" or sub.begins_with("."):
			continue
		out.append_array(_all_gate_under(addons.path_join(sub)))
	return out


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
			if (not n.begins_with(".") and not d.is_link(p)
					and not _is_gdignored(p)):
				out.append_array(_all_gate_under(p))
		elif n.get_extension().to_lower() == "gate":
			out.append(p)
		n = d.get_next()
	d.list_dir_end()
	return out


static func find_gate_files(root: String) -> Array[String]:
	return GateProject.find_gate_files(root)

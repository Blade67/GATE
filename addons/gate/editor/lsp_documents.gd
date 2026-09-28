@tool
extends RefCounted

## The files a client holds open, and the one place a document URI becomes a path.
##
## While a client holds a file open, every answer about that file is computed from
## the text the client sent. A file it has not opened is read from disk, exactly as
## the editor integration does. A file the client saved is still the client's: the
## two agree at that moment anyway, and reading the disk back would answer from a
## file the editor may not have rescanned yet.
##
## It also holds the publish countdown, because the same object already knows which
## documents there are. The count is in polls, not milliseconds: see the server.

## The only extension served. A `.gd` belongs to Godot's own language server, and
## two servers answering for one file is worse than one.
const EXTENSION: String = "gate"


class _Doc extends RefCounted:
	var uri: String
	var path: String
	var text: String
	var version: int

	func _init(p_uri: String, p_path: String, p_text: String, p_version: int) -> void:
		uri = p_uri
		path = p_path
		text = p_text
		version = p_version


var _open: Dictionary = {}
var _waiting: Dictionary = {}
var _full: Dictionary = {}


## A document URI as a `res://` path, or why it is not one, as
## `{"path": String, "fault": String}`.
##
## The shapes a real client sends are all handled: `file:///E:/...`, a drive letter
## in either case, a percent-encoded space or colon, and a path written with
## backslashes. Anything else is refused rather than guessed at, because a guessed
## path is a file read, or reported on, that nobody asked about.
static func path_of(uri: String) -> Dictionary:
	if not uri.begins_with("file://"):
		return _fault("only file:// document URIs are served, and this one is \"%s\"" % uri)
	var rest: String = uri.substr(7).uri_decode().replace("\\", "/")
	# `file:///E:/x` carries a leading slash in front of the drive letter and
	# `file:///home/x` carries the root itself. Only the first kind loses it.
	if rest.length() >= 3 and rest[0] == "/" and rest[2] == ":":
		rest = rest.substr(1)
	var full: String = rest.simplify_path()
	var root: String = ProjectSettings.globalize_path("res://").replace("\\", "/")
	if not root.ends_with("/"):
		root += "/"
	if not _under(full, root):
		return _fault("\"%s\" is outside the project, which is %s" % [full, root])
	var relative: String = full.substr(root.length())
	var extension: String = relative.get_extension().to_lower()
	if extension != EXTENSION:
		if extension == "gd":
			return _fault(("GATE's language server does not answer for a .gd: "
				+ "Godot's own language server owns those, and \"%s\" is one") % relative)
		return _fault("GATE's language server answers for .gate files only, and \"%s\" is not one"
			% relative)
	return {"path": "res://" + relative, "fault": ""}


## A `res://` path as a document URI, which is the way back out of `path_of`.
static func uri_of_path(path: String) -> String:
	var full: String = ProjectSettings.globalize_path(path).replace("\\", "/")
	var parts: PackedStringArray = PackedStringArray()
	for part in full.split("/"):
		var piece: String = String(part)
		parts.append(piece if _is_drive(piece) else piece.uri_encode())
	var joined: String = "/".join(parts)
	if joined.begins_with("/"):
		return "file://" + joined
	return "file:///" + joined


static func _is_drive(part: String) -> bool:
	return part.length() == 2 and part[1] == ":"


## The client's text for a file it holds open, or the file on disk.
func text_of(path: String) -> String:
	if _open.has(path):
		return (_open[path] as _Doc).text
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func is_open(path: String) -> bool:
	return _open.has(path)


func paths() -> Array:
	return _open.keys()


## The URI the client used for this file. Answered with the client's own spelling
## rather than one built back from the path: a client matches a published
## diagnostic to a buffer by the URI string it sent, and the two spellings of one
## file are not always the same string.
func uri_of(path: String) -> String:
	return (_open[path] as _Doc).uri if _open.has(path) else ""


func version_of(path: String) -> int:
	return (_open[path] as _Doc).version if _open.has(path) else 0


func open(uri: String, text: String, version: int) -> Dictionary:
	var found: Dictionary = path_of(uri)
	if String(found["fault"]) != "":
		return found
	var path: String = String(found["path"])
	_open[path] = _Doc.new(uri, path, text, version)
	return found


## A change for a file that was never opened opens it. The protocol says a client
## opens before it changes, and a client that does not is still better served with
## diagnostics than with silence.
func change(uri: String, text: String, version: int) -> Dictionary:
	var found: Dictionary = path_of(uri)
	if String(found["fault"]) != "":
		return found
	var path: String = String(found["path"])
	if not _open.has(path):
		_open[path] = _Doc.new(uri, path, text, version)
		return found
	var doc: _Doc = _open[path]
	doc.text = text
	doc.version = version
	return found


func close(uri: String) -> Dictionary:
	var found: Dictionary = path_of(uri)
	if String(found["fault"]) != "":
		return found
	var path: String = String(found["path"])
	_open.erase(path)
	_waiting.erase(path)
	_full.erase(path)
	return found


func clear() -> void:
	_open.clear()
	_waiting.clear()
	_full.clear()


## This file is due for diagnostics in `polls` polls. Asked again before it comes
## due, the count starts over, which is what makes it a debounce.
##
## `full` asks for the tier that costs a compile as well as the one that costs a
## lex. It is set by a save and by nothing else: the compile is measured at twenty
## times the lexer pass, and a file that is being typed into would pay it on every
## pause.
func wait(path: String, polls: int, full: bool = false) -> void:
	_waiting[path] = maxi(1, polls)
	if full:
		_full[path] = true


## Whether the publish about to go out is a full one. Asked once: the next change
## is a keystroke again.
func take_full(path: String) -> bool:
	if not _full.has(path):
		return false
	_full.erase(path)
	return true


func forget(path: String) -> void:
	_waiting.erase(path)
	_full.erase(path)


## One poll: the files whose count has run out, which is usually none.
func step() -> Array:
	if _waiting.is_empty():
		return []
	var due: Array = []
	for path in _waiting.keys():
		var left: int = int(_waiting[path]) - 1
		if left > 0:
			_waiting[path] = left
			continue
		_waiting.erase(path)
		due.append(path)
	return due


static func _fault(why: String) -> Dictionary:
	return {"path": "", "fault": why}


## Windows and macOS do not tell two spellings of one path apart, and a drive
## letter is the one that actually varies: VS Code sends a lower-case one. The
## path's own case is kept whatever the comparison decided.
static func _under(full: String, root: String) -> bool:
	if full.length() < root.length():
		return false
	var head: String = full.substr(0, root.length())
	if head == root:
		return true
	if not (OS.has_feature("windows") or OS.has_feature("macos")):
		return false
	return head.to_lower() == root.to_lower()

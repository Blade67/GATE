@tool
extends Node

## GATE's language server: a loopback listener, `Content-Length` framing, the
## JSON-RPC 2.0 envelope, the LSP lifecycle, document sync and diagnostics.
##
## Its own node, polled every frame. The plugin's own `_process` is the project
## warm-up and switches itself off once that is done, so a listener polled from
## there goes silent a few seconds into the session.
##
## Every request this does not answer is answered with "method not found", never
## with an empty result: a client told the method is missing looks elsewhere, and
## a client told there are zero completions believes GATE has none.

const _Protocol: GDScript = preload("res://addons/gate/editor/lsp_protocol.gd")
const _Positions: GDScript = preload("res://addons/gate/editor/lsp_positions.gd")
const _Documents: GDScript = preload("res://addons/gate/editor/lsp_documents.gd")
const _Diagnostics: GDScript = preload("res://addons/gate/editor/lsp_diagnostics.gd")
const _Editing: GDScript = preload("res://addons/gate/editor/lsp_complete.gd")

const NODE_NAME: String = "GateLanguageServer"
const ENABLED_SETTING: String = "gate/lsp/enabled"
const PORT_SETTING: String = "gate/lsp/port"

## Loopback, never a routable interface.
const BIND_HOST: String = "127.0.0.1"

## How often the two settings are read again, in polls. The editor has no signal
## for a project setting changing that a plugin can rely on, and this costs two
## dictionary lookups a few times a second.
const SETTING_POLL_FRAMES: int = 30

## Polls a finished write is left to go out before the socket is closed. Closing
## in the same poll as the write discards it, and the client then cannot tell a
## refusal from a server that is not running.
const DRAIN_POLLS: int = 3

## Polls an edited file waits before its diagnostics are worked out, counted in
## polls rather than milliseconds on purpose.
##
## A poll is an editor frame, and the editor's frame period is 6.9 ms while it has
## focus and 100 ms while it does not, on a default install. The editor is
## unfocused for the whole time a client is being typed in, which is the only time
## there is a burst of changes to coalesce, so counting frames gives about 20 ms
## in the state where nothing is arriving and about 300 ms in the state where a
## keystroke arrives every 100 ms. A wall-clock timer gives one number for both.
const DIAGNOSTIC_POLLS: int = 3

## A file that was opened or saved is not a burst, so it goes out on the next poll
## rather than waiting for the debounce.
const DIAGNOSTIC_AT_ONCE: int = 1


## How long the editor is allowed to sleep between frames while a client is
## attached, in microseconds. ~60 Hz.
##
## The editor sleeps its unfocused period between frames - 100,000 us on the
## machine this was measured on, against 6,900 focused - and unfocused is what it
## is the whole time somebody is typing in another editor, which is exactly when
## this server is answering. That is up to 10 Hz for completion and diagnostics.
##
## `OS.low_processor_usage_mode_sleep_usec` is a runtime property, not an editor
## setting: GATE never writes one of those. The editor does not put its own value
## back, measured at 0 reversions in 2,032 frames, and this is written every poll
## rather than once, so an editor that re-applied its own on a focus change would
## lose it again on the next frame.
##
## 6,900 would be the editor's own focused figure, ~145 Hz, and nothing here needs
## that: it would spin the editor at full rate for as long as an external editor
## is attached. 10 Hz is what makes completion feel late; 60 Hz does not.
const HELD_SLEEP_USEC: int = 16000

## LSP's TextDocumentSyncKind.Full. The whole text arrives on every change: GATE
## lexes a file in about 18 ms per thousand lines, so there is nothing to win from
## applying ranges, and a range applied wrongly is a file the server and the client
## disagree about.
const SYNC_FULL: int = 1

## LSP's MessageType.Error.
const LOG_ERROR: int = 1

var _server: TCPServer = TCPServer.new()
var _peer: StreamPeerTCP = null
var _reader: RefCounted = _Protocol._Reader.new()
var _docs: RefCounted = _Documents.new()
var _tx: PackedByteArray = PackedByteArray()
var _refused: Array = []
var _initialized: bool = false
var _shutting_down: bool = false
var _closing: bool = false
var _drained_polls: int = 0
var _encoding: String = _Positions.UTF16
var _port: int = 0
var _failed_port: int = -1
var _polls: int = 0
## The period the editor itself last asked for, to be put back on release.
var _editor_usec: int = 0
var _holding: bool = false


func _init() -> void:
	name = NODE_NAME


func _ready() -> void:
	set_process(true)
	_apply_settings()


func _exit_tree() -> void:
	stop()


func is_listening() -> bool:
	return _server.is_listening()


func port() -> int:
	return _port


func host() -> String:
	return BIND_HOST


func has_client() -> bool:
	return _peer != null


## The text every answer about this file is computed from: the client's while it
## holds the file open, and the file on disk otherwise.
func text_of(path: String) -> String:
	return _docs.text_of(path)


func open_documents() -> Array:
	return _docs.paths()


## Loopback only, and the port the setting asks for or nothing. A bind that fails
## says why and stops: a server on a port the client was not told about is worse
## than no server at all.
func start(with_port: int) -> void:
	if not _is_loopback(BIND_HOST):
		push_error("[GATE] the language server will not bind %s: loopback only." % BIND_HOST)
		return
	var err: int = _server.listen(with_port, BIND_HOST)
	if err != OK:
		_failed_port = with_port
		push_error(("[GATE] the language server could not listen on %s:%d: %s. "
			+ "Set %s to a free port, or switch %s off.")
			% [BIND_HOST, with_port, error_string(err), PORT_SETTING, ENABLED_SETTING])
		return
	if _server.get_local_port() != with_port:
		push_error("[GATE] the language server asked for port %d and was given %d; stopping."
			% [with_port, _server.get_local_port()])
		_server.stop()
		_failed_port = with_port
		return
	_port = with_port
	_failed_port = -1
	print("[GATE] language server listening on %s:%d" % [BIND_HOST, with_port])


func stop() -> void:
	_drop_peer()
	for entry in _refused:
		entry["peer"].disconnect_from_host()
	_refused.clear()
	if _server.is_listening():
		_server.stop()
	_port = 0
	_release_rate()


func _process(_delta: float) -> void:
	_polls += 1
	_hold_rate()
	if _polls % SETTING_POLL_FRAMES == 0:
		_apply_settings()
	if not _server.is_listening():
		return
	# Pumped before accepting: a client that has gone is noticed in the same poll
	# as the next one arrives, so the next one is served instead of being told
	# something else is connected.
	_pump()
	_accept()
	_drain_refusals()


## Keep the editor's loop quick enough to answer while it is not the focused
## window. Only ever shortens the period: a focused editor is already faster than
## this, and slowing it down to 60 Hz would be a bug rather than a fix.
func _hold_rate() -> void:
	var now: int = OS.low_processor_usage_mode_sleep_usec
	# Any value that is not the one being held is the editor speaking, which is
	# what a focus change looks like from here.
	if not _holding or now != HELD_SLEEP_USEC:
		_editor_usec = now
	if has_client() and _editor_usec > HELD_SLEEP_USEC:
		OS.low_processor_usage_mode_sleep_usec = HELD_SLEEP_USEC
		_holding = true
		return
	_release_rate()


## Hand the loop back to whatever the editor last wanted, rather than to whatever
## it wanted when the client connected, which may be a whole focus change ago.
func _release_rate() -> void:
	if not _holding:
		return
	OS.low_processor_usage_mode_sleep_usec = _editor_usec
	_holding = false


func _apply_settings() -> void:
	var wanted: bool = bool(GateFeatures.plugin_setting(ENABLED_SETTING))
	var wanted_port: int = int(GateFeatures.plugin_setting(PORT_SETTING))
	if not wanted:
		_failed_port = -1
		if _server.is_listening():
			stop()
		return
	if _server.is_listening():
		if wanted_port == _port:
			return
		stop()
	if wanted_port == _failed_port:
		return
	start(wanted_port)


func _is_loopback(address: String) -> bool:
	return address == "127.0.0.1" or address == "::1"


func _accept() -> void:
	while _server.is_connection_available():
		var peer: StreamPeerTCP = _server.take_connection()
		if peer == null:
			continue
		if _peer == null:
			_adopt(peer)
		else:
			_refuse(peer)


func _adopt(peer: StreamPeerTCP) -> void:
	_peer = peer
	_peer.set_no_delay(true)
	_reader.reset()
	_docs.clear()
	_tx = PackedByteArray()
	_initialized = false
	_shutting_down = false
	_closing = false
	_drained_polls = 0
	_encoding = _Positions.UTF16


## Queued like any other write and sent over the next few polls. The socket is
## closed only once it has gone.
func _refuse(peer: StreamPeerTCP) -> void:
	peer.set_no_delay(true)
	var body: String = JSON.stringify(_Protocol.failure(null, _Protocol.UNKNOWN_ERROR_CODE,
		"GATE's language server serves one client at a time, and one is already connected."))
	_refused.append({"peer": peer, "tx": _Protocol.frame(body), "polls": 0})


func _drain_refusals() -> void:
	var still: Array = []
	for entry in _refused:
		var peer: StreamPeerTCP = entry["peer"]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		var pending: PackedByteArray = entry["tx"]
		if not pending.is_empty():
			var got: Array = peer.put_partial_data(pending)
			if int(got[0]) != OK:
				continue
			entry["tx"] = pending.slice(int(got[1]))
			still.append(entry)
			continue
		entry["polls"] = int(entry["polls"]) + 1
		if int(entry["polls"]) >= DRAIN_POLLS:
			peer.disconnect_from_host()
			continue
		still.append(entry)
	_refused = still


func _pump() -> void:
	if _peer == null:
		return
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_drop_peer()
		return
	var available: int = _peer.get_available_bytes()
	if available > 0:
		var got: Array = _peer.get_partial_data(available)
		if int(got[0]) == OK:
			_reader.feed(got[1])
	while true:
		var body: String = _reader.next_body()
		if body == "":
			break
		var reply: String = handle_text(body)
		if reply != "":
			_tx.append_array(_Protocol.frame(reply))
	if _reader.fault != "":
		push_warning("[GATE] the language server closed a connection: %s" % _reader.fault)
		_drop_peer()
		return
	_publish_due()
	_flush()
	if _closing and _tx.is_empty():
		_drained_polls += 1
		if _drained_polls >= DRAIN_POLLS:
			_drop_peer()


## Never put_data: it blocks the editor's thread until every byte has gone, and a
## client that has stopped reading is then a frozen editor.
func _flush() -> void:
	if _peer == null or _tx.is_empty():
		return
	var got: Array = _peer.put_partial_data(_tx)
	if int(got[0]) != OK:
		_drop_peer()
		return
	_tx = _tx.slice(int(got[1]))


func _drop_peer() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
	_peer = null
	_reader.reset()
	# The documents belong to the connection. A client that went away holds nothing
	# open any more, and the next one opens its own.
	_docs.clear()
	_tx = PackedByteArray()
	_initialized = false
	_shutting_down = false
	_closing = false
	_drained_polls = 0
	_encoding = _Positions.UTF16


## One message in, its answer out, or "" when there is nothing to answer. A
## notification is never answered, whatever it asked for.
func handle_text(text: String) -> String:
	# JSON.parse_string pushes an engine error of its own on malformed input, which
	# would fill the Output panel with GATE's name every time a client sent a bad
	# frame. An instance answers with an error code and a message instead.
	var reader: JSON = JSON.new()
	var err: int = reader.parse(text)
	if err != OK:
		return JSON.stringify(_Protocol.failure(null, _Protocol.PARSE_ERROR,
			"the message is not JSON: %s (line %d)"
			% [reader.get_error_message(), reader.get_error_line()]))
	if typeof(reader.data) != TYPE_DICTIONARY:
		return JSON.stringify(_Protocol.failure(null, _Protocol.PARSE_ERROR,
			"the message is not a JSON object"))
	var msg: Dictionary = reader.data
	var fault: String = _Protocol.envelope_fault(msg)
	if fault != "":
		return JSON.stringify(_Protocol.failure(msg.get("id", null),
			_Protocol.INVALID_REQUEST, fault))
	var method: String = String(msg["method"])
	var params: Dictionary = msg["params"] if msg.get("params", null) is Dictionary else {}
	if not msg.has("id"):
		_notify(method, params)
		return ""
	return JSON.stringify(_answer(method, msg["id"], params))


func _answer(method: String, id: Variant, params: Dictionary) -> Dictionary:
	if method == "initialize":
		if _initialized:
			return _Protocol.failure(id, _Protocol.INVALID_REQUEST,
				"this connection has already been initialized")
		_initialized = true
		_encoding = _Positions.choose_encoding(_offered_encodings(params))
		return _Protocol.result(id, {
			"capabilities": {
				"positionEncoding": _encoding,
				"textDocumentSync": {
					"openClose": true,
					"change": SYNC_FULL,
					# The client's buffer is the server's text and a save does not
					# change it, so there is nothing to read back.
					"save": {"includeText": false},
				},
				"completionProvider": {
					"triggerCharacters": _Editing.COMPLETION_TRIGGERS,
					"resolveProvider": false,
				},
				"signatureHelpProvider": {
					"triggerCharacters": _Editing.SIGNATURE_TRIGGERS,
				},
				"definitionProvider": true,
				"hoverProvider": true,
				"documentSymbolProvider": true,
			},
			"serverInfo": {"name": "GATE", "version": _plugin_version()},
		})
	if not _initialized:
		return _Protocol.failure(id, _Protocol.SERVER_NOT_INITIALIZED,
			"GATE's language server has not been initialized")
	if _shutting_down:
		return _Protocol.failure(id, _Protocol.INVALID_REQUEST,
			"this connection has been shut down")
	if method == "shutdown":
		_shutting_down = true
		return _Protocol.result(id, null)

	# --- capability dispatch: one lane's entries go here, nothing else moves ---
	if method == _Editing.COMPLETION or method == _Editing.SIGNATURE_HELP:
		return _Editing.answer(method, id, params, _docs, _encoding)
	# preload here rather than a file-level const so every line this adds to this
	# file sits between the two markers.
	if (method == "textDocument/definition" or method == "textDocument/hover"
			or method == "textDocument/documentSymbol"):
		var navigation: GDScript = preload("res://addons/gate/editor/lsp_navigation.gd")
		var about: Dictionary = _Documents.path_of(String(_document_of(params).get("uri", "")))
		if String(about.get("fault", "")) != "":
			return _Protocol.failure(id, _Protocol.INVALID_PARAMS, String(about["fault"]))
		var document: String = String(about["path"])
		return _Protocol.result(id, navigation.answer(method, _docs.text_of(document),
			document, params, _encoding))
	# --- end capability dispatch ---
	return _Protocol.failure(id, _Protocol.METHOD_NOT_FOUND,
		"GATE's language server does not answer %s yet" % method)


## `exit` closes the connection and leaves the listener up. The protocol has it
## end the server process; here the process is the editor.
func _notify(method: String, params: Dictionary) -> void:
	if method == "exit":
		_closing = true
		_drained_polls = 0
		return
	if not _initialized or _shutting_down:
		return
	if method == "textDocument/didOpen":
		_did_open(params)
	elif method == "textDocument/didChange":
		_did_change(params)
	elif method == "textDocument/didSave":
		_did_save(params)
	elif method == "textDocument/didClose":
		_did_close(params)


func _did_open(params: Dictionary) -> void:
	var document: Dictionary = _document_of(params)
	var uri: String = String(document.get("uri", ""))
	var got: Dictionary = _docs.open(uri, String(document.get("text", "")),
		int(document.get("version", 0)))
	if not _taken(uri, got):
		return
	_docs.wait(String(got["path"]), DIAGNOSTIC_AT_ONCE)


## Full text sync: the last change in the list is the document. A client that sends
## a range anyway has ignored the capability, and applying it as if it were the
## whole file would replace the text with a fragment.
func _did_change(params: Dictionary) -> void:
	var document: Dictionary = _document_of(params)
	var uri: String = String(document.get("uri", ""))
	var changes: Array = params["contentChanges"] if params.get("contentChanges", null) is Array else []
	if changes.is_empty():
		return
	var last: Dictionary = changes[changes.size() - 1] if changes[changes.size() - 1] is Dictionary else {}
	if last.has("range"):
		_tell_client(("a change for \"%s\" carried a range, and GATE asked for the whole "
			+ "text of the document on every change; it was not applied") % uri)
		return
	var got: Dictionary = _docs.change(uri, String(last.get("text", "")),
		int(document.get("version", 0)))
	if not _taken(uri, got):
		return
	_docs.wait(String(got["path"]), DIAGNOSTIC_POLLS)


func _did_save(params: Dictionary) -> void:
	var uri: String = String(_document_of(params).get("uri", ""))
	var got: Dictionary = _Documents.path_of(uri)
	if not _taken(uri, got):
		return
	if _docs.is_open(String(got["path"])):
		_docs.wait(String(got["path"]), DIAGNOSTIC_AT_ONCE, true)


## Closing drops the overlay, so the file goes back to being served from disk, and
## clears what was published about it. A red squiggle left on a file nobody is
## looking at any more is the complaint every language server gets.
func _did_close(params: Dictionary) -> void:
	var uri: String = String(_document_of(params).get("uri", ""))
	var got: Dictionary = _Documents.path_of(uri)
	if not _taken(uri, got):
		return
	var path: String = String(got["path"])
	var was_open: bool = _docs.is_open(path)
	_docs.close(uri)
	if was_open:
		_push("textDocument/publishDiagnostics", {"uri": uri, "diagnostics": []})


func _document_of(params: Dictionary) -> Dictionary:
	return params["textDocument"] if params.get("textDocument", null) is Dictionary else {}


## Whether a notification named a document GATE serves. A notification has no id to
## answer against, so the reason goes to the client's own log rather than to
## Godot's Output panel: a misconfigured client sending every open file would
## otherwise fill the panel with GATE's name for something that is not GATE's
## doing.
func _taken(uri: String, got: Dictionary) -> bool:
	if String(got.get("fault", "")) == "":
		return true
	_tell_client("%s (from \"%s\")" % [String(got["fault"]), uri])
	return false


func _tell_client(message: String) -> void:
	_push("window/logMessage", {"type": LOG_ERROR, "message": "[GATE] " + message})


## One poll of the publish countdown. Usually nothing is waiting.
func _publish_due() -> void:
	if _closing or _shutting_down:
		return
	for path in _docs.step():
		_publish(String(path))


func _publish(path: String) -> void:
	if not _docs.is_open(path):
		return
	var uri: String = _docs.uri_of(path)
	_push("textDocument/publishDiagnostics", {
		"uri": uri,
		"version": _docs.version_of(path),
		"diagnostics": _Diagnostics.of_text(_docs.text_of(path), path, uri, _encoding,
			_docs.take_full(path)),
	})


func _push(method: String, params: Dictionary) -> void:
	if _peer == null:
		return
	_tx.append_array(_Protocol.frame(JSON.stringify(_Protocol.notification_of(method, params))))


func _offered_encodings(params: Dictionary) -> Variant:
	var capabilities: Dictionary = params["capabilities"] if params.get("capabilities", null) is Dictionary else {}
	var general: Dictionary = capabilities["general"] if capabilities.get("general", null) is Dictionary else {}
	return general.get("positionEncodings", [])


func _plugin_version() -> String:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load("res://addons/gate/plugin.cfg") != OK:
		return ""
	return String(cfg.get_value("plugin", "version", ""))

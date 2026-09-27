@tool
extends RefCounted

## LSP's `Content-Length` framing and the JSON-RPC 2.0 envelope.

const VERSION: String = "2.0"

## A frame is parsed and answered inside one editor frame, and the cost is linear
## in its size. Nothing a language client legitimately sends is bigger than a
## source file.
const MAX_CONTENT_LENGTH: int = 1048576

const PARSE_ERROR: int = -32700
const INVALID_REQUEST: int = -32600
const METHOD_NOT_FOUND: int = -32601
const INVALID_PARAMS: int = -32602
const INTERNAL_ERROR: int = -32603
const SERVER_NOT_INITIALIZED: int = -32002
const UNKNOWN_ERROR_CODE: int = -32001

const _CR: int = 13
const _LF: int = 10


## One connection's incoming bytes. Fed whatever a poll read, asked for whole
## messages until it has none, and closed by the caller once `fault` is set.
class _Reader extends RefCounted:

	## Why this connection cannot continue. Empty while the stream makes sense.
	var fault: String = ""

	var _buf: PackedByteArray = PackedByteArray()

	func feed(bytes: PackedByteArray) -> void:
		_buf.append_array(bytes)

	func reset() -> void:
		_buf = PackedByteArray()
		fault = ""

	func buffered() -> int:
		return _buf.size()

	## The next whole message, or "" when the rest of it has not arrived.
	func next_body() -> String:
		if fault != "":
			return ""
		var end: int = _header_end()
		if end < 0:
			return ""
		var length: int = _content_length(_buf.slice(0, end).get_string_from_utf8())
		if length < 0:
			return ""
		var start: int = end + 4
		if _buf.size() - start < length:
			return ""
		var body: String = _buf.slice(start, start + length).get_string_from_utf8()
		_buf = _buf.slice(start + length)
		return body

	func _header_end() -> int:
		var i: int = 0
		while i + 3 < _buf.size():
			if _buf[i] == _CR and _buf[i + 1] == _LF and _buf[i + 2] == _CR and _buf[i + 3] == _LF:
				return i
			i += 1
		return -1

	## Content-Type and anything else a client sends is ignored. A missing or
	## oversized Content-Length sets `fault`, because neither can be recovered
	## from: the stream can no longer be cut into messages.
	func _content_length(header: String) -> int:
		var length: int = -1
		for line in header.split("\r\n"):
			var at: int = line.find(":")
			if at < 0:
				continue
			if line.substr(0, at).strip_edges().to_lower() != "content-length":
				continue
			var value: String = line.substr(at + 1).strip_edges()
			if not value.is_valid_int():
				fault = "a frame announced a Content-Length that is not a number: %s" % value
				return -1
			length = int(value)
		if length < 0:
			fault = "a frame arrived with no Content-Length header"
			return -1
		if length > MAX_CONTENT_LENGTH:
			fault = "a frame announced %d bytes, over the %d byte cap" % [length, MAX_CONTENT_LENGTH]
			return -1
		return length


## The header counts bytes, so a body with anything outside ASCII in it is longer
## than its own `length()`.
static func frame(body: String) -> PackedByteArray:
	var bytes: PackedByteArray = body.to_utf8_buffer()
	var out: PackedByteArray = ("Content-Length: %d\r\n\r\n" % bytes.size()).to_utf8_buffer()
	out.append_array(bytes)
	return out


static func result(id: Variant, value: Variant) -> Dictionary:
	return {"jsonrpc": VERSION, "id": id, "result": value}


## A message the server sends of its own accord. It carries no id, so the client
## never answers it.
static func notification_of(method: String, params: Variant) -> Dictionary:
	return {"jsonrpc": VERSION, "method": method, "params": params}


static func failure(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": VERSION, "id": id, "error": {"code": code, "message": message}}


## What is wrong with the envelope, in a sentence, or "" when nothing is.
static func envelope_fault(msg: Dictionary) -> String:
	if String(msg.get("jsonrpc", "")) != VERSION:
		return "a message must carry \"jsonrpc\": \"%s\"" % VERSION
	if typeof(msg.get("method", null)) != TYPE_STRING:
		return "a message must carry a method name"
	if msg.has("id"):
		var kind: int = typeof(msg["id"])
		if kind != TYPE_STRING and kind != TYPE_INT and kind != TYPE_FLOAT:
			return "an id must be a string or a number"
	return ""

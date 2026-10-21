extends Node
## The City Invaders server on VGData (server/README.md): Bah's AI chat,
## feedback reports from the players and shared mods. Where it lives and the
## public client key come from res://assets/online.json; this install's id
## (no personal data) is kept in user://online.json. Every call is
## asynchronous and ends in its callback - the game never waits on it.

const CONFIG := "res://assets/online.json"
const STATE := "user://online.json"

var base := ""
var key := ""
var session_id := ""
var conversation_id := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if FileAccess.file_exists(CONFIG):
		var c = JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
		if c is Dictionary:
			base = String(c.get("base", "")).trim_suffix("/")
			key = String(c.get("game_key", ""))
	if OS.get_environment("CITY_INVADERS_API") != "":
		base = OS.get_environment("CITY_INVADERS_API").trim_suffix("/")     # a local server, for testing
	if FileAccess.file_exists(STATE):
		var s = JSON.parse_string(FileAccess.get_file_as_string(STATE))
		if s is Dictionary:
			session_id = String(s.get("session_id", ""))
	if session_id == "":
		session_id = _uuid()
		var f := FileAccess.open(STATE, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify({"session_id": session_id}))


func enabled() -> bool:
	return base != ""


func version() -> String:
	var v := String(ProjectSettings.get_setting("application/config/version", ""))
	return v if v != "" else "dev"


## Bah: `done` gets (reply: String, ok: bool). The conversation goes on until
## the game restarts.
func chat(message: String, context: Dictionary, done: Callable) -> void:
	var body := {"session_id": session_id, "message": message.left(500), "lang": "pt-BR", "context": context}
	if conversation_id != "":
		body["conversation_id"] = conversation_id
	_post("/api/bah/chat", body, func(code: int, data: Dictionary):
		if code == 200:
			conversation_id = String(data.get("conversation_id", conversation_id))
			done.call(String(data.get("reply", "")), true)
		else:
			done.call(_why(code, data), false))


## A bug or an idea from the player: `done` gets (ok: bool, text: String).
func report(kind: String, text: String, extra: Dictionary, screenshot_png: PackedByteArray, done: Callable) -> void:
	var body := {"session_id": session_id, "kind": kind, "text": text.left(4000), "game_version": version(),
			"os": "%s %s" % [OS.get_name(), OS.get_version()]}
	body.merge(extra)
	if not screenshot_png.is_empty() and screenshot_png.size() < 3_000_000:
		body["screenshot_png_base64"] = Marshalls.raw_to_base64(screenshot_png)
	_post("/api/feedback", body, func(code: int, data: Dictionary):
		done.call(code == 201, "Thank you! Sent." if code == 201 else _why(code, data)))


## Mods: the published list - `done` gets (items: Array, ok: bool).
func list_mods(done: Callable) -> void:
	_request("/api/mods?limit=100", HTTPClient.METHOD_GET, [], PackedByteArray(), func(code: int, raw: PackedByteArray):
		var data = JSON.parse_string(raw.get_string_from_utf8()) if raw.size() > 0 else {}
		done.call(data.get("items", []) if code == 200 and data is Dictionary else [], code == 200))


## One mod's zip - `done` gets (bytes: PackedByteArray, ok: bool).
func download_mod(id: String, done: Callable) -> void:
	_request("/api/mods/%s/download" % id.uri_encode(), HTTPClient.METHOD_GET, [], PackedByteArray(),
			func(code: int, raw: PackedByteArray): done.call(raw, code == 200))


## Share a mod (a zip): it waits for a review before others see it -
## `done` gets (ok: bool, text: String).
func upload_mod(fields: Dictionary, zip: PackedByteArray, done: Callable) -> void:
	var boundary := "----cityinvaders" + str(randi())
	var body := PackedByteArray()
	fields["session_id"] = session_id
	fields["game_version"] = version()
	for k in fields:
		body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % [boundary, k, str(fields[k])]).to_utf8_buffer())
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"mod.zip\"\r\nContent-Type: application/zip\r\n\r\n" % boundary).to_utf8_buffer())
	body.append_array(zip)
	body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
	_request("/api/mods", HTTPClient.METHOD_POST, ["Content-Type: multipart/form-data; boundary=" + boundary], body,
			func(code: int, raw: PackedByteArray):
				var data = JSON.parse_string(raw.get_string_from_utf8()) if raw.size() > 0 else {}
				done.call(code == 201, "Sent! It shows up for everyone once it is reviewed." if code == 201
						else _why(code, data if data is Dictionary else {})))


func _request(path: String, method: int, headers: Array, body: PackedByteArray, done: Callable) -> void:
	if not enabled():
		done.call(0, PackedByteArray())
		return
	var http := HTTPRequest.new()
	http.timeout = 60.0
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, raw: PackedByteArray):
		http.queue_free()
		done.call(code if result == HTTPRequest.RESULT_SUCCESS else 0, raw))
	var err := http.request_raw(base + path, PackedStringArray(headers + ["X-Game-Key: " + key]), method, body)
	if err != OK:
		http.queue_free()
		done.call(0, PackedByteArray())


func _why(code: int, data: Dictionary) -> String:
	match String(data.get("error", "")):
		"rate_limited":
			return "Too many messages - try again in a few minutes."
		"bah_unavailable", "daily_budget_exhausted":
			return "Bah is resting right now. The quick questions still work."
	if code == 0:
		return "No connection to the server."
	return "The server said no (%d %s)." % [code, String(data.get("message", ""))]


func _post(path: String, body: Dictionary, done: Callable) -> void:
	if not enabled():
		done.call(0, {})
		return
	var http := HTTPRequest.new()
	http.timeout = 30.0
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, raw: PackedByteArray):
		http.queue_free()
		var data = JSON.parse_string(raw.get_string_from_utf8()) if raw.size() > 0 else {}
		done.call(code if result == HTTPRequest.RESULT_SUCCESS else 0, data if data is Dictionary else {}))
	var err := http.request(base + path, ["Content-Type: application/json", "X-Game-Key: " + key],
			HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		done.call(0, {})


static func _uuid() -> String:
	var b := PackedByteArray()
	for i in 16:
		b.append(randi() & 0xff)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]

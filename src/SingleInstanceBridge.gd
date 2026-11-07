class_name PixeloramaSingleInstance
extends Node
## Windows file-open redirection without a TCP request/ACK race.
##
## The primary editor owns a local TCP listening port as an exclusive
## instance marker. Later file-association launches check its recent
## heartbeat, atomically put their paths into a per-user disk inbox, and quit.
## The primary processes the inbox on its normal editor loop. A lost ACK
## cannot cause two processes to open the same file, because there is no ACK.
##
## A queued request stays on disk until the receiver has handled it. If the
## primary closes unexpectedly, the next instance can recover the request.

signal files_received(paths: PackedStringArray, request_path: String)

const HOST := "127.0.0.1"
const PORT_BASE := 42000
const PORT_SPAN := 20000
const HEARTBEAT_A := "user://single_instance_state_a.json"
const HEARTBEAT_B := "user://single_instance_state_b.json"
const INBOX := "user://single_instance_requests"
const HEARTBEAT_INTERVAL_MS := 700
const SCAN_INTERVAL_MS := 100
const RETRY_LISTEN_MS := 2000
const ALIVE_SECONDS := 6.0
const MAX_FILES_PER_REQUEST := 32
const MAX_REQUEST_BYTES := 32768
const FORWARDABLE_EXTENSIONS := [
	"pxo", "ase", "aseprite", "ora", "kra", "psd", "piskel",
	"png", "apng", "jpg", "jpeg", "webp", "bmp", "gif", "tga", "svg"
]

var _server := TCPServer.new()
var _owner := ""
var _heartbeat_slot := 0
var _next_heartbeat_ms := 0
var _next_scan_ms := 0
var _next_listen_attempt_ms := 0
var _in_flight: Dictionary[String, bool] = {}


static func _port() -> int:
	var hash_prefix := OS.get_user_data_dir().md5_text().substr(0, 4)
	return PORT_BASE + hash_prefix.hex_to_int() % PORT_SPAN


static func can_forward_file(path: String) -> bool:
	return FileAccess.file_exists(path) and path.get_extension().to_lower() in FORWARDABLE_EXTENSIONS


static func _absolute(path: String) -> String:
	return ProjectSettings.globalize_path(path)


static func _read_state() -> Dictionary:
	var newest := {}
	for state_file in [HEARTBEAT_A, HEARTBEAT_B]:
		if not FileAccess.file_exists(state_file):
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(state_file))
		if not parsed is Dictionary:
			continue
		var saved_time: Variant = parsed.get("time", 0.0)
		if not saved_time is float and not saved_time is int:
			continue
		if float(saved_time) > float(newest.get("time", 0.0)):
			newest = parsed
	return newest


func _write_heartbeat() -> bool:
	if _owner.is_empty():
		return false
	var path := HEARTBEAT_A if _heartbeat_slot == 0 else HEARTBEAT_B
	_heartbeat_slot = 1 - _heartbeat_slot
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Pixelorama file-open bridge: cannot update instance heartbeat")
		return false
	file.store_string(JSON.stringify({
		"owner": _owner,
		"pid": OS.get_process_id(),
		"time": Time.get_unix_time_from_system()
	}))
	file.flush()
	file.close()
	_next_heartbeat_ms = Time.get_ticks_msec() + HEARTBEAT_INTERVAL_MS
	return true


func start_listening() -> bool:
	if OS.get_name() != "Windows" or not Global.open_files_in_existing_window:
		return false
	if _server.is_listening():
		return true
	_next_listen_attempt_ms = Time.get_ticks_msec() + RETRY_LISTEN_MS
	if _server.listen(_port(), HOST) != OK:
		return false
	_owner = "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	# Both slots are initialized so readers can safely use the other one
	# while a heartbeat write is in progress.
	if not _write_heartbeat() or not _write_heartbeat():
		stop_listening()
		return false
	if not DirAccess.dir_exists_absolute(_absolute(INBOX)):
		if DirAccess.make_dir_recursive_absolute(_absolute(INBOX)) != OK:
			stop_listening()
			return false
	_next_scan_ms = 0
	return true


func stop_listening() -> void:
	_server.stop()
	if _owner.is_empty():
		return
	for path in [HEARTBEAT_A, HEARTBEAT_B]:
		if not FileAccess.file_exists(path):
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and parsed.get("owner", "") == _owner:
			DirAccess.remove_absolute(_absolute(path))
	_owner = ""


func _exit_tree() -> void:
	stop_listening()


## This runs synchronously at the beginning of Main._ready, before any
## brush/UI setup. Only return true when a durable request has been written.
## If the first editor vanished, the request stays on disk for recovery.
func forward_files(files: PackedStringArray) -> bool:
	if files.is_empty() or files.size() > MAX_FILES_PER_REQUEST:
		return false
	if _server.is_listening():
		return false
	for path in files:
		if not can_forward_file(path):
			return false
	var state := _read_state()
	if str(state.get("owner", "")).is_empty():
		return false
	if int(state.get("pid", 0)) == OS.get_process_id():
		return false
	var age := Time.get_unix_time_from_system() - float(state.get("time", 0.0))
	if age < 0.0 or age > ALIVE_SECONDS:
		return false
	if not DirAccess.dir_exists_absolute(_absolute(INBOX)):
		if DirAccess.make_dir_recursive_absolute(_absolute(INBOX)) != OK:
			return false

	var payload := JSON.stringify({"files": Array(files)})
	if payload.to_utf8_buffer().size() > MAX_REQUEST_BYTES:
		return false
	var id := "request-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var final_path := INBOX.path_join(id + ".json")
	var temp_path := INBOX.path_join(id + ".tmp")
	var output := FileAccess.open(temp_path, FileAccess.WRITE)
	if output == null:
		return false
	output.store_string(payload)
	output.flush()
	output.close()
	var result := DirAccess.rename_absolute(_absolute(temp_path), _absolute(final_path))
	if result != OK:
		DirAccess.remove_absolute(_absolute(temp_path))
		return false
	return true


func _process(_delta: float) -> void:
	if OS.get_name() != "Windows":
		return
	if not Global.open_files_in_existing_window:
		if _server.is_listening():
			stop_listening()
		return
	if not _server.is_listening():
		if Time.get_ticks_msec() >= _next_listen_attempt_ms:
			start_listening()
		return
	var now := Time.get_ticks_msec()
	if now >= _next_heartbeat_ms:
		_write_heartbeat()
	if now >= _next_scan_ms:
		_next_scan_ms = now + SCAN_INTERVAL_MS
		_scan_requests()


func _scan_requests() -> void:
	if not DirAccess.dir_exists_absolute(_absolute(INBOX)):
		return
	for filename in DirAccess.get_files_at(_absolute(INBOX)):
		if not filename.begins_with("request-") or not filename.ends_with(".json"):
			continue
		var request_path := INBOX.path_join(filename)
		if _in_flight.has(request_path):
			continue
		var raw := FileAccess.get_file_as_string(request_path)
		if raw.to_utf8_buffer().size() > MAX_REQUEST_BYTES:
			DirAccess.remove_absolute(_absolute(request_path))
			continue
		var decoded: Variant = JSON.parse_string(raw)
		var paths := _validated_paths(decoded)
		if paths.is_empty():
			DirAccess.remove_absolute(_absolute(request_path))
			continue
		_in_flight[request_path] = true
		files_received.emit(paths, request_path)


func _validated_paths(decoded: Variant) -> PackedStringArray:
	var result := PackedStringArray()
	if not decoded is Dictionary:
		return result
	var files: Variant = decoded.get("files", [])
	if not files is Array or files.is_empty() or files.size() > MAX_FILES_PER_REQUEST:
		return result
	for path in files:
		if not path is String or not can_forward_file(path):
			return PackedStringArray()
		result.append(path)
	return result


## Called only after the editor has dispatched the request for opening.
func finish_request(request_path: String) -> void:
	if not _in_flight.has(request_path):
		return
	var error := DirAccess.remove_absolute(_absolute(request_path))
	if error == OK:
		_in_flight.erase(request_path)
	else:
		# Do not reopen a failed-to-delete request during this process.
		# It remains recoverable on disk after a future restart.
		push_warning("Pixelorama file-open bridge: could not remove processed request")

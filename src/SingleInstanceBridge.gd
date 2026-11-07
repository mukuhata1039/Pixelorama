class_name PixeloramaSingleInstance
extends Node
## Small Windows-only loopback bridge. The first running editor owns the
## listener; later launches forward files and exit only after an explicit ACK.
## A failed connection must NEVER prevent the new process from opening files.

signal files_received(paths: PackedStringArray)

const HOST := "127.0.0.1"
## Isolate different Windows accounts instead of sharing a system-wide port.
## Hashing the user-data directory also reduces collisions with other apps.
const PORT_BASE := 42000
const PORT_SPAN := 20000
const PROTOCOL := "pixelorama-open-files-v1"
const ACK := "pixelorama-open-accepted-v1\n"
const MAX_MESSAGE_BYTES := 32768
const MAX_CLIENTS := 8
const FORWARD_TIMEOUT_MS := 1300
const CLIENT_TIMEOUT_MS := 3000
const ACK_GRACE_MS := 350
const RETRY_LISTEN_MS := 2000
const FORWARDABLE_EXTENSIONS := [
	"pxo", "ase", "aseprite", "ora", "kra", "psd", "piskel",
	"png", "apng", "jpg", "jpeg", "webp", "bmp", "gif", "tga", "svg"
]

var _server := TCPServer.new()
var _clients: Array[Dictionary] = []
var _next_listen_attempt_ms := 0


static func _port() -> int:
	var hash_prefix := OS.get_user_data_dir().md5_text().substr(0, 4)
	return PORT_BASE + hash_prefix.hex_to_int() % PORT_SPAN


static func can_forward_file(path: String) -> bool:
	return FileAccess.file_exists(path) and path.get_extension().to_lower() in FORWARDABLE_EXTENSIONS


func start_listening() -> bool:
	if OS.get_name() != "Windows" or not Global.open_files_in_existing_window:
		return false
	if _server.is_listening():
		return true
	_next_listen_attempt_ms = Time.get_ticks_msec() + RETRY_LISTEN_MS
	var error := _server.listen(_port(), HOST)
	if error == OK:
		return true
	# A bound port usually means a previous instance is running. The caller
	# attempts a handshake and falls back to opening normally if it fails.
	return false


func stop_listening() -> void:
	_server.stop()
	for client in _clients:
		var peer: StreamPeerTCP = client["peer"]
		peer.disconnect_from_host()
	_clients.clear()


func _exit_tree() -> void:
	stop_listening()


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

	# Accept only a bounded number of local clients. Never read sockets in a
	# blocking fashion; a slow or broken launch must not stall the editor.
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if not is_instance_valid(peer):
			break
		if _clients.size() >= MAX_CLIENTS:
			peer.disconnect_from_host()
			continue
		peer.set_no_delay(true)
		_clients.append({
			"peer": peer,
			"bytes": PackedByteArray(),
			"deadline": Time.get_ticks_msec() + CLIENT_TIMEOUT_MS,
			"responded": false
		})

	for i in range(_clients.size() - 1, -1, -1):
		var client: Dictionary = _clients[i]
		var peer: StreamPeerTCP = client["peer"]
		peer.poll()
		if (
			peer.get_status() != StreamPeerTCP.STATUS_CONNECTED
			or Time.get_ticks_msec() > int(client["deadline"])
		):
			peer.disconnect_from_host()
			_clients.remove_at(i)
			continue
		# Keep a successfully answered socket alive briefly so the client can
		# read the acknowledgement before the connection is closed.
		if client["responded"]:
			continue
		var data: PackedByteArray = client["bytes"]
		var byte_count := peer.get_available_bytes()
		if byte_count == 0:
			continue
		if byte_count > MAX_MESSAGE_BYTES - data.size():
			peer.disconnect_from_host()
			_clients.remove_at(i)
			continue
		var received := peer.get_data(byte_count)
		if received[0] != OK:
			peer.disconnect_from_host()
			_clients.remove_at(i)
			continue
		data.append_array(received[1])
		client["bytes"] = data
		if data.find(10) == -1:
			continue
		var line := data.get_string_from_utf8().get_slice("\n", 0)
		var decoded: Variant = JSON.parse_string(line)
		var paths := _validate_request(decoded)
		if not paths.is_empty():
			# The secondary quits only when it receives this positive ACK.
			# Rejecting invalid paths leaves the original launch intact.
			if peer.put_data(ACK.to_utf8_buffer()) == OK:
				files_received.emit(paths)
				client["responded"] = true
				client["deadline"] = Time.get_ticks_msec() + ACK_GRACE_MS
				continue
		peer.disconnect_from_host()
		_clients.remove_at(i)


func _validate_request(decoded: Variant) -> PackedStringArray:
	var paths := PackedStringArray()
	if not decoded is Dictionary or decoded.get("protocol", "") != PROTOCOL:
		return paths
	var sent_files: Variant = decoded.get("files")
	if not sent_files is Array or sent_files.is_empty() or sent_files.size() > 32:
		return paths
	for file in sent_files:
		if not file is String or not can_forward_file(file):
			return PackedStringArray()
		paths.append(file)
	return paths


## Connect, send, and wait for an ACK using the normal frame loop. Timeout and
## socket failures return false so the second editor can open its files itself.
func forward_files(files: PackedStringArray) -> bool:
	if files.is_empty() or files.size() > 32:
		return false
	var items: Array[String] = []
	for file in files:
		if not can_forward_file(file):
			return false
		items.append(file)
	var payload := (JSON.stringify({"protocol": PROTOCOL, "files": items}) + "\n").to_utf8_buffer()
	if payload.size() > MAX_MESSAGE_BYTES:
		return false
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(HOST, _port()) != OK:
		return false
	peer.set_no_delay(true)
	var sent := false
	var reply := PackedByteArray()
	var deadline := Time.get_ticks_msec() + FORWARD_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			if not sent:
				if peer.put_data(payload) != OK:
					break
				sent = true
			var count := peer.get_available_bytes()
			if count > 0:
				var chunk := peer.get_data(mini(count, 128))
				if chunk[0] != OK:
					break
				reply.append_array(chunk[1])
				if reply.get_string_from_utf8().contains(ACK):
					peer.disconnect_from_host()
					return true
				if reply.size() >= 128:
					break
		elif status != StreamPeerTCP.STATUS_CONNECTING:
			break
		await get_tree().process_frame
	peer.disconnect_from_host()
	return false

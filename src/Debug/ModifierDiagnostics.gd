extends Node

## Opt-in Ctrl/Alt/Shift/Tab input trace. No input is modified, consumed or injected.
## Enable via: Pixelorama.exe -- --modifier-diagnostics
## Optionally set PXO_MODIFIER_DIAG_DIR to share an output directory with a Windows probe.

const DEFAULT_DIRECTORY := "user://modifier_diagnostics"
const ENV_DIRECTORY := "PXO_MODIFIER_DIAG_DIR"
const WATCHED_KEYS := [KEY_CTRL, KEY_ALT, KEY_SHIFT, KEY_META, KEY_TAB]

var _file: FileAccess
var _last_state := ""
var _next_heartbeat_msec := 0
var _refocus_sample_ticks: Array[int] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var directory := OS.get_environment(ENV_DIRECTORY)
	if directory.is_empty():
		directory = ProjectSettings.globalize_path(DEFAULT_DIRECTORY)
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		push_warning("Modifier diagnostics cannot create directory: %s" % directory)
		set_process(false)
		set_process_input(false)
		return
	var timestamp := Time.get_datetime_string_from_system(true).replace(":", "-").replace("T", "_")
	var file_path := directory.path_join(
		"godot_modifiers_%s_%s.log" % [timestamp, Time.get_ticks_msec()]
	)
	_file = FileAccess.open(file_path, FileAccess.WRITE)
	if _file == null:
		push_warning("Modifier diagnostics cannot open log: %s" % file_path)
		set_process(false)
		set_process_input(false)
		return
	_write("START Godot=%s platform=%s path=%s" % [
		Engine.get_version_info().get("string", "unknown"), OS.get_name(), file_path
	])
	_sample("START")
	_next_heartbeat_msec = Time.get_ticks_msec() + 1000


func _input(event: InputEvent) -> void:
	if _file == null or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if (
		key_event.keycode not in WATCHED_KEYS
		and key_event.physical_keycode not in WATCHED_KEYS
	):
		return
	_write(
		"KEY keycode=%s physical=%s pressed=%s echo=%s event_ctrl=%s event_alt=%s event_shift=%s event_meta=%s" %
		[
			key_event.keycode, key_event.physical_keycode, key_event.pressed, key_event.echo,
			key_event.ctrl_pressed, key_event.alt_pressed, key_event.shift_pressed,
			key_event.meta_pressed
		]
	)
	_sample("AFTER_KEY_EVENT")


func _notification(what: int) -> void:
	if _file == null:
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_sample("FOCUS_OUT")
		_refocus_sample_ticks.clear()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_sample("FOCUS_IN")
		var now := Time.get_ticks_msec()
		for delay_msec in [100, 250, 500, 1000, 2000]:
			_refocus_sample_ticks.append(now + delay_msec)


func _process(_delta: float) -> void:
	if _file == null:
		return
	var state := _get_state()
	if state != _last_state:
		_sample("STATE_CHANGED")
	var now := Time.get_ticks_msec()
	while not _refocus_sample_ticks.is_empty() and now >= _refocus_sample_ticks[0]:
		_refocus_sample_ticks.pop_front()
		_sample("AFTER_FOCUS_IN")
	if now >= _next_heartbeat_msec:
		_sample("HEARTBEAT")
		_next_heartbeat_msec = now + 1000


func _get_state() -> String:
	return (
		"focus=%s ctrl=%s alt=%s shift=%s meta=%s tab=%s action_ctrl=%s action_shift=%s"
		% [
			get_window().has_focus(),
			Input.is_key_pressed(KEY_CTRL),
			Input.is_key_pressed(KEY_ALT),
			Input.is_key_pressed(KEY_SHIFT),
			Input.is_key_pressed(KEY_META),
			Input.is_key_pressed(KEY_TAB),
			Input.is_action_pressed(&"ctrl"),
			Input.is_action_pressed(&"shift"),
		]
	)


func _sample(reason: String) -> void:
	var state := _get_state()
	_last_state = state
	_write("%s %s" % [reason, state])


func _write(message: String) -> void:
	if _file == null:
		return
	_file.store_line("%s ticks=%s %s" % [
		Time.get_datetime_string_from_system(true), Time.get_ticks_msec(), message
	])
	_file.flush()


func _exit_tree() -> void:
	if _file != null:
		_write("STOP")
		_file.close()
		_file = null

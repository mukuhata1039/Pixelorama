extends Node

## Windows Ctrl+Alt+Tab may deliver Ctrl/Alt down events *after* focus out.
## If their key-up events go to the task switcher, Godot can retain both as
## pressed after focus returns. The normal focus-out input clear is too early.
## Only reconcile modifiers that were pressed after the focus-out notification,
## and only if they are still stuck shortly after focus returns.
const REFOCUS_SETTLE_MSEC := 120

var _lost_focus := false
var _late_modifier_down: Dictionary = {}
var _recover_after_msec := -1


func _ready() -> void:
	# Input and recovery must keep running even when "pause when unfocused"
	# pauses the scene tree. Otherwise late key-down events are missed.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_lost_focus = true
			_late_modifier_down.clear()
			_recover_after_msec = -1
		NOTIFICATION_APPLICATION_FOCUS_IN:
			if _lost_focus:
				_recover_after_msec = Time.get_ticks_msec() + REFOCUS_SETTLE_MSEC


func _input(event: InputEvent) -> void:
	if not _lost_focus or _recover_after_msec >= 0 or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	var key := key_event.keycode
	if key != KEY_CTRL and key != KEY_ALT:
		key = key_event.physical_keycode
	if key != KEY_CTRL and key != KEY_ALT:
		return
	if key_event.pressed and not key_event.echo:
		_late_modifier_down[key] = true
	elif not key_event.pressed:
		_late_modifier_down.erase(key)


func _process(_delta: float) -> void:
	if _recover_after_msec < 0 or Time.get_ticks_msec() < _recover_after_msec:
		return
	if not get_window().has_focus():
		return

	_recover_after_msec = -1
	_lost_focus = false
	for key in [KEY_CTRL, KEY_ALT]:
		# Ordinary Alt+Tab and genuinely released modifiers need no action.
		# Never clear unrelated keys, mouse buttons, or normal shortcuts.
		if not _late_modifier_down.has(key) or not Input.is_key_pressed(key):
			continue
		var release_event := InputEventKey.new()
		release_event.keycode = key
		release_event.physical_keycode = key
		release_event.pressed = false
		Input.parse_input_event(release_event)
		print("Recovered stale modifier after focus switch: ", "Ctrl" if key == KEY_CTRL else "Alt")
	_late_modifier_down.clear()

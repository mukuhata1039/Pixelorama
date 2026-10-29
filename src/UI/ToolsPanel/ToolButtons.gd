extends FlowContainer

var pen_inverted := false
var _navigation_tool := ""


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		pen_inverted = event.pen_inverted
		return
	if not Global.can_draw:
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	if get_tree().current_scene.is_writing_text:
		return
	if _handle_space_alt_quick_navigation(event):
		return
	# A remapped rotation chord such as R should take priority over
	# tool-selection shortcuts bound to the same key while held.
	if Tools.is_keyboard_shortcut_held(&"canvas_rotate_drag"):
		return
	# When the quick picker shortcut itself is a right click, the canvas
	# samples directly from the sprite. Never run the later generic tool
	# swap for that same physical mouse event.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		for shortcut_event in InputMap.action_get_events(&"quick_colorpicker_tool"):
			if not shortcut_event is InputEventMouseButton:
				continue
			var binding := shortcut_event as InputEventMouseButton
			if (
				binding.button_index == MOUSE_BUTTON_RIGHT
				and binding.alt_pressed == event.alt_pressed
				and binding.shift_pressed == event.shift_pressed
				and binding.ctrl_pressed == event.ctrl_pressed
				and binding.meta_pressed == event.meta_pressed
			):
				return
	var tool_activated := Tools.active_multi_state_tools > 0

	for tool_name in Tools.tools:  # Handle tool shortcuts
		if not get_node(tool_name).visible:
			continue
		var t: Tools.Tool = Tools.tools[tool_name]
		var right_tool_shortcut := "right_" + t.shortcut + "_tool"
		if not Global.single_tool_mode and InputMap.has_action(right_tool_shortcut):
			if event.is_action_pressed(right_tool_shortcut, false, true):
				# All tools sharing this key cycle in their registration order.
				_assign_cycled_tool(event, MOUSE_BUTTON_RIGHT)
				return
		var left_tool_shortcut := "left_" + t.shortcut + "_tool"
		if InputMap.has_action(left_tool_shortcut):
			if event.is_action_pressed(left_tool_shortcut, false, true):
				_assign_cycled_tool(event, MOUSE_BUTTON_LEFT)
				return

		var quick_tool_shortcut := "quick_" + t.shortcut + "_tool"
		if InputMap.has_action(quick_tool_shortcut) and not Tools.selection_tool_has_selection():
			if event.is_action_pressed(quick_tool_shortcut, false, true) and not tool_activated:
				Tools.quick_assign_tool(t.name, MOUSE_BUTTON_LEFT)
				Tools.quick_assign_tool(t.name, MOUSE_BUTTON_RIGHT)
				return
			if event.is_action_released(quick_tool_shortcut):
				Tools.quick_assign_tool_revert(MOUSE_BUTTON_RIGHT)
				Tools.quick_assign_tool_revert(MOUSE_BUTTON_LEFT)
				return


## Collect all visible tools whose shortcut matches this event. A single
## match behaves as before; multiple matches cycle from the current tool.
## This needs no separate cycle state, so toolbar clicks and other shortcuts
## immediately establish the correct next tool.
func _assign_cycled_tool(event: InputEvent, button: MouseButton) -> void:
	var matches: Array[String] = []
	var prefix := "right_" if button == MOUSE_BUTTON_RIGHT else "left_"
	for tool_name in Tools.tools:
		if not get_node(tool_name).visible:
			continue
		var action: StringName = prefix + Tools.tools[tool_name].shortcut + "_tool"
		if InputMap.has_action(action) and event.is_action_pressed(action, false, true):
			matches.append(tool_name)
	if matches.is_empty():
		return
	# Keyboard auto-repeat must not cycle a held key repeatedly.
	if matches.size() > 1 and event is InputEventKey:
		if (event as InputEventKey).echo:
			return
	var target := matches[0]
	if matches.size() > 1:
		var active_button := MOUSE_BUTTON_RIGHT if Global.single_tool_mode else button
		var current_tool := Tools.get_tool(active_button).tool_node.name
		var current_index := matches.find(current_tool)
		if current_index >= 0:
			target = matches[(current_index + 1) % matches.size()]
	Tools.assign_tool(target, button)
	Tools.prev_tool_names[button] = ""


## Periodically reconcile quick-navigation tools against actual held keys.
## Godot can consume Alt-up in menu/GUI handling before _unhandled_input,
## so relying solely on stored key-down/key-up events leaves Zoom stuck.
func _process(_delta: float) -> void:
	if not Global.pixelorama_has_loaded:
		return
	if not Tools.has_space_alt_quick_navigation():
		if not _navigation_tool.is_empty():
			_restore_quick_navigation_tool()
		return
	_sync_space_alt_quick_navigation()


func _is_quick_navigation_blocked() -> bool:
	var focused := get_viewport().gui_get_focus_owner()
	return (
		not get_window().has_focus()
		or not Global.can_draw
		or get_tree().current_scene.is_writing_text
		or focused is LineEdit
		or focused is TextEdit
	)


## Update immediately for normal key events; _process also runs this
## so missed modifier releases and focus changes never leave Zoom selected.
func _handle_space_alt_quick_navigation(event: InputEvent) -> bool:
	if not Tools.has_space_alt_quick_navigation() or not event is InputEventKey:
		return false
	var key_event := event as InputEventKey
	if key_event.echo:
		return false
	if (
		key_event.keycode not in [KEY_SPACE, KEY_ALT, KEY_SHIFT]
		and key_event.physical_keycode not in [KEY_SPACE, KEY_ALT, KEY_SHIFT]
	):
		return false
	var old_tool := _navigation_tool
	_sync_space_alt_quick_navigation()
	return old_tool != _navigation_tool or not _navigation_tool.is_empty()


func _sync_space_alt_quick_navigation() -> void:
	var blocked := _is_quick_navigation_blocked()
	var space_down := not blocked and Input.is_key_pressed(KEY_SPACE)
	var alt_down := not blocked and Input.is_key_pressed(KEY_ALT)
	var rotating := not blocked and Tools.is_keyboard_shortcut_held(&"canvas_rotate_drag")
	var wanted_tool := ""
	if rotating:
		pass  # Camera takes priority over quick Pan/Zoom.
	elif space_down:
		wanted_tool = "Zoom" if alt_down else "Pan"
	elif (
		alt_down
		and Tools.has_keyboard_quick_shortcut(&"quick_colorpicker_tool", KEY_ALT, false)
	):
		wanted_tool = "ColorPicker"

	if wanted_tool == _navigation_tool:
		return

	# Do not interrupt a stroke that was already active when navigation began.
	if wanted_tool != "" and _navigation_tool.is_empty() and Tools.active_button != -1:
		return

	if _navigation_tool == "Pan" or _navigation_tool == "Zoom":
		if Tools.active_button != -1:
			Tools.get_tool(Tools.active_button).tool_node.draw_end(Vector2i.ZERO)
			Tools.active_button = -1
		if _navigation_tool == "Pan":
			for camera: CanvasCamera in get_tree().get_nodes_in_group("CanvasCameras"):
				camera.drag = false

	if wanted_tool.is_empty():
		_restore_quick_navigation_tool()
	else:
		Tools.quick_assign_tool(wanted_tool, MOUSE_BUTTON_LEFT)
		Tools.quick_assign_tool(wanted_tool, MOUSE_BUTTON_RIGHT)
		_navigation_tool = wanted_tool


func _restore_quick_navigation_tool() -> void:
	if _navigation_tool.is_empty():
		return
	if _navigation_tool == "Pan" or _navigation_tool == "Zoom":
		if Tools.active_button != -1:
			Tools.get_tool(Tools.active_button).tool_node.draw_end(Vector2i.ZERO)
			Tools.active_button = -1
		for camera: CanvasCamera in get_tree().get_nodes_in_group("CanvasCameras"):
			camera.drag = false
	Tools.quick_assign_tool_revert(MOUSE_BUTTON_RIGHT)
	Tools.quick_assign_tool_revert(MOUSE_BUTTON_LEFT)
	_navigation_tool = ""


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_restore_quick_navigation_tool()


func _on_tool_pressed(tool_pressed: BaseButton) -> void:
	var button := MOUSE_BUTTON_LEFT
	if not Global.single_tool_mode:
		button = (
			MOUSE_BUTTON_RIGHT
			if (
				Input.is_action_just_released("right_mouse")
				or (pen_inverted and Input.is_action_just_released("left_mouse"))
			)
			else button
		)
	if button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		Tools.assign_tool(tool_pressed.name, button)

extends FlowContainer

var pen_inverted := false
var _navigation_space_down := false
var _navigation_alt_down := false
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
	var tool_activated := Tools.active_multi_state_tools > 0

	for tool_name in Tools.tools:  # Handle tool shortcuts
		if not get_node(tool_name).visible:
			continue
		var t: Tools.Tool = Tools.tools[tool_name]
		var right_tool_shortcut := "right_" + t.shortcut + "_tool"
		if not Global.single_tool_mode and InputMap.has_action(right_tool_shortcut):
			if event.is_action_pressed(right_tool_shortcut, false, true):
				# Shortcut for right button (with Alt)
				Tools.assign_tool(t.name, MOUSE_BUTTON_RIGHT)
				Tools.prev_tool_names[MOUSE_BUTTON_RIGHT] = ""
				return
		var left_tool_shortcut := "left_" + t.shortcut + "_tool"
		if InputMap.has_action(left_tool_shortcut):
			if event.is_action_pressed(left_tool_shortcut, false, true):
				# Shortcut for left button
				Tools.assign_tool(t.name, MOUSE_BUTTON_LEFT)
				Tools.prev_tool_names[MOUSE_BUTTON_LEFT] = ""
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


## Handle Space (quick Pan) and Alt+Space (quick Zoom) as held keys, not
## just as a single key-press event. This makes either press order work and
## restores Pan when Alt is released while Space is still held.
func _handle_space_alt_quick_navigation(event: InputEvent) -> bool:
	if not Tools.has_space_alt_quick_navigation() or not event is InputEventKey:
		return false
	var key_event := event as InputEventKey
	if key_event.echo:
		return false
	if key_event.keycode == KEY_SPACE or key_event.physical_keycode == KEY_SPACE:
		_navigation_space_down = key_event.pressed
	elif key_event.keycode == KEY_ALT or key_event.physical_keycode == KEY_ALT:
		_navigation_alt_down = key_event.pressed
	else:
		return false

	var wanted_tool := ""
	if _navigation_space_down:
		wanted_tool = "Zoom" if _navigation_alt_down else "Pan"
	elif (
		_navigation_alt_down
		and Tools.has_keyboard_quick_shortcut(&"quick_colorpicker_tool", KEY_ALT, false)
	):
		wanted_tool = "ColorPicker"

	if wanted_tool == _navigation_tool:
		return not wanted_tool.is_empty()

	# Finish the current navigation drag before replacing its tool node.
	# Otherwise Pan can leave camera.drag enabled when switching to Zoom.
	if _navigation_tool == "Pan" or _navigation_tool == "Zoom":
		if Tools.active_button != -1:
			Tools.get_tool(Tools.active_button).tool_node.draw_end(Vector2i.ZERO)
		if _navigation_tool == "Pan":
			for camera: CanvasCamera in get_tree().get_nodes_in_group("CanvasCameras"):
				camera.drag = false

	if wanted_tool.is_empty():
		Tools.quick_assign_tool_revert(MOUSE_BUTTON_RIGHT)
		Tools.quick_assign_tool_revert(MOUSE_BUTTON_LEFT)
		# Do not start painting if the user releases Space mid-drag.
		if _navigation_tool == "Pan" or _navigation_tool == "Zoom":
			Tools.active_button = -1
	else:
		# Avoid interrupting a paint stroke when no quick tool is active.
		if _navigation_tool.is_empty() and Tools.active_button != -1:
			return true
		Tools.quick_assign_tool(wanted_tool, MOUSE_BUTTON_LEFT)
		Tools.quick_assign_tool(wanted_tool, MOUSE_BUTTON_RIGHT)
		# Switching back to a non-navigation tool must not turn an
		# unfinished Pan/Zoom drag into a painting or color-picking stroke.
		if wanted_tool != "Pan" and wanted_tool != "Zoom":
			if _navigation_tool == "Pan" or _navigation_tool == "Zoom":
				Tools.active_button = -1
	_navigation_tool = wanted_tool
	return true


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_navigation_space_down = false
		_navigation_alt_down = false
		if _navigation_tool == "Pan":
			for camera: CanvasCamera in get_tree().get_nodes_in_group("CanvasCameras"):
				camera.drag = false
		if _navigation_tool == "Pan" or _navigation_tool == "Zoom":
			Tools.active_button = -1
		_navigation_tool = ""


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

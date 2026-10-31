extends Node2D


func _ready() -> void:
	Global.camera.zoom_changed.connect(_update_on_zoom)


func _input(event: InputEvent) -> void:
	if event is InputEventMouse or event is InputEventKey:
		queue_redraw()


func _draw() -> void:
	if Global.can_draw:
		# Layer picking uses the existing change_layer_automatically shortcut.
		# Only hide the brush footprint when this is an actual layer-pick mode;
		# leave the normal mouse cursor and the cel-switch action untouched.
		if (
			Tools.active_button == -1
			and Input.is_action_pressed(&"change_layer_automatically", true)
			and Tools.get_tool(MOUSE_BUTTON_LEFT).tool_node is not BaseSelectionTool
		):
			return
		# Navigation, not painting: hide the active brush footprint and
		# preview while the configurable Rotate View shortcut is held.
		# Also cover captured mouse-button rotation gestures.
		if is_instance_valid(Global.camera) and (
			Global.camera._clipstudio_rotate_drag
			or (
				Tools.active_button == -1
				and Tools.is_keyboard_shortcut_held(&"canvas_rotate_drag")
			)
		):
			return
		Tools.draw_preview()


func _update_on_zoom() -> void:
	material.set_shader_parameter("width", 1.0 / Global.camera.zoom.x)

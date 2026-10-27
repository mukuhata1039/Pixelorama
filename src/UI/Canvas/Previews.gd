extends Node2D


func _ready() -> void:
	Global.camera.zoom_changed.connect(_update_on_zoom)


func _input(event: InputEvent) -> void:
	if event is InputEventMouse or event is InputEventKey:
		queue_redraw()


func _draw() -> void:
	if Global.can_draw:
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

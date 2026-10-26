extends Node2D


func _ready() -> void:
	# Navigation changes the canvas-to-screen transform even when the mouse
	# hasn't moved. Refresh the brush indicator during pan and zoom as well.
	Global.camera.zoom_changed.connect(queue_redraw)
	Global.camera.offset_changed.connect(queue_redraw)
	Global.camera.rotation_changed.connect(queue_redraw)


func _input(event: InputEvent) -> void:
	if event is InputEventMouse or event is InputEventKey:
		queue_redraw()


func _draw() -> void:
	if not Global.can_draw:
		return
	# Canvas intentionally skips tool input during Space navigation. Read the
	# current canvas-space mouse position here instead of drawing with stale
	# tool cursors captured before a camera transform change.
	var pixel := Vector2i(Global.canvas.get_local_mouse_position().floor())
	Tools.get_tool(MOUSE_BUTTON_LEFT).tool_node.cursor_move(pixel)
	Tools.get_tool(MOUSE_BUTTON_RIGHT).tool_node.cursor_move(pixel)
	Tools.draw_indicator()

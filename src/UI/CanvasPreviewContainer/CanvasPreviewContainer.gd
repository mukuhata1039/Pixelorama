extends PanelContainer

@onready var preview_zoom_slider := $VBox/HBox/VBoxContainer/PreviewZoomSlider as VSlider
@onready var preview_viewport_container := $VBox/HBox/PreviewViewportContainer as SubViewportContainer
@onready var canvas_preview := $"%CanvasPreview" as Node2D
@onready var camera := $"%CameraPreview" as CanvasCamera
@onready var play_button := $"%PlayButton" as Button
@onready var start_frame := $"%StartFrame" as ValueSlider
@onready var end_frame := $"%EndFrame" as ValueSlider


func _ready() -> void:
	camera.zoom_changed.connect(_zoom_changed)
	preview_viewport_container.resized.connect(_fit_preview_if_needed)
	visibility_changed.connect(_fit_preview_if_needed)
	Global.project_switched.connect(_fit_preview_if_needed)
	_fit_preview_if_needed.call_deferred()


## Shrink the preview image as its dock becomes narrower, instead of cropping it.
## Leave deliberate user zooms alone until the viewport is resized.
func _fit_preview_if_needed() -> void:
	if not is_visible_in_tree():
		return
	var image_size := Vector2(Global.current_project.size)
	var viewport_size := preview_viewport_container.size
	if (
		image_size.x <= 0.0
		or image_size.y <= 0.0
		or viewport_size.x <= 0.0
		or viewport_size.y <= 0.0
	):
		return
	var fit_zoom := minf(viewport_size.x / image_size.x, viewport_size.y / image_size.y)
	if camera.zoom.x <= fit_zoom:
		return
	# Keep the whole image visible while preserving its aspect ratio.
	var new_zoom := maxf(preview_zoom_slider.min_value, fit_zoom)
	camera.offset = image_size / 2.0
	camera.zoom = Vector2(new_zoom, new_zoom)


func _gui_input(event: InputEvent) -> void:
	var checker: ColorRect = $VBox/HBox/PreviewViewportContainer/SubViewport/TransparentChecker
	if event is InputEventMouseButton:
		var mouse_pos := checker.get_local_mouse_position()
		if (
			mouse_pos.x >= 0
			and mouse_pos.y >= 0
			and mouse_pos.x <= checker.size.x
			and mouse_pos.y <= checker.size.y
		):
			if event.double_click:
				if canvas_preview.mode == canvas_preview.Mode.SPRITESHEET:
					var sprite_sheet_idx = canvas_preview.frame_index
					var x: int = sprite_sheet_idx % canvas_preview.h_frames
					var y: int = sprite_sheet_idx / canvas_preview.v_frames
					mouse_pos += Vector2(x, y) * checker.size
				Global.camera.offset = mouse_pos


func _zoom_changed() -> void:
	preview_zoom_slider.value = camera.zoom.x


func _on_PreviewZoomSlider_value_changed(value: float) -> void:
	camera.zoom = Vector2(value, value)
	camera.update_transparent_checker_offset()


func _on_PlayButton_toggled(button_pressed: bool) -> void:
	if button_pressed:
		if canvas_preview.mode == canvas_preview.Mode.TIMELINE:
			if Global.current_project.frames.size() <= 1:
				play_button.button_pressed = false
				return
		else:
			if start_frame.value == end_frame.value:
				play_button.button_pressed = false
				return
		canvas_preview.animation_timer.start()
		Global.change_button_texturerect(play_button.get_child(0), "pause.png")
	else:
		canvas_preview.animation_timer.stop()
		Global.change_button_texturerect(play_button.get_child(0), "play.png")


func _on_OptionButton_item_selected(index: int) -> void:
	play_button.button_pressed = false
	canvas_preview.mode = index
	if index == 0:
		$VBox/Animation/VBoxContainer/Options.visible = false
		canvas_preview.transparent_checker.fit_rect(
			Rect2(Vector2.ZERO, Global.current_project.size)
		)
	else:
		$VBox/Animation/VBoxContainer/Options.visible = true
	canvas_preview.queue_redraw()


func _on_HFrames_value_changed(value: float) -> void:
	canvas_preview.h_frames = value
	var frames: int = canvas_preview.h_frames * canvas_preview.v_frames
	start_frame.max_value = frames
	end_frame.max_value = frames
	canvas_preview.queue_redraw()


func _on_VFrames_value_changed(value: float) -> void:
	canvas_preview.v_frames = value
	var frames: int = canvas_preview.h_frames * canvas_preview.v_frames
	start_frame.max_value = frames
	end_frame.max_value = frames
	canvas_preview.queue_redraw()


func _on_StartFrame_value_changed(value: float) -> void:
	canvas_preview.frame_index = value - 1
	canvas_preview.start_sprite_sheet_frame = value
	if end_frame.value < value:
		end_frame.value = value
	canvas_preview.queue_redraw()


func _on_EndFrame_value_changed(value: float) -> void:
	canvas_preview.end_sprite_sheet_frame = value
	if start_frame.value > value:
		start_frame.value = value
		canvas_preview.frame_index = value - 1
	canvas_preview.queue_redraw()


func _on_PreviewViewportContainer_mouse_entered() -> void:
	camera.set_process_input(true)


func _on_PreviewViewportContainer_mouse_exited() -> void:
	camera.set_process_input(false)

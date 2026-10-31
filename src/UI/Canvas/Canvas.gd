class_name Canvas
extends Node2D

const CURSOR_SPEED_RATE := 6.0
const LIVE_RECOLOR_SHADER := preload("res://src/Shaders/LiveRecolor.gdshader")

var current_pixel := Vector2.ZERO
var _quick_navigation_captured_left_mouse := false
var _brush_size_drag_captured_left_mouse := false
## One-click sampling when Quick Color Picker is explicitly bound to right mouse.
var _quick_right_color_picker_active := false
var sprite_changed_this_frame := false  ## For optimization purposes
## Diagnostic counters for large-brush performance (draft PR only).
var brush_profile_active := false
var brush_profile_texture_us := 0
var brush_profile_texture_calls := 0
var brush_profile_layers_us := 0
var brush_profile_layers_calls := 0
var update_all_layers := false
## For optimization purposes. A kind of override to force include a layer during canvas update.
## Used in Undo/Redo for FX and visibility changes
var mandatory_update_layers := PackedInt32Array()
var project_changed := false
var move_preview_location := Vector2i.ZERO
var layer_texture_array := Texture2DArray.new()
var layer_metadata_image := Image.new()
var layer_metadata_texture := ImageTexture.new()
## Temporary draw-only color replacement. Never writes to PixelCel.image until Apply.
var live_recolor_project: Project
var live_recolor_targets: Dictionary = {}
var live_recolor_color := Color.BLACK
var live_recolor_enabled := false

@onready var currently_visible_frame := $CurrentlyVisibleFrame as SubViewport
@onready var current_frame_drawer := $CurrentlyVisibleFrame/CurrentFrameDrawer as Node2D
@onready var tile_mode := $TileMode as Node2D
@onready var color_index := $ColorIndex as Node2D
@onready var selection := $Selection as SelectionNode
@onready var onion_past := $OnionPast as Node2D
@onready var onion_future := $OnionFuture as Node2D
@onready var crop_rect := $CropRect as CropRect
@onready var indicators := $Indicators as Node2D
@onready var previews := $Previews as Node2D
@onready var previews_sprite := $PreviewsSprite as Sprite2D
@onready var mouse_guide_container := $MouseGuideContainer as Node2D
@onready var gizmos_3d := $Gizmos3D as Node2D
@onready var measurements := $Measurements as Node2D
@onready var reference_image_container := $ReferenceImages as Node2D
@onready var tilemap_property_drawing := $TilemapPropertyDrawing as Node2D


func _ready() -> void:
	material.set_shader_parameter("layers", layer_texture_array)
	material.set_shader_parameter("metadata", layer_metadata_texture)
	Global.project_created.connect(camera_zoom)
	Global.project_about_to_switch.connect(_on_project_about_to_switch)
	Global.project_switched.connect(_on_project_switched)
	Global.cel_switched.connect(queue_redraw_all_layers)
	onion_past.type = onion_past.PAST
	onion_past.blue_red_color = Global.onion_skinning_past_color
	onion_future.type = onion_future.FUTURE
	onion_future.blue_red_color = Global.onion_skinning_future_color
	await get_tree().process_frame
	camera_zoom()


func _draw() -> void:
	var project := Global.current_project
	var position_tmp := position
	var scale_tmp := scale
	if Global.mirror_view:
		position_tmp.x = position_tmp.x + project.size.x
		scale_tmp.x = -1
	draw_set_transform(position_tmp, rotation, scale_tmp)
	# Placeholder so we can have a material here
	var image_to_draw := project.empty_image_texture
	draw_texture(image_to_draw, Vector2.ZERO)
	var layer_start_us := Time.get_ticks_usec() if brush_profile_active else 0
	draw_layers(project_changed)
	if brush_profile_active:
		brush_profile_layers_us += Time.get_ticks_usec() - layer_start_us
		brush_profile_layers_calls += 1
	project_changed = false
	if Global.onion_skinning:
		refresh_onion()
	currently_visible_frame.size = project.size
	current_frame_drawer.queue_redraw()
	tile_mode.queue_redraw()
	draw_set_transform(position, rotation, scale)
	color_index.queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_brush_size_drag_captured_left_mouse = false
		# A release event may be lost when the window loses focus.
		_quick_right_color_picker_active = false


## Mouse actions are routed to the original drawing tool before quick tool
## swaps happen in ToolButtons._unhandled_input. Query the actual user binding,
## rather than assuming an InputEvent action resolves in that exact order.
func _quick_picker_matches_right_mouse(event: InputEventMouseButton) -> bool:
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
			return true
	return false


## Read the actual cel pixels, never the color shown by the cursor preview.
## This avoids swapping tools in the middle of an InputEvent.
func _sample_quick_right_color(pixel: Vector2i) -> void:
	if Global.mirror_view:
		pixel.x = Global.current_project.size.x - pixel.x - 1
	var color_picker_script := preload("res://src/Tools/UtilityTools/ColorPicker.gd")
	var sampled: Dictionary = color_picker_script.sample_top_color(pixel)
	Tools.assign_color(sampled["color"], MOUSE_BUTTON_LEFT, false, sampled["index"])


## Keep the normal brush cursor and previews tracking the mouse during right-click sampling.
## Do not call Tools.handle_draw() here: that would invoke painting actions.
func _update_quick_right_picker_cursor() -> Vector2i:
	current_pixel = get_local_mouse_position()
	var pixel := Vector2i(current_pixel.floor())
	Tools.get_tool(MOUSE_BUTTON_LEFT).tool_node.cursor_move(pixel)
	Tools.get_tool(MOUSE_BUTTON_RIGHT).tool_node.cursor_move(pixel)
	indicators.queue_redraw()
	previews.queue_redraw()
	return pixel


func _handle_quick_right_color_picker(event: InputEvent) -> bool:
	if event is InputEventMouseMotion and _quick_right_color_picker_active:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			_quick_right_color_picker_active = false
			return false
		if Global.can_draw:
			var pixel := _update_quick_right_picker_cursor()
			if Rect2i(Vector2i.ZERO, Global.current_project.size).has_point(pixel):
				_sample_quick_right_color(pixel)
		return true

	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_RIGHT:
		return false

	if _quick_right_color_picker_active and not event.pressed:
		_quick_right_color_picker_active = false
		get_viewport().set_input_as_handled()
		return true

	if (
		not event.pressed
		or not _quick_picker_matches_right_mouse(event)
		or not Global.can_draw
		or Tools.active_button != -1
		or Tools.is_placing_tiles()
	):
		return false

	var pixel := Vector2i(get_local_mouse_position().floor())
	if not Rect2i(Vector2i.ZERO, Global.current_project.size).has_point(pixel):
		return false

	_quick_right_color_picker_active = true
	_update_quick_right_picker_cursor()
	_sample_quick_right_color(pixel)
	get_viewport().set_input_as_handled()
	return true

func _input(event: InputEvent) -> void:
	# Do not paint while the user holds the configured rotation key
	# chord or starts a rotation with a bound mouse button. Captured
	# rotation drags remain blocked even if their modifier is released.
	if (
		(is_instance_valid(Global.camera) and Global.camera._clipstudio_rotate_drag)
		or (
			Tools.active_button == -1
			and (
				Tools.is_keyboard_shortcut_held(&"canvas_rotate_drag", true)
				or (
					event is InputEventMouseButton
					and event.is_action_pressed(&"canvas_rotate_drag", false, true)
				)
			)
		)
	):
		return
	if _handle_quick_right_color_picker(event):
		return
	# Capture brush resizing at the initial left press. Keep consuming the
	# drag until mouse-up even if the shortcut is released halfway through,
	# otherwise the remaining drag could paint on the canvas.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_brush_size_drag_captured_left_mouse = (
				Global.can_draw
				and not Input.is_key_pressed(KEY_SPACE)
				and Input.is_action_pressed(&"mm_change_brush_size", true)
				and Tools.get_tool(MOUSE_BUTTON_LEFT).tool_node is BaseDrawTool
			)
		elif _brush_size_drag_captured_left_mouse:
			_brush_size_drag_captured_left_mouse = false
			return
	if (
		_brush_size_drag_captured_left_mouse
		and event is InputEventMouseMotion
		and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	):
		_brush_size_drag_captured_left_mouse = false
	if _brush_size_drag_captured_left_mouse:
		if event is InputEventMouseMotion:
			# Keep the brush footprint under the mouse while resizing. The
			# early return must still prevent drawing on the canvas.
			current_pixel = get_local_mouse_position()
			var cursor_pixel := Vector2i(current_pixel.floor())
			Tools.get_tool(MOUSE_BUTTON_LEFT).tool_node.cursor_move(cursor_pixel)
			Tools.get_tool(MOUSE_BUTTON_RIGHT).tool_node.cursor_move(cursor_pixel)
			# If the shortcut is no longer held, the tool itself will not resize.
			var draw_tool := Tools.get_tool(MOUSE_BUTTON_LEFT).tool_node as BaseDrawTool
			if is_instance_valid(draw_tool):
				draw_tool.change_brush_size_by_mouse_drag(event)
			indicators.queue_redraw()
		return
	# Space+left-drag navigation is implemented directly by CanvasCamera.
	# Do not send that drag to the drawing tools as an ordinary brush stroke.
	if Tools.has_space_alt_quick_navigation():
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and Input.is_key_pressed(KEY_SPACE):
				_quick_navigation_captured_left_mouse = true
			elif not event.pressed and _quick_navigation_captured_left_mouse:
				_quick_navigation_captured_left_mouse = false
				return
		if _quick_navigation_captured_left_mouse or Input.is_key_pressed(KEY_SPACE):
			return
	# Move the cursor with the keyboard (numpad keys by default)
	var mouse_movement := Input.get_vector(
		&"move_mouse_left", &"move_mouse_right", &"move_mouse_up", &"move_mouse_down"
	)
	# Don't process anything below if the input isn't a mouse event, a tool activation shortcut,
	# or the numpad keys that move the cursor.
	# This decreases CPU/GPU usage slightly.
	if event is not InputEventMouseMotion and event is not InputEventGesture:
		if (
			mouse_movement == Vector2.ZERO
			and not (
				event.is_action(&"activate_left_tool") or event.is_action(&"activate_right_tool")
			)
		):
			return
	if mouse_movement != Vector2.ZERO:
		var tmp_position := get_viewport().get_mouse_position()
		tmp_position += mouse_movement * CURSOR_SPEED_RATE
		get_viewport().warp_mouse(tmp_position)
	current_pixel = get_local_mouse_position()

	sprite_changed_this_frame = false
	Tools.handle_draw(Vector2i(current_pixel.floor()), event)

	if sprite_changed_this_frame:
		queue_redraw()
		var texture_start_us := Time.get_ticks_usec() if brush_profile_active else 0
		update_selected_cels_textures()
		if brush_profile_active:
			brush_profile_texture_us += Time.get_ticks_usec() - texture_start_us
			brush_profile_texture_calls += 1


## These numbers measure CPU call times, NOT asynchronous GPU execution.
func begin_brush_profile() -> void:
	brush_profile_active = true
	brush_profile_texture_us = 0
	brush_profile_texture_calls = 0
	brush_profile_layers_us = 0
	brush_profile_layers_calls = 0


func finish_brush_profile() -> Dictionary:
	brush_profile_active = false
	return {
		"texture_us": brush_profile_texture_us,
		"texture_calls": brush_profile_texture_calls,
		"layers_us": brush_profile_layers_us,
		"layers_calls": brush_profile_layers_calls,
	}


func queue_redraw_all_layers() -> void:
	project_changed = true
	var project := Global.current_project
	var current_cel := project.get_current_cel()
	if current_cel is Cel3D:
		var layer_3d := project.layers[project.current_layer] as Layer3D
		layer_3d.animation_player.speed_scale = project.fps
		layer_3d.animation.length = project.frames.size()
		layer_3d.animation_player.seek(project.current_frame, true)
		current_cel.update_texture()
	else:
		queue_redraw()


func camera_zoom(project := Global.current_project) -> void:
	await get_tree().process_frame
	for camera: CanvasCamera in get_tree().get_nodes_in_group("CanvasCameras"):
		camera.fit_to_frame(project.size)
	Global.transparent_checker.update_rect()


## Update only rendered images; original cel pixel data stays untouched.
func set_live_recolor_preview(project: Project, targets: Array, color: Color) -> void:
	live_recolor_project = project
	live_recolor_targets.clear()
	for target in targets:
		live_recolor_targets[Vector2i(target[0], target[1])] = true
	live_recolor_color = color
	live_recolor_enabled = not live_recolor_targets.is_empty()
	update_all_layers = true
	queue_redraw()


func clear_live_recolor_preview() -> void:
	if not live_recolor_enabled:
		return
	live_recolor_enabled = false
	live_recolor_targets.clear()
	live_recolor_project = null
	update_all_layers = true
	queue_redraw()


func apply_live_recolor_preview(
	image: Image, layer_index: int, frame_index: int, project: Project
) -> void:
	if (
		not live_recolor_enabled
		or project != live_recolor_project
		or not live_recolor_targets.has(Vector2i(frame_index, layer_index))
		or image.is_empty()
	):
		return
	var generator := ShaderImageEffect.new()
	generator.generate_image(
		image, LIVE_RECOLOR_SHADER, {"target_color": live_recolor_color}, image.get_size()
	)


static func get_canvas_cel_image(cel: BaseCel, layer: BaseLayer, image: Image) -> void:
	var project := layer.project
	if layer.is_blender():
		var frame := project.frames[project.current_frame]
		var blended: Image = layer.blend_children(frame, false, Global.display_layer_effects)
		image.copy_from(blended)
	else:
		if Global.display_layer_effects:
			image.copy_from(layer.display_effects(cel, false))
			if layer.use_cel_image_for_effects:
				image.copy_from(project.crop_image_to_project_size(image, cel.offset))
		else:
			image.copy_from(project.crop_image_to_project_size(cel.get_image(), cel.offset))
			# Display effects may be disabled without disabling recolor preview.
			if layer is PixelLayer and cel is PixelCel and not cel is CelTileMap:
				Global.canvas.apply_live_recolor_preview(
					image, layer.index, project.current_frame, project
				)


func update_texture(
	layer_i: int, frame_i := -1, project := Global.current_project, undo := false
) -> void:
	if frame_i == -1:
		frame_i = project.current_frame

	if frame_i < project.frames.size() and layer_i < project.layers.size():
		var current_cel := project.frames[frame_i].cels[layer_i]
		current_cel.update_texture(undo)
		# Needed so that changes happening to the non-selected layer(s) are also visible
		# e.g. when undoing/redoing, when applying image effects to the entire frame, etc
		if frame_i != project.current_frame:
			# Don't update if the cel is on a different frame (can happen with undo/redo)
			return
		var layer := project.layers[layer_i].get_blender_ancestor()
		var cel_image := Image.new()
		get_canvas_cel_image(current_cel, layer, cel_image)
		if (
			cel_image.get_size()
			== Vector2i(layer_texture_array.get_width(), layer_texture_array.get_height())
		):
			layer_texture_array.update_layer(cel_image, project.ordered_layers.find(layer.index))


func update_selected_cels_textures(project := Global.current_project) -> void:
	for cel_index in project.selected_cels:
		var frame_index: int = cel_index[0]
		var layer_index: int = cel_index[1]
		if frame_index < project.frames.size() and layer_index < project.layers.size():
			var current_cel := project.frames[frame_index].cels[layer_index]
			current_cel.update_texture()


func draw_layers(force_recreate := false) -> void:
	var project := Global.current_project
	var recreate_texture_array := (
		layer_texture_array.get_layers() != project.layers.size()
		or layer_texture_array.get_width() != project.size.x
		or layer_texture_array.get_height() != project.size.y
		or force_recreate
	)
	if recreate_texture_array:
		var textures: Array[Image] = []
		textures.resize(project.layers.size())
		# Nx4 texture, where N is the number of layers and the first row are the blend modes,
		# the second are the opacities, the third are the clipping mask booleans.
		layer_metadata_image = Image.create(project.layers.size(), 4, false, Image.FORMAT_R8)
		# Draw current frame layers
		for i in project.layers.size():
			var layer := project.layers[i]
			var ordered_index := project.ordered_layers.find(layer.index)
			var cel_image := Image.new()
			_update_texture_array_layer(project, layer, cel_image, false)
			textures[ordered_index] = cel_image

		layer_texture_array.create_from_images(textures)
		layer_metadata_texture.set_image(layer_metadata_image)
	else:  # Update the TextureArray
		if layer_texture_array.get_layers() > 0:
			for i in project.layers.size():
				var layer := project.layers[i]
				if not update_all_layers:
					var test_array := [project.current_frame, i]
					if not test_array in project.selected_cels:
						var include := false
						# Some layers are required for mandatory update because they are part of
						# an undo/redo action that is being performed right now. The may not be
						# currently selected but still require an update
						if i in mandatory_update_layers:
							include = true
						else:
							var parents := layer.get_ancestors()
							# Even if the layer itself is not changed, if it is part of a group layer
							# with passthrough mode, it will still need an update if it's group cel is
							# selected.
							for parent in parents:
								if parent.blend_mode == BaseLayer.BlendModes.PASS_THROUGH:
									var test_array_parent := [project.current_frame, parent.index]
									if test_array_parent in project.selected_cels:
										include = true
						if not include:
							continue
				var cel_image := Image.new()
				_update_texture_array_layer(project, layer, cel_image, true)
				var parent_layer := layer.get_blender_ancestor()
				if layer != parent_layer:
					# True when the layer has parents. In that case, update its top-most parent.
					_update_texture_array_layer(project, parent_layer, Image.new(), true)
			layer_metadata_texture.update(layer_metadata_image)

	mandatory_update_layers = []
	update_all_layers = false


func _update_texture_array_layer(
	project: Project, layer: BaseLayer, cel_image: Image, update_layer: bool
) -> void:
	var ordered_index := project.ordered_layers.find(layer.index)
	var cel := project.frames[project.current_frame].cels[layer.index]
	var include := true
	get_canvas_cel_image(cel, layer, cel_image)
	if layer.is_blended_by_ancestor():
		include = false
	if update_layer:
		layer_texture_array.update_layer(cel_image, ordered_index)
	DrawingAlgos.set_layer_metadata_image(
		layer, cel, layer_metadata_image, ordered_index, include, false
	)


func refresh_onion() -> void:
	onion_past.queue_redraw()
	onion_future.queue_redraw()


func _on_project_about_to_switch() -> void:
	var project := Global.current_project
	if project.resized.is_connected(camera_zoom):
		project.resized.disconnect(camera_zoom)


func _on_project_switched() -> void:
	var project := Global.current_project
	if not project.resized.is_connected(camera_zoom):
		project.resized.connect(camera_zoom.bind(project))

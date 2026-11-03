extends BaseDrawTool

var _prev_mode := false
var _last_position := Vector2i(Vector2.INF)
# Position of the last completed pencil stroke, for Shift+click straight lines.
# Scoped to the same project, frame and layer so a click never joins other cels.
var _line_anchor := Vector2i(Vector2.INF)
var _line_anchor_project: Project
var _line_anchor_frame := -1
var _line_anchor_layer := -1
var _shift_click_press_pos := Vector2i(Vector2.INF)
var _shift_click_uses_anchor := false
# Cache the cursor-to-anchor outline until the pointer or brush actually changes.
var _hover_line_start := Vector2i(Vector2.INF)
var _hover_line_end := Vector2i(Vector2.INF)
var _hover_line_indicator: BitMap
var _changed := false
var _overwrite := false
var _fill_inside := false
var _fill_inside_rect := Rect2i()  ## The bounding box that surrounds the area that gets filled.
var _draw_points := PackedVector2Array()
var _old_spacing_mode := false  ## Needed to reset spacing mode in case we change it


class PencilOp:
	extends Drawer.ColorOp
	var changed := false
	var overwrite := false

	func process(src: Color, dst: Color) -> Color:
		changed = true
		# Match Aseprite's transparent drawing color: clear even without
		# enabling the optional Overwrite setting. Semi-transparent colors
		# still accumulate across separate pencil strokes.
		if is_zero_approx(src.a):
			return dst if Tools.alpha_locked else Color.TRANSPARENT
		src.a *= strength
		if overwrite:
			return src
		return dst.blend(src)


func _init() -> void:
	_drawer.color_op = PencilOp.new()


func _ready() -> void:
	super._ready()
	Global.cel_switched.connect(_clear_line_anchor)
	Global.project_switched.connect(_clear_line_anchor)


func _clear_line_anchor() -> void:
	_line_anchor = Vector2i(Vector2.INF)
	_line_anchor_project = null
	_line_anchor_frame = -1
	_line_anchor_layer = -1
	_shift_click_uses_anchor = false
	_hover_line_start = Vector2i(Vector2.INF)
	_hover_line_end = Vector2i(Vector2.INF)
	_hover_line_indicator = null


func cancel_tool() -> void:
	var was_drawing := is_moving
	super.cancel_tool()
	_clear_line_anchor()
	_draw_line = false
	if was_drawing:
		_spacing_mode = _old_spacing_mode


func _on_Overwrite_toggled(button_pressed: bool) -> void:
	_overwrite = button_pressed
	update_config()
	save_config()


func _on_FillInside_toggled(button_pressed: bool) -> void:
	_fill_inside = button_pressed
	update_config()
	save_config()


func _on_SpacingMode_toggled(button_pressed: bool) -> void:
	# This acts as an interface to access the intrinsic spacing_mode feature
	# BaseTool holds the spacing system, but for a tool to access them it's recommended to do it in
	# their own script
	_spacing_mode = button_pressed
	update_config()
	save_config()


func _on_Spacing_value_changed(value: Vector2) -> void:
	_spacing = value
	save_config()


func _input(event: InputEvent) -> void:
	super(event)
	var overwrite_button: CheckBox = $Overwrite

	if event.is_action_pressed("change_tool_mode"):
		_prev_mode = overwrite_button.button_pressed
	if event.is_action("change_tool_mode"):
		overwrite_button.set_pressed_no_signal(!_prev_mode)
		_overwrite = overwrite_button.button_pressed
	if event.is_action_released("change_tool_mode"):
		overwrite_button.set_pressed_no_signal(_prev_mode)
		_overwrite = overwrite_button.button_pressed


func get_config() -> Dictionary:
	var config := super.get_config()
	config["overwrite"] = _overwrite
	config["fill_inside"] = _fill_inside
	config["spacing_mode"] = _spacing_mode
	config["spacing"] = _spacing
	return config


func set_config(config: Dictionary) -> void:
	super.set_config(config)
	_overwrite = config.get("overwrite", _overwrite)
	_fill_inside = config.get("fill_inside", _fill_inside)
	_spacing_mode = config.get("spacing_mode", _spacing_mode)
	_spacing = config.get("spacing", _spacing)


func update_config() -> void:
	super.update_config()
	$Overwrite.button_pressed = _overwrite
	$FillInside.button_pressed = _fill_inside
	$SpacingMode.button_pressed = _spacing_mode
	$Spacing.visible = _spacing_mode
	$Spacing.value = _spacing


## The existing line-outline renderer is also used before a click. Holding
## Shift displays the would-be segment from the previous completed endpoint
## to the cursor, without editing any pixels or creating an undo action.
func draw_indicator(left: bool) -> void:
	var project := Global.current_project
	if (
		is_moving
		or Tools.active_button != -1
		or not Input.is_action_pressed(&"draw_create_line")
		or Input.is_action_pressed(&"change_layer_automatically", true)
		or _line_anchor == Vector2i(Vector2.INF)
		or _line_anchor_project != project
		or _line_anchor_frame != project.current_frame
		or _line_anchor_layer != project.current_layer
		or not Rect2i(Vector2i.ZERO, project.size).has_point(_cursor)
	):
		super.draw_indicator(left)
		return

	var start := _line_anchor
	var end := Vector2i(snap_position(_cursor))
	if Global.mirror_view:
		start.x = (project.size.x - 1) - start.x
		end.x = (project.size.x - 1) - end.x
	end = _line_angle_constraint(start, end).position
	if (
		start != _hover_line_start
		or end != _hover_line_end
		or _hover_line_indicator != _indicator
	):
		update_line_polylines(start, end)
		_hover_line_start = start
		_hover_line_end = end
		_hover_line_indicator = _indicator

	# Reuse the exact brush-footprint outline shown during Shift-drag, so
	# previews remain consistent for 1px, large, dither, and custom brushes.
	var saved_start := _line_start
	var saved_end := _line_end
	_line_start = start
	_line_end = end
	_draw_line = true
	super.draw_indicator(left)
	_draw_line = false
	_line_start = saved_start
	_line_end = saved_end


func draw_start(pos: Vector2i) -> void:
	_old_spacing_mode = _spacing_mode
	pos = snap_position(pos)
	_shift_click_press_pos = pos
	_shift_click_uses_anchor = false
	# Active Shift-drag reuses _line_polylines, so its next hover preview
	# must rebuild the outline even if the cursor ends at the same pixel.
	_hover_line_start = Vector2i(Vector2.INF)
	_hover_line_end = Vector2i(Vector2.INF)
	super.draw_start(pos)

	Global.transform_content_confirmed.emit()
	prepare_undo()
	var can_skip_mask := true
	if tool_slot.color.a < 1 and !_overwrite and not is_zero_approx(tool_slot.color.a):
		can_skip_mask = false
	update_mask(can_skip_mask)
	_changed = false
	_drawer.color_op.changed = false
	_drawer.color_op.overwrite = _overwrite
	_draw_points = []

	_drawer.reset()

	_draw_line = Input.is_action_pressed("draw_create_line")
	var project := Global.current_project
	var current_cel := project.get_current_cel()
	var draw_pos := pos
	if current_cel is Cel3D:
		var layer := project.layers[project.current_layer] as Layer3D
		draw_pos = draw_on_3d_object(pos, layer)
		if draw_pos == Vector2i(Vector2.INF):
			return
	if _draw_line:
		_spacing_mode = false  # spacing mode is disabled during line mode
		var line_start := pos
		if (
			current_cel is PixelCel
			and not current_cel is CelTileMap
			and _line_anchor != Vector2i(Vector2.INF)
			and _line_anchor_project == project
			and _line_anchor_frame == project.current_frame
			and _line_anchor_layer == project.current_layer
		):
			# Shift+click begins at the endpoint of the last stroke, not here.
			line_start = _line_anchor
			_shift_click_uses_anchor = true
		if Global.mirror_view:
			# Only the line preview needs mirrored coordinates.
			line_start.x = (project.size.x - 1) - line_start.x
			pos.x = (project.size.x - 1) - pos.x
		_line_start = line_start
		_line_end = pos
		update_line_polylines(_line_start, _line_end)
	else:
		if _fill_inside:
			_draw_points.append(pos)
			_fill_inside_rect = Rect2i(pos, Vector2i.ZERO)
		draw_tool(draw_pos)
		_last_position = pos
		Global.canvas.sprite_changed_this_frame = true
	cursor_text = ""


func draw_move(pos_i: Vector2i) -> void:
	var pos := _get_stabilized_position(pos_i)
	pos = snap_position(pos)
	super.draw_move(pos)

	if _draw_line:
		_spacing_mode = false  # spacing mode is disabled during line mode
		# Keep the existing Shift+drag behavior. A movement of at least
		# three canvas pixels makes the mouse-down point the line start;
		# a click (including tiny pointer jitter) uses the previous endpoint.
		if _shift_click_uses_anchor and (Vector2i(pos) - _shift_click_press_pos).length_squared() >= 9:
			_shift_click_uses_anchor = false
			_line_start = _shift_click_press_pos
			if Global.mirror_view:
				_line_start.x = (Global.current_project.size.x - 1) - _line_start.x
		if Global.mirror_view:
			# mirroring position is ONLY required by "Preview"
			pos.x = (Global.current_project.size.x - 1) - pos.x
		var d := _line_angle_constraint(_line_start, pos)
		_line_end = d.position
		cursor_text = d.text
		update_line_polylines(_line_start, _line_end)
	else:
		if _last_position == Vector2i(Vector2.INF):
			return
		draw_fill_gap(_last_position, pos)
		_last_position = pos
		cursor_text = ""
		Global.canvas.sprite_changed_this_frame = true
		if _fill_inside:
			_draw_points.append(pos)
			_fill_inside_rect = _fill_inside_rect.expand(pos)


func draw_end(pos: Vector2i) -> void:
	pos = snap_position(pos)
	var stroke_end := _last_position

	if _draw_line:
		_spacing_mode = false  # spacing mode is disabled during line mode
		if Global.mirror_view:
			# now we revert back the coordinates from their mirror form so that line can be drawn
			_line_start.x = (Global.current_project.size.x - 1) - _line_start.x
			_line_end.x = (Global.current_project.size.x - 1) - _line_end.x
		draw_tool(_line_start)
		draw_fill_gap(_line_start, _line_end)
		stroke_end = _line_end
		_draw_line = false
	else:
		if _fill_inside:
			_draw_points.append(pos)
			if _draw_points.size() > 3:
				var v := Vector2i()
				for x in _fill_inside_rect.size.x:
					v.x = x + _fill_inside_rect.position.x
					for y in _fill_inside_rect.size.y:
						v.y = y + _fill_inside_rect.position.y
						if Geometry2D.is_point_in_polygon(v, _draw_points):
							if _spacing_mode:
								# use of get_spacing_position() in Pencil.gd is a rare case
								# (you would ONLY need _spacing_mode and _spacing in most cases)
								v = get_spacing_position(v)
							draw_tool(v)

	_fill_inside_rect = Rect2i()
	commit_undo()
	super.draw_end(pos)
	# The next Shift+click can now continue from this stroke's endpoint.
	var project := Global.current_project
	var cel := project.get_current_cel()
	if cel is PixelCel and not cel is CelTileMap:
		_line_anchor = stroke_end
		_line_anchor_project = project
		_line_anchor_frame = project.current_frame
		_line_anchor_layer = project.current_layer
	else:
		_clear_line_anchor()
	_shift_click_uses_anchor = false
	cursor_text = ""
	update_random_image()
	_spacing_mode = _old_spacing_mode


func _draw_brush_image(
	brush_image: Image, src_rect: Rect2i, dst: Vector2i, overwrite := _overwrite
) -> void:
	_changed = true
	super(brush_image, src_rect, dst, overwrite)

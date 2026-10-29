extends Container

const PADDING := 1
const CEL_BUTTON_SCRIPT := preload("res://src/UI/Timeline/CelButton.gd")
# https://github.com/godotengine/godot/blob/master/scene/gui/scroll_bar.h#L113
const PAGE_DIVISOR := 8
# https://github.com/godotengine/godot/pull/111305
const PAN_MULTIPLIER := 5

@export var keyframe_timeline: KeyframeTimeline
@export var h_scroll_bar: HScrollBar

var drag_speed := 0.0
var drag_accum := 0.0
var drag_from := 0.0
var last_drag_accum := 0.0
var deadzone := 0.0
var time_since_motion := 0.0
var drag_touching := false
var drag_touching_deaccel := false
var beyond_deadzone := false
var scroll_on_drag_hover := false
var scroll_border := 20
var scroll_speed := 12


func _ready() -> void:
	sort_children.connect(_on_sort_children)
	if is_instance_valid(h_scroll_bar):
		h_scroll_bar.resized.connect(_update_scroll)
		h_scroll_bar.value_changed.connect(_on_scroll_bar_value_changed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_BEGIN:
		if scroll_on_drag_hover and is_visible_in_tree():
			set_process_internal(true)
	elif what == NOTIFICATION_DRAG_END:
		set_process_internal(false)
	elif what == NOTIFICATION_INTERNAL_PROCESS:
		# Handle auto-scroll when dragging near edges
		if scroll_on_drag_hover and get_viewport().gui_is_dragging():
			var mouse_position := get_viewport().get_mouse_position() - get_global_position()
			var xform := get_transform()
			var rect := Rect2(Vector2.ZERO, xform.get_scale() * get_size()).grow(scroll_border)

			if rect.has_point(mouse_position):
				var point := Vector2.ZERO

				if (
					absf(mouse_position.x) < absf(mouse_position.x - get_size().x)
					and absf(mouse_position.x) < scroll_border
				):
					point.x = mouse_position.x - scroll_border
				elif absf(mouse_position.x - get_size().x) < scroll_border:
					point.x = mouse_position.x - (get_size().x - scroll_border)

				if (
					absf(mouse_position.y) < absf(mouse_position.y - get_size().y)
					and absf(mouse_position.y) < scroll_border
				):
					point.y = mouse_position.y - scroll_border
				elif absf(mouse_position.y - get_size().y) < scroll_border:
					point.y = mouse_position.y - (get_size().y - scroll_border)

				point *= scroll_speed * get_process_delta_time()
				point += Vector2(h_scroll_bar.value, 0)

				h_scroll_bar.value = point.x

		# Handle drag inertial scrolling
		if drag_touching:
			if drag_touching_deaccel:
				var pos := h_scroll_bar.value
				pos += drag_speed * get_process_delta_time()

				var turnoff_h := false

				if pos < 0.0:
					pos = 0.0
					turnoff_h = true
				if pos > (h_scroll_bar.max_value - h_scroll_bar.page):
					pos = h_scroll_bar.max_value - h_scroll_bar.page
					turnoff_h = true

				h_scroll_bar.value = pos

				var sgn_x := -1.0 if drag_speed < 0.0 else 1.0
				var val_x := absf(drag_speed)
				val_x -= 1000.0 * get_process_delta_time()
				if val_x < 0.0:
					turnoff_h = true

				drag_speed = sgn_x * val_x

				if turnoff_h:
					_cancel_drag()

			else:
				if time_since_motion == 0.0 or time_since_motion > 0.1:
					var diff := drag_accum - last_drag_accum
					last_drag_accum = drag_accum
					drag_speed = diff / get_process_delta_time()


func _gui_input(event: InputEvent) -> void:
	if get_child_count() == 0:
		return
	var vertical_scroll: bool = get_child(0).size.y >= size.y
	var should_h_scroll := not vertical_scroll
	if event is InputEventWithModifiers and not should_h_scroll:
		should_h_scroll = event.shift_pressed
	if event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_WHEEL_RIGHT, MOUSE_BUTTON_WHEEL_LEFT]:
			# This helps/allows two finger scrolling (on Laptops)
			should_h_scroll = true
		if should_h_scroll:
			if is_instance_valid(h_scroll_bar):
				if (
					event.button_index == MOUSE_BUTTON_WHEEL_UP
					or event.button_index == MOUSE_BUTTON_WHEEL_LEFT
				):
					h_scroll_bar.value -= PAGE_DIVISOR * event.factor
					accept_event()
					return
				if (
					event.button_index == MOUSE_BUTTON_WHEEL_DOWN
					or event.button_index == MOUSE_BUTTON_WHEEL_RIGHT
				):
					h_scroll_bar.value += PAGE_DIVISOR * event.factor
					accept_event()
					return
	_touchscreen_scroll(event)


func _touchscreen_scroll(event: InputEvent) -> void:
	if not DisplayServer.is_touchscreen_available():
		return
	if get_viewport().gui_is_dragging() and not scroll_on_drag_hover:
		_cancel_drag()
		return
	var prev_h_scroll := h_scroll_bar.value
	# Handle mouse button input
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return

		if mb.pressed:
			if drag_touching:
				_cancel_drag()

			drag_speed = 0.0
			drag_accum = 0.0
			last_drag_accum = 0.0
			drag_from = prev_h_scroll
			drag_touching = true
			drag_touching_deaccel = false
			beyond_deadzone = false
			time_since_motion = 0.0
			set_process_internal(true)
			time_since_motion = 0.0
		else:
			if drag_touching:
				if drag_speed == 0.0:
					_cancel_drag()
				else:
					drag_touching_deaccel = true
		return

	# Handle mouse motion input
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if drag_touching and not drag_touching_deaccel:
			var motion := mm.relative.x
			drag_accum -= motion

			if beyond_deadzone or (absf(drag_accum) > deadzone):
				if not beyond_deadzone:
					propagate_notification(NOTIFICATION_SCROLL_BEGIN)
					beyond_deadzone = true
					# Reset accum for smooth start
					drag_accum = -motion

				var diff := drag_from + drag_accum
				h_scroll_bar.value = diff
				time_since_motion = 0.0

		if h_scroll_bar.value != prev_h_scroll:
			accept_event()
		return

	# Pan scrolling, used by some MacOS devices
	# (see: https://github.com/Orama-Interactive/Pixelorama/discussions/1218)
	if event is InputEventPanGesture:
		if event.delta.x != 0:
			h_scroll_bar.value += signf(event.delta.x) * PAN_MULTIPLIER


func _cancel_drag() -> void:
	set_process_internal(false)
	drag_touching_deaccel = false
	drag_touching = false
	drag_speed = 0.0
	drag_accum = 0.0
	last_drag_accum = 0.0
	drag_from = 0.0

	if beyond_deadzone:
		beyond_deadzone = false
		propagate_notification(NOTIFICATION_SCROLL_END)


func _update_scroll() -> void:
	if get_child_count() > 0 and is_instance_valid(h_scroll_bar):
		var cel_margin_container := get_child(0) as Control
		var child_min_size := cel_margin_container.get_combined_minimum_size()
		if is_instance_valid(keyframe_timeline) and keyframe_timeline.visible:
			h_scroll_bar.visible = false
		else:
			h_scroll_bar.visible = child_min_size.x > size.x
		h_scroll_bar.max_value = child_min_size.x
		if h_scroll_bar.visible:
			h_scroll_bar.page = size.x - h_scroll_bar.get_combined_minimum_size().x
		else:
			h_scroll_bar.page = size.x
		cel_margin_container.position.x = -h_scroll_bar.value + PADDING


func ensure_control_visible(control: Control) -> void:
	if not is_instance_valid(control):
		return
	# Based on Godot's implementation in ScrollContainer
	var global_rect := get_global_rect()
	var other_rect := control.get_global_rect()
	var diff := maxf(
		minf(other_rect.position.x, global_rect.position.x),
		other_rect.position.x + other_rect.size.x - global_rect.size.x
	)
	h_scroll_bar.value += diff - global_rect.position.x


func _on_sort_children() -> void:
	if get_child_count():
		get_child(0).size = get_child(0).get_combined_minimum_size()
		_update_scroll()


func _on_scroll_bar_value_changed(value: float) -> void:
	if get_child_count() > 0 and is_instance_valid(h_scroll_bar):
		var cel_margin_container := get_child(0) as Control
		cel_margin_container.position.x = -value + PADDING


## Accept cel copies/moves on the empty strip to the right of the last frame.
## That strip has no CelButton, so CelButton._can_drop_data() cannot receive it.
func _get_future_cel_drop_target(local_pos: Vector2) -> Vector2i:
	var result := Vector2i(-1, -1)
	var timeline := Global.animation_timeline
	if timeline.frame_scroll_container != self:
		return result  # This script also serves the frame header.
	if is_instance_valid(keyframe_timeline) and keyframe_timeline.visible:
		return result
	var global_pos := to_global(local_pos)
	if not get_global_rect().has_point(global_pos):
		return result
	var cel_rows: VBoxContainer = timeline.cel_vbox
	for row_index in cel_rows.get_child_count():
		var row := cel_rows.get_child(row_index) as HBoxContainer
		if not is_instance_valid(row) or not row.visible or row.get_child_count() == 0:
			continue
		var first_cel := row.get_child(0) as Control
		var last_cel := row.get_child(row.get_child_count() - 1) as Control
		if global_pos.y < first_cel.global_position.y:
			continue
		if global_pos.y >= first_cel.global_position.y + first_cel.size.y:
			continue
		if global_pos.x < last_cel.global_position.x + last_cel.size.x:
			continue
		var frame_index := floori(
			(global_pos.x - first_cel.global_position.x) / maxf(first_cel.size.x, 1.0)
		)
		if frame_index < Global.current_project.frames.size():
			continue
		result = Vector2i(frame_index, cel_rows.get_child_count() - row_index - 1)
		break
	return result


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_ARRAY or data.size() < 3 or data[0] != "Cel":
		return false
	var target := _get_future_cel_drop_target(at_position)
	if target.x < 0:
		return false
	var source_coords: Array = data[1]
	var anchor: Array = data[2]
	if source_coords.is_empty() or anchor.size() != 2:
		return false
	var offset := target - Vector2i(int(anchor[0]), int(anchor[1]))
	if not CEL_BUTTON_SCRIPT._can_transfer_pixel_cels(source_coords, offset):
		return false
	var destinations := []
	for coords in source_coords:
		destinations.append(
			Vector2i(int(coords[0]) + offset.x, int(coords[1]) + offset.y)
		)
	var timeline := Global.animation_timeline
	timeline.set_virtual_cels_highlight(destinations)
	timeline.drag_highlight.global_position = global_position
	timeline.drag_highlight.size = size
	timeline.drag_highlight.show()
	return true


func _drop_data(at_position: Vector2, data: Variant) -> void:
	var target := _get_future_cel_drop_target(at_position)
	if target.x < 0 or data.size() < 3:
		return
	var anchor: Array = data[2]
	var offset := target - Vector2i(int(anchor[0]), int(anchor[1]))
	var copy := Global.is_ctrl_or_cmd_pressed() or Input.is_key_pressed(KEY_ALT)
	CEL_BUTTON_SCRIPT._transfer_pixel_cels(data[1], offset, copy)
	Global.animation_timeline.drag_highlight.hide()


func _clips_input() -> bool:
	return true

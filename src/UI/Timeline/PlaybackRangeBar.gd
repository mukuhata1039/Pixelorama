extends Control
## Interactive playback-range ruler, aligned with the numbered frame headers.
## Drag either marker; this automatically enables the manual playback range.

const START_COLOR := Color("f0bf64")
const END_COLOR := Color("7fc6f1")
const INACTIVE_COLOR := Color(0.6, 0.6, 0.6, 0.45)
const HANDLE_HIT_RADIUS := 12.0

var _dragging_handle := -1  ## 0: start, 1: end; -1: none.


func _frame_center(frame_index: int) -> float:
	var timeline := Global.animation_timeline
	if not is_instance_valid(timeline) or timeline.frame_hbox.get_child_count() == 0:
		return 0.0
	var index: int = clampi(frame_index, 0, timeline.frame_hbox.get_child_count() - 1)
	var button: Control = timeline.frame_hbox.get_child(index)
	return button.position.x + button.size.x * 0.5


func _frame_at_x(x: float) -> int:
	var timeline := Global.animation_timeline
	var count: int = timeline.frame_hbox.get_child_count()
	if count == 0:
		return 0
	var best := 0
	var distance := INF
	for i in count:
		var candidate: float = absf(x - _frame_center(i))
		if candidate < distance:
			distance = candidate
			best = i
	return best


func _bounds() -> Vector2i:
	var project := Global.current_project
	var last: int = maxi(0, project.frames.size() - 1)
	var start: int = clampi(project.playback_range_start, 0, last)
	var finish: int = (
		last if project.playback_range_end < 0
		else clampi(project.playback_range_end, start, last)
	)
	return Vector2i(start, finish)


func _draw() -> void:
	var timeline := Global.animation_timeline
	if not is_instance_valid(timeline) or timeline.frame_hbox.get_child_count() == 0:
		return
	var project := Global.current_project
	var range_bounds := _bounds()
	var left: float = _frame_center(range_bounds.x)
	var right: float = _frame_center(range_bounds.y)
	var y: float = size.y * 0.55
	var active: bool = project.playback_range_enabled
	var from_color: Color = START_COLOR if active else INACTIVE_COLOR
	var to_color: Color = END_COLOR if active else INACTIVE_COLOR
	var fill: Color = Color(0.22, 0.58, 0.49, 0.34) if active else Color(0.4, 0.4, 0.4, 0.16)
	# The selected interval and its two draggable endpoint markers.
	draw_line(Vector2(left, y), Vector2(right, y), fill, 7.0)
	draw_line(Vector2(left, y - 7), Vector2(left, y + 7), from_color, 2.0)
	draw_line(Vector2(right, y - 7), Vector2(right, y + 7), to_color, 2.0)
	draw_colored_polygon(
		PackedVector2Array([Vector2(left - 5, 0), Vector2(left + 5, 0), Vector2(left, 7)]),
		from_color
	)
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(right - 5, size.y), Vector2(right + 5, size.y),
			Vector2(right, size.y - 7)
		]), to_color
	)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.pressed:
			var bounds := _bounds()
			var start_distance: float = absf(event.position.x - _frame_center(bounds.x))
			var end_distance: float = absf(event.position.x - _frame_center(bounds.y))
			# Nearest marker is also directly draggable from anywhere on the ruler.
			_dragging_handle = 0 if start_distance <= end_distance else 1
			_set_boundary(_frame_at_x(event.position.x))
		else:
			_dragging_handle = -1
		accept_event()
	elif event is InputEventMouseMotion and _dragging_handle >= 0:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_set_boundary(_frame_at_x(event.position.x))
		else:
			_dragging_handle = -1
		accept_event()


func _set_boundary(frame_index: int) -> void:
	var timeline := Global.animation_timeline
	var bounds := _bounds()
	if _dragging_handle == 0:
		timeline.set_manual_playback_range(mini(frame_index, bounds.y), bounds.y)
	elif _dragging_handle == 1:
		timeline.set_manual_playback_range(bounds.x, maxi(frame_index, bounds.x))

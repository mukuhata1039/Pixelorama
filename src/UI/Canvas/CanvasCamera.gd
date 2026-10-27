class_name CanvasCamera
extends Node2D

signal zoom_changed
signal rotation_changed
signal offset_changed

enum Cameras { MAIN, SECOND, SMALL }

const CAMERA_SPEED_RATE := 15.0

@export var index := 0

var zoom := Vector2.ONE:
	set(value):
		zoom = value
		Global.current_project.cameras_zoom[index] = zoom
		zoom_changed.emit()
		_update_viewport_transform()
var camera_angle := 0.0:
	set(value):
		camera_angle = wrapf(value, -PI, PI)
		camera_angle_degrees = rad_to_deg(camera_angle)
		Global.current_project.cameras_rotation[index] = camera_angle
		rotation_changed.emit()
		_update_viewport_transform()
var camera_angle_degrees := 0.0
var offset := Vector2.ZERO:
	set(value):
		offset = value
		Global.current_project.cameras_offset[index] = offset
		offset_changed.emit()
		_update_viewport_transform()
var camera_screen_center := Vector2.ZERO
var zoom_in_max := Vector2(500, 500)
var zoom_out_max := Vector2(0.01, 0.01)
var viewport_container: SubViewportContainer
var transparent_checker: ColorRect
var mouse_pos := Vector2.ZERO
var drag := false
var _quick_navigation_drag := false
var _quick_zoom_anchor := Vector2.ZERO
## Canvas rotation drag driven by the current editable shortcut profile.
var _clipstudio_rotate_drag := false
var _clipstudio_rotate_button := MOUSE_BUTTON_LEFT
var _clipstudio_rotate_mouse_shortcut := false
var _clipstudio_rotate_previous_mouse := Vector2.ZERO
var rotation_slider: ValueSlider
var zoom_slider: ValueSlider
var should_tween := true
var auto_release_gui_focus := true

@onready var viewport := get_viewport()


func _ready() -> void:
	viewport.size_changed.connect(_update_viewport_transform)
	Global.project_switched.connect(_project_switched)
	if not DisplayServer.is_touchscreen_available():
		set_process_input(false)
	if index == Cameras.MAIN:
		rotation_slider = Global.top_menu_container.get_node("%RotationSlider")
		rotation_slider.value_changed.connect(_rotation_slider_value_changed)
		zoom_slider = Global.top_menu_container.get_node("%ZoomSlider")
		zoom_slider.value_changed.connect(_zoom_slider_value_changed)
	zoom_changed.connect(_zoom_changed)
	rotation_changed.connect(_rotation_changed)
	viewport_container = get_viewport().get_parent()
	transparent_checker = get_viewport().get_node("TransparentChecker")
	update_transparent_checker_offset()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_clipstudio_rotate_drag = false
		_clipstudio_rotate_mouse_shortcut = false


func _input(event: InputEvent) -> void:
	if not DisplayServer.is_touchscreen_available() and auto_release_gui_focus:
		get_window().gui_release_focus()
	if !Global.can_draw:
		drag = false
		_quick_navigation_drag = false
		_clipstudio_rotate_drag = false
		_clipstudio_rotate_mouse_shortcut = false
		return
	mouse_pos = viewport_container.get_local_mouse_position()
	if _handle_clipstudio_rotation(event):
		return

	# Quick Pan/Zoom must respond to the *held* Space and Alt keys, even when
	# they are pressed in the opposite order. Handle the physical drag here,
	# independently of the currently displayed tool icon.
	if Tools.has_space_alt_quick_navigation():
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_quick_navigation_drag = (
					Input.is_key_pressed(KEY_SPACE)
					and viewport_container.get_global_rect().has_point(
						viewport_container.get_global_mouse_position()
					)
				)
			else:
				_quick_navigation_drag = false
			if _quick_navigation_drag:
				# Keep the zoom pivot at the original mouse-down location,
				# even while the mouse moves during the drag.
				_quick_zoom_anchor = mouse_pos
				return
		elif event is InputEventMouseMotion and _quick_navigation_drag:
			if Input.is_key_pressed(KEY_SPACE):
				if Input.is_key_pressed(KEY_ALT):
					# Use immediate updates for continuous dragging so separate
					# smooth-zoom tweens do not compete for camera position.
					zoom_camera(event.relative.x / 3.0, _quick_zoom_anchor, true)
				else:
					offset = offset - event.relative.rotated(camera_angle) / zoom
					update_transparent_checker_offset()
			else:
				_quick_navigation_drag = false
			return
		elif event is InputEventKey and not Input.is_key_pressed(KEY_SPACE):
			_quick_navigation_drag = false

	if event.is_action_pressed(&"pan"):
		# When Space is configured as Quick Pan, do not let its legacy
		# camera-pan binding move the canvas without a mouse drag.
		if event is InputEventKey and Tools.has_space_alt_quick_navigation():
			var key_event := event as InputEventKey
			if key_event.keycode != KEY_SPACE and key_event.physical_keycode != KEY_SPACE:
				drag = true
		else:
			drag = true
	elif event.is_action_released(&"pan"):
		drag = false
	elif event.is_action_pressed(&"zoom_in", false, true):  # Wheel Up Event
		zoom_camera(1)
	elif event.is_action_pressed(&"zoom_out", false, true):  # Wheel Down Event
		zoom_camera(-1)
	elif event.is_action_pressed(&"rotate_right", false, true):  # Wheel Up Event
		rotate_camera(1)
	elif event.is_action_pressed(&"rotate_left", false, true):  # Wheel Down Event
		rotate_camera(-1)

	elif event is InputEventMagnifyGesture:  # Zoom gesture on touchscreens
		var scale_factor := (event as InputEventMagnifyGesture).factor
		var zoom_strength := log(scale_factor) * 8.0
		zoom_camera(zoom_strength, event.position)
	elif event is InputEventPanGesture:
		# Pan gesture on touchscreens
		offset = offset + event.delta.rotated(camera_angle) * 2.0 / zoom
	elif event is InputEventMouseMotion:
		if drag:
			offset = offset - event.relative.rotated(camera_angle) / zoom
			update_transparent_checker_offset()
	else:
		var dir := Input.get_vector(&"camera_left", &"camera_right", &"camera_up", &"camera_down")
		var root := get_tree().current_scene
		if (
			dir != Vector2.ZERO
			and not Tools.selection_tool_has_selection()
			and not root.is_writing_text
		):
			offset = offset + (dir.rotated(camera_angle) / zoom) * CAMERA_SPEED_RATE


## Temporary canvas rotation, without modifying image pixels. All activation
## shortcuts come from the active Keychain shortcut profile.
## Hold its configured key chord and left-drag, or drag with a bound
## mouse button (for example Shift+Middle Mouse). Double-click with the
## same activation resets to zero as a convenience.
func _handle_clipstudio_rotation(event: InputEvent) -> bool:
	var in_canvas := viewport_container.get_global_rect().has_point(
		viewport_container.get_global_mouse_position()
	)

	# Reset is an independent, remappable shortcut (default: 0).
	if in_canvas and event.is_action_pressed(&"canvas_rotate_reset", false, true):
		camera_angle = 0.0
		get_viewport().set_input_as_handled()
		return true

	# These can be Shift+wheel by default, or any other input the user chooses.
	if in_canvas and event.is_action_pressed(&"canvas_rotate_step_left", false, true):
		rotate_camera(-5.0)
		get_viewport().set_input_as_handled()
		return true
	if in_canvas and event.is_action_pressed(&"canvas_rotate_step_right", false, true):
		rotate_camera(5.0)
		get_viewport().set_input_as_handled()
		return true

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if _clipstudio_rotate_drag and mouse_event.button_index == _clipstudio_rotate_button:
			if not mouse_event.pressed:
				_clipstudio_rotate_drag = false
				_clipstudio_rotate_mouse_shortcut = false
				get_viewport().set_input_as_handled()
				return true
		if not mouse_event.pressed or not in_canvas or Tools.active_button != -1:
			return false
		var held_key_and_left_button := (
			mouse_event.button_index == MOUSE_BUTTON_LEFT
			and Tools.is_keyboard_shortcut_held(&"canvas_rotate_drag")
		)
		var bound_mouse_button := event.is_action_pressed(&"canvas_rotate_drag", false, true)
		if not held_key_and_left_button and not bound_mouse_button:
			return false
		_clipstudio_rotate_drag = true
		_clipstudio_rotate_button = mouse_event.button_index
		_clipstudio_rotate_mouse_shortcut = bound_mouse_button and not held_key_and_left_button
		_clipstudio_rotate_previous_mouse = mouse_pos
		drag = false
		_quick_navigation_drag = false
		if mouse_event.double_click:
			camera_angle = 0.0
		get_viewport().set_input_as_handled()
		return true

	if event is InputEventMouseMotion and _clipstudio_rotate_drag:
		if not Input.is_mouse_button_pressed(_clipstudio_rotate_button):
			_clipstudio_rotate_drag = false
			_clipstudio_rotate_mouse_shortcut = false
			return true
		if (
			_clipstudio_rotate_mouse_shortcut
			or Tools.is_keyboard_shortcut_held(&"canvas_rotate_drag")
		):
			var center := viewport_container.size * 0.5
			var previous := _clipstudio_rotate_previous_mouse - center
			var current := mouse_pos - center
			# Avoid angular jumps when a drag passes through the pivot.
			if previous.length_squared() > 256.0 and current.length_squared() > 256.0:
				camera_angle -= previous.angle_to(current)
		_clipstudio_rotate_previous_mouse = mouse_pos
		get_viewport().set_input_as_handled()
		return true
	return false

func rotate_camera(dir: float) -> void:
	camera_angle += PI / 180 * dir


func zoom_camera(dir: float, event_pos := mouse_pos, immediate := false) -> void:
	var viewport_size := viewport_container.size
	if Global.smooth_zoom:
		var zoom_margin := zoom * dir / 5
		var new_zoom := zoom + zoom_margin
		if Global.integer_zoom:
			if dir < 0:
				new_zoom = new_zoom.floor()
			else:
				new_zoom = new_zoom.ceil()
		if new_zoom < zoom_in_max && new_zoom > zoom_out_max:
			var new_offset := (
				offset
				+ (
					(-0.5 * viewport_size + event_pos).rotated(camera_angle)
					* (Vector2.ONE / zoom - Vector2.ONE / new_zoom)
				)
			)
			if immediate:
				zoom = new_zoom
				offset = new_offset
			else:
				var tween := create_tween().set_parallel()
				tween.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN)
				tween.tween_property(self, "zoom", new_zoom, 0.05)
				tween.tween_property(self, "offset", new_offset, 0.05)
	else:
		var prev_zoom := zoom
		var zoom_margin := zoom * dir / 10
		if zoom + zoom_margin <= zoom_in_max:
			zoom += zoom_margin
		if Global.integer_zoom:
			if dir < 0:
				zoom = zoom.floor()
			else:
				zoom = zoom.ceil()
		if zoom < zoom_out_max:
			if Global.integer_zoom:
				zoom = Vector2.ONE
			else:
				zoom = zoom_out_max
		offset = (
			offset
			+ (
				(-0.5 * viewport_size + event_pos).rotated(camera_angle)
				* (Vector2.ONE / prev_zoom - Vector2.ONE / zoom)
			)
		)


func zoom_100() -> void:
	zoom = Vector2.ONE
	offset = Global.current_project.size / 2


func fit_to_frame(size: Vector2) -> void:
	viewport_container = get_viewport().get_parent()
	var h_ratio := viewport_container.size.x / size.x
	var v_ratio := viewport_container.size.y / size.y
	var ratio := minf(h_ratio, v_ratio)
	if ratio == 0 or !viewport_container.visible:
		return
	# Temporarily disable integer zoom.
	var reset_integer_zoom := Global.integer_zoom
	if reset_integer_zoom:
		Global.integer_zoom = !Global.integer_zoom
	offset = size / 2

	# Adjust to the rotated size:
	if camera_angle != 0.0:
		# Calculating the rotated corners of the frame to find its rotated size.
		var a := Vector2.ZERO  # Top left
		var b := Vector2(size.x, 0).rotated(camera_angle)  # Top right.
		var c := Vector2(0, size.y).rotated(camera_angle)  # Bottom left.
		var d := Vector2(size.x, size.y).rotated(camera_angle)  # Bottom right.

		# Find how far apart each opposite point is on each axis, and take the longer one.
		size.x = maxf(absf(a.x - d.x), absf(b.x - c.x))
		size.y = maxf(absf(a.y - d.y), absf(b.y - c.y))

	ratio = clampf(ratio, 0.1, ratio)
	zoom = Vector2(ratio, ratio)
	if reset_integer_zoom:
		Global.integer_zoom = !Global.integer_zoom


func update_transparent_checker_offset() -> void:
	var o := get_global_transform_with_canvas().get_origin()
	var s := get_global_transform_with_canvas().get_scale()
	transparent_checker.update_offset(o, s)


## Updates the viewport's canvas transform, which is the area of the canvas that is
## currently visible. Called every time the camera's zoom, rotation or origin changes.
func _update_viewport_transform() -> void:
	if not is_instance_valid(viewport):
		return
	var zoom_scale := Vector2.ONE / zoom
	var viewport_size := get_viewport_rect().size
	var half_size := viewport_size * 0.5
	var screen_offset := -(half_size * zoom_scale).rotated(camera_angle) + offset
	var xform := Transform2D(camera_angle, zoom_scale, 0, screen_offset)
	camera_screen_center = xform * half_size
	viewport.canvas_transform = xform.affine_inverse()


func _zoom_changed() -> void:
	update_transparent_checker_offset()
	if index == Cameras.MAIN:
		should_tween = false
		zoom_slider.set_value_no_signal_update_display(zoom.x * 100.0)
		should_tween = true
		for guide in Global.current_project.guides:
			guide.width = 1.0 / zoom.x * 2


func _rotation_changed() -> void:
	if index == Cameras.MAIN:
		# Negative to make going up in value clockwise, and match the spinbox which does the same
		rotation_slider.value = -camera_angle_degrees


func _zoom_slider_value_changed(value: float) -> void:
	if value <= 0:
		value = 1
	var new_zoom := Vector2(value, value) / 100.0
	if zoom.is_equal_approx(new_zoom):
		return
	if Global.smooth_zoom and should_tween:
		var tween := create_tween().set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN)
		tween.tween_property(self, "zoom", new_zoom, 0.05)
	else:
		zoom = new_zoom


func _rotation_slider_value_changed(value: float) -> void:
	# Negative makes going up rotate clockwise
	var angle := deg_to_rad(-value)
	var difference := angle - camera_angle
	var canvas_center: Vector2 = Global.current_project.size / 2
	offset = (offset - canvas_center).rotated(difference) + canvas_center
	camera_angle = angle


func _project_switched() -> void:
	offset = Global.current_project.cameras_offset[index]
	camera_angle = Global.current_project.cameras_rotation[index]
	zoom = Global.current_project.cameras_zoom[index]


func _rotate_camera_around_point(degrees: float, point: Vector2) -> void:
	var angle := deg_to_rad(degrees)
	offset = (offset - point).rotated(angle) + point
	camera_angle = camera_angle + angle

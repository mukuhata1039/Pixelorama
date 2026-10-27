extends Container

const VALUE_ARROW := preload("res://assets/graphics/misc/value_arrow_right.svg")
const VALUE_ARROW_EXPANDED := preload("res://assets/graphics/misc/value_arrow.svg")

## The HBoxContainer parent of the picker shapes.
var shapes_container: HBoxContainer
## The internal control node of the HSV Rectangle of the [ColorPicker] node.
var hsv_rectangle: Control
## The internal control node of the HSV Wheel of the [ColorPicker] node.
var hsv_wheel: Control
## The internal control node of the VHS Circle of the [ColorPicker] node.
var vhs_circle: Control
## The internal control node of OKHSL VHS Circle of the [ColorPicker] node.
var okhsl_circle: Control
## The internal control node of the OK HS Rectangle of the [ColorPicker] node.
var ok_hs_rectangle: Control
## The internal control node of the OK HL Rectangle of the [ColorPicker] node.
var ok_hl_rectangle: Control
## The internal swatches button of the [ColorPicker] node.
## Used to ensure that swatches are always invisible.
var swatches_button: HBoxContainer
## The internal container for the color sliders of the [ColorPicker] node.
var color_slider_types_hbox: HBoxContainer
var color_sliders_grid: GridContainer
var _skip_color_picker_update := false
## A compact horizontal hue strip replaces only the HSV rectangle's native
## vertical hue control. Other picker shapes retain Godot's native behavior.
var hue_strip: Control
var native_hue_control: Control
var compact_hex_row: HBoxContainer
var _dragging_hue := false

@onready var color_picker := %ColorPicker as ColorPicker
@onready var color_buttons := %ColorButtons as HBoxContainer
@onready var left_color_rect := %LeftColorRect as ColorRect
@onready var right_color_rect := %RightColorRect as ColorRect
@onready var average_color := %AverageColor as ColorRect
@onready var expand_button: Button = $ScrollContainer/VerticalContainer/ExpandButton

@onready
var _mm_change_hue := Keychain.actions[&"mm_color_change_hue"] as Keychain.MouseMovementInputAction
@onready var _mm_change_sat := (
	Keychain.actions[&"mm_color_change_saturation"] as Keychain.MouseMovementInputAction
)
@onready var _mm_change_value := (
	Keychain.actions[&"mm_color_change_value"] as Keychain.MouseMovementInputAction
)
@onready var _mm_change_alpha := (
	Keychain.actions[&"mm_color_change_alpha"] as Keychain.MouseMovementInputAction
)


func _ready() -> void:
	Tools.options_reset.connect(reset_options)
	Tools.color_changed.connect(update_color)
	_average(left_color_rect.color, right_color_rect.color)
	color_picker.color_mode = Global.config_cache.get_value(
		"color_picker", "color_mode", ColorPicker.MODE_RGB
	)
	color_picker.picker_shape = Global.config_cache.get_value(
		"color_picker", "picker_shape", ColorPicker.SHAPE_HSV_RECTANGLE
	)
	# Make changes to the UI of the color picker by modifying its internal children
	await get_tree().process_frame
	# The MarginContainer that contains all of the color picker nodes.
	var picker_margin_container := color_picker.get_child(0, true) as MarginContainer
	picker_margin_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var picker_vbox_container := picker_margin_container.get_child(0, true) as VBoxContainer

	shapes_container = picker_vbox_container.get_child(0, true)
	shapes_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shapes_container.size_flags_vertical = Control.SIZE_FILL
	shapes_container.custom_minimum_size.y = 108
	hsv_rectangle = shapes_container.get_child(0, true) as Control
	hsv_rectangle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The native hue is a second child of Godot's HSV shape HBox. Its
	# input logic assumes vertical movement, so a separate horizontal
	# control is needed rather than simply reparenting/rotating it.
	native_hue_control = hsv_rectangle.get_parent().get_child(hsv_rectangle.get_index() + 1, true) as Control
	if is_instance_valid(native_hue_control):
		# The built-in picker may show this control again when it updates
		# its shape. Re-hide it whenever that happens, not just at startup.
		native_hue_control.visibility_changed.connect(_ensure_native_hue_hidden)
		_ensure_native_hue_hidden()
	_create_horizontal_hue_strip(picker_vbox_container)
	# The HBoxContainer of the screen color picker, the color preview rectangle and the
	# button that lets users change the picker shape. It is visible because
	# color_picker.sampler_visible is set to true.
	# We are hiding the color preview rectangle, adding the hex LineEdit, the
	# left/right color buttons and the color switch, default and average buttons.
	var sampler_cont := picker_vbox_container.get_child(1, true) as HBoxContainer
	# The color preview rectangle that we're hiding.
	var color_texture_rect := sampler_cont.get_child(1, true) as TextureRect
	color_texture_rect.visible = false
	var shape_menu_button := sampler_cont.get_child(2, true) as MenuButton
	var shape_popup_menu := shape_menu_button.get_popup()
	shape_popup_menu.id_pressed.connect(_on_shape_popup_menu_id_pressed)
	# Aseprite-style narrow stack: don't put buttons + HEX in the same row
	# as the sampler; that old arrangement forced the dock to grow wide.
	var hex_cont := picker_vbox_container.get_child(4, true) as Container
	var hex_edit := hex_cont.get_child(2, true) as LineEdit
	hex_cont.remove_child(hex_edit)
	compact_hex_row = HBoxContainer.new()
	var hex_row := compact_hex_row
	hex_row.name = "CompactHexRow"
	hex_row.visible = false
	hex_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hex_row.add_theme_constant_override("separation", 4)
	var hex_label := Label.new()
	hex_label.text = "HEX"
	hex_label.add_theme_font_size_override("font_size", 11)
	hex_row.add_child(hex_label)
	hex_row.add_child(hex_edit)
	hex_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hex_edit.custom_minimum_size.x = 90
	picker_vbox_container.add_child(hex_row)
	# Reuse the existing color button controls, keeping all their signals.
	color_buttons.get_parent().remove_child(color_buttons)
	picker_vbox_container.add_child(color_buttons)
	color_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	color_buttons.add_theme_constant_override("separation", 2)

	color_slider_types_hbox = picker_vbox_container.get_child(2, true) as HBoxContainer
	color_slider_types_hbox.visible = false
	color_sliders_grid = picker_vbox_container.get_child(3, true) as GridContainer
	color_sliders_grid.visible = false
	swatches_button = picker_vbox_container.get_child(5, true).get_child(0, true) as HBoxContainer
	swatches_button.visible = false
	# The GridContainer that contains the swatch buttons. These are not visible in our case
	# but for some reason its h_separation needs to be set to a value larger than 4,
	# otherwise a weird bug occurs with the Recent Colors where, adding new colors
	# increases the size of the color buttons.
	var presets_container := (
		picker_vbox_container.get_child(5, true).get_child(2, true) as GridContainer
	)
	presets_container.add_theme_constant_override("h_separation", 5)
	# Keep the eyedropper and picker-shape menu, but place them on the
	# same row as foreground/background instead of wasting another row.
	sampler_cont.get_parent().remove_child(sampler_cont)
	color_buttons.add_child(sampler_cont)
	sampler_cont.add_theme_constant_override("separation", 1)
	# Move the expand button with the rest of the native picker controls.
	expand_button.get_parent().remove_child(expand_button)
	picker_vbox_container.add_child(expand_button)

	# Keep Godot's native alpha control and its signals (including values).
	var alpha_row := _move_alpha_slider_below_color_square(picker_vbox_container)

	# Explicit visual order, independent of the native ColorPicker internals:
	# SV square / horizontal hue / alpha / colors+sampler / options / HEX.
	# HEX is only revealed when the user opens the advanced options.
	var ordered_rows: Array[Control] = [
		shapes_container, hue_strip, alpha_row, color_buttons,
		expand_button, hex_row
	]
	for index in ordered_rows.size():
		if is_instance_valid(ordered_rows[index]):
			picker_vbox_container.move_child(ordered_rows[index], index)
	picker_vbox_container.add_theme_constant_override("separation", 1)

	expand_button.button_pressed = Global.config_cache.get_value(
		"color_picker", "is_expanded", false
	)
	_on_shape_popup_menu_id_pressed(color_picker.picker_shape)


## Reuse the native alpha controls instead of duplicating them.
## Their existing ColorPicker signals and shared range continue to work.
func _move_alpha_slider_below_color_square(picker_vbox_container: VBoxContainer) -> HBoxContainer:
	var alpha_label: Label
	var alpha_slider: HSlider
	var alpha_spinbox: SpinBox
	for index in color_sliders_grid.get_child_count() - 2:
		var label := color_sliders_grid.get_child(index) as Label
		if is_instance_valid(label) and label.text == "A":
			alpha_label = label
			alpha_slider = color_sliders_grid.get_child(index + 1) as HSlider
			alpha_spinbox = color_sliders_grid.get_child(index + 2) as SpinBox
			break
	if not is_instance_valid(alpha_label):
		push_warning("Could not locate the ColorPicker alpha controls.")
		return null
	if not is_instance_valid(alpha_slider) or not is_instance_valid(alpha_spinbox):
		push_warning("Could not locate the ColorPicker alpha slider or value.")
		return null

	var alpha_row := HBoxContainer.new()
	alpha_row.name = "AlphaSliderRow"
	alpha_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	alpha_row.add_theme_constant_override("separation", 3)
	alpha_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The number field duplicates the alpha slider: keep the native
	# SpinBox alive for ColorPicker logic, but do not show it in the UI.
	alpha_spinbox.hide()
	alpha_spinbox.visibility_changed.connect(func():
		if alpha_spinbox.visible:
			alpha_spinbox.hide()
	)
	picker_vbox_container.add_child(alpha_row)
	picker_vbox_container.move_child(alpha_row, shapes_container.get_index() + 1)
	for control in [alpha_label, alpha_slider, alpha_spinbox]:
		color_sliders_grid.remove_child(control)
		alpha_row.add_child(control)
	return alpha_row


## Godot's native HSV hue strip is vertical. Draw our own horizontal strip
## while keeping the native SV square and alpha controls fully functional.
func _create_horizontal_hue_strip(picker_vbox_container: VBoxContainer) -> void:
	hue_strip = Control.new()
	hue_strip.name = "HorizontalHueStrip"
	hue_strip.custom_minimum_size.y = 12
	hue_strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hue_strip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hue_strip.tooltip_text = "Hue"
	picker_vbox_container.add_child(hue_strip)
	hue_strip.draw.connect(_draw_horizontal_hue_strip)
	hue_strip.gui_input.connect(_on_horizontal_hue_gui_input)
	color_picker.color_changed.connect(func(_color: Color): hue_strip.queue_redraw())


## Keep the redundant native hue column hidden after Godot's internal updates.
func _ensure_native_hue_hidden() -> void:
	if is_instance_valid(native_hue_control) and native_hue_control.visible:
		native_hue_control.hide()


func _draw_horizontal_hue_strip() -> void:
	if not is_instance_valid(hue_strip) or not hue_strip.visible:
		return
	var strip_size := hue_strip.size
	var segments := maxi(1, ceili(strip_size.x))
	for i in segments:
		var x := float(i) / float(segments) * strip_size.x
		var next_x := float(i + 1) / float(segments) * strip_size.x
		hue_strip.draw_rect(
			Rect2(x, 0, next_x - x + 0.5, strip_size.y),
			Color.from_hsv(float(i) / float(segments), 1.0, 1.0)
		)
	var marker_x := roundf(color_picker.color.h * (strip_size.x - 1.0))
	hue_strip.draw_line(Vector2(marker_x, 0), Vector2(marker_x, strip_size.y), Color.BLACK, 3.0)
	hue_strip.draw_line(Vector2(marker_x, 0), Vector2(marker_x, strip_size.y), Color.WHITE, 1.0)
	hue_strip.draw_rect(Rect2(Vector2.ZERO, strip_size), Color(0.2, 0.2, 0.2), false, 1.0)


func _on_horizontal_hue_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging_hue = event.pressed
		if _dragging_hue:
			_apply_horizontal_hue(event.position.x)
	elif event is InputEventMouseMotion and _dragging_hue:
		_apply_horizontal_hue(event.position.x)


func _apply_horizontal_hue(x: float) -> void:
	var selected := color_picker.color
	selected.h = clampf(x / maxf(1.0, hue_strip.size.x - 1.0), 0.0, 1.0)
	color_picker.color = selected
	# Programmatic ColorPicker.color assignment doesn't emit color_changed.
	_on_color_picker_color_changed(selected)
	# A locked layer may reject the chosen hue: keep the preview in sync.
	color_picker.color = Tools.get_assigned_color(Tools.picking_color_for)
	hue_strip.queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_instance_valid(left_color_rect):
		_average(left_color_rect.color, right_color_rect.color)


func _input(event: InputEvent) -> void:
	var hue_value := _mm_change_hue.get_action_distance(event)
	var sat_value := _mm_change_sat.get_action_distance(event)
	var value_value := _mm_change_value.get_action_distance(event)
	var alpha_value := _mm_change_alpha.get_action_distance(event)
	if (
		is_zero_approx(hue_value)
		and is_zero_approx(sat_value)
		and is_zero_approx(value_value)
		and is_zero_approx(alpha_value)
	):
		return
	var c: Color = Tools._slots[Tools.picking_color_for].color
	c.h += hue_value
	c.s += sat_value
	c.v += value_value
	c.a += alpha_value
	Tools.assign_color(c, Tools.picking_color_for, false)


func _on_color_picker_color_changed(color: Color) -> void:
	# Due to the decimal nature of the color values, some values get rounded off
	# unintentionally before entering this method.
	# Even though the decimal values change, the HTML code remains the same after the change.
	# So we're using this trick to convert the values back to how they are shown in
	# the color picker's UI.
	color = Color(color.to_html())
	_skip_color_picker_update = true
	# This was requested by Issue #54 on GitHub
	# Do it here instead of in Tools.assign_color in order to ensure that the
	# color picker's color value changes.
	var c: Color = Tools._slots[Tools.picking_color_for].color
	if color.a == 0:
		if color.r != c.r or color.g != c.g or color.b != c.b:
			color.a = 1
			color_picker.color.a = 1
	Tools.assign_color(color, Tools.picking_color_for, false)


func _on_shape_popup_menu_id_pressed(id: ColorPicker.PickerShapeType) -> void:
	if is_instance_valid(hue_strip):
		hue_strip.visible = id == ColorPicker.SHAPE_HSV_RECTANGLE
	_ensure_native_hue_hidden()
	Global.config_cache.set_value("color_picker", "picker_shape", color_picker.picker_shape)
	# All of this is needed so that the shape controls scale well when resized.
	# The internal AspectRatioContainer was removed in Godot 4.5 so we have to add our own
	# for the non-rectangular shapes.
	_hide_shape_controls()
	if id == ColorPicker.SHAPE_HSV_WHEEL:
		if is_instance_valid(hsv_wheel):
			hsv_wheel.get_parent().visible = true
		else:
			hsv_wheel = shapes_container.get_child(-1, true)
			_modify_color_shapes(hsv_wheel, false)
	elif id == ColorPicker.SHAPE_VHS_CIRCLE:
		if is_instance_valid(vhs_circle):
			vhs_circle.get_parent().visible = true
		else:
			vhs_circle = shapes_container.get_child(-2, true)
			_modify_color_shapes(vhs_circle, false)
	elif id == ColorPicker.SHAPE_OKHSL_CIRCLE:
		if is_instance_valid(okhsl_circle):
			okhsl_circle.get_parent().visible = true
		else:
			okhsl_circle = shapes_container.get_child(-2, true)
			_modify_color_shapes(okhsl_circle, false)
	elif id == ColorPicker.SHAPE_OK_HS_RECTANGLE and not is_instance_valid(ok_hs_rectangle):
		ok_hs_rectangle = shapes_container.get_child(-2, true)
		_modify_color_shapes(ok_hs_rectangle, true)
	elif id == ColorPicker.SHAPE_OK_HL_RECTANGLE and not is_instance_valid(ok_hl_rectangle):
		ok_hl_rectangle = shapes_container.get_child(-2, true)
		_modify_color_shapes(ok_hl_rectangle, true)


func _modify_color_shapes(node: Control, rectangle: bool) -> void:
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not rectangle:
		var aspect_ratio_container := AspectRatioContainer.new()
		aspect_ratio_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		aspect_ratio_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var node_index := node.get_index(true)
		shapes_container.remove_child(node)
		aspect_ratio_container.add_child(node)
		shapes_container.add_child(aspect_ratio_container)
		shapes_container.move_child(aspect_ratio_container, node_index)


func _hide_shape_controls() -> void:
	if is_instance_valid(hsv_wheel):
		hsv_wheel.get_parent().visible = false
	if is_instance_valid(vhs_circle):
		vhs_circle.get_parent().visible = false
	if is_instance_valid(okhsl_circle):
		okhsl_circle.get_parent().visible = false


func _on_left_color_button_toggled(toggled_on: bool) -> void:
	if toggled_on:
		Tools.picking_color_for = MOUSE_BUTTON_LEFT
		color_picker.color = left_color_rect.color
	else:
		Tools.picking_color_for = MOUSE_BUTTON_RIGHT
		color_picker.color = right_color_rect.color
	_average(left_color_rect.color, right_color_rect.color)
	if is_instance_valid(hue_strip):
		hue_strip.queue_redraw()


func reset_options() -> void:
	color_picker.color_mode = ColorPicker.MODE_RGB
	color_picker.picker_shape = ColorPicker.SHAPE_HSV_RECTANGLE
	expand_button.button_pressed = false


func update_color(color_info: Dictionary, button: int) -> void:
	var color = color_info.get("color", Color.WHITE)
	if Tools.picking_color_for == button and not _skip_color_picker_update:
		color_picker.color = color
	if button == MOUSE_BUTTON_RIGHT:
		right_color_rect.color = color
	else:
		left_color_rect.color = color
	_average(left_color_rect.color, right_color_rect.color)
	if is_instance_valid(hue_strip):
		hue_strip.queue_redraw()
	Global.config_cache.set_value("color_picker", "color_mode", color_picker.color_mode)
	Global.config_cache.set_value("color_picker", "picker_shape", color_picker.picker_shape)
	_skip_color_picker_update = false


func _on_ColorSwitch_pressed() -> void:
	Tools.swap_color()


func _on_ColorDefaults_pressed() -> void:
	Tools.default_color()


func _on_expand_button_toggled(toggled_on: bool) -> void:
	if is_instance_valid(compact_hex_row):
		compact_hex_row.visible = toggled_on
	if toggled_on:
		expand_button.icon = VALUE_ARROW_EXPANDED
	else:
		expand_button.icon = VALUE_ARROW
	color_picker.color_modes_visible = toggled_on
	color_picker.sliders_visible = toggled_on
	color_picker.presets_visible = toggled_on
	if is_instance_valid(swatches_button):
		swatches_button.visible = false
	if is_instance_valid(color_sliders_grid):
		color_slider_types_hbox.visible = toggled_on
		color_sliders_grid.visible = toggled_on
	Global.config_cache.set_value("color_picker", "is_expanded", toggled_on)


func _average(color_1: Color, color_2: Color) -> void:
	var average := (color_1 + color_2) / 2.0
	var copy_button := average_color.get_parent() as Control
	copy_button.tooltip_text = str(tr("Average Color:"), "\n#", average.to_html())
	average_color.color = average


func _on_CopyAverage_button_down() -> void:
	average_color.visible = false


func _on_CopyAverage_button_up() -> void:
	average_color.visible = true


func _on_copy_average_gui_input(event: InputEvent) -> void:
	if event.is_action_released(&"left_mouse"):
		Tools.assign_color(average_color.color, MOUSE_BUTTON_LEFT)
	elif event.is_action_released(&"right_mouse"):
		Tools.assign_color(average_color.color, MOUSE_BUTTON_RIGHT)

extends ConfirmationDialog

const RECOLOR_SHADER := preload("res://src/Shaders/LiveRecolor.gdshader")
const POSITION_CONFIG_SECTION := "recolor_dialog"
const POSITION_CONFIG_KEY := "last_position"
## Replace all nontransparent pixels in the chosen cels with a single RGBA color.
## Preview is rendered through Canvas/BaseLayer, so Cancel never modifies image data.

var _project: Project
var _targets: Array = []
## Set before popup by TopMenuContainer to enable whole-layer recoloring.
var requested_layer: PixelLayer
var _target_layer: PixelLayer

@onready var content_scroll := $ContentScroll as ScrollContainer
@onready var help_label := $ContentScroll/VBox/Help as Label
@onready var scope_label := $ContentScroll/VBox/ScopeLabel as Label
@onready var color_picker := %ColorPicker as ColorPicker
@onready var alpha_slider := %AlphaSlider as HSlider
@onready var alpha_label := %AlphaLabel as Label
@onready var scope_button := %ScopeButton as OptionButton
@onready var affected_label := %AffectedLabel as Label
@onready var previous_frame := %PreviousFrame as Button
@onready var next_frame := %NextFrame as Button


func _ready() -> void:
	get_ok_button().text = tr("Apply")
	about_to_popup.connect(_prepare)
	size_changed.connect(_sync_scroll_area)
	confirmed.connect(_apply)
	visibility_changed.connect(_on_visibility_changed)
	color_picker.color_changed.connect(_on_color_changed)
	alpha_slider.value_changed.connect(_on_alpha_changed)
	scope_button.item_selected.connect(_on_scope_changed)
	previous_frame.pressed.connect(_change_preview_frame.bind(-1))
	next_frame.pressed.connect(_change_preview_frame.bind(1))
	Global.project_about_to_switch.connect(_stop_preview)


## The popup has a bounded height, with its Apply/Cancel footer kept visible.
## Use identical sizing before popup and during about_to_popup.
func _desired_dialog_size() -> Vector2i:
	var editor_height := Global.control.get_window().size.y
	return Vector2i(530, clampi(editor_height - 70, 220, 640))


## Open at the last closed position, including after restarting Pixelorama.
## If monitors change or the saved location is no longer visible, center it.
func popup_at_last_position() -> void:
	var desired_size := _desired_dialog_size()
	var remembered: Variant = Global.config_cache.get_value(
		POSITION_CONFIG_SECTION, POSITION_CONFIG_KEY, null
	)
	if remembered is Vector2i:
		var remembered_position: Vector2i = remembered
		var embedded := Global.control.get_viewport().gui_embed_subwindows
		if embedded:
			var editor_rect := Rect2i(Vector2i.ZERO, Global.control.get_window().size)
			if editor_rect.has_point(remembered_position):
				popup(Rect2i(_clamp_position(remembered_position, desired_size, editor_rect), desired_size))
				return
		else:
			for i in DisplayServer.get_screen_count():
				var screen_rect := DisplayServer.screen_get_usable_rect(i)
				if screen_rect.has_point(remembered_position):
					popup(Rect2i(_clamp_position(remembered_position, desired_size, screen_rect), desired_size))
					return
	popup_centered_clamped(desired_size)


func _clamp_position(pos: Vector2i, dialog_size: Vector2i, area: Rect2i) -> Vector2i:
	return Vector2i(
		clampi(pos.x, area.position.x, maxi(area.position.x, area.end.x - dialog_size.x)),
		clampi(pos.y, area.position.y, maxi(area.position.y, area.end.y - dialog_size.y))
	)


## The first popup can be relaid out after about_to_popup. Fit it once
## before opening and once on the next idle frame to correct that first-open
## stretch without requiring the user to close and reopen the window.
func _fit_dialog_to_editor() -> void:
	var requested_size := _desired_dialog_size()
	if size != requested_size:
		size = requested_size
	_sync_scroll_area()


func _sync_scroll_area() -> void:
	if not is_instance_valid(content_scroll):
		return
	# ConfirmationDialog owns the bottom Apply/Cancel row, outside the scroll.
	content_scroll.offset_right = float(size.x - 16)
	content_scroll.offset_bottom = float(size.y - 60)


func _prepare() -> void:
	_fit_dialog_to_editor()
	call_deferred("_fit_dialog_to_editor")
	content_scroll.scroll_vertical = 0
	_project = Global.current_project
	if _project == null:
		return
	_target_layer = requested_layer if is_instance_valid(requested_layer) else null
	requested_layer = null
	var editing_layer := is_instance_valid(_target_layer)
	title = "Change layer color" if editing_layer else "Recolor drawn pixels"
	help_label.text = (
		"Replace all painted pixels on this layer in every frame. "
		+ "Original pixel opacity is ignored."
		if editing_layer else "Replace every nontransparent pixel with the chosen color."
	)
	scope_label.visible = not editing_layer
	scope_button.visible = not editing_layer
	var base_color := (
		_target_layer.drawing_color
		if editing_layer else Tools.get_assigned_color(MOUSE_BUTTON_LEFT)
	)
	# The layer icon changes *all* painted pixels to the chosen new opacity,
	# not their old opacity. Start at fully opaque even if the lock was translucent.
	base_color.a = 1.0
	color_picker.color = base_color
	alpha_slider.set_value_no_signal(roundi(base_color.a * 100.0))
	alpha_label.text = "%d%%" % roundi(base_color.a * 100.0)
	# Layer-icon mode always targets every frame, regardless of timeline selection.
	scope_button.select(2 if editing_layer else (1 if _project.selected_cels.size() > 1 else 0))
	_refresh_preview()


func _get_target_indices() -> Array:
	var target_indices: Array = []
	if not is_instance_valid(_project):
		return target_indices
	if is_instance_valid(_target_layer):
		if _target_layer.project != _project or not _project.layers.has(_target_layer):
			return target_indices
		for frame_index in _project.frames.size():
			target_indices.append([frame_index, _target_layer.index])
	else:
		match scope_button.selected:
			0:
				target_indices.append([_project.current_frame, _project.current_layer])
			1:
				for pair in _project.selected_cels:
					if not target_indices.has(pair):
						target_indices.append(pair.duplicate())
			2:
				for frame_index in _project.frames.size():
					target_indices.append([frame_index, _project.current_layer])
	var result: Array = []
	for pair in target_indices:
		if pair[0] < 0 or pair[0] >= _project.frames.size():
			continue
		if pair[1] < 0 or pair[1] >= _project.layers.size():
			continue
		var layer := _project.layers[pair[1]]
		if not layer is PixelLayer:
			continue
		if not is_instance_valid(_target_layer) and not layer.can_layer_get_drawn():
			continue
		var cel := _project.frames[pair[0]].cels[pair[1]]
		if not cel is PixelCel or cel is CelTileMap:
			continue
		result.append(pair)
	return result


func _refresh_preview() -> void:
	if not is_instance_valid(_project):
		return
	_targets = _get_target_indices()
	var alpha_percent := roundi(alpha_slider.value)
	var selected_color := _get_selected_color()
	alpha_label.text = "%d%%" % alpha_percent
	var unsupported := _project.is_indexed()
	if unsupported:
		affected_label.text = tr("Indexed-color projects are not supported.")
	else:
		affected_label.text = tr("Affected cels: %d") % _targets.size()
	get_ok_button().disabled = (
		unsupported
		or _targets.is_empty()
		or (is_instance_valid(_target_layer) and selected_color.a <= 0.0)
	)
	previous_frame.disabled = _project.frames.size() <= 1
	next_frame.disabled = _project.frames.size() <= 1
	if unsupported or _targets.is_empty():
		Global.canvas.clear_live_recolor_preview()
	else:
		Global.canvas.set_live_recolor_preview(
			_project, _targets, selected_color, false
		)


## Use one external opacity slider rather than a second alpha slider in the picker.
## The picker edits RGB/HSV; the slider supplies the saved and previewed alpha.
func _get_selected_color() -> Color:
	var chosen := color_picker.color
	chosen.a = alpha_slider.value / 100.0
	return chosen


func _on_color_changed(_color: Color) -> void:
	_refresh_preview()


func _on_alpha_changed(_value: float) -> void:
	_refresh_preview()


func _on_scope_changed(_index: int) -> void:
	_refresh_preview()


func _change_preview_frame(direction: int) -> void:
	if not is_instance_valid(_project) or _project != Global.current_project:
		return
	if _project.frames.size() < 2:
		return
	var target_frame := wrapi(_project.current_frame + direction, 0, _project.frames.size())
	_project.change_cel(target_frame, _project.current_layer)
	# Preview the newly active cel in single-cel mode, or retain the
	# selected-layer targets in the other two modes.
	_refresh_preview()


func _apply() -> void:
	if not is_instance_valid(_project) or _project.is_indexed():
		return
	var targets := _targets.duplicate(true)
	if targets.is_empty():
		return
	# The preview must be disabled before the real images are written.
	Global.canvas.clear_live_recolor_preview()
	var selected_color := _get_selected_color()
	var selected: Dictionary = {}
	for pair in targets:
		selected[_project.frames[pair[0]].cels[pair[1]]] = true
	var reused_images: Dictionary = {}
	var entries: Array[Dictionary] = []
	for pair in targets:
		var layer := _project.layers[pair[1]] as PixelLayer
		var cel := _project.frames[pair[0]].cels[pair[1]] as PixelCel
		var old_image := cel.get_image()
		var link_set = cel.link_set
		var split_link := false
		if link_set != null and link_set.has("cels"):
			for linked_cel in link_set["cels"]:
				if not selected.has(linked_cel):
					split_link = true
					break
		var replacement: ImageExtended
		var image_key := old_image.get_instance_id()
		if not split_link and reused_images.has(image_key):
			replacement = reused_images[image_key]
		else:
			replacement = ImageExtended.create_from_image(old_image)
			var generator := ShaderImageEffect.new()
			generator.generate_image(
				replacement,
				RECOLOR_SHADER,
				{
					"target_color": selected_color,
					"preserve_alpha": false,
				},
				replacement.get_size()
			)
			if not split_link:
				reused_images[image_key] = replacement
		entries.append({
			"cel": cel,
			"layer": layer,
			"before": old_image,
			"after": replacement,
			"offset": cel.offset,
			"link_set": link_set,
			"split_link": split_link,
		})
	var undo_redo := _project.undo_redo
	var editing_layer: PixelLayer = _target_layer if is_instance_valid(_target_layer) else null
	undo_redo.create_action("Change Layer Color" if editing_layer != null else "Draw")
	undo_redo.add_do_method(_set_recolored_contents.bind(entries, true))
	if editing_layer != null:
		var old_color: Color = editing_layer.drawing_color
		var was_locked: bool = editing_layer.drawing_color_locked
		undo_redo.add_do_method(
			_set_layer_locked_color.bind(editing_layer, selected_color, true)
		)
		undo_redo.add_undo_method(
			_set_layer_locked_color.bind(editing_layer, old_color, was_locked)
		)
	undo_redo.add_do_method(Global.undo_or_redo.bind(false, -1, -1, _project))
	undo_redo.add_undo_method(Global.undo_or_redo.bind(true, -1, -1, _project))
	undo_redo.add_undo_method(_set_recolored_contents.bind(entries, false))
	undo_redo.commit_action()


func _set_layer_locked_color(layer: PixelLayer, color: Color, locked: bool) -> void:
	if not is_instance_valid(layer):
		return
	layer.drawing_color = color
	layer.drawing_color_locked = locked
	Tools.apply_layer_drawing_color_lock()


func _set_recolored_contents(entries: Array[Dictionary], apply_new: bool) -> void:
	for entry in entries:
		var cel := entry["cel"] as PixelCel
		var layer := entry["layer"] as PixelLayer
		if apply_new and entry["split_link"]:
			layer.link_cel(cel, null)
		var contents: ImageExtended = entry["after"] if apply_new else entry["before"]
		cel.set_content([contents, entry["offset"]])
		if not apply_new and entry["split_link"]:
			layer.link_cel(cel, entry["link_set"])
	Global.canvas.update_all_layers = true
	Global.canvas.queue_redraw()


func _stop_preview() -> void:
	if is_instance_valid(Global.canvas):
		Global.canvas.clear_live_recolor_preview()


func _on_visibility_changed() -> void:
	if visible:
		return
	# Keep only the window position, not its size. The height continues
	# to adapt to the editor on the next opening.
	Global.config_cache.set_value(POSITION_CONFIG_SECTION, POSITION_CONFIG_KEY, position)
	Global.config_cache.save(Global.CONFIG_PATH)
	_stop_preview()
	# The recolor dialog does not dim the background when opened, so it must
	# not reset the shared dialog dimming state when it closes.
	# Keep the snapshot here: ConfirmationDialog can hide before emitting
	# confirmed, and _apply() must still be able to access its targets.

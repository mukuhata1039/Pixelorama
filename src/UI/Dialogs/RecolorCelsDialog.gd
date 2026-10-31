extends ConfirmationDialog

const RECOLOR_SHADER := preload("res://src/Shaders/LiveRecolor.gdshader")
## Replace all nontransparent pixels in the chosen cels with a single RGBA color.
## Preview is rendered through Canvas/BaseLayer, so Cancel never modifies image data.

var _project: Project
var _targets: Array = []

@onready var color_button := %ColorButton as ColorPickerButton
@onready var alpha_slider := %AlphaSlider as HSlider
@onready var alpha_label := %AlphaLabel as Label
@onready var scope_button := %ScopeButton as OptionButton
@onready var affected_label := %AffectedLabel as Label
@onready var previous_frame := %PreviousFrame as Button
@onready var next_frame := %NextFrame as Button


func _ready() -> void:
	get_ok_button().text = tr("Apply")
	about_to_popup.connect(_prepare)
	confirmed.connect(_apply)
	visibility_changed.connect(_on_visibility_changed)
	color_button.color_changed.connect(_on_color_changed)
	alpha_slider.value_changed.connect(_on_alpha_changed)
	scope_button.item_selected.connect(_on_scope_changed)
	previous_frame.pressed.connect(_change_preview_frame.bind(-1))
	next_frame.pressed.connect(_change_preview_frame.bind(1))
	Global.project_about_to_switch.connect(_stop_preview)


func _prepare() -> void:
	_project = Global.current_project
	if _project == null:
		return
	var base_color := Tools.get_assigned_color(MOUSE_BUTTON_LEFT)
	base_color.a = 1.0
	color_button.color = base_color
	alpha_slider.set_value_no_signal(100.0)
	alpha_label.text = "100%"
	# Multi-cell mode is most useful when several timeline cels are selected.
	scope_button.select(1 if _project.selected_cels.size() > 1 else 0)
	_refresh_preview()


func _get_target_indices() -> Array:
	var target_indices: Array = []
	if not is_instance_valid(_project):
		return target_indices
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
		if not layer is PixelLayer or not layer.can_layer_get_drawn():
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
	var alpha_percent := roundi(color_button.color.a * 100.0)
	alpha_slider.set_value_no_signal(alpha_percent)
	alpha_label.text = "%d%%" % alpha_percent
	var unsupported := _project.is_indexed()
	if unsupported:
		affected_label.text = tr("Indexed-color projects are not supported.")
	else:
		affected_label.text = tr("Affected cels: %d") % _targets.size()
	get_ok_button().disabled = unsupported or _targets.is_empty()
	previous_frame.disabled = _project.frames.size() <= 1
	next_frame.disabled = _project.frames.size() <= 1
	if unsupported or _targets.is_empty():
		Global.canvas.clear_live_recolor_preview()
	else:
		Global.canvas.set_live_recolor_preview(_project, _targets, color_button.color)


func _on_color_changed(_color: Color) -> void:
	_refresh_preview()


func _on_alpha_changed(value: float) -> void:
	var color := color_button.color
	color.a = value / 100.0
	color_button.color = color
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
				replacement, RECOLOR_SHADER,
				{"target_color": color_button.color}, replacement.get_size()
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
	undo_redo.create_action("Draw")
	undo_redo.add_do_method(_set_recolored_contents.bind(entries, true))
	undo_redo.add_do_method(Global.undo_or_redo.bind(false, -1, -1, _project))
	undo_redo.add_undo_method(Global.undo_or_redo.bind(true, -1, -1, _project))
	undo_redo.add_undo_method(_set_recolored_contents.bind(entries, false))
	undo_redo.commit_action()


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
	_stop_preview()
	Global.dialog_open(false)
	# Keep the snapshot here: ConfirmationDialog can hide before emitting
	# confirmed, and _apply() must still be able to access its targets.

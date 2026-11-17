extends ConfirmationDialog
## Generate seamless, local 1-3 pixel silhouette changes from the active pixel cel.
## Keep the source cel intact. Insert new frames or overwrite only the active layer
## in existing frames. Preserve linked source cels and support Undo/Redo.

@onready var frame_count_input := $ContentScroll/Options/Frames/Count as SpinBox
@onready var radius_input := $ContentScroll/Options/Radius/Radius as SpinBox
@onready var destination_input := $ContentScroll/Options/Destination/Mode as OptionButton
@onready var content_scroll := $ContentScroll as ScrollContainer


func _ready() -> void:
	get_ok_button().text = "生成"
	about_to_popup.connect(_fit_dialog)
	size_changed.connect(_sync_scroll_area)
	confirmed.connect(_generate)
	visibility_changed.connect(_on_visibility_changed)


## Keep the Confirm/Cancel buttons at the bottom, outside the scroll area.
func _fit_dialog() -> void:
	var editor_height := Global.control.get_window().size.y
	size = Vector2i(400, clampi(editor_height - 80, 150, 260))
	_sync_scroll_area()


func _sync_scroll_area() -> void:
	if is_instance_valid(content_scroll):
		content_scroll.offset_right = float(size.x - 12)
		content_scroll.offset_bottom = float(maxi(80, size.y - 60))


func _on_visibility_changed() -> void:
	if not visible:
		Global.dialog_open(false)


func _generate() -> void:
	var project := Global.current_project
	if not is_instance_valid(project) or project.is_indexed():
		Global.popup_error("RGBAモードのプロジェクトで使用してください。")
		return
	var layer_index := project.current_layer
	if layer_index < 0 or layer_index >= project.layers.size():
		return
	var layer := project.layers[layer_index]
	if not layer is PixelLayer or not layer.can_layer_get_drawn():
		Global.popup_error("編集可能なピクセルレイヤーを選択してください。")
		return
	Global.transform_content_confirmed.emit(project)
	var first_frame_index := project.current_frame
	var first_frame := project.frames[first_frame_index]
	var source_cel := first_frame.cels[layer_index]
	if not source_cel is PixelCel or source_cel is CelTileMap:
		Global.popup_error("通常のピクセルセルが必要です。")
		return
	var width := project.size.x
	var height := project.size.y
	var source := project.new_empty_image()
	source.fill(Color.TRANSPARENT)
	source.blit_rect(
		source_cel.get_image(),
		Rect2i(Vector2i.ZERO, source_cel.get_image().get_size()),
		source_cel.offset
	)
	var solid := PackedByteArray()
	solid.resize(width * height)
	var painted := false
	for y in range(height):
		for x in range(width):
			var index := y * width + x
			if source.get_pixel(x, y).a > 0.0:
				solid[index] = 1
				painted = true
	if not painted:
		Global.popup_error("選択セルには描画されたピクセルがありません。")
		return
	var distance_to_solid := _distance_field(solid, width, height, 1)
	var distance_to_empty := _distance_field(solid, width, height, 0)
	var selected: PackedByteArray
	if project.has_selection:
		selected.resize(width * height)
		# Cache the selection rectangle; otherwise this helper recalculates
		# get_used_rect() for every pixel on large images.
		project.selection_map.lock_selection_rect(project, true)
		for y in range(height):
			for x in range(width):
				if project.selection_map.is_pixel_selected(Vector2i(x, y)):
					selected[y * width + x] = 1
		project.selection_map.lock_selection_rect(project, false)
	var total_frames := int(frame_count_input.value)
	var radius := int(radius_input.value)
	# 0: insert copied frames. 1: overwrite next existing frames on this layer.
	if destination_input.selected == 1:
		_overwrite_existing(
			project, layer as PixelLayer, source, solid, selected,
			distance_to_solid, distance_to_empty, first_frame_index, total_frames, radius
		)
	else:
		_insert_new(
			project, source, solid, selected, distance_to_solid, distance_to_empty,
			first_frame_index, layer_index, total_frames, radius
		)


func _overwrite_existing(
	project: Project,
	layer: PixelLayer,
	source: Image,
	solid: PackedByteArray,
	selected: PackedByteArray,
	distance_to_solid: PackedInt32Array,
	distance_to_empty: PackedInt32Array,
	first_frame_index: int,
	total_frames: int,
	radius: int
) -> void:
	var layer_index := layer.index
	# Never silently append frames in overwrite mode or partially overwrite.
	if project.frames.size() - first_frame_index < total_frames:
		Global.popup_error(
			"既存フレームが不足しています。元のコマを含めて%dコマ必要です。" % total_frames
		)
		return
	var entries: Array[Dictionary] = []
	for step in range(1, total_frames):
		var target := project.frames[first_frame_index + step].cels[layer_index] as PixelCel
		if target == null or target is CelTileMap:
			Global.popup_error("上書き先に通常のピクセルセルが必要です。")
			return
		var rendered := _render_frame(
			source, solid, selected, distance_to_solid, distance_to_empty,
			step, total_frames, radius
		)
		if not selected.is_empty():
			# In overwrite mode, pixels outside the selection must remain intact
			# in EACH destination frame, not revert to the source image.
			var existing := project.new_empty_image()
			existing.fill(Color.TRANSPARENT)
			existing.blit_rect(
				target.get_image(),
				Rect2i(Vector2i.ZERO, target.get_image().get_size()),
				target.offset
			)
			for y in range(project.size.y):
				for x in range(project.size.x):
					if selected[y * project.size.x + x] != 0:
						existing.set_pixel(x, y, rendered.get_pixel(x, y))
			rendered = existing
		entries.append({
			"cel": target,
			"layer": layer,
			"before": target.get_content(),
			"after": ImageExtended.create_from_image(rendered),
			"link_set": target.link_set
		})
	var undo_redo := project.undo_redo
	undo_redo.create_action("Overwrite Wriggle Animation")
	undo_redo.add_do_method(_apply_overwrites.bind(entries, true))
	undo_redo.add_do_method(Global.undo_or_redo.bind(false, -1, -1, project))
	undo_redo.add_undo_method(Global.undo_or_redo.bind(true, -1, -1, project))
	undo_redo.add_undo_method(_apply_overwrites.bind(entries, false))
	undo_redo.commit_action()


func _apply_overwrites(entries: Array[Dictionary], apply_new: bool) -> void:
	for entry in entries:
		var cel := entry["cel"] as PixelCel
		var layer := entry["layer"] as PixelLayer
		# Break each existing link before writing so neither the source frame
		# nor linked cels elsewhere can change indirectly.
		if apply_new:
			if cel.link_set != null:
				layer.link_cel(cel, null)
			cel.set_content([entry["after"], Vector2i.ZERO])
		else:
			cel.set_content(entry["before"])
			if entry["link_set"] != null:
				layer.link_cel(cel, entry["link_set"])
		cel.update_texture()
	Global.canvas.update_all_layers = true
	Global.canvas.queue_redraw()


func _insert_new(
	project: Project,
	source: Image,
	solid: PackedByteArray,
	selected: PackedByteArray,
	distance_to_solid: PackedInt32Array,
	distance_to_empty: PackedInt32Array,
	first_frame_index: int,
	layer_index: int,
	total_frames: int,
	radius: int
) -> void:
	var first_frame := project.frames[first_frame_index]
	var inserted_count := total_frames - 1
	var indices := PackedInt32Array()
	var frames: Array[Frame] = []
	for frame_step in range(1, total_frames):
		var copy := Frame.new()
		copy.duration = first_frame.duration
		copy.marker_color = first_frame.marker_color
		for index in range(project.layers.size()):
			var original_cel := first_frame.cels[index]
			var copied_cel := original_cel.duplicate_cel()
			copied_cel.set_content(original_cel.copy_content())
			copy.cels.append(copied_cel)
		var rendered := _render_frame(
			source, solid, selected, distance_to_solid, distance_to_empty,
			frame_step, total_frames, radius
		)
		var target := copy.cels[layer_index] as PixelCel
		target.set_content([ImageExtended.create_from_image(rendered), Vector2i.ZERO])
		frames.append(copy)
		indices.append(first_frame_index + frame_step)

	# Preserve existing animation tags when inserting between frames.
	var adjusted_tags := project.animation_tags.duplicate()
	var first_inserted_number := first_frame_index + 2
	for i in range(adjusted_tags.size()):
		adjusted_tags[i] = adjusted_tags[i].duplicate()
		var tag: AnimationTag = adjusted_tags[i]
		if first_inserted_number <= tag.from:
			tag.from += inserted_count
			tag.to += inserted_count
		elif first_inserted_number <= tag.to:
			tag.to += inserted_count
	var old_selection := project.selected_cels.duplicate(true)
	var old_tags := project.animation_tags
	var new_selection := [[first_frame_index + 1, layer_index]]
	var undo_redo := project.undo_redo
	undo_redo.create_action("Generate Wriggle Animation")
	undo_redo.add_do_method(project.add_frames.bind(frames, indices))
	undo_redo.add_do_property(project, "animation_tags", adjusted_tags)
	undo_redo.add_do_property(project, "selected_cels", new_selection)
	undo_redo.add_do_method(project.change_cel.bind(first_frame_index + 1, layer_index))
	undo_redo.add_do_method(Global.undo_or_redo.bind(false, -1, -1, project))
	undo_redo.add_undo_method(Global.undo_or_redo.bind(true, -1, -1, project))
	undo_redo.add_undo_method(project.change_cel.bind(first_frame_index, layer_index))
	undo_redo.add_undo_property(project, "selected_cels", old_selection)
	undo_redo.add_undo_property(project, "animation_tags", old_tags)
	undo_redo.add_undo_method(project.remove_frames.bind(indices))
	undo_redo.commit_action()


## Chessboard-distance maps: 8-connected pixel morphology, with no antialiasing.
func _distance_field(
	solid: PackedByteArray, width: int, height: int, target: int
) -> PackedInt32Array:
	const FAR := 32767
	var distance := PackedInt32Array()
	distance.resize(width * height)
	distance.fill(FAR)
	for y in range(height):
		for x in range(width):
			var i := y * width + x
			if solid[i] == target:
				distance[i] = 0
			else:
				if x > 0:
					distance[i] = mini(distance[i], distance[i - 1] + 1)
				if y > 0:
					distance[i] = mini(distance[i], distance[i - width] + 1)
					if x > 0:
						distance[i] = mini(distance[i], distance[i - width - 1] + 1)
					if x + 1 < width:
						distance[i] = mini(distance[i], distance[i - width + 1] + 1)
	for y in range(height - 1, -1, -1):
		for x in range(width - 1, -1, -1):
			var i := y * width + x
			if x + 1 < width:
				distance[i] = mini(distance[i], distance[i + 1] + 1)
			if y + 1 < height:
				distance[i] = mini(distance[i], distance[i + width] + 1)
				if x > 0:
					distance[i] = mini(distance[i], distance[i + width - 1] + 1)
				if x + 1 < width:
					distance[i] = mini(distance[i], distance[i + width + 1] + 1)
	return distance


func _render_frame(
	source: Image,
	solid: PackedByteArray,
	selected: PackedByteArray,
	distance_to_solid: PackedInt32Array,
	distance_to_empty: PackedInt32Array,
	frame_step: int,
	total_frames: int,
	radius: int
) -> Image:
	var width := source.get_width()
	var height := source.get_height()
	var result := Image.create_empty(width, height, false, source.get_format())
	result.copy_from(source)
	var angle := TAU * float(frame_step) / float(total_frames)
	# A smoothly varying spatial phase gives neighboring contours different timing.
	# Subtract the t=0 value so the first (original) frame closes the loop.
	for y in range(height):
		for x in range(width):
			var i := y * width + x
			if not selected.is_empty() and selected[i] == 0:
				continue
			var phase := (
				sin(float(x) / 23.0) * 1.7
				+ cos(float(y) / 19.0) * 1.4
				+ sin(float(x + y) / 31.0)
			)
			var shift := float(radius) * 0.5 * (sin(angle + phase) - sin(phase))
			if solid[i] != 0:
				if shift < 0.0 and float(distance_to_empty[i]) <= -shift:
					result.set_pixel(x, y, Color.TRANSPARENT)
			elif shift > 0.0 and float(distance_to_solid[i]) <= shift:
				result.set_pixel(x, y, Color.BLACK)
	return result

extends Button

## The entire purpose of this script is to handle layer drag and dropping.

var layer_index := 0
var hierarchy_depth_pixel_shift := 16
const HEADER_DRAG_BORDER := 5.0
var _drag_started_on_selected_border := false


func _ready() -> void:
	if DisplayServer.is_touchscreen_available():
		mouse_filter = Control.MOUSE_FILTER_PASS


## The 1px selection outline is the drag handle. Dragging the header
## interior starts a range selection (Aseprite's STATE_SELECTING_LAYERS).
func _is_drag_border(local_pos: Vector2) -> bool:
	var timeline := Global.animation_timeline
	if not timeline.is_layer_header_range(layer_index):
		return false
	var first: bool = not timeline.is_layer_header_range(layer_index + 1)
	var last: bool = not timeline.is_layer_header_range(layer_index - 1)
	return (
		local_pos.x <= HEADER_DRAG_BORDER
		or (first and local_pos.y <= HEADER_DRAG_BORDER)
		or (last and local_pos.y >= size.y - HEADER_DRAG_BORDER)
	)


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		_drag_started_on_selected_border = _is_drag_border(event.position)
		if not _drag_started_on_selected_border:
			Global.animation_timeline.update_drag_header_range_preview(
				true, layer_index, layer_index
			)
	elif not get_viewport().gui_is_dragging():
		Global.animation_timeline.clear_drag_cel_range_preview()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		# A canceled drag never commits the preview range.
		Global.animation_timeline.clear_drag_cel_range_preview()


func _get_drag_data(_position: Vector2) -> Variant:
	if DisplayServer.is_touchscreen_available() and not button_pressed:
		return null
	if not _drag_started_on_selected_border and not DisplayServer.is_touchscreen_available():
		Global.animation_timeline.update_drag_header_range_preview(
			true, layer_index, layer_index
		)
		return ["LayerRange", layer_index]
	var layers := _get_layer_indices()
	for layer_i in layers:  # Add child layers, if we have selected groups
		var layer := Global.current_project.layers[layer_i]
		for child in layer.get_children(true):
			var child_index := Global.current_project.layers.find(child)
			if not child_index in layers:  # Do not add the same index multiple times
				layers.append(child_index)
	layers.sort()

	var box := VBoxContainer.new()
	for i in layers.size():
		var button := Button.new()
		button.custom_minimum_size = size
		button.theme = Global.control.theme
		button.text = Global.current_project.layers[layers[-1 - i]].name
		box.add_child(button)
	set_drag_preview(box)
	return ["Layer", layers]


func _can_drop_data(pos: Vector2, data) -> bool:
	if typeof(data) != TYPE_ARRAY:
		Global.animation_timeline.drag_highlight.visible = false
		return false
	if data.is_empty():
		return false
	if data[0] == "LayerRange":
		Global.animation_timeline.drag_highlight.hide()
		Global.animation_timeline.update_drag_header_range_preview(
			true, int(data[1]), layer_index
		)
		return true
	if data[0] != "Layer":
		Global.animation_timeline.drag_highlight.visible = false
		return false
	# Ensure that the target and its neighbors remain visible.
	var layer_button := get_parent()
	var layer_button_index := layer_button.get_index()
	var layer_container := layer_button.get_parent()
	Global.animation_timeline.timeline_scroll.ensure_control_visible(layer_button)
	if pos.y > size.y / 2.0 and layer_button_index + 1 < layer_container.get_child_count():
		Global.animation_timeline.timeline_scroll.ensure_control_visible(
			layer_container.get_child(layer_button_index + 1)
		)
	if pos.y < size.y / 2.0 and layer_button_index - 1 > 0:
		Global.animation_timeline.timeline_scroll.ensure_control_visible(
			layer_container.get_child(layer_button_index - 1)
		)

	var curr_layer := Global.current_project.layers[layer_index]
	var drop_layers: PackedInt32Array = data[1]

	var is_copy := Global.is_ctrl_or_cmd_pressed() or Input.is_key_pressed(KEY_ALT)
	# Moving onto itself or into a descendant is invalid. Copying is safe.
	if not is_copy:
		for drop_layer in drop_layers:
			if drop_layer == layer_index:
				Global.animation_timeline.drag_highlight.visible = false
				return false

	var region: Rect2
	var depth := curr_layer.get_hierarchy_depth()
	var last_layer := Global.current_project.layers[drop_layers[-1]]
	if not is_copy:
		for drop_layer_index in drop_layers:
			var drop_layer := Global.current_project.layers[drop_layer_index]
			if drop_layer.is_ancestor_of(curr_layer):
				Global.animation_timeline.drag_highlight.visible = false
				return false
	# Group center drops clone/move the dragged layers into the group.
	if (
		curr_layer.accepts_child(last_layer)
		and pos.y > size.y / 4.0
		and pos.y < 3.0 * size.y / 4.0
	):
		region = _get_region_rect(0.15, 0.85)
		depth += 1
	else:
		region = (
			_get_region_rect(-0.1, 0.15)
			if pos.y < size.y / 2.0
			else _get_region_rect(0.85, 1.1)
		)
	# Shift drawn region to the right a bit for hierarchy depth visualization:
	region.position.x += depth * hierarchy_depth_pixel_shift
	region.size.x -= depth * hierarchy_depth_pixel_shift
	Global.animation_timeline.drag_highlight.global_position = region.position
	Global.animation_timeline.drag_highlight.size = region.size
	Global.animation_timeline.drag_highlight.visible = true
	return true


func _drop_data(pos: Vector2, data) -> void:
	if data[0] == "LayerRange":
		Global.animation_timeline.commit_drag_header_range(true, int(data[1]), layer_index)
		return
	var initial_drop_layers: PackedInt32Array = data[1]
	var project := Global.current_project
	var curr_layer := project.layers[layer_index]
	var layers := project.layers  # This shouldn't be modified directly
	var drop_from_indices: PackedInt32Array = []
	var children_indices: PackedInt32Array = []  # Child layer indices, if a group layer is selected
	# Add dropped indices to drop_from_indices
	# We do this in case a child layer is selected along with its ancestor,
	# we don't want both of them to be in the final array, as ancestors will automatically include
	# their children anyway.
	for drop_layer_index in initial_drop_layers:
		if not drop_layer_index in drop_from_indices:  # Do not add the same index multiple times
			drop_from_indices.append(drop_layer_index)
		var drop_layer := project.layers[drop_layer_index]
		for child in drop_layer.get_children(true):
			var child_index := project.layers.find(child)
			if not child_index in children_indices:
				children_indices.append(child_index)
			if not child_index in drop_from_indices:  # Do not add the same index multiple times
				drop_from_indices.append(child_index)
	drop_from_indices.sort()
	children_indices.sort()

	var drop_from_parents := []
	for i in range(drop_from_indices.size()):
		drop_from_parents.append(layers[drop_from_indices[i]].parent)

	# Ctrl/Alt-drag copies the complete layer(s), matching Aseprite.
	if Global.is_ctrl_or_cmd_pressed() or Input.is_key_pressed(KEY_ALT):
		var last_layer := project.layers[drop_from_indices[-1]]
		var to_index: int
		var to_parent: BaseLayer
		if (
			curr_layer.accepts_child(last_layer)
			and pos.y > size.y / 4.0
			and pos.y < 3.0 * size.y / 4.0
		):
			to_index = layer_index
			to_parent = curr_layer
		elif pos.y < size.y / 2.0:
			to_index = layer_index + 1
			to_parent = curr_layer.parent
		else:
			to_index = (
				curr_layer.get_children(true)[0].index
				if curr_layer.has_children() else layer_index
			)
			to_parent = curr_layer.parent
		Global.animation_timeline.drag_highlight.hide()
		Global.animation_timeline.copy_layers_at(drop_from_indices, to_index, to_parent)
		return

	project.undo_redo.create_action("Change Layer Order")
	var to_index: int  # the index where the LOWEST moved layer should end up
	var to_parent: BaseLayer
	var last_layer := project.layers[drop_from_indices[-1]]
	# If accepted as a child, is it in the center region?
	if (
		curr_layer.accepts_child(last_layer)  # Any dropped layer should probably work here
		and pos.y > size.y / 4.0
		and pos.y < 3.0 * size.y / 4.0
	):
		to_index = layer_index
		to_parent = curr_layer
	else:
		if pos.y < size.y / 2.0:  # Top region
			to_index = layer_index + 1
			to_parent = curr_layer.parent
		else:  # Bottom region
			# Place under the layer, if it has children, place after its lowest child
			if curr_layer.has_children():
				to_index = curr_layer.get_children(true)[0].index
				for drop_layer in drop_from_indices:
					if curr_layer.is_ancestor_of(layers[drop_layer]):
						to_index += 1
			else:
				to_index = layer_index
			to_parent = curr_layer.parent

	for drop_layer in drop_from_indices:
		if drop_layer < layer_index:
			to_index -= 1

	var drop_to_indices: PackedInt32Array = range(to_index, to_index + drop_from_indices.size())
	var to_parents := drop_from_parents.duplicate()
	for i in to_parents.size():
		# Re-parent only the parent layers, not the child layers of a group
		if not drop_from_indices[i] in children_indices:
			to_parents[i] = to_parent

	project.undo_redo.add_do_method(
		project.move_layers.bind(drop_from_indices, drop_to_indices, to_parents)
	)
	project.undo_redo.add_undo_method(
		project.move_layers.bind(drop_to_indices, drop_from_indices, drop_from_parents)
	)
	if project.current_layer in drop_from_indices:
		project.undo_redo.add_do_method(project.change_cel.bind(-1, layer_index))
	else:
		project.undo_redo.add_do_method(project.change_cel.bind(-1, project.current_layer))
	project.undo_redo.add_undo_method(project.change_cel.bind(-1, project.current_layer))
	project.undo_redo.add_undo_method(Global.undo_or_redo.bind(true))
	project.undo_redo.add_do_method(Global.undo_or_redo.bind(false))
	project.undo_redo.commit_action()


func _get_region_rect(y_begin: float, y_end: float) -> Rect2:
	var rect := get_global_rect()
	rect.position.y += rect.size.y * y_begin
	rect.size.y *= y_end - y_begin
	return rect


func _get_layer_indices() -> PackedInt32Array:
	var indices := []
	for cel in Global.current_project.selected_cels:
		var l: int = cel[1]
		if not l in indices:
			indices.append(l)
	indices.sort()
	if not layer_index in indices:
		indices = [layer_index]
	return indices

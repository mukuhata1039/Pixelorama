extends Button

enum MenuOptions { PROPERTIES, PLAY_AUDIO, SELECT_PIXELS, CENTER, DELETE, LINK, UNLINK, CLONE_CEL }

## A 5px hit target remains usable even in the 20px compact timeline.
const CEL_DRAG_BORDER := 5.0
## The active frame/layer guides are separate from the selected cel range.
const ACTIVE_GUIDE_COLOR := Color("688ea4")
const RANGE_OUTLINE_COLOR := Color("d1c275")

var frame := 0
var layer := 0
var cel: BaseCel

var _drag_started_on_selected_border := false

@onready var popup_menu: PopupMenu = $PopupMenu
@onready var ui_color_rect: ColorRect = $UIColorRect
@onready var linked_rect: ColorRect = $Linked
@onready var cel_texture: TextureRect = $CelTexture
@onready var transparent_checker: ColorRect = $CelTexture/TransparentChecker
@onready var z_index_indicator: TextureRect = $ZIndexIndicator
@onready var properties: AcceptDialog = Global.control.find_child("CelProperties")


func _ready() -> void:
	if DisplayServer.is_touchscreen_available():
		mouse_filter = Control.MOUSE_FILTER_PASS
	Themes.theme_switched.connect(cel_switched.bind(true))
	cel = Global.current_project.frames[frame].cels[layer]
	button_setup()
	apply_compact_layout(Global.animation_timeline.compact_timeline)
	_dim_checker()
	cel.texture_changed.connect(_dim_checker)
	z_index_indicator.visible = cel.z_index != 0
	ui_color_rect.color = cel.ui_color
	cel.z_index_changed.connect(func(): z_index_indicator.visible = cel.z_index != 0)
	cel.ui_color_changed.connect(func(): ui_color_rect.color = cel.ui_color)
	for selected in Global.current_project.selected_cels:
		if selected[1] == layer and selected[0] == frame:
			button_pressed = true
	cel_switched()
	popup_menu.add_item("Properties", MenuOptions.PROPERTIES)
	if cel is AudioCel:
		popup_menu.add_item("Play audio here", MenuOptions.PLAY_AUDIO)
		_is_playing_audio()
		Global.cel_switched.connect(_is_playing_audio)
		Themes.theme_switched.connect(_is_playing_audio)
		Global.current_project.fps_changed.connect(_is_playing_audio)
		Global.current_project.layers[layer].audio_changed.connect(_is_playing_audio)
		Global.current_project.layers[layer].playback_frame_changed.connect(_is_playing_audio)
	else:
		popup_menu.add_item("Select pixels", MenuOptions.SELECT_PIXELS)
	if cel is PixelCel:
		popup_menu.add_item("Center content", MenuOptions.CENTER)
		popup_menu.add_item("Delete", MenuOptions.DELETE)
		popup_menu.add_item("Link cels to", MenuOptions.LINK)
		popup_menu.add_item("Unlink cels", MenuOptions.UNLINK)
		_set_menu_shortcut(&"clone_cel", popup_menu, "Clone Cel", MenuOptions.CLONE_CEL, true)
	elif cel is GroupCel:
		transparent_checker.visible = false


## Shrink only the timeline thumbnail and badges; keep the cel's contents intact.
func apply_compact_layout(enabled: bool) -> void:
	var padding := 2.0 if enabled else 6.0
	cel_texture.offset_left = padding
	cel_texture.offset_top = padding
	cel_texture.offset_right = -padding
	cel_texture.offset_bottom = -padding
	var linked_half_height := 6.0 if enabled else 8.0
	linked_rect.custom_minimum_size.y = linked_half_height * 2
	linked_rect.offset_top = -linked_half_height
	linked_rect.offset_bottom = linked_half_height
	z_index_indicator.offset_left = -12.0 if enabled else -18.0
	z_index_indicator.offset_top = -12.0 if enabled else -18.0
	z_index_indicator.offset_right = -2.0 if enabled else -3.0
	z_index_indicator.offset_bottom = -2.0 if enabled else -3.0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_pressed() and [frame, layer] in Global.current_project.selected_cels:
		popup_menu.activate_item_by_event(event)


func _set_menu_shortcut(
	action: StringName,
	menu: PopupMenu,
	label: String,
	id: int,
	echo := false,
) -> void:
	var menu_shortcut := Shortcut.new()
	var event := InputEventAction.new()
	event.action = action
	menu_shortcut.events.append(event)
	menu.add_shortcut(menu_shortcut, id, false, echo)
	menu.set_item_text(menu.get_item_index(id), label)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		tooltip_text = (
			tr("Frame: %s, Layer: %s") % [frame + 1, Global.current_project.layers[layer].name]
		)


## Aseprite separates the timeline selection range from the blue row/column
## guides. Every row/column touched by the selected cells receives a blue guide,
## but the active editing cel remains independent of the range selection.
## Only the selected cells receive the dark fill and thin yellow perimeter.
func cel_switched(_force_stylebox_change := false) -> void:
	var project := Global.current_project
	z_index = 1 if button_pressed else 0
	var on_guide_frame: bool = Global.animation_timeline.range_guide_frames.has(frame)
	var on_guide_layer: bool = Global.animation_timeline.range_guide_layers.has(layer)
	var in_active_guides: bool = on_guide_frame or on_guide_layer
	for style_name: StringName in [&"normal", &"hover"]:
		remove_theme_stylebox_override(style_name)
		if in_active_guides:
			var source := Global.control.theme.get_stylebox(style_name, &"CelButton")
			if source is StyleBoxFlat:
				var guide := source.duplicate() as StyleBoxFlat
				var guide_strength := 0.7 if on_guide_frame and on_guide_layer else 0.55
				guide.bg_color = guide.bg_color.lerp(ACTIVE_GUIDE_COLOR, guide_strength)
				add_theme_stylebox_override(style_name, guide)
	_update_range_outline()
	queue_redraw()


## Every selected cel must keep the 1px internal grid. Previously the
## pressed StyleBox hid the borders between selected neighbors, which merged
## the entire range into one solid dark rectangle. The thin yellow range outline
## is drawn separately in _draw() so it doesn't replace the internal grid.
func _update_range_outline() -> void:
	var project := Global.current_project
	if not project.selected_cels.has([frame, layer]):
		remove_theme_stylebox_override(&"pressed")
		remove_theme_stylebox_override(&"hover_pressed")
		return
	var source := Global.control.theme.get_stylebox(&"pressed", &"CelButton")
	var normal_source := Global.control.theme.get_stylebox(&"normal", &"CelButton")
	if not source is StyleBoxFlat or not normal_source is StyleBoxFlat:
		return
	var normal := normal_source as StyleBoxFlat
	var style := source.duplicate() as StyleBoxFlat
	# Retain a distinct, readable cell for every frame, even inside a
	# rectangular selection. Leave room for textures and linked-cel badges.
	style.bg_color = normal.bg_color.lerp(ACTIVE_GUIDE_COLOR, 0.30)
	if frame == project.current_frame and layer == project.current_layer:
		style.bg_color = normal.bg_color.lerp(ACTIVE_GUIDE_COLOR, 0.65)
	style.border_color = normal.border_color
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	add_theme_stylebox_override(&"pressed", style)
	add_theme_stylebox_override(&"hover_pressed", style)


## Render only the perimeter of the actual selected range. The base Button
## still draws all dark internal grid borders and the original cel thumbnail.
## Borders touching a selected neighbor are not part of the yellow perimeter.
func _draw() -> void:
	if not is_instance_valid(Global.current_project):
		return
	# While the rectangle is being dragged, only its moving outline is
	# visible. Do not leave the old committed range's border underneath it.
	if Global.animation_timeline.selection_drag_highlight.visible:
		return
	var selected := Global.current_project.selected_cels
	if not selected.has([frame, layer]):
		return
	var x_end := size.x - 0.5
	var y_end := size.y - 0.5
	if frame > 0 and not selected.has([frame - 1, layer]):
		draw_line(Vector2(0.5, 0.5), Vector2(0.5, y_end), RANGE_OUTLINE_COLOR, 1.0, false)
	elif frame == 0 and not Global.animation_timeline.is_layer_header_range(layer):
		draw_line(Vector2(0.5, 0.5), Vector2(0.5, y_end), RANGE_OUTLINE_COLOR, 1.0, false)
	if not selected.has([frame + 1, layer]):
		draw_line(Vector2(x_end, 0.5), Vector2(x_end, y_end), RANGE_OUTLINE_COLOR, 1.0, false)
	if layer < Global.current_project.layers.size() - 1:
		if not selected.has([frame, layer + 1]):
			draw_line(Vector2(0.5, 0.5), Vector2(x_end, 0.5), RANGE_OUTLINE_COLOR, 1.0, false)
	elif not Global.animation_timeline.is_frame_header_range(frame):
		draw_line(Vector2(0.5, 0.5), Vector2(x_end, 0.5), RANGE_OUTLINE_COLOR, 1.0, false)
	if not selected.has([frame, layer - 1]):
		draw_line(Vector2(0.5, y_end), Vector2(x_end, y_end), RANGE_OUTLINE_COLOR, 1.0, false)

func button_setup() -> void:
	custom_minimum_size.x = Global.animation_timeline.cel_size
	custom_minimum_size.y = Global.animation_timeline.cel_size

	var base_layer := Global.current_project.layers[layer]
	tooltip_text = tr("Frame: %s, Layer: %s") % [frame + 1, base_layer.name]
	if cel is not AudioCel:
		cel_texture.texture = cel.image_texture
	if is_instance_valid(linked_rect):
		linked_rect.visible = cel.link_set != null
		if cel.link_set != null:
			linked_rect.color.h = cel.link_set["hue"]


## Remember where the press began: Godot starts drag-and-drop after the mouse moves,
## when the pointer may no longer be on the original 5px border.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_drag_started_on_selected_border = (
				Global.current_project.selected_cels.has([frame, layer])
				and (
					_is_drag_border(event.position)
					or Global.is_ctrl_or_cmd_pressed()
					or Input.is_key_pressed(KEY_ALT)
				)
			)
	elif event is InputEventMouseMotion:
		var moving_selected_cels := (
			Global.current_project.selected_cels.has([frame, layer])
			and (
				_is_drag_border(event.position)
				or Global.is_ctrl_or_cmd_pressed()
				or Input.is_key_pressed(KEY_ALT)
			)
		)
		var copying_selected_cels := (
			Global.current_project.selected_cels.has([frame, layer])
			and (Global.is_ctrl_or_cmd_pressed() or Input.is_key_pressed(KEY_ALT))
		)
		mouse_default_cursor_shape = (
			Control.CURSOR_CAN_DROP
			if copying_selected_cels
			else Control.CURSOR_MOVE if moving_selected_cels else Control.CURSOR_ARROW
		)


func _is_drag_border(local_pos: Vector2) -> bool:
	# Aseprite uses the outside of the selected range, not every inner cell edge.
	var selected: Array = Global.current_project.selected_cels
	if not selected.has([frame, layer]):
		return false
	return (
		(local_pos.x < CEL_DRAG_BORDER and not selected.has([frame - 1, layer]))
		or (local_pos.x >= size.x - CEL_DRAG_BORDER and not selected.has([frame + 1, layer]))
		or (local_pos.y < CEL_DRAG_BORDER and not selected.has([frame, layer + 1]))
		or (local_pos.y >= size.y - CEL_DRAG_BORDER and not selected.has([frame, layer - 1]))
	)


func _on_CelButton_pressed() -> void:
	var project := Global.current_project
	var is_left_click := Input.is_action_just_released(&"left_mouse")
	if is_left_click or Input.is_action_just_released(&"ui_accept"):
		Global.transform_content_confirmed.emit()
		Global.animation_timeline.select_cel_range_source()
		var frame_layer := [frame, layer]
		var change_cel := true
		if is_left_click and Global.is_ctrl_or_cmd_pressed() and Input.is_action_pressed("shift"):
			# Keep a contiguous rectangular selection available without occupying Shift alone.
			var anchor_frame := project.current_frame
			var anchor_layer := project.current_layer
			project.selected_cels.clear()
			for f in range(mini(anchor_frame, frame), maxi(anchor_frame, frame) + 1):
				for l in range(mini(anchor_layer, layer), maxi(anchor_layer, layer) + 1):
					project.selected_cels.append([f, l])
		elif is_left_click and Global.is_ctrl_or_cmd_pressed() and cel is not AudioCel:
			# Select the opaque pixels of the clicked cel, not multiple timeline cels.
			project.selected_cels = [frame_layer]
			project.change_cel(frame, layer)
			Global.canvas.selection.select_cel_pixels(project.layers[layer], project.frames[frame])
			return
		elif Input.is_action_pressed("shift"):
			# Add/remove individual, possibly non-adjacent cels.
			if project.selected_cels.has(frame_layer):
				if project.selected_cels.size() > 1:
					project.selected_cels.erase(frame_layer)
					change_cel = false
			else:
				project.selected_cels.append(frame_layer)
		else:
			project.selected_cels = [frame_layer]

		if change_cel:
			project.change_cel(frame, layer)
		else:
			var remaining_cel: Array = project.selected_cels[0]
			project.change_cel(remaining_cel[0], remaining_cel[1])
			release_focus()

	elif Input.is_action_just_released("right_mouse"):
		popup_menu.popup_on_parent(Rect2(get_global_mouse_position(), Vector2.ONE))
		button_pressed = !button_pressed
	elif Input.is_action_just_released("middle_mouse"):
		button_pressed = !button_pressed
		_delete_cel_content()
	else:  # An example of this would be Space
		button_pressed = !button_pressed

func _on_PopupMenu_id_pressed(id: int) -> void:
	var project := Global.current_project
	var layer_class := project.layers[layer]
	match id:
		MenuOptions.PROPERTIES:
			properties.cel_indices = _get_cel_indices()
			properties.popup_centered_clamped()
		MenuOptions.PLAY_AUDIO:
			if layer_class is AudioLayer:
				layer_class.playback_frame = frame
		MenuOptions.SELECT_PIXELS:
			Global.canvas.selection.select_cel_pixels(layer_class, project.frames[frame])
		MenuOptions.CENTER:
			DrawingAlgos.center_cels(_get_cel_indices())
		MenuOptions.DELETE:
			_delete_cel_content()

		MenuOptions.LINK, MenuOptions.UNLINK:
			if id == MenuOptions.UNLINK:
				project.undo_redo.create_action("Unlink Cel")
				var selected_cels := _get_cel_indices(true)
				if not selected_cels.has([frame, layer]):
					selected_cels.append([frame, layer])  # Include this cel with the selected ones
				for cel_index in selected_cels:
					if layer != cel_index[1]:  # Skip selected cels not on the same layer
						continue
					var s_cel := project.frames[cel_index[0]].cels[cel_index[1]]
					if s_cel.link_set == null:  # Skip cels that aren't linked
						continue
					project.undo_redo.add_do_method(
						project.layers[layer].link_cel.bind(s_cel, null)
					)
					project.undo_redo.add_undo_method(
						project.layers[layer].link_cel.bind(s_cel, s_cel.link_set)
					)
					if s_cel.link_set.size() > 1:  # Skip copying content if not linked to another
						var new_texture := ImageTexture.create_from_image(s_cel.get_image())
						project.undo_redo.add_do_method(
							s_cel.set_content.bind(s_cel.copy_content(), new_texture)
						)
						project.undo_redo.add_undo_method(
							s_cel.set_content.bind(s_cel.get_content(), s_cel.image_texture)
						)

			elif id == MenuOptions.LINK:
				project.undo_redo.create_action("Link Cel")
				var link_set: Dictionary = {} if cel.link_set == null else cel.link_set
				if cel.link_set == null:
					project.undo_redo.add_do_method(
						project.layers[layer].link_cel.bind(cel, link_set)
					)
					project.undo_redo.add_undo_method(
						project.layers[layer].link_cel.bind(cel, null)
					)

				for cel_index in project.selected_cels:
					if layer != cel_index[1]:  # Skip selected cels not on the same layer
						continue
					var s_cel := project.frames[cel_index[0]].cels[cel_index[1]]
					if cel == s_cel:  # Don't need to link cel to itself
						continue
					if s_cel.link_set == link_set:  # Skip cels that were already linked
						continue
					project.undo_redo.add_do_method(
						project.layers[layer].link_cel.bind(s_cel, link_set)
					)
					project.undo_redo.add_undo_method(
						project.layers[layer].link_cel.bind(s_cel, s_cel.link_set)
					)
					project.undo_redo.add_do_method(
						s_cel.set_content.bind(cel.get_content(), cel.image_texture)
					)
					project.undo_redo.add_undo_method(
						s_cel.set_content.bind(s_cel.get_content(), s_cel.image_texture)
					)

			# Remove and add a new cel button to update appearance (can't use button_setup
			# because there is no guarantee that it will be the exact same cel button instance)
			# May be able to use button_setup with a lambda to find correct cel button in Godot 4
			for f in project.frames.size():
				project.undo_redo.add_do_method(
					Global.animation_timeline.project_cel_removed.bind(f, layer)
				)
				project.undo_redo.add_undo_method(
					Global.animation_timeline.project_cel_removed.bind(f, layer)
				)
				project.undo_redo.add_do_method(
					Global.animation_timeline.project_cel_added.bind(f, layer)
				)
				project.undo_redo.add_undo_method(
					Global.animation_timeline.project_cel_added.bind(f, layer)
				)

			project.undo_redo.add_do_method(Global.undo_or_redo.bind(false))
			project.undo_redo.add_undo_method(Global.undo_or_redo.bind(true))
			project.undo_redo.commit_action()

		MenuOptions.CLONE_CEL:
			_clone_cel_content(_get_cel_indices())


## Aseprite moves/copies the contents of cels to the destination instead of
## reordering the timeline. Use this path for ordinary, unlinked image cels.
## Linked/procedural cels keep the older Pixelorama implementation for safety.
static func _can_transfer_pixel_cels(indices: Array, paste_offset: Vector2i) -> bool:
	var project := Global.current_project
	if indices.is_empty() or paste_offset == Vector2i.ZERO:
		return false
	for indices_pair in indices:
		var source := Vector2i(int(indices_pair[0]), int(indices_pair[1]))
		var target := source + paste_offset
		if (
			source.x < 0
			or source.x >= project.frames.size()
			or source.y < 0
			or source.y >= project.layers.size()
			or target.x < 0
			or target.y < 0
			or target.y >= project.layers.size()
		):
			return false
		var source_cel: BaseCel = project.frames[source.x].cels[source.y]
		if source_cel is not PixelCel or source_cel.link_set != null:
			return false
		if project.layers[source.y].get_script() != project.layers[target.y].get_script():
			return false
		if target.x < project.frames.size():
			var target_cel: BaseCel = project.frames[target.x].cels[target.y]
			if target_cel is not PixelCel or target_cel.link_set != null:
				return false
		elif project.layers[target.y].new_cels_linked:
			return false
	return true


static func _pixel_cel_state(cel: PixelCel, content: Variant) -> Dictionary:
	return {
		"content": content,
		"opacity": cel.opacity,
		"z_index": cel.z_index,
		"user_data": cel.user_data,
		"ui_color": cel.ui_color,
	}


static func _transfer_pixel_cels(indices: Array, paste_offset: Vector2i, copy: bool) -> bool:
	if not _can_transfer_pixel_cels(indices, paste_offset):
		return false
	var project := Global.current_project
	var old_selection := project.selected_cels.duplicate(true)
	var old_frame := project.current_frame
	var old_layer := project.current_layer
	var max_target := project.frames.size() - 1
	var states := {}
	var changes := {}
	var selected_destinations := []
	# Snapshot every source before touching destinations, including overlapping ranges.
	for indices_pair in indices:
		var source := Vector2i(int(indices_pair[0]), int(indices_pair[1]))
		var cel: PixelCel = project.frames[source.x].cels[source.y] as PixelCel
		states[source] = _pixel_cel_state(cel, cel.copy_content())
	for indices_pair in indices:
		var source := Vector2i(int(indices_pair[0]), int(indices_pair[1]))
		var target := source + paste_offset
		max_target = maxi(max_target, target.x)
		selected_destinations.append([target.x, target.y])
		if not copy:
			var cel: PixelCel = project.frames[source.x].cels[source.y] as PixelCel
			changes[source] = {
				"content": cel.create_empty_content(),
				"opacity": 1.0,
				"z_index": 0,
				"user_data": "",
				"ui_color": Color.TRANSPARENT,
			}
	for indices_pair in indices:
		var source := Vector2i(int(indices_pair[0]), int(indices_pair[1]))
		changes[source + paste_offset] = states[source]

	# Global.undo_or_redo refreshes cel textures for the standard "Draw" action.
	project.undo_redo.create_action("Draw")
	var new_frames: Dictionary[int, Frame] = {}
	if max_target >= project.frames.size():
		var new_indices := PackedInt32Array()
		for i in range(project.frames.size(), max_target + 1):
			new_indices.append(i)
		new_frames = Global.animation_timeline.undo_redo_add_frames(new_indices)

	for coord: Vector2i in changes:
		var destination: PixelCel
		var created_frame := new_frames.has(coord.x)
		if created_frame:
			destination = new_frames[coord.x].cels[coord.y] as PixelCel
		else:
			destination = project.frames[coord.x].cels[coord.y] as PixelCel
		var before_content: Variant = destination.get_content()
		var after_state: Dictionary = changes[coord]
		project.undo_redo.add_do_method(destination.set_content.bind(after_state["content"]))
		if not created_frame:
			project.undo_redo.add_undo_method(destination.set_content.bind(before_content))
		for property_name: String in ["opacity", "z_index", "user_data", "ui_color"]:
			project.undo_redo.add_do_property(
				destination, property_name, after_state[property_name]
			)
			if not created_frame:
				project.undo_redo.add_undo_property(
					destination, property_name, destination.get(property_name)
				)
		project.undo_redo.add_do_method(
			Global.undo_or_redo.bind(false, coord.x, coord.y, project)
		)
		if not created_frame:
			project.undo_redo.add_undo_method(
				Global.undo_or_redo.bind(true, coord.x, coord.y, project)
			)
	project.undo_redo.add_do_property(project, "selected_cels", selected_destinations)
	project.undo_redo.add_do_method(
		project.change_cel.bind(selected_destinations[0][0], selected_destinations[0][1])
	)
	project.undo_redo.add_undo_property(project, "selected_cels", old_selection)
	project.undo_redo.add_undo_method(project.change_cel.bind(old_frame, old_layer))
	project.undo_redo.commit_action()
	return true


## Clones the cel content only (skips other properties like duration, opacity etc...)
static func _clone_cel_content(indices: Array, paste_offset := Vector2i.RIGHT) -> void:
	var project := Global.current_project
	project.undo_redo.create_action("Draw")
	var new_selected_cels := []
	var new_frames: Dictionary[int, Frame] = {}
	var new_frames_idx := PackedInt32Array()
	var max_dest_frame := project.frames.size() - 1
	var filtered_indices := []
	for cel_index in indices:
		# Calculate which indices are valid and which indices need new frames
		var new_frame_layer := [cel_index[0] + paste_offset.x, cel_index[1] + paste_offset.y]
		if (
			new_frame_layer[0] < 0
			or new_frame_layer[1] < 0
			or new_frame_layer[1] >= project.layers.size()
		):
			continue
		filtered_indices.append(cel_index)
		max_dest_frame = maxi(max_dest_frame, new_frame_layer[0])
	# The copy may extend beyond the last frame, requiring intermediate empty frames.
	for f in range(project.frames.size(), max_dest_frame + 1):
		new_frames_idx.append(f)
	if filtered_indices.is_empty():
		project.undo_redo.commit_action()
		return
	if new_frames_idx.size() > 0:
		new_frames = Global.animation_timeline.undo_redo_add_frames(new_frames_idx)
	for cel_index in filtered_indices:
		var frame_index: int = cel_index[0]
		var layer_index: int = cel_index[1]
		var new_frame_layer := [frame_index + paste_offset.x, layer_index + paste_offset.y]
		if !new_selected_cels.has(new_frame_layer):
			new_selected_cels.append(new_frame_layer)
		var selected_cel := project.frames[frame_index].cels[layer_index]
		var next_cel: BaseCel = null
		var is_using_new_frame := false
		if new_frames.has(new_frame_layer[0]):
			next_cel = new_frames.get(new_frame_layer[0]).cels[new_frame_layer[1]]
			is_using_new_frame = true
		else:
			next_cel = project.frames[new_frame_layer[0]].cels[new_frame_layer[1]]
		var old_content = next_cel.get_content()
		var new_content = selected_cel.copy_content()
		if next_cel.link_set == null or next_cel.link_set.is_empty():
			project.undo_redo.add_do_method(next_cel.set_content.bind(new_content))
			project.undo_redo.add_undo_method(next_cel.set_content.bind(old_content))
		else:
			for linked_cel in next_cel.link_set["cels"]:
				project.undo_redo.add_do_method(linked_cel.set_content.bind(new_content))
				project.undo_redo.add_undo_method(linked_cel.set_content.bind(old_content))
		project.undo_redo.add_do_method(
			Global.undo_or_redo.bind(false, new_frame_layer[0], new_frame_layer[1], project)
		)
		if not is_using_new_frame:
			project.undo_redo.add_undo_method(
				Global.undo_or_redo.bind(true, new_frame_layer[0], new_frame_layer[1], project)
			)
	project.undo_redo.add_do_property(project, "selected_cels", new_selected_cels)
	project.undo_redo.add_do_method(project.change_cel.bind(new_selected_cels[0][0]))
	project.undo_redo.add_undo_property(project, "selected_cels", indices)
	project.undo_redo.add_undo_method(project.change_cel.bind(project.current_frame))
	project.undo_redo.commit_action()


func _delete_cel_content() -> void:
	var indices := _get_cel_indices()
	var project := Global.current_project
	project.undo_redo.create_action("Draw")
	for cel_index in indices:
		var frame_index: int = cel_index[0]
		var layer_index: int = cel_index[1]
		var selected_cel := project.frames[frame_index].cels[layer_index]
		var empty_content = selected_cel.create_empty_content()
		var old_content = selected_cel.get_content()
		if selected_cel.link_set == null:
			project.undo_redo.add_do_method(selected_cel.set_content.bind(empty_content))
			project.undo_redo.add_undo_method(selected_cel.set_content.bind(old_content))
		else:
			for linked_cel in selected_cel.link_set["cels"]:
				project.undo_redo.add_do_method(linked_cel.set_content.bind(empty_content))
				project.undo_redo.add_undo_method(linked_cel.set_content.bind(old_content))
		project.undo_redo.add_do_method(
			Global.undo_or_redo.bind(false, frame_index, layer_index, project)
		)
		project.undo_redo.add_undo_method(
			Global.undo_or_redo.bind(true, frame_index, layer_index, project)
		)
	project.undo_redo.commit_action()


func _dim_checker() -> void:
	var image := cel.get_image()
	if image == null:
		return
	if image.is_empty() or image.is_invisible():
		transparent_checker.visible = false
	else:
		transparent_checker.visible = true


func _get_drag_data(_position: Vector2) -> Variant:
	if DisplayServer.is_touchscreen_available() and not button_pressed:
		return null
	# Dragging the inside of a cel selects a rectangle of timeline cels.
	# The selected cel's outer border still starts the existing move/swap operation.
	if not _drag_started_on_selected_border and not DisplayServer.is_touchscreen_available():
		return ["CelRectangle", [frame, layer]]
	var button := Button.new()
	button.size = size
	button.theme = Global.control.theme
	var texture_rect := TextureRect.new()
	texture_rect.size = cel_texture.size
	texture_rect.position = cel_texture.position
	texture_rect.expand = true
	texture_rect.texture = cel_texture.texture
	button.add_child(texture_rect)
	set_drag_preview(button)
	# Keep the clicked cel as the drag anchor, even when several cels are selected.
	return ["Cel", _get_cel_indices(), [frame, layer]]


func _preview_cel_rectangle(origin: Array) -> bool:
	if origin.size() != 2:
		return false
	var timeline := Global.animation_timeline
	var cel_vbox: VBoxContainer = timeline.cel_vbox
	var row_index: int = cel_vbox.get_child_count() - 1 - origin[1]
	if row_index < 0 or row_index >= cel_vbox.get_child_count():
		return false
	var row: Control = cel_vbox.get_child(row_index)
	if origin[0] < 0 or origin[0] >= row.get_child_count():
		return false
	var first_cel: Control = row.get_child(origin[0])
	var rect := first_cel.get_global_rect().merge(get_global_rect())
	# Do not paint the selection preview over layer names or outside the timeline.
	rect = rect.intersection(timeline.frame_scroll_container.get_global_rect())
	rect = rect.intersection(timeline.timeline_scroll.get_global_rect())
	timeline.selection_drag_highlight.global_position = rect.position
	timeline.selection_drag_highlight.size = rect.size
	timeline.selection_drag_highlight.visible = rect.has_area()
	# Redraw the yellow perimeter as the drag changes the selection rectangle.
	# No blue overlay is painted, so the cel grid remains visible.
	timeline.selection_drag_highlight.queue_redraw()
	return true


func _select_cel_rectangle(origin: Array) -> void:
	if origin.size() != 2:
		return
	var project := Global.current_project
	var new_selected_cels := []
	var cel_vbox: VBoxContainer = Global.animation_timeline.cel_vbox
	for l in range(mini(origin[1], layer), maxi(origin[1], layer) + 1):
		var row: Control = cel_vbox.get_child(cel_vbox.get_child_count() - 1 - l)
		if not row.visible:
			continue
		for f in range(mini(origin[0], frame), maxi(origin[0], frame) + 1):
			new_selected_cels.append([f, l])
	if new_selected_cels.is_empty():
		return
	Global.animation_timeline.select_cel_range_source()
	project.selected_cels = new_selected_cels
	project.change_cel(frame, layer)

func _can_drop_data(pos: Vector2, data) -> bool:
	var project := Global.current_project
	if typeof(data) != TYPE_ARRAY or data.size() < 2:
		Global.animation_timeline.drag_highlight.visible = false
		return false
	if data[0] == "CelRectangle":
		Global.animation_timeline.drag_highlight.visible = false
		return _preview_cel_rectangle(data[1])
	if data[0] != "Cel":
		Global.animation_timeline.drag_highlight.visible = false
		return false
	# Ensure that the target and its neighbors remain visible.
	Global.animation_timeline.frame_scroll_container.ensure_control_visible(self)
	var frame_container := get_parent()
	if pos.x > size.x / 2.0 and get_index() + 1 < frame_container.get_child_count():
		Global.animation_timeline.frame_scroll_container.ensure_control_visible(
			frame_container.get_child(get_index() + 1)
		)
	if pos.x < size.x / 2.0 and get_index() - 1 >= 0:
		Global.animation_timeline.frame_scroll_container.ensure_control_visible(
			frame_container.get_child(get_index() - 1)
		)
	var cel_vbox := frame_container.get_parent()
	var frame_container_index := frame_container.get_index()
	if pos.y > size.y / 2.0 and frame_container_index + 1 < cel_vbox.get_child_count():
		Global.animation_timeline.timeline_scroll.ensure_control_visible(
			cel_vbox.get_child(frame_container_index + 1)
		)
	if pos.y < size.y / 2.0 and frame_container_index - 1 > 0:
		Global.animation_timeline.timeline_scroll.ensure_control_visible(
			cel_vbox.get_child(frame_container_index - 1)
		)

	var drop_cels: Array = data[1].duplicate(true)
	drop_cels.sort_custom(_sort_cel_indices_by_frame)
	var drag_anchor: Array = data[2] if data.size() > 2 else drop_cels[0]
	var drop_frames: PackedInt32Array = []
	var drop_layers: PackedInt32Array = []
	for cel_idx in drop_cels:
		drop_frames.append(cel_idx[0])
		drop_layers.append(cel_idx[1])

	# Get offset
	var offset: Vector2i = Vector2i.ZERO
	if drop_cels.size() > 0:
		offset.x = frame - drag_anchor[0]
		offset.y = layer - drag_anchor[1]

	var drop_layer := drop_layers[0]
	# Check if all dropped cels are on the same layer
	var different_layers := false
	for l in drop_layers:
		if l != layer:
			different_layers = true
	var copy_drag := Global.is_ctrl_or_cmd_pressed() or Input.is_key_pressed(KEY_ALT)
	var pixel_transfer := _can_transfer_pixel_cels(drop_cels, offset)
	var is_swapping_or_cloning := pixel_transfer or copy_drag or different_layers

	if is_swapping_or_cloning:
		for cel_idx in drop_cels:
			var dest_frame: int = cel_idx[0] + offset.x
			var dest_layer: int = cel_idx[1] + offset.y
			if dest_frame < 0 or dest_layer < 0 or dest_layer >= project.layers.size():
				Global.animation_timeline.drag_highlight.visible = false
				return false
			if not (copy_drag or pixel_transfer) and dest_frame >= project.frames.size():
				Global.animation_timeline.drag_highlight.visible = false
				return false
			# Can't move to the same cel
			if not (copy_drag or pixel_transfer) and drop_cels.has([cel_idx[0] + offset.x, cel_idx[1] + offset.y]):
				Global.animation_timeline.drag_highlight.visible = false
				return false
			# Can't move different types of layers between them
			if (
				project.layers[cel_idx[1]].get_script()
				!= project.layers[cel_idx[1] + offset.y].get_script()
			):
				Global.animation_timeline.drag_highlight.visible = false
				return false
	else:
		# Can't move to the same cel
		for d_frame in drop_frames:
			if d_frame == frame and drop_layers[-1] == layer:
				Global.animation_timeline.drag_highlight.visible = false
				return false
		# Can't move different types of layers between them
		for d_layer in drop_layers:
			if project.layers[d_layer].get_script() != project.layers[layer].get_script():
				Global.animation_timeline.drag_highlight.visible = false
				return false

	# Check if any of the dropped cels are linked
	var are_dropped_cels_linked := false
	for f in drop_frames:
		if project.frames[f].cels[drop_layer].link_set != null:
			are_dropped_cels_linked = true

	if (  # If both cels are on the same layer, or both are not linked
		drop_layer == layer
		or (project.frames[frame].cels[layer].link_set == null and not are_dropped_cels_linked)
	):
		var region: Rect2
		if is_swapping_or_cloning:  # Copy or swap cels
			var copy_drop_cels := drop_cels.duplicate(true)
			Global.animation_timeline.set_cels_highlight(copy_drop_cels, offset)
			# Draw the target rectangles relative to this overlay.
			region = Global.animation_timeline.frame_scroll_container.get_global_rect()
		else:  # Move cels using the old insertion/reordering path
			Global.animation_timeline.drag_highlight.color = Color(
				0.0, 0.741176, 1.0, 0.501961
			)
			if _get_region_rect(0, 0.5).has_point(get_global_mouse_position()):  # Left
				region = _get_region_rect(-0.125, 0.125)
				region.position.x -= 2  # Container spacing
			else:  # Right
				region = _get_region_rect(0.875, 1.125)
				region.position.x += 2  # Container spacing
		Global.animation_timeline.drag_highlight.global_position = region.position
		Global.animation_timeline.drag_highlight.size = region.size
		Global.animation_timeline.drag_highlight.visible = true
		return true

	Global.animation_timeline.drag_highlight.visible = false
	return false


func _drop_data(_pos: Vector2, data) -> void:
	if data[0] == "CelRectangle":
		_select_cel_rectangle(data[1])
		Global.animation_timeline.selection_drag_highlight.hide()
		return
	var drop_cels: Array = data[1].duplicate(true)
	drop_cels.sort_custom(_sort_cel_indices_by_frame)
	var drag_anchor: Array = data[2] if data.size() > 2 else drop_cels[0]
	var drop_frames: PackedInt32Array = []
	var drop_layers: PackedInt32Array = []
	for cel_idx in drop_cels:
		drop_frames.append(cel_idx[0])
		drop_layers.append(cel_idx[1])
	var different_layers := false
	for l in drop_layers:
		if l != layer:
			different_layers = true
	# Get offset
	var offset: Vector2i = Vector2i.ZERO
	if drop_cels.size() > 0:
		offset.x = frame - drag_anchor[0]
		offset.y = layer - drag_anchor[1]
	var project := Global.current_project
	# Aseprite moves/copies the cel content, rather than reordering frame slots.
	var copy_drag := Global.is_ctrl_or_cmd_pressed() or Input.is_key_pressed(KEY_ALT)
	if _transfer_pixel_cels(drop_cels, offset, copy_drag):
		return
	# Fallback for linked, group, or other non-pixel cels.
	if copy_drag:
		if offset != Vector2i.ZERO:
			_clone_cel_content(drop_cels, offset)
		return
	project.undo_redo.create_action("Move Cels")
	if different_layers:  # Preserve the old cross-layer swap for plain movement
		var swap_cel_positions := []
		for cel_idx in drop_cels:
			var drop_point_frame: int = cel_idx[0] + offset.x
			var drop_point_layer: int = cel_idx[1] + offset.y
			# If Swapping is done with currently non-existing cels, ignore those
			if drop_point_frame < 0 or drop_point_frame >= project.frames.size():
				continue
			if drop_point_layer < 0 or drop_point_layer >= project.layers.size():
				continue
			# if layer types are incompatible
			if (
				project.layers[drop_point_layer].get_layer_type()
				!= project.layers[cel_idx[1]].get_layer_type()
			):
				continue
			swap_cel_positions.append([drop_point_frame, drop_point_layer])
			project.undo_redo.add_do_method(
				project.swap_cel.bind(drop_point_frame, drop_point_layer, cel_idx[0], cel_idx[1])
			)
			project.undo_redo.add_undo_method(
				project.swap_cel.bind(drop_point_frame, drop_point_layer, cel_idx[0], cel_idx[1])
			)
		project.undo_redo.add_do_property(project, "selected_cels", swap_cel_positions)
	else:  # Move cels
		var to_frame: int
		if _get_region_rect(0, 0.5).has_point(get_global_mouse_position()):  # Left
			to_frame = frame
		else:  # Right
			to_frame = frame + 1
		for drop_frame in drop_frames:
			if drop_frame < frame:
				to_frame -= 1
		var to_frames := range(to_frame, to_frame + drop_frames.size())
		project.undo_redo.add_do_method(
			project.move_cels_same_layer.bind(drop_frames, to_frames, layer)
		)
		project.undo_redo.add_undo_method(
			project.move_cels_same_layer.bind(to_frames, drop_frames, layer)
		)

	project.undo_redo.add_do_method(project.change_cel.bind(frame, layer))
	project.undo_redo.add_undo_method(
		project.change_cel.bind(project.current_frame, project.current_layer)
	)
	project.undo_redo.add_undo_method(Global.undo_or_redo.bind(true))
	project.undo_redo.add_do_method(Global.undo_or_redo.bind(false))
	project.undo_redo.commit_action()


func _get_region_rect(x_begin: float, x_end: float) -> Rect2:
	var rect := get_global_rect()
	rect.position.x += rect.size.x * x_begin
	rect.size.x *= x_end - x_begin
	return rect


func _get_cel_indices(add_current_cel := false) -> Array:
	var indices := Global.current_project.selected_cels.duplicate()
	if not [frame, layer] in indices:
		if add_current_cel:
			indices.append([frame, layer])
		else:
			indices = [[frame, layer]]
	return indices


func _sort_cel_indices_by_frame(a: Array, b: Array) -> bool:
	var frame_a: int = a[0]
	var frame_b: int = b[0]
	if frame_a < frame_b:
		return true
	return false


func _is_playing_audio() -> void:
	var project := Global.current_project
	var frame_class := project.frames[frame]
	var layer_class := project.layers[layer] as AudioLayer
	var audio_length := layer_class.get_audio_length()
	var frame_pos := frame_class.position_in_seconds(project, layer_class.playback_frame)
	var audio_color := Color.LIGHT_GRAY
	var pressed_stylebox := Global.control.theme.get_stylebox(&"pressed", &"CelButton")
	if pressed_stylebox is StyleBoxFlat:
		audio_color = pressed_stylebox.border_color
	var is_last_frame := frame + 1 >= project.frames.size()
	if not is_last_frame:
		is_last_frame = (
			project.frames[frame + 1].position_in_seconds(project, layer_class.playback_frame)
			>= audio_length
		)
	if frame_pos == 0 or (is_last_frame and frame_pos < audio_length and audio_length >= 1.0):
		cel_texture.texture = preload("res://assets/graphics/misc/musical_note.png")
		cel_texture.self_modulate = audio_color
		linked_rect.visible = false
	else:
		linked_rect.visible = frame_pos < audio_length and frame_pos > 0
		linked_rect.color = audio_color
		cel_texture.texture = null

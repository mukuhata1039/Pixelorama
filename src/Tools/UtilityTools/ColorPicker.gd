extends BaseTool

enum { TOP_COLOR, CURRENT_LAYER }

var _prev_mode := 0
var _color_slot := 0
var _mode := 0


func _ready() -> void:
	_color_slot = 0 if tool_slot.button == MOUSE_BUTTON_LEFT else 1
	super._ready()


func _input(event: InputEvent) -> void:
	var options: OptionButton = $ColorPicker/Options

	if event.is_action_pressed("change_tool_mode"):
		_prev_mode = options.selected
	if event.is_action("change_tool_mode"):
		options.selected = _prev_mode ^ 1
		_color_slot = options.selected
	if event.is_action_released("change_tool_mode"):
		options.selected = _prev_mode
		_color_slot = options.selected


func _on_Options_item_selected(id: int) -> void:
	_color_slot = id
	update_config()
	save_config()


func _on_ExtractFrom_item_selected(index: int) -> void:
	_mode = index
	update_config()
	save_config()


func get_config() -> Dictionary:
	return {"color_slot": _color_slot, "mode": _mode}


func set_config(config: Dictionary) -> void:
	_color_slot = config.get("color_slot", _color_slot)
	_mode = config.get("mode", _mode)


func update_config() -> void:
	$ColorPicker/Options.selected = _color_slot
	$ColorPicker/ExtractFrom.selected = _mode


func draw_start(pos: Vector2i) -> void:
	super.draw_start(pos)
	_pick_color(pos)


func draw_move(pos: Vector2i) -> void:
	super.draw_move(pos)
	_pick_color(pos)


func draw_end(pos: Vector2i) -> void:
	super.draw_end(pos)


## Get the topmost visible pixel color without using the brush preview or
## activating a temporary tool. Used by the color-picker tool and right-click
## quick sampling alike.
static func sample_top_color(pos: Vector2i) -> Dictionary:
	var project := Global.current_project
	pos = project.tiles.get_canon_position(pos)
	if pos.x < 0 or pos.y < 0 or pos.x >= project.size.x or pos.y >= project.size.y:
		return {"color": Color.TRANSPARENT, "index": -1}
	var frame := project.frames[project.current_frame]
	for layer_index in range(project.layers.size() - 1, -1, -1):
		if not project.layers[layer_index].is_visible_in_hierarchy():
			continue
		var cel := frame.cels[layer_index]
		var image := cel.get_image()
		var sample_pos := pos - cel.offset
		if not Rect2i(Vector2i.ZERO, image.get_size()).has_point(sample_pos):
			continue
		var sampled_color := image.get_pixelv(sample_pos)
		if is_zero_approx(sampled_color.a):
			continue
		var palette_index := -1
		if cel is PixelCel and image is ImageExtended and image.is_indexed:
			palette_index = image.indices_image.get_pixelv(sample_pos).r8 - 1
		return {"color": sampled_color, "index": palette_index}
	return {"color": Color.TRANSPARENT, "index": -1}


func _pick_color(pos: Vector2i) -> void:
	var project := Global.current_project
	pos = project.tiles.get_canon_position(pos)
	if pos.x < 0 or pos.y < 0 or pos.x > project.size.x - 1 or pos.y > project.size.y - 1:
		return
	if Tools.is_placing_tiles():
		var cel := Global.current_project.get_current_cel() as CelTileMap
		pos -= cel.offset
		Tools.selected_tile_index_changed.emit(cel.get_cell_index_at_coords(pos))
		return
	var image := _get_draw_image()
	var color := Color(0, 0, 0, 0)
	var palette_index := -1
	match _mode:
		TOP_COLOR:
			var sampled := sample_top_color(pos)
			color = sampled["color"]
			palette_index = sampled["index"]
		CURRENT_LAYER:
			var current_cel := project.get_current_cel()
			pos -= current_cel.offset
			if image.pos_inside_image(pos):
				color = image.get_pixelv(pos)
				if current_cel is PixelCel:
					if image.is_indexed:
						palette_index = image.indices_image.get_pixel(pos.x, pos.y).r8 - 1
	var button := MOUSE_BUTTON_LEFT if _color_slot == 0 else MOUSE_BUTTON_RIGHT
	Tools.assign_color(color, button, false, palette_index)

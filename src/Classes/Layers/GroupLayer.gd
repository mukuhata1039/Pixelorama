class_name GroupLayer
extends BaseLayer
## A class for group layer properties

var expanded := true
var _group_cache: Dictionary
var _cache_texture_data: Array[PackedByteArray]
var _blend_generator := ShaderImageEffect.new()

# The normal-group compositor is expensive during a brush stroke: rebuilding an
# entire Texture2DArray for every mouse move scales with every child layer.
# Keep a stroke-local array and update just the painted direct child instead.
# The cache is released on stroke completion/cancel and never reused for general
# editor redraws, frame changes, or multiple selected cels.
var _stroke_frame: Frame
var _stroke_texture_array: Texture2DArray
var _stroke_metadata_texture: ImageTexture
var _stroke_child_index := -1
var _stroke_image_format := Image.FORMAT_RGBA8
var _stroke_animate_params := false
var _stroke_apply_effects := false


func clear_stroke_blend_cache() -> void:
	_stroke_frame = null
	_stroke_texture_array = null
	_stroke_metadata_texture = null
	_stroke_child_index = -1


func _get_stroke_child_index(frame: Frame, children: Array[BaseLayer]) -> int:
	var canvas := Global.canvas
	if not is_instance_valid(canvas) or not canvas.brush_profile_active:
		return -1
	if (
		canvas.update_all_layers
		or canvas.project_changed
		or canvas.live_recolor_enabled
		or not canvas.mandatory_update_layers.is_empty()
		or project != Global.current_project
	):
		return -1
	if frame != project.frames[project.current_frame] or project.selected_cels.size() != 1:
		return -1
	var selected_cel: Array = project.selected_cels[0]
	if selected_cel[0] != project.current_frame or selected_cel[1] != project.current_layer:
		return -1
	var painted_layer := project.layers[project.current_layer]
	if painted_layer.parent != self:
		return -1
	# Nested groups need their own recomposition/invalidation; leave those
	# cases on the original full-compositing path for visual correctness.
	for child in children:
		if child is GroupLayer:
			return -1
	return children.find(painted_layer)



func _init(_project: Project, _name := "") -> void:
	super(_project, _name)
	blend_mode = BlendModes.PASS_THROUGH


## Blends all of the images of children layer of the group layer into a single image.
func blend_children(frame: Frame, animate_params := true, apply_effects := true) -> Image:
	var image := ImageExtended.create_custom(
		project.size.x, project.size.y, false, project.get_image_format(), project.is_indexed()
	)
	var children := get_children(false)
	if children.size() <= 0:
		return image
	var painted_child_index := _get_stroke_child_index(frame, children)
	if (
		painted_child_index >= 0
		and is_instance_valid(_stroke_texture_array)
		and _stroke_frame == frame
		and _stroke_child_index == painted_child_index
		and _stroke_animate_params == animate_params
		and _stroke_apply_effects == apply_effects
	):
		var painted_layer := children[painted_child_index]
		var painted_cel := frame.cels[painted_layer.index]
		var changed_image: Image
		if apply_effects:
			changed_image = painted_layer.display_effects(painted_cel, animate_params)
		else:
			changed_image = painted_cel.get_image()
		if (
			changed_image.get_size()
			== Vector2i(_stroke_texture_array.get_width(), _stroke_texture_array.get_height())
			and changed_image.get_format() == _stroke_image_format
		):
			_stroke_texture_array.update_layer(changed_image, painted_child_index)
			_blend_generator.generate_image(
				image,
				DrawingAlgos.blend_layers_shader,
				{"layers": _stroke_texture_array, "metadata": _stroke_metadata_texture},
				project.size,
				true,
				false
			)
			# A regular redraw after painting must never reuse a stale result.
			_group_cache.clear()
			if apply_effects:
				image = display_effects(frame.cels[index], animate_params, image)
			return image
	# Cache is only valid for the same child, frame, and composition settings.
	clear_stroke_blend_cache()
	var textures: Array[Image] = []
	_cache_texture_data.clear()
	var metadata_image := Image.create(children.size(), 4, false, Image.FORMAT_RGH)
	# Corresponding to the index of texture in textures. This is not the layer index
	var current_metadata_index := 0
	for i in children.size():
		var layer := children[i]
		if layer is GroupLayer:
			current_metadata_index = _blend_child_group(
				image,
				layer,
				frame,
				textures,
				metadata_image,
				current_metadata_index,
				animate_params,
				apply_effects
			)
			# NOTE: incrementation of current_metadata_index is done internally in
			# _blend_child_group(), so we don't have to use current_metadata_index += 1 here
		else:
			_include_child_in_blending(
				image,
				layer,
				frame,
				textures,
				metadata_image,
				current_metadata_index,
				animate_params,
				apply_effects
			)
			current_metadata_index += 1

	if DisplayServer.get_name() != "headless" and textures.size() > 0:
		var texture_array := Texture2DArray.new()
		texture_array.create_from_images(textures)
		var metadata_texture := ImageTexture.create_from_image(metadata_image)
		var blend_params := {"layers": texture_array, "metadata": metadata_texture}
		if painted_child_index >= 0:
			# Initial full composition for this stroke. Subsequent dabs update
			# just one GPU texture layer, skipping all unchanged child images.
			_stroke_frame = frame
			_stroke_texture_array = texture_array
			_stroke_metadata_texture = metadata_texture
			_stroke_child_index = painted_child_index
			_stroke_image_format = textures[painted_child_index].get_format()
			_stroke_animate_params = animate_params
			_stroke_apply_effects = apply_effects
			_cache_texture_data.clear()
			_group_cache.clear()
			_blend_generator.generate_image(
				image, DrawingAlgos.blend_layers_shader, blend_params, project.size, true, false
			)
		else:
			var c_key := [_cache_texture_data, metadata_image.get_data()]
			if _group_cache.has(c_key):
				# Don't waste time re-generating for groups that have remained unchanged
				var cache_image = Image.create_from_data(
					project.size.x,
					project.size.y,
					false,
					project.get_image_format(),
					_group_cache[c_key]
				)
				image.blit_rect(
					cache_image, Rect2i(Vector2i.ZERO, cache_image.get_size()), Vector2i.ZERO
				)
			else:
				_group_cache.clear()
				_blend_generator.generate_image(
					image, DrawingAlgos.blend_layers_shader, blend_params, project.size, true, false
				)
				_group_cache[c_key] = image.get_data()
		if apply_effects:
			image = display_effects(frame.cels[index], animate_params, image)
	return image


func _include_child_in_blending(
	image: ImageExtended,
	layer: BaseLayer,
	frame: Frame,
	textures: Array[Image],
	metadata_image: Image,
	i: int,
	animate_params: bool,
	apply_effects: bool
) -> void:
	var cel := frame.cels[layer.index]
	if DisplayServer.get_name() == "headless":
		DrawingAlgos.blend_layers_headless(image, project, layer, cel, Vector2i.ZERO)
	else:
		var cel_image: Image
		if apply_effects:
			cel_image = layer.display_effects(cel, animate_params)
		else:
			cel_image = cel.get_image()
		textures.append(cel_image)
		_cache_texture_data.append(cel_image.get_data())
		DrawingAlgos.set_layer_metadata_image(
			layer, cel, metadata_image, i, true, animate_params, false
		)


## Include a child group in the blending process.
## If the child group is set to pass through mode, loop through its children
## and include them as separate images, instead of blending them all together.
## Gets called recursively if the child group has children groups of its own,
## and they are also set to pass through mode.
func _blend_child_group(
	image: ImageExtended,
	layer: BaseLayer,
	frame: Frame,
	textures: Array[Image],
	metadata_image: Image,
	i: int,
	animate_params: bool,
	apply_effects: bool
) -> int:
	var new_i := i
	var blend_rect := Rect2i(Vector2i.ZERO, project.size)
	var cel := frame.cels[layer.index]
	if layer.blend_mode == BlendModes.PASS_THROUGH:
		var children := layer.get_children(false)
		for j in children.size():
			var child := children[j]
			if child is GroupLayer:
				new_i = _blend_child_group(
					image,
					child,
					frame,
					textures,
					metadata_image,
					new_i,
					animate_params,
					apply_effects
				)
			else:
				metadata_image.crop(metadata_image.get_width() + 1, metadata_image.get_height())
				_include_child_in_blending(
					image,
					child,
					frame,
					textures,
					metadata_image,
					new_i,
					animate_params,
					apply_effects
				)
				new_i += 1
	else:
		var blended_children := (layer as GroupLayer).blend_children(frame)
		if DisplayServer.get_name() == "headless":
			image.blend_rect(blended_children, blend_rect, Vector2i.ZERO)
		else:
			textures.append(blended_children)
			_cache_texture_data.append(blended_children.get_data())
			DrawingAlgos.set_layer_metadata_image(
				layer, cel, metadata_image, i, true, animate_params, false
			)
		new_i += 1
	return new_i


# Overridden Methods:


func serialize() -> Dictionary:
	var data := super.serialize()
	data["type"] = get_layer_type()
	data["expanded"] = expanded
	return data


func deserialize(dict: Dictionary) -> void:
	super.deserialize(dict)
	expanded = dict.expanded


func get_layer_type() -> int:
	return Global.LayerTypes.GROUP


func new_empty_cel() -> BaseCel:
	return GroupCel.new()


func set_name_to_default(number: int) -> void:
	name = tr("Group") + " %s" % number


func accepts_child(_layer: BaseLayer) -> bool:
	return true


func is_blender() -> bool:
	return blend_mode != BlendModes.PASS_THROUGH

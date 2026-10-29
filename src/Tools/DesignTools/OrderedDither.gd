# A standalone pencil variant with its own settings and shortcut actions.
# The procedural Bayer rendering remains shared with BaseDrawTool.
extends "res://src/Tools/DesignTools/Pencil.gd"


func _init() -> void:
	super()
	_brush = _new_dither_brush()


func _ready() -> void:
	super()
	# This is its own tool, not a fourth option in Pencil's brush popup.
	$Brush/Type.hide()
	$Brush/Type.disabled = true


func set_config(config: Dictionary) -> void:
	# Sizes and density are stored separately under the OrderedDither
	# tool name, even if other tool settings are shared.
	super(config)
	# BaseDrawTool.set_config() resolves types through the brush popup.
	# This procedural brush is deliberately not listed there.
	_brush = _new_dither_brush()


func _new_dither_brush() -> Brushes.Brush:
	var brush := Brushes.Brush.new()
	brush.type = Brushes.DITHER
	brush.index = 0
	# BaseDrawTool.update_brush() uses this only for its option icon.
	# The actual stamp and cursor preview come from the 4x4 Bayer mask.
	brush.image = Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	brush.image.fill(Color.WHITE)
	return brush

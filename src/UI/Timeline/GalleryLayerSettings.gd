class_name GalleryLayerSettings
extends ConfirmationDialog
## Editor-only settings for turning Pixelorama layers into gallery parts.
## The data is attached to the layer, not encoded in its name or user notes.
##
## Schema (all keys optional; missing mode means inherit from parent):
## {
##   "mode": "toggle" | "always" | "exclude",
##   "toggle_group": "shirt",  # only relevant for mode=toggle
##   "variant_group": "ghost_top",  # mutually exclusive variant family
##   "conditions": {"shirt": true, "bra": false},  # unset = don't care
##   "condition_logic": "or"  # optional; defaults to "and"
## }
##
## Evaluate only specified conditions: AND requires all to match, OR requires
## at least one to match. With no conditions the layer is unconditional for
## either mode. The future importer should AND each layer's resulting condition
## expression with its ancestors' expressions, while preserving each layer's
## chosen AND/OR logic.
##
## Children inherit their parent mode, toggle_group, and variant_group unless
## overridden. Conditions on ancestors and descendants are combined by the
## future importer. Root layers without a mode are ignored by default.

const GROUP_IDS := [
	"body", "panty", "bra", "shirt", "skirt", "socks", "shoes", "ghost",
	"hair", "fluid"
]
const GROUP_NAMES := [
	"身体", "パンティ", "ブラ", "シャツ", "スカート", "靴下", "靴",
	"幽霊", "髪", "体液"
]
const CONDITION_IDS := ["panty", "bra", "shirt", "skirt", "socks", "shoes"]
const CONDITION_NAMES := ["パンティ", "ブラ", "シャツ", "スカート", "靴下", "靴"]

enum Mode { INHERIT, TOGGLE, ALWAYS, EXCLUDE }
enum ConditionLogic { AND, OR }

var _layer: BaseLayer
var _project: Project
var _target_label: Label
var _mode_button: OptionButton
var _group_line_edit: LineEdit
var _group_box: VBoxContainer
var _effective_group_label: Label
var _variant_line_edit: LineEdit
var _effective_variant_label: Label
var _condition_logic_button: OptionButton
var _condition_container: VBoxContainer
var _condition_buttons: Dictionary = {}
var _condition_rows: Dictionary = {}
var _custom_condition_line_edit: LineEdit
var _notice_label: Label


func _ready() -> void:
	title = "ギャラリー設定"
	get_ok_button().text = "保存"
	get_cancel_button().text = "キャンセル"
	confirmed.connect(_save_settings)
	visibility_changed.connect(func(): Global.dialog_open(visible))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(510, 470)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# AcceptDialog lays out direct Control children above its buttons.
	add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)

	_target_label = _add_label(content, "対象レイヤー")
	_add_label(content, "取り込み方法")
	_mode_button = OptionButton.new()
	_mode_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_button.add_item("親グループの設定を継承（ルートは除外）", Mode.INHERIT)
	_mode_button.add_item("表示グループに所属", Mode.TOGGLE)
	_mode_button.add_item("常に表示", Mode.ALWAYS)
	_mode_button.add_item("ギャラリーから除外", Mode.EXCLUDE)
	_mode_button.item_selected.connect(_on_mode_selected)
	content.add_child(_mode_button)

	_group_box = VBoxContainer.new()
	_group_box.add_child(_add_label_unparented("操作グループ"))
	content.add_child(_group_box)
	_effective_group_label = _add_label(content, "")
	var group_row := HBoxContainer.new()
	_group_box.add_child(group_row)
	var group_picker := OptionButton.new()
	group_picker.add_item("候補を選択")
	for i in GROUP_IDS.size():
		group_picker.add_item(GROUP_NAMES[i], i + 1)
	group_row.add_child(group_picker)
	_group_line_edit = LineEdit.new()
	_group_line_edit.placeholder_text = "例: body / shirt / body_set"
	_group_line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	group_row.add_child(_group_line_edit)
	group_picker.item_selected.connect(
		func(index: int):
			if index > 0:
				_group_line_edit.text = GROUP_IDS[index - 1]
				# Setting LineEdit.text from code does not emit text_changed.
				# Refresh Save validity and the effective-group preview explicitly.
				_validate()
	)
	_group_line_edit.text_changed.connect(func(_text: String): _validate())

	_add_label(content, "差分グループ（任意・例: ghost_top）")
	_variant_line_edit = LineEdit.new()
	_variant_line_edit.placeholder_text = "同じ位置で切り替える差分を同じIDにする"
	content.add_child(_variant_line_edit)
	_effective_variant_label = _add_label(content, "")
	_variant_line_edit.text_changed.connect(func(_text: String): _validate())

	_add_label(content, "表示条件（『問わない』なら条件なし）")
	_add_label(content, "条件の結合方法")
	_condition_logic_button = OptionButton.new()
	_condition_logic_button.add_item("AND（すべての条件を満たす）", ConditionLogic.AND)
	_condition_logic_button.add_item("OR（どれか1つでも条件を満たす）", ConditionLogic.OR)
	_condition_logic_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_condition_logic_button)
	_condition_container = VBoxContainer.new()
	content.add_child(_condition_container)

	var add_row := HBoxContainer.new()
	content.add_child(add_row)
	_custom_condition_line_edit = LineEdit.new()
	_custom_condition_line_edit.placeholder_text = "追加する条件のID（例: accessory）"
	_custom_condition_line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_row.add_child(_custom_condition_line_edit)
	var add_button := Button.new()
	add_button.text = "条件を追加"
	add_button.pressed.connect(_add_custom_condition)
	add_row.add_child(add_button)

	_notice_label = Label.new()
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	content.add_child(_notice_label)
	_add_label(
		content,
		"グループ設定は子レイヤーに継承されます。子レイヤーでは条件だけの追加も可能です。"
	)


func _add_label(parent: Node, value: String) -> Label:
	var label := _add_label_unparented(value)
	parent.add_child(label)
	return label


func _add_label_unparented(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	return label


func open_for_layer(layer: BaseLayer) -> void:
	_layer = layer
	_project = layer.project
	_target_label.text = "対象: " + layer.name
	var settings: Dictionary = layer.gallery_settings
	# New top-level layers should default to a toggle group, so the user
	# does not need to open the import-mode dropdown every time. Child layers
	# keep inheritance, and existing metadata always keeps its saved meaning.
	var selected_mode := Mode.INHERIT
	if settings.is_empty() and not is_instance_valid(layer.parent):
		selected_mode = Mode.TOGGLE
	match str(settings.get("mode", "")):
		"toggle":
			selected_mode = Mode.TOGGLE
		"always":
			selected_mode = Mode.ALWAYS
		"exclude":
			selected_mode = Mode.EXCLUDE
	_mode_button.select(selected_mode)
	_group_line_edit.text = str(settings.get("toggle_group", ""))
	_variant_line_edit.text = str(settings.get("variant_group", ""))
	_condition_logic_button.select(
		ConditionLogic.OR if str(settings.get("condition_logic", "and")) == "or"
		else ConditionLogic.AND
	)
	_on_mode_selected(selected_mode)

	for key in _condition_rows.keys():
		var row: HBoxContainer = _condition_rows[key]
		_condition_container.remove_child(row)
		row.queue_free()
	_condition_rows.clear()
	_condition_buttons.clear()

	var saved_conditions: Dictionary = settings.get("conditions", {})
	for i in CONDITION_IDS.size():
		_add_condition_row(CONDITION_IDS[i], saved_conditions.get(CONDITION_IDS[i], null))
	for key in saved_conditions.keys():
		var condition_key := str(key)
		if not CONDITION_IDS.has(condition_key):
			_add_condition_row(condition_key, saved_conditions[key])
	_custom_condition_line_edit.clear()
	_notice_label.text = ""
	_validate()
	popup_centered(Vector2i(560, 630))


func _on_mode_selected(_index: int) -> void:
	_group_box.visible = _mode_button.get_selected_id() == Mode.TOGGLE
	_validate()


func _add_condition_row(key: String, selected_value: Variant) -> void:
	if _condition_buttons.has(key):
		return
	var row := HBoxContainer.new()
	_condition_container.add_child(row)
	_condition_rows[key] = row
	var name_label := Label.new()
	var name_index := CONDITION_IDS.find(key)
	name_label.text = CONDITION_NAMES[name_index] if name_index >= 0 else key
	name_label.custom_minimum_size.x = 175
	row.add_child(name_label)
	var value_button := OptionButton.new()
	value_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_button.add_item("問わない", 0)
	value_button.add_item("表示", 1)
	value_button.add_item("非表示", 2)
	var selection := 0
	if selected_value is bool:
		selection = 1 if selected_value else 2
	value_button.select(selection)
	row.add_child(value_button)
	_condition_buttons[key] = value_button
	if name_index < 0:
		var remove_button := Button.new()
		remove_button.text = "削除"
		remove_button.pressed.connect(_remove_custom_condition.bind(key))
		row.add_child(remove_button)


func _remove_custom_condition(key: String) -> void:
	if not _condition_rows.has(key):
		return
	var row: HBoxContainer = _condition_rows[key]
	_condition_container.remove_child(row)
	row.queue_free()
	_condition_rows.erase(key)
	_condition_buttons.erase(key)


func _add_custom_condition() -> void:
	var key := _custom_condition_line_edit.text.strip_edges().to_lower()
	if not key.is_valid_identifier():
		_notice_label.text = "条件IDには英数字とアンダースコアを使用してください。"
		return
	if _condition_buttons.has(key):
		_notice_label.text = "その条件は既にあります。"
		return
	_add_condition_row(key, null)
	_custom_condition_line_edit.clear()
	_notice_label.text = ""


func _validate() -> void:
	if not is_instance_valid(_mode_button) or not is_instance_valid(_group_line_edit):
		return
	var group_id := _group_line_edit.text.strip_edges()
	var variant_id := _variant_line_edit.text.strip_edges()
	var group_invalid := (
		_mode_button.get_selected_id() == Mode.TOGGLE
		and not group_id.is_valid_identifier()
	)
	var variant_invalid := not variant_id.is_empty() and not variant_id.is_valid_identifier()
	get_ok_button().disabled = group_invalid or variant_invalid
	_refresh_effective_settings()


## Shows the resolved values without copying inherited metadata onto this layer.
## Local edits change the preview immediately but are only saved on confirmation.
func _refresh_effective_settings() -> void:
	if not is_instance_valid(_layer):
		return
	match _mode_button.get_selected_id():
		Mode.TOGGLE:
			var group_name := _group_line_edit.text.strip_edges()
			_effective_group_label.text = "操作グループ：" + group_name + "（このレイヤーで設定）"
		Mode.ALWAYS:
			_effective_group_label.text = "操作グループ：なし（常に表示）"
		Mode.EXCLUDE:
			_effective_group_label.text = "操作グループ：なし（ギャラリーから除外）"
		Mode.INHERIT:
			_effective_group_label.text = _get_inherited_mode_description()

	var own_variant := _variant_line_edit.text.strip_edges()
	var parent_variant := _find_parent_value("variant_group")
	if not own_variant.is_empty():
		_effective_variant_label.text = (
			"差分グループ：" + own_variant + "（このレイヤーで設定）"
		)
	elif not parent_variant.is_empty():
		var inherited_variant := str(parent_variant["value"])
		_effective_variant_label.text = (
			"差分グループ：" + inherited_variant
			+ "（親「" + str(parent_variant["source"]) + "」から継承）"
		)
	else:
		_effective_variant_label.text = "差分グループ：なし"
	_variant_line_edit.placeholder_text = (
		"空欄なら親から継承（" + str(parent_variant["value"]) + "）"
		if not parent_variant.is_empty()
		else "任意・例: ghost_top"
	)


func _get_inherited_mode_description() -> String:
	var ancestor := _layer.parent
	while is_instance_valid(ancestor):
		var inherited_settings: Dictionary = ancestor.gallery_settings
		var mode := str(inherited_settings.get("mode", ""))
		match mode:
			"toggle":
				return (
					"操作グループ：" + str(inherited_settings.get("toggle_group", ""))
					+ "（親「" + ancestor.name + "」から継承）"
				)
			"always":
				return "操作グループ：なし（親「" + ancestor.name + "」の常時表示を継承）"
			"exclude":
				return "操作グループ：なし（親「" + ancestor.name + "」の除外を継承）"
		ancestor = ancestor.parent
	return "操作グループ：なし（親に設定なし・ギャラリーから除外）"


func _find_parent_value(key: String) -> Dictionary:
	var ancestor := _layer.parent
	while is_instance_valid(ancestor):
		var value := str(ancestor.gallery_settings.get(key, "")).strip_edges()
		if not value.is_empty():
			return {"value": value, "source": ancestor.name}
		ancestor = ancestor.parent
	return {}


func _save_settings() -> void:
	if not is_instance_valid(_layer) or _project != Global.current_project:
		return
	if not _project.layers.has(_layer):
		return
	var data: Dictionary = {}
	match _mode_button.get_selected_id():
		Mode.TOGGLE:
			data["mode"] = "toggle"
			data["toggle_group"] = _group_line_edit.text.strip_edges()
		Mode.ALWAYS:
			data["mode"] = "always"
		Mode.EXCLUDE:
			data["mode"] = "exclude"
		# INHERIT is represented by an absent mode key.
	var variant_id := _variant_line_edit.text.strip_edges()
	if not variant_id.is_empty():
		data["variant_group"] = variant_id
	var conditions: Dictionary = {}
	for key in _condition_buttons.keys():
		var choice: OptionButton = _condition_buttons[key]
		match choice.get_selected_id():
			1:
				conditions[key] = true
			2:
				conditions[key] = false
	if not conditions.is_empty():
		data["conditions"] = conditions
	# Omit the default so existing PXO files stay backward compatible.
	if _condition_logic_button.get_selected_id() == ConditionLogic.OR:
		data["condition_logic"] = "or"
	var old_data := _layer.gallery_settings.duplicate(true)
	if old_data == data:
		return
	_project.undo_redo.create_action("Change Gallery Layer Settings")
	_project.undo_redo.add_do_property(_layer, "gallery_settings", data)
	_project.undo_redo.add_undo_property(_layer, "gallery_settings", old_data)
	_project.undo_redo.add_do_method(Global.undo_or_redo.bind(false))
	_project.undo_redo.add_undo_method(Global.undo_or_redo.bind(true))
	_project.undo_redo.commit_action()

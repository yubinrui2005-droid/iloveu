extends CanvasLayer
## HUD + 所有界面状态
## （准星、血条、波次、Boss 血条、武器面板、暂停、三选一强化、结算排行榜、换房淡黑）。
##
## 为什么界面全部用代码搭：这样不需要美术资源，也不用在编辑器里对齐锚点，
## 你直接改这里的数字就能调整版式。想换成编辑器里拖 UI，把 _build() 拆成 .tscn 即可。

signal upgrade_chosen(id: String)
signal restart_requested

enum State { PLAYING, UPGRADE, PAUSED, DEAD }

const COL_TEXT := Color(0.93, 0.94, 0.96)
const COL_DIM := Color(0.62, 0.66, 0.74)
const COL_ACCENT := Color(0.90, 0.31, 0.33)
const COL_GOLD := Color(0.95, 0.77, 0.33)
const COL_BLUE := Color(0.42, 0.68, 0.95)
const COL_GREEN := Color(0.36, 0.82, 0.60)

var state: State = State.PLAYING
var run_seed := 0

var _player: Node = null
var _wave := 0
var _enemies := 0
var _room := 0
var _elapsed := 0.0
var _hint_timer := 16.0
var _hit_flash := 0.0
var _flash_alpha := 0.0
var _last_hp := -1.0
var _best_wave := 0
var _hint_touch := false
var _portrait_hint: Label

var _root: Control
var _crosshair: Control
var _hp_bar: ProgressBar
var _hp_label: Label
var _ammo_label: Label
var _weapon_label: Label
var _slot_labels: Array[Label] = []
var _slot_box: VBoxContainer
var _top_label: Label
var _stat_label: Label
var _hint_label: Label
var _flash: ColorRect
var _fade: ColorRect
var _banner: Label
var _toast: Label
var _boss_box: Control
var _boss_name: Label
var _boss_bar: ProgressBar
var _upgrade_panel: Control
var _upgrade_title: Label
var _upgrade_box: VBoxContainer
var _pause_panel: Control
var _dead_panel: Control
var _dead_stats: Label
var _dead_rank: Label
var _board_box: VBoxContainer


func _ready() -> void:
	layer = 3                       # 高于触屏控件的 layer 2，换房淡黑才能盖住按钮
	_best_wave = int(SaveData.best().get("wave", 0))
	_build()
	_sync_mouse_mode()


func _sync_mouse_mode() -> void:
	if TouchUI.is_active():
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# ============================================================
#  构建界面
# ============================================================
func _place(c: Control, preset: int, l: float, t: float, r: float, b: float) -> void:
	c.set_anchors_preset(preset, false)
	c.offset_left = l
	c.offset_top = t
	c.offset_right = r
	c.offset_bottom = b


func _make_label(text: String, fsize: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# ---- 受伤红屏 ----
	_flash = ColorRect.new()
	_flash.color = Color(0.8, 0.1, 0.12, 0.0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_flash)

	# ---- 准星 ----
	_crosshair = Control.new()
	_place(_crosshair, Control.PRESET_CENTER, -40, -40, 40, 40)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair.draw.connect(_draw_crosshair)
	_root.add_child(_crosshair)

	# ---- 顶部：波次 / 剩余敌人 / 房间 ----
	_top_label = _make_label("", 21, COL_TEXT)
	_place(_top_label, Control.PRESET_CENTER_TOP, -420, 14, 420, 50)
	_top_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_top_label)

	# ---- 左上：击杀 / 用时 / 历史最佳 ----
	_stat_label = _make_label("", 16, COL_DIM)
	_place(_stat_label, Control.PRESET_TOP_LEFT, 26, 14, 460, 40)
	_root.add_child(_stat_label)

	# ---- Boss 血条（挂在顶部，平时隐藏）----
	_build_boss_bar()

	# ---- 左下：生命 ----
	_hp_label = _make_label("", 16, COL_DIM)
	_place(_hp_label, Control.PRESET_BOTTOM_LEFT, 28, -98, 320, -76)
	_root.add_child(_hp_label)

	_hp_bar = ProgressBar.new()
	_hp_bar.max_value = 100.0
	_hp_bar.value = 100.0
	_hp_bar.show_percentage = false
	_place(_hp_bar, Control.PRESET_BOTTOM_LEFT, 28, -72, 300, -52)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.55)
	bg.set_corner_radius_all(3)
	var fg := StyleBoxFlat.new()
	fg.bg_color = COL_ACCENT
	fg.set_corner_radius_all(3)
	_hp_bar.add_theme_stylebox_override("background", bg)
	_hp_bar.add_theme_stylebox_override("fill", fg)
	_root.add_child(_hp_bar)

	# ---- 右下：武器 / 弹药 ----
	_build_weapon_panel()

	# ---- 底部中间：操作提示 ----
	_hint_label = _make_label("", 15, COL_DIM)
	_place(_hint_label, Control.PRESET_CENTER_BOTTOM, -520, -44, 520, -18)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_hint_label)
	_update_hint()

	# ---- 中央大字（波次 / 强化提示）----
	_banner = _make_label("", 44, COL_TEXT)
	_place(_banner, Control.PRESET_CENTER, -420, -150, 420, -90)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.modulate.a = 0.0
	_root.add_child(_banner)

	# ---- 飘字提示 ----
	_toast = _make_label("", 20, COL_GOLD)
	_place(_toast, Control.PRESET_CENTER, -460, 96, 460, 130)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.modulate.a = 0.0
	_root.add_child(_toast)

	_build_upgrade_panel()
	_build_pause_panel()
	_build_dead_panel()

	# ---- 竖屏提示（触屏下竖着拿手机时盖住整个画面）----
	_portrait_hint = _make_label("请把手机横过来 · 本作是横屏游戏", 26, COL_GOLD)
	_portrait_hint.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_portrait_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_portrait_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 用 Label 的 normal 样式盒给它铺一层不透明底，这样能把整个画面盖住
	var cover := StyleBoxFlat.new()
	cover.bg_color = Color(0.03, 0.03, 0.05, 1.0)
	_portrait_hint.add_theme_stylebox_override("normal", cover)
	_portrait_hint.visible = false
	_root.add_child(_portrait_hint)

	# ---- 换房淡黑（最后加，盖在所有东西上面）----
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_fade)

	_hp_bar.value = 100.0
	_hp_label.text = "生命 100 / 100"


func _update_hint() -> void:
	if _hint_label == null:
		return
	_hint_label.text = "左侧摇杆移动 · 右侧滑动转视角 · 射击 / 跳跃 / 换弹 / 换枪按钮" \
			if TouchUI.is_active() else \
			"WASD 移动 · 鼠标左键射击 · R 换弹 · Shift 疾跑 · 空格跳跃 · 1~4 或滚轮换枪 · Esc 暂停"


func _build_boss_bar() -> void:
	_boss_box = Control.new()
	_place(_boss_box, Control.PRESET_CENTER_TOP, -330, 56, 330, 112)
	_boss_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_box.visible = false
	_root.add_child(_boss_box)

	_boss_name = _make_label("", 17, COL_GOLD)
	_place(_boss_name, Control.PRESET_TOP_WIDE, 0, 0, 0, 28)
	_boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_box.add_child(_boss_name)

	_boss_bar = ProgressBar.new()
	_boss_bar.max_value = 100.0
	_boss_bar.value = 100.0
	_boss_bar.show_percentage = false
	_place(_boss_bar, Control.PRESET_TOP_WIDE, 0, 30, 0, 48)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.6)
	bg.border_color = Color(0.55, 0.16, 0.20, 0.9)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(3)
	var fg := StyleBoxFlat.new()
	fg.bg_color = Color(0.86, 0.20, 0.26)
	fg.set_corner_radius_all(3)
	_boss_bar.add_theme_stylebox_override("background", bg)
	_boss_bar.add_theme_stylebox_override("fill", fg)
	_boss_box.add_child(_boss_bar)


func _build_weapon_panel() -> void:
	_ammo_label = _make_label("", 30, COL_TEXT)
	_place(_ammo_label, Control.PRESET_BOTTOM_RIGHT, -400, -84, -28, -36)
	_ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_root.add_child(_ammo_label)

	_weapon_label = _make_label("", 16, COL_GOLD)
	_place(_weapon_label, Control.PRESET_BOTTOM_RIGHT, -520, -112, -28, -88)
	_weapon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_root.add_child(_weapon_label)

	var box := VBoxContainer.new()
	_slot_box = box
	_place(box, Control.PRESET_BOTTOM_RIGHT, -520, -238, -28, -118)
	box.alignment = BoxContainer.ALIGNMENT_END
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(box)

	for i in 4:
		var l := _make_label("", 14, COL_DIM)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		box.add_child(l)
		_slot_labels.append(l)


## 触屏模式把「武器栏 + 弹药数」从右下角挪到右上角。
##
## 为什么：触屏的射击/跳跃/换弹/换枪按钮占着右下角一大片（见 touch_ui.gd 的 _layout），
## 而这块信息原来也贴着右下角，两边直接叠在一起——实测 844x390 横屏手机上
## 「24 / 24」弹匣数和武器名都被按钮盖住，看都看不见。
## 横屏手机屏幕矮，右下角腾不出空位，所以触屏时整块搬到右上角去。
func _apply_touch_layout(touch: bool) -> void:
	if _ammo_label == null or _slot_box == null or _weapon_label == null:
		return
	if _player != null:
		_refresh_weapon_label(_player.current_weapon())
	if touch:
		_slot_box.alignment = BoxContainer.ALIGNMENT_BEGIN
		_place(_weapon_label, Control.PRESET_TOP_RIGHT, -250, 4, -12, 26)
		_place(_slot_box, Control.PRESET_TOP_RIGHT, -250, 28, -12, 120)
		_place(_ammo_label, Control.PRESET_TOP_RIGHT, -250, 122, -12, 166)
		# 首领血条本来横在顶部中间（-330..330），会顶到右上角这块武器栏，
		# 触屏时把它往左收一点，给武器栏让出右边 250px。
		if _boss_box != null:
			_place(_boss_box, Control.PRESET_CENTER_TOP, -290, 56, 160, 112)
	else:
		_slot_box.alignment = BoxContainer.ALIGNMENT_END
		_place(_slot_box, Control.PRESET_BOTTOM_RIGHT, -520, -238, -28, -118)
		_place(_weapon_label, Control.PRESET_BOTTOM_RIGHT, -520, -112, -28, -88)
		_place(_ammo_label, Control.PRESET_BOTTOM_RIGHT, -400, -84, -28, -36)
		if _boss_box != null:
			_place(_boss_box, Control.PRESET_CENTER_TOP, -330, 56, 330, 112)


func _build_upgrade_panel() -> void:
	_upgrade_panel = Control.new()
	_upgrade_panel.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_upgrade_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_upgrade_panel.visible = false
	_root.add_child(_upgrade_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.04, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_upgrade_panel.add_child(dim)

	_upgrade_title = _make_label("选择一项强化", 30, COL_GOLD)
	_place(_upgrade_title, Control.PRESET_CENTER, -400, -170, 400, -120)
	_upgrade_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_upgrade_panel.add_child(_upgrade_title)

	var sub := _make_label("清空一间房后从 3 个词条里选 1 个，效果永久叠加", 15, COL_DIM)
	_place(sub, Control.PRESET_CENTER, -400, -118, 400, -92)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_upgrade_panel.add_child(sub)

	_upgrade_box = VBoxContainer.new()
	_place(_upgrade_box, Control.PRESET_CENTER, -340, -60, 340, 200)
	_upgrade_box.add_theme_constant_override("separation", 14)
	_upgrade_box.mouse_filter = Control.MOUSE_FILTER_PASS
	_upgrade_panel.add_child(_upgrade_box)


func _build_pause_panel() -> void:
	_pause_panel = Control.new()
	_pause_panel.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_pause_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_panel.visible = false
	_root.add_child(_pause_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.04, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_panel.add_child(dim)

	var t := _make_label("已暂停", 40, COL_TEXT)
	_place(t, Control.PRESET_CENTER, -400, -70, 400, -10)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pause_panel.add_child(t)

	var s := _make_label("按 Esc 或点击屏幕继续", 17, COL_DIM)
	_place(s, Control.PRESET_CENTER, -400, 0, 400, 30)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pause_panel.add_child(s)


func _build_dead_panel() -> void:
	_dead_panel = Control.new()
	_dead_panel.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_dead_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_dead_panel.visible = false
	_root.add_child(_dead_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.10, 0.01, 0.02, 0.80)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dead_panel.add_child(dim)

	var t := _make_label("你 阵 亡 了", 46, COL_ACCENT)
	_place(t, Control.PRESET_CENTER, -400, -260, 400, -200)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dead_panel.add_child(t)

	_dead_stats = _make_label("", 19, COL_TEXT)
	_place(_dead_stats, Control.PRESET_CENTER, -460, -192, 460, -160)
	_dead_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dead_panel.add_child(_dead_stats)

	_dead_rank = _make_label("", 22, COL_GOLD)
	_place(_dead_rank, Control.PRESET_CENTER, -460, -156, 460, -122)
	_dead_rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dead_panel.add_child(_dead_rank)

	var board_title := _make_label("— 本地排行榜 TOP 5 —", 15, COL_DIM)
	_place(board_title, Control.PRESET_CENTER, -460, -104, 460, -78)
	board_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dead_panel.add_child(board_title)

	_board_box = VBoxContainer.new()
	_place(_board_box, Control.PRESET_CENTER, -420, -74, 420, 96)
	_board_box.add_theme_constant_override("separation", 3)
	_board_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dead_panel.add_child(_board_box)

	var again := Button.new()
	again.text = "重新开始（新的一局，房间会全部重新随机）"
	again.add_theme_font_size_override("font_size", 18)
	_place(again, Control.PRESET_CENTER, -240, 116, 240, 164)
	again.pressed.connect(func() -> void: restart_requested.emit())
	_dead_panel.add_child(again)


# ============================================================
#  对外接口（由 main.gd 调用）
# ============================================================
func bind(player: Node) -> void:
	_player = player
	player.health_changed.connect(_on_health_changed)
	player.ammo_changed.connect(_on_ammo_changed)
	player.reload_changed.connect(_on_reload_changed)
	player.hit_confirmed.connect(_on_hit_confirmed)
	player.weapon_changed.connect(_on_weapon_changed)
	player.weapon_locked.connect(_on_weapon_locked)
	_on_health_changed(player.health, player.max_health)
	_on_ammo_changed(player.ammo, player.mag_size)
	_refresh_slots()


func set_wave_info(wave: int, enemies_left: int, room := 0) -> void:
	_wave = wave
	_enemies = enemies_left
	_room = room


func show_banner(text: String) -> void:
	_banner.text = text
	_banner.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_banner, "modulate:a", 1.0, 0.18)
	tw.tween_interval(1.0)
	tw.tween_property(_banner, "modulate:a", 0.0, 0.5)


func show_toast(text: String) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(1.4)
	tw.tween_property(_toast, "modulate:a", 0.0, 0.7)


func show_boss(name: String, hp: float, max_hp: float) -> void:
	_boss_name.text = "%s   %d / %d" % [name, roundi(hp), roundi(max_hp)]
	_boss_bar.max_value = max_hp
	_boss_bar.value = hp
	_boss_box.visible = true


func update_boss(hp: float, max_hp: float) -> void:
	_boss_bar.max_value = max_hp
	_boss_bar.value = hp
	var base: String = _boss_name.text.split("   ")[0]
	_boss_name.text = "%s   %d / %d" % [base, roundi(maxf(hp, 0.0)), roundi(max_hp)]


func hide_boss() -> void:
	_boss_box.visible = false


## 换房时的黑场过渡
func fade_out(dur := 0.3) -> void:
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 1.0, dur)


func fade_in(dur := 0.35) -> void:
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 0.0, dur)


func show_upgrade_choices(choices: Array) -> void:
	for child in _upgrade_box.get_children():
		child.queue_free()

	for entry in choices:
		var b := Button.new()
		var tag := _rarity_tag(int(entry["rarity"]))
		b.text = "%s  %s   ·   %s" % [tag, entry["name"], entry["desc"]]
		b.custom_minimum_size = Vector2(0, 62)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 19)
		b.add_theme_color_override("font_color", COL_TEXT)
		var col := _rarity_color(int(entry["rarity"]))
		b.add_theme_stylebox_override("normal", _card_style(col, 0.10))
		b.add_theme_stylebox_override("hover", _card_style(col, 0.28))
		b.add_theme_stylebox_override("pressed", _card_style(col, 0.42))
		var id: String = entry["id"]
		b.pressed.connect(func() -> void: upgrade_chosen.emit(id))
		_upgrade_box.add_child(b)

	_upgrade_title.text = "第 %d 波清理完毕 · 选择一项强化" % _wave
	state = State.UPGRADE
	_upgrade_panel.visible = true
	TouchUI.set_allowed(false)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().paused = true
	if _upgrade_box.get_child_count() > 0:
		(_upgrade_box.get_child(0) as Button).grab_focus()


func close_upgrade_choices() -> void:
	_upgrade_panel.visible = false
	state = State.PLAYING
	TouchUI.set_allowed(true)
	get_tree().paused = false
	_sync_mouse_mode()


## 供 main.gd 判断当前是否处于「可操作」局面
func is_playing() -> bool:
	return state == State.PLAYING


func show_game_over(stats: Dictionary) -> void:
	_dead_stats.text = "坚持到第 %d 波 · 走过 %d 间房 · 击杀 %d 个 · 用时 %s" % [
		stats.get("wave", 0), stats.get("rooms", 0), stats.get("kills", 0),
		_format_time(stats.get("time", 0.0))
	]
	var rank := int(stats.get("rank", 0))
	if rank <= 0:
		_dead_rank.text = "未进入排行榜前 %d 名" % SaveData.MAX_ENTRIES
		_dead_rank.add_theme_color_override("font_color", COL_DIM)
	elif bool(stats.get("is_best", false)):
		_dead_rank.text = "★ 新纪录！本地第 1 名 ★"
		_dead_rank.add_theme_color_override("font_color", COL_GOLD)
	else:
		_dead_rank.text = "本地排行榜第 %d 名" % rank
		_dead_rank.add_theme_color_override("font_color", COL_BLUE)

	_fill_board(stats.get("entries", []), int(stats.get("wave", 0)))

	state = State.DEAD
	_dead_panel.visible = true
	TouchUI.set_allowed(false)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().paused = true


func _fill_board(entries: Array, my_wave: int) -> void:
	_board_box.visible = entries.size() > 0
	for child in _board_box.get_children():
		child.queue_free()
	for i in mini(5, entries.size()):
		var e: Dictionary = entries[i]
		var col := COL_TEXT if int(e.get("wave", 0)) == my_wave else COL_DIM
		var date := String(e.get("date", ""))
		if date.length() > 10:
			date = date.substr(0, 10)
		var l := _make_label("%d.  第 %2d 波  击杀 %3d  %s   %s" % [
			i + 1, int(e.get("wave", 0)), int(e.get("kills", 0)),
			_format_time(e.get("time", 0.0)), date
		], 15, col)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_board_box.add_child(l)


func damage_flash() -> void:
	_flash_alpha = 0.3


# ============================================================
#  输入（暂停 / 重开）
# ============================================================
func _input(event: InputEvent) -> void:
	match state:
		State.PLAYING:
			if event.is_action_pressed("ui_cancel"):
				state = State.PAUSED
				_pause_panel.visible = true
				TouchUI.set_allowed(false)
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				get_tree().paused = true
		State.PAUSED:
			var resume: bool = event.is_action_pressed("ui_cancel") \
					or (event is InputEventMouseButton and event.pressed) \
					or (event is InputEventScreenTouch and event.pressed)
			if resume:
				state = State.PLAYING
				_pause_panel.visible = false
				TouchUI.set_allowed(true)
				get_tree().paused = false
				_sync_mouse_mode()
		State.DEAD:
			if event.is_action_pressed("reload"):
				restart_requested.emit()
		_:
			pass


# ============================================================
#  每帧刷新
# ============================================================
func _process(delta: float) -> void:
	if state != State.PAUSED and state != State.DEAD:
		_elapsed += delta

	if _hit_flash > 0.0:
		_hit_flash = maxf(_hit_flash - delta * 5.0, 0.0)
		_crosshair.queue_redraw()

	if _flash_alpha > 0.0:
		_flash_alpha = maxf(_flash_alpha - delta * 1.4, 0.0)
		_flash.color.a = _flash_alpha

	if _hint_timer > 0.0:
		_hint_timer -= delta
		if _hint_timer <= 0.0:
			var tw := create_tween()
			tw.tween_property(_hint_label, "modulate:a", 0.0, 0.8)

	# 触屏模式可能在游玩途中才被激活（玩家第一次摸屏幕），提示语要跟着换
	var touch_now := TouchUI.is_active()
	if touch_now != _hint_touch:
		_hint_touch = touch_now
		_update_hint()
		_apply_touch_layout(touch_now)
		_hint_label.modulate.a = 1.0
		_hint_timer = 8.0

	# 手机竖着拿的时候，把画面盖掉并提示横屏（canvas_items + expand 下靠宽高比判断）
	if _portrait_hint != null:
		_portrait_hint.visible = touch_now and _root.size.x < _root.size.y

	var enemies_text := ("剩余敌人 %d" % _enemies) if _enemies > 0 else "出口已开启 · 走向发光的门"
	_top_label.text = "第 %d 波    房间 %d    %s" % [_wave, _room, enemies_text]

	var kill_count := 0
	if _player != null:
		kill_count = int(_player.kills)
	var best := ("　历史最佳 第 %d 波" % _best_wave) if _best_wave > 0 else ""
	_stat_label.text = "击杀 %d    用时 %s%s" % [kill_count, _format_time(_elapsed), best]


# ============================================================
#  内部回调
# ============================================================
func _on_health_changed(hp: float, max_hp: float) -> void:
	if _last_hp >= 0.0 and hp < _last_hp:
		damage_flash()
	_last_hp = hp
	_hp_bar.max_value = max_hp
	_hp_bar.value = hp
	_hp_label.text = "生命 %d / %d" % [roundi(hp), roundi(max_hp)]
	var ratio := hp / maxf(max_hp, 1.0)
	var fg := StyleBoxFlat.new()
	fg.bg_color = COL_ACCENT if ratio > 0.35 else Color(1.0, 0.42, 0.2)
	fg.set_corner_radius_all(3)
	_hp_bar.add_theme_stylebox_override("fill", fg)
	if ratio <= 0.35:
		_flash_alpha = maxf(_flash_alpha, 0.16)


## 当前这一局已用时（秒），供结算界面使用
func elapsed_time() -> float:
	return _elapsed


func _on_ammo_changed(ammo: int, mag: int) -> void:
	_ammo_label.text = "%d / %d" % [ammo, mag]
	_ammo_label.add_theme_color_override("font_color", COL_ACCENT if ammo <= 0 else COL_TEXT)


func _on_reload_changed(reloading: bool) -> void:
	if reloading:
		_ammo_label.text = "换弹中…"
		_ammo_label.add_theme_color_override("font_color", COL_GOLD)


func _on_hit_confirmed(_crit: bool) -> void:
	_hit_flash = 1.0
	_crosshair.queue_redraw()


func _on_weapon_changed(_index: int, data: WeaponData) -> void:
	_refresh_weapon_label(data)
	_refresh_slots()


## 武器信息行。触屏模式下这行被搬到了右上角，那块地方只有 238px 宽，
## 「突击步枪    伤害 18 · 射速 7.5/s · 弹匣 24」根本放不下（会被右边缘裁掉），
## 所以触屏时去掉武器名（下面高亮的那一行已经写了）、字号也降一档。
func _refresh_weapon_label(data: WeaponData) -> void:
	if _weapon_label == null:
		return
	if _hint_touch:
		_weapon_label.add_theme_font_size_override("font_size", 13)
		_weapon_label.text = _stat_line(data)
	else:
		_weapon_label.add_theme_font_size_override("font_size", 16)
		_weapon_label.text = "%s    %s" % [data.display_name, _stat_line(data)]


func _on_weapon_locked(index: int, data: WeaponData) -> void:
	show_toast("%s 还没解锁 —— 第 %d 波到手" % [data.display_name, data.unlock_wave])


## 用「当前实际数值」而不是武器基础值，这样强化效果在面板上看得见
func _stat_line(_data: WeaponData) -> String:
	if _player == null:
		return ""
	var parts := "伤害 %.0f · 射速 %.1f/s · 弹匣 %d" % [
		_player.weapon_damage, _player.fire_rate, _player.mag_size
	]
	if _player.pellets > 1:
		parts += " · %d 弹丸" % _player.pellets
	if _player.pierce_bonus > 0:
		parts += " · 穿透 %d" % _player.pierce_bonus
	return parts


func _refresh_slots() -> void:
	if _player == null:
		return
	var n: int = mini(4, _player.weapons.size())
	for i in _slot_labels.size():
		var l := _slot_labels[i]
		if i >= n:
			l.text = ""
			continue
		var w: WeaponData = _player.weapons[i]
		var unlocked: bool = _player.is_unlocked(i)
		var current: bool = int(_player.weapon_index) == i
		if not unlocked:
			l.text = "%d  ？ 锁定（第 %d 波解锁）" % [i + 1, w.unlock_wave]
			l.add_theme_color_override("font_color", Color(0.40, 0.42, 0.47))
		else:
			l.text = "%d  %s" % [i + 1, w.display_name]
			l.add_theme_color_override("font_color", COL_GOLD if current else COL_DIM)


# ============================================================
#  绘制 / 工具
# ============================================================
func _draw_crosshair() -> void:
	var c := _crosshair.size * 0.5
	var col := Color(1, 1, 1, 0.85)
	var gap := 5.0
	var ln := 9.0
	var w := 2.0
	_crosshair.draw_line(c + Vector2(-gap - ln, 0), c + Vector2(-gap, 0), col, w)
	_crosshair.draw_line(c + Vector2(gap, 0), c + Vector2(gap + ln, 0), col, w)
	_crosshair.draw_line(c + Vector2(0, -gap - ln), c + Vector2(0, -gap), col, w)
	_crosshair.draw_line(c + Vector2(0, gap), c + Vector2(0, gap + ln), col, w)
	_crosshair.draw_circle(c, 1.6, col)
	if _hit_flash > 0.0:
		var hc := Color(1.0, 0.85, 0.3, _hit_flash)
		var d := 7.0
		_crosshair.draw_line(c + Vector2(-d, -d), c + Vector2(-d * 0.4, -d * 0.4), hc, 2.5)
		_crosshair.draw_line(c + Vector2(d, -d), c + Vector2(d * 0.4, -d * 0.4), hc, 2.5)
		_crosshair.draw_line(c + Vector2(-d, d), c + Vector2(-d * 0.4, d * 0.4), hc, 2.5)
		_crosshair.draw_line(c + Vector2(d, d), c + Vector2(d * 0.4, d * 0.4), hc, 2.5)


func _card_style(accent: Color, alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.13, alpha + 0.35)
	sb.border_color = Color(accent.r, accent.g, accent.b, alpha + 0.5)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	return sb


func _rarity_tag(rarity: int) -> String:
	match rarity:
		3: return "[传说]"
		2: return "[稀有]"
		_: return "[普通]"


func _rarity_color(rarity: int) -> Color:
	match rarity:
		3: return COL_GOLD
		2: return COL_BLUE
		_: return Color(0.72, 0.75, 0.8)


func _format_time(sec: float) -> String:
	var t := int(sec)
	return "%02d:%02d" % [t / 60, t % 60]

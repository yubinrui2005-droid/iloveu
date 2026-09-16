extends CanvasLayer
## HUD + 所有界面状态（准星、血条、波次信息、暂停、三选一强化、结算）。
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

var state: State = State.PLAYING
var run_seed := 0

var _player: Node = null
var _wave := 0
var _enemies := 0
var _elapsed := 0.0
var _hint_timer := 14.0
var _hit_flash := 0.0
var _flash_alpha := 0.0
var _last_hp := -1.0

var _root: Control
var _crosshair: Control
var _hp_bar: ProgressBar
var _hp_label: Label
var _ammo_label: Label
var _top_label: Label
var _stat_label: Label
var _hint_label: Label
var _flash: ColorRect
var _banner: Label
var _toast: Label
var _upgrade_panel: Control
var _upgrade_title: Label
var _upgrade_box: VBoxContainer
var _pause_panel: Control
var _dead_panel: Control
var _dead_stats: Label


func _ready() -> void:
	_build()
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

	# ---- 顶部：波次 / 剩余敌人 ----
	_top_label = _make_label("", 22, COL_TEXT)
	_place(_top_label, Control.PRESET_CENTER_TOP, -320, 16, 320, 54)
	_top_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_top_label)

	# ---- 左上：击杀 / 用时 ----
	_stat_label = _make_label("", 17, COL_DIM)
	_place(_stat_label, Control.PRESET_TOP_LEFT, 26, 16, 420, 42)
	_root.add_child(_stat_label)

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

	# ---- 右下：弹药 ----
	_ammo_label = _make_label("", 26, COL_TEXT)
	_place(_ammo_label, Control.PRESET_BOTTOM_RIGHT, -360, -80, -28, -32)
	_ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_root.add_child(_ammo_label)

	# ---- 底部中间：操作提示 ----
	_hint_label = _make_label("WASD 移动 · 鼠标左键射击 · R 换弹 · Shift 疾跑 · 空格跳跃 · Esc 暂停", 15, COL_DIM)
	_place(_hint_label, Control.PRESET_CENTER_BOTTOM, -420, -44, 420, -18)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_hint_label)

	# ---- 中央大字（波次 / 强化提示）----
	_banner = _make_label("", 44, COL_TEXT)
	_place(_banner, Control.PRESET_CENTER, -400, -150, 400, -90)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.modulate.a = 0.0
	_root.add_child(_banner)

	# ---- 飘字提示 ----
	_toast = _make_label("", 20, COL_GOLD)
	_place(_toast, Control.PRESET_CENTER, -400, 96, 400, 130)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.modulate.a = 0.0
	_root.add_child(_toast)

	_build_upgrade_panel()
	_build_pause_panel()
	_build_dead_panel()

	_hp_bar.value = 100.0
	_hp_label.text = "生命 100 / 100"


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

	var sub := _make_label("清空一波后从 3 个词条里选 1 个，效果永久叠加", 15, COL_DIM)
	_place(sub, Control.PRESET_CENTER, -400, -118, 400, -92)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_upgrade_panel.add_child(sub)

	_upgrade_box = VBoxContainer.new()
	_place(_upgrade_box, Control.PRESET_CENTER, -330, -60, 330, 200)
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
	dim.color = Color(0.12, 0.01, 0.02, 0.75)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dead_panel.add_child(dim)

	var t := _make_label("你 阵 亡 了", 52, COL_ACCENT)
	_place(t, Control.PRESET_CENTER, -400, -150, 400, -80)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dead_panel.add_child(t)

	_dead_stats = _make_label("", 20, COL_TEXT)
	_place(_dead_stats, Control.PRESET_CENTER, -400, -60, 400, 20)
	_dead_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dead_panel.add_child(_dead_stats)

	var again := Button.new()
	again.text = "重新开始（新的一局，关卡会重新随机）"
	again.add_theme_font_size_override("font_size", 18)
	_place(again, Control.PRESET_CENTER, -220, 60, 220, 106)
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
	_on_health_changed(player.health, player.max_health)
	_on_ammo_changed(player.ammo, player.mag_size)


func set_wave_info(wave: int, enemies_left: int) -> void:
	_wave = wave
	_enemies = enemies_left


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
	tw.tween_interval(1.1)
	tw.tween_property(_toast, "modulate:a", 0.0, 0.6)


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
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().paused = true
	# 让第一个按钮拿到焦点，方便后续接手柄/键盘操作
	if _upgrade_box.get_child_count() > 0:
		(_upgrade_box.get_child(0) as Button).grab_focus()


func close_upgrade_choices() -> void:
	_upgrade_panel.visible = false
	state = State.PLAYING
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func show_game_over(stats: Dictionary) -> void:
	_dead_stats.text = "坚持到第 %d 波 · 击杀 %d 个 · 用时 %s" % [
		stats.get("wave", 0), stats.get("kills", 0), _format_time(stats.get("time", 0.0))
	]
	state = State.DEAD
	_dead_panel.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().paused = true


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
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				get_tree().paused = true
		State.PAUSED:
			if event.is_action_pressed("ui_cancel") \
					or (event is InputEventMouseButton and event.pressed):
				state = State.PLAYING
				_pause_panel.visible = false
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				get_tree().paused = false
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

	var enemies_text := ("剩余敌人 %d" % _enemies) if _enemies > 0 else "等待下一波…"
	_top_label.text = "第 %d 波    %s" % [_wave, enemies_text]
	var kill_count := 0
	if _player != null:
		kill_count = int(_player.kills)
	_stat_label.text = "击杀 %d    用时 %s" % [kill_count, _format_time(_elapsed)]


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


func _on_hit_confirmed(crit: bool) -> void:
	_hit_flash = 1.0
	_crosshair.queue_redraw()


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

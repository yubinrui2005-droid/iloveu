class_name TouchUI
extends CanvasLayer
## 手机端触屏操作：虚拟摇杆 + 右侧拖动转视角 + 右侧动作按钮。
##
## 设计取舍：
##  1. 不用 TouchScreenButton，而是自己在一层 Control 上画圆并做命中判定 ——
##     因为要支持「同时」按摇杆、转视角、按射击（三点触控），
##     交给控件树去分发反而更难控制。
##  2. 这一层的 mouse_filter 设为 IGNORE，所以它不会吃掉 HUD 上
##     「三选一强化」「重新开始」这些按钮的点击。
##  3. 首次触摸屏幕时自动启用，桌面玩家完全感知不到它的存在。
##
## 静态入口（和 Sfx 同一套路），player.gd 不需要判空。

const JOY_RADIUS := 84.0
const KNOB_RADIUS := 34.0
const BTN_HIT_PAD := 16.0
const MOUSE_TAKEOVER_DELAY_MS := 700   ## 触摸后多久才允许鼠标抢回控制权（见 _hand_back_to_mouse）

static var _inst: TouchUI = null

var active := false

var _sticky := false           ## 玩家/平台"想要"触屏操控（一旦为真就不再关掉）
var _allow := true             ## 当前局面允不允许显示（强化三选一/暂停时不显示）
var _suppress_auto := false
var _force := false            ## 手动指定（--touch / 测试）：连"鼠标抢回控制权"都不允许
var _last_touch_ms := -999999  ## 最近一次真实触摸的时刻，用来区分真鼠标和触摸补出来的鼠标事件

var _layer_root: Control
var _buttons: Array = []
var _font: Font = null

var _joy_index := -1
var _joy_origin := Vector2.ZERO
var _joy_knob := Vector2.ZERO
var _move := Vector2.ZERO

var _look_index := -1
var _look_last := Vector2.ZERO
var _look_delta := Vector2.ZERO

var _btn_owner: Dictionary = {}      ## touch index -> button id
var _pressed: Dictionary = {}        ## button id -> true

var _edge_jump := false
var _edge_reload := false
var _edge_swap := false


# ============================================================
#  静态入口
# ============================================================
static func create(parent: Node) -> TouchUI:
	if _inst != null and is_instance_valid(_inst):
		return _inst
	var t := TouchUI.new()
	t.name = "TouchUI"
	t.layer = 2
	parent.add_child(t)
	return t


static func is_active() -> bool:
	return _inst != null and is_instance_valid(_inst) and _inst.active


static func move_vector() -> Vector2:
	return _inst._move if is_active() else Vector2.ZERO


static func consume_look() -> Vector2:
	if not is_active():
		return Vector2.ZERO
	var d := _inst._look_delta
	_inst._look_delta = Vector2.ZERO
	return d


static func fire_held() -> bool:
	return is_active() and _inst._pressed.has("fire")


static func sprint_held() -> bool:
	return is_active() and _inst._move.length() > 0.9


static func consume_jump() -> bool:
	if not is_active():
		return false
	var v := _inst._edge_jump
	_inst._edge_jump = false
	return v


static func consume_reload() -> bool:
	if not is_active():
		return false
	var v := _inst._edge_reload
	_inst._edge_reload = false
	return v


static func consume_swap() -> bool:
	if not is_active():
		return false
	var v := _inst._edge_swap
	_inst._edge_swap = false
	return v


# ============================================================
#  生命周期
# ============================================================
func _ready() -> void:
	_inst = self
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 2

	_layer_root = Control.new()
	_layer_root.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_layer_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer_root.draw.connect(_on_draw)
	_layer_root.resized.connect(_layout)
	add_child(_layer_root)

	_layout()
	visible = false


func _exit_tree() -> void:
	if _inst == self:
		_inst = null


## 静态入口：只有"正常游玩中"才把控件亮出来（HUD 与关卡管理器都会调它）
static func set_allowed(v: bool) -> void:
	if _inst != null and is_instance_valid(_inst):
		_inst.allow(v)


func allow(v: bool) -> void:
	if _allow == v:
		return
	_allow = v
	_refresh()


## 主动开启触屏操控（真机检测 / 首次触摸 / 命令行参数都会走这里）
##
## manual=true 表示"这是人手动指定的"，此时不再允许鼠标把控制权抢回去。
func request_enable(manual := false) -> void:
	_sticky = true
	if manual:
		_force = true
	_refresh()


func _refresh() -> void:
	_set_active(_sticky and _allow)


func _set_active(v: bool) -> void:
	if active == v:
		return
	active = v
	visible = v
	if v:
		_release_all()
		if DisplayServer.get_name() != "headless" and DisplayServer.get_name() != "dummy":
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_layout()
	_redraw()


## 平台是否"确实"应该默认用触屏操控（真手机 / 平板）。
##
## ★ 别用 DisplayServer.is_touchscreen_available() 判断这件事，它在 Web 上的实现是
##   `"ontouchstart" in window`（导出后在 index.js 里搜
##   _godot_js_display_touchscreen_is_available 就能看到）。那是"浏览器支持触摸事件"，
##   不是"这台机器有触摸屏"—— Windows 上装过触摸屏、或某些人体学输入设备的机器都会为真。
##   误判的代价：电脑玩家一进游戏就被切进触屏模式，而 player.gd 在触屏模式下会把
##   鼠标控制权整个让出去，于是"电脑网页端鼠标完全转不动镜头"。
##   所以 Web 上只认 UA；桌面浏览器交给"第一次真实触摸"来触发（见 _input）。
static func platform_prefers_touch() -> bool:
	if OS.has_feature("mobile"):
		return true
	if OS.has_feature("web"):
		return OS.has_feature("web_android") or OS.has_feature("web_ios")
	return DisplayServer.is_touchscreen_available()


# ============================================================
#  布局
# ============================================================
func _layout() -> void:
	if _layer_root == null:
		return
	var s := _layer_root.size
	if s.x < 10.0 or s.y < 10.0:
		return
	var m := minf(s.x, s.y)
	# 小屏手机（横屏 640x360 这种）按钮要跟着缩小，否则会叠在一起
	var k := clampf(m / 720.0, 0.62, 1.0)
	var fire_r := 66.0 * k
	var small_r := 40.0 * k

	_buttons = [
		{"id": "fire", "pos": Vector2(s.x - fire_r - 26.0, s.y - fire_r - 26.0),
			"r": fire_r, "label": "射击", "big": true},
		{"id": "jump", "pos": Vector2(s.x - 268.0 * k - 20.0, s.y - 92.0 * k - 20.0),
			"r": small_r, "label": "跳跃", "big": false},
		# 换弹/换枪压在右下角，别往上爬太高：HUD 的武器栏在触屏模式下会挪到右上角
		# （见 hud.gd 的 _apply_touch_layout），按钮再高就会盖住它。
		{"id": "reload", "pos": Vector2(s.x - 96.0 * k - 20.0, s.y - 250.0 * k - 20.0),
			"r": small_r, "label": "换弹", "big": false},
		{"id": "swap", "pos": Vector2(s.x - 236.0 * k - 20.0, s.y - 228.0 * k - 20.0),
			"r": small_r, "label": "换枪", "big": false},
	]
	_redraw()


func _redraw() -> void:
	if _layer_root != null:
		_layer_root.queue_redraw()


# ============================================================
#  输入
# ============================================================
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		_last_touch_ms = Time.get_ticks_msec()
		if not _sticky and not _suppress_auto:
			request_enable()            # 第一次摸屏幕就自动亮出触屏控件
	elif event is InputEventMouseMotion and _sticky and not _force:
		_hand_back_to_mouse(event)

	if not active:
		return

	if event is InputEventScreenTouch:
		_handle_touch(event.index, event.position, event.pressed)
	elif event is InputEventScreenDrag:
		_handle_drag(event.index, event.position)


## 鼠标反过来把控制权抢回来。
##
## 为什么需要：触摸屏笔记本上手指只要碰过一次屏幕，_sticky 就把触屏模式焊死了，
## 之后鼠标再也转不动镜头（而"第一次触摸自动启用"又是必需的，否则平板用户没控件）。
## 判据要满足两条，缺一不可：
##   1. 位移够大 —— 过滤掉鼠标停在原地时的零位移噪声；
##   2. 最近 0.7 秒内没有任何触摸事件 —— 这半句是关键：引擎默认开着
##      input_devices/pointing/emulate_mouse_from_touch，手指拖动会被补出一串
##      MouseMotion，只判位移就会把玩家的手指误判成鼠标，触屏控件一动就自己关掉。
##      窗口取 0.7 秒就够：补出来的鼠标事件一定紧跟在触摸的几毫秒之后；
##      真实的"手指离开、马上换鼠标"本来也分不出，多等一下即可。
func _hand_back_to_mouse(motion: InputEventMouseMotion) -> void:
	if absf(motion.relative.x) + absf(motion.relative.y) < 6.0:
		return
	if Time.get_ticks_msec() - _last_touch_ms < MOUSE_TAKEOVER_DELAY_MS:
		return
	_sticky = false
	_refresh()


## 给自动化测试用：先关掉"自动启用"，再手动 request_enable
func suppress_auto_enable() -> void:
	_suppress_auto = true


func _handle_touch(index: int, pos: Vector2, pressed: bool) -> void:
	if pressed:
		for b in _buttons:
			if pos.distance_to(b["pos"]) <= float(b["r"]) + BTN_HIT_PAD:
				_btn_owner[index] = b["id"]
				_pressed[b["id"]] = true
				match String(b["id"]):
					"jump": _edge_jump = true
					"reload": _edge_reload = true
					"swap": _edge_swap = true
				_redraw()
				return

		if _joy_index < 0 and pos.x < _layer_root.size.x * 0.52:
			_joy_index = index
			_joy_origin = pos
			_joy_knob = pos
			_move = Vector2.ZERO
			_redraw()
			return

		if _look_index < 0:
			_look_index = index
			_look_last = pos
	else:
		var owned: String = String(_btn_owner.get(index, ""))
		if owned != "":
			_pressed.erase(owned)
			_btn_owner.erase(index)
			_redraw()
		elif index == _joy_index:
			_joy_index = -1
			_move = Vector2.ZERO
			_redraw()
		elif index == _look_index:
			_look_index = -1


func _handle_drag(index: int, pos: Vector2) -> void:
	if index == _joy_index:
		var off := pos - _joy_origin
		if off.length() > JOY_RADIUS:
			off = off.normalized() * JOY_RADIUS
		_joy_knob = _joy_origin + off
		_move = off / JOY_RADIUS
		# 摇杆本身不放大到 1.0 太灵敏，开个死区
		if _move.length() < 0.16:
			_move = Vector2.ZERO
		_redraw()
	elif index == _look_index:
		_look_delta += pos - _look_last
		_look_last = pos


func _release_all() -> void:
	_joy_index = -1
	_look_index = -1
	_joy_knob = _joy_origin
	_move = Vector2.ZERO
	_look_delta = Vector2.ZERO
	_btn_owner.clear()
	_pressed.clear()
	_redraw()


# ============================================================
#  绘制
# ============================================================
func _on_draw() -> void:
	if _font == null:
		_font = _layer_root.get_theme_default_font()
	_draw_joystick()
	_draw_buttons()


func _draw_joystick() -> void:
	if _joy_index < 0:
		return
	_layer_root.draw_circle(_joy_origin, JOY_RADIUS, Color(1, 1, 1, 0.10))
	_layer_root.draw_arc(_joy_origin, JOY_RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.34), 2.0, true)
	_layer_root.draw_circle(_joy_knob, KNOB_RADIUS, Color(1, 1, 1, 0.30))
	_layer_root.draw_arc(_joy_knob, KNOB_RADIUS, 0.0, TAU, 32, Color(1, 1, 1, 0.6), 2.0, true)


func _draw_buttons() -> void:
	for b in _buttons:
		var id := String(b["id"])
		var on: bool = _pressed.has(id)
		var r := float(b["r"])
		var pos: Vector2 = b["pos"]
		var fill := Color(0.92, 0.32, 0.34, 0.42) if on else Color(0.06, 0.07, 0.10, 0.34)
		if id == "fire":
			fill = Color(0.95, 0.32, 0.30, 0.55) if on else Color(0.45, 0.13, 0.14, 0.38)
		_layer_root.draw_circle(pos, r, fill)
		_layer_root.draw_arc(pos, r, 0.0, TAU, 40,
				Color(1, 1, 1, 0.72 if on else 0.42), 2.0, true)
		if _font != null:
			var fs := int(20.0 * clampf(r / 44.0, 0.75, 1.5))
			_layer_root.draw_string(_font, pos + Vector2(-r, 7.0), String(b["label"]),
					HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, fs, Color(1, 1, 1, 0.92))

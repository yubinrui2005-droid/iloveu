extends Node
## 自动化验证探针 —— 只在 URL 带 `?fps_debug=1`（或命令行 `-- --fps-debug`）时挂载。
##
## 为什么需要它：
##   "网页版视角转不动"这种问题，光看截图分不出是哪一条出的错 ——
##     ① 鼠标事件压根没进来
##     ② 被 TouchUI 抢走了控制权（平台判定误把电脑当手机）
##     ③ 鼠标模式不是 CAPTURED，被 player.gd 的门槛挡住
##     ④ 游戏被暂停了
##   把这几项状态周期打到控制台，配合 tools/input_probe.mjs 就能一眼看出是哪条，
##   而且能量化（yaw 到底转了多少度），不用靠"看起来好像动了"。
##
## Web 上 print() 会进浏览器控制台，CDP 的 Runtime.consoleAPICalled 直接抓得到。
## 正常玩家不带这个参数，所以不会有任何输出。
##
## 另外：探针挂着的时候会给玩家续命。原因很实在 —— 自动化测试里玩家是站着不动的，
## 三五秒就会被围殴致死，一旦死亡 can_control=0 / paused=true，视角和输入本来就不该
## 响应，测出来的"鼠标转不动"全是假阳性（这个坑真踩过）。所以续命是测量前提，
## 不是作弊：输入链路跟在场有几个敌人无关。只在带调试参数时生效，玩家感知不到。

const INTERVAL := 0.5

var _t := 0.0
var _player: Node = null
var _neck: Node3D = null


func _ready() -> void:
	# 暂停（强化三选一 / 结算）时也要能打日志，否则最该看状态的时候反而是空的
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[qa] 探针已挂载 平台建议触屏=%s 触摸能力=%s mobile=%s" % [
		str(TouchUI.platform_prefers_touch()),
		str(DisplayServer.is_touchscreen_available()),
		str(OS.has_feature("mobile"))])


func _process(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = INTERVAL
	if _player == null or not is_instance_valid(_player):
		_player = get_parent().get("player")
		if _player == null:
			return
		_neck = _player.get_node_or_null("Neck") as Node3D
	if _neck == null:
		return
	var p: Vector3 = _player.global_position
	# 续命（见文件头说明）。用 set/get 而不是直接点属性，避免静态类型检查报错。
	if not get_tree().paused:
		_player.set("health", _player.get("max_health"))
	print("[qa] yaw=%.1f pitch=%.1f touch=%d mouse_mode=%d paused=%s ctl=%d pos=%.1f,%.1f" % [
		rad_to_deg(_player.rotation.y),
		rad_to_deg(_neck.rotation.x),
		int(TouchUI.is_active()),
		int(Input.get_mouse_mode()),
		str(get_tree().paused),
		int(_player.get("can_control")),
		p.x, p.z])

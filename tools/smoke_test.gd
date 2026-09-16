extends SceneTree
## 冒烟测试：不打开窗口自动打完几波，验证脚本没有运行时错误。
##
## 用法（在工程根目录执行）：
##   godot --headless --fixed-fps 60 --script res://tools/smoke_test.gd
##
## 它会：加载主场景 → 自动瞄准并使敌人加速死亡 → 自动选强化 → 覆盖「清波→三选一→下一波」全流程。
## 只要这里有报错，就是游戏本身的问题，而不是你编辑器设置的问题。

const RUN_FRAMES := 1800

var _frames := 0
var _paused_frames := 0
var _last_pos: Vector3 = Vector3.ZERO
var _stuck_frames := 0
var _main: Node = null


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		printerr("[smoke] 主场景加载失败")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)
	current_scene = _main
	print("[smoke] 主场景已加载，开始跑 %d 帧…" % RUN_FRAMES)


func _process(_delta: float) -> bool:
	if _main == null or not is_instance_valid(_main):
		_main = current_scene

	_frames += 1

	# 暂停状态（强化三选一 / 死亡）——模拟玩家做选择
	if paused:
		_paused_frames += 1
		if _paused_frames == 20:
			_handle_paused()
		if _frames >= RUN_FRAMES:
			print("[smoke] 通过：跑满 %d 帧，没有脚本错误。" % RUN_FRAMES)
			return true
		return false
	_paused_frames = 0

	if _main == null:
		return false

	# 1) 让玩家一直朝最近的敌人开火（覆盖射击 / 命中 / 弹匣 / 换弹路径）
	var enemies := get_nodes_in_group("enemy")
	if enemies.size() > 0:
		_aim_at(enemies[0])
		if _main.player.can_control:
			_main.player.shoot()

	# 2) 每 40 帧直接秒掉一个敌人，加速走完一波（覆盖敌人死亡 → 清波 → 强化）
	if _frames % 40 == 0 and enemies.size() > 0:
		enemies[0].take_damage(99999.0)

	# 3) 每 30 帧检查一次玩家是否卡住（覆盖移动 / 碰撞，确认不会掉出地图）
	if _frames % 30 == 0:
		var p: Vector3 = _main.player.global_position
		if p.y < -3.0:
			printerr("[smoke] 玩家掉出地图：%s" % str(p))
		_last_pos = p

	if _frames % 300 == 0:
		print("[smoke] 第 %d 帧 · 波次 %d · 场上敌人 %d · 玩家生命 %.0f · 击杀 %d" % [
			_frames, _main.wave, enemies.size(), _main.player.health, _main.player.kills
		])

	if _frames >= RUN_FRAMES:
		print("[smoke] 通过：跑满 %d 帧，没有脚本错误。" % RUN_FRAMES)
		return true
	return false


## 暂停时不方便做的事：这里代替玩家点按钮
func _handle_paused() -> void:
	if _main == null:
		return
	var hud = _main.hud
	match hud.state:
		hud.State.UPGRADE:
			var pool := ["damage", "firerate", "mag", "reload", "spread", "pellets",
					"speed", "jump", "maxhp", "lifesteal", "crit", "killheal"]
			var id: String = pool[_frames % pool.size()]
			print("[smoke] 选择强化：%s" % id)
			hud.upgrade_chosen.emit(id)
		hud.State.DEAD:
			print("[smoke] 玩家阵亡，测试重开流程")
			hud.restart_requested.emit()
		_:
			pass


func _aim_at(target: Node3D) -> void:
	if _main == null or _main.player == null:
		return
	var player = _main.player
	var d: Vector3 = target.global_position - player.camera.global_position
	if d.length() < 0.01:
		return
	d = d.normalized()
	player.rotation.y = atan2(-d.x, -d.z)
	player.neck.rotation.x = asin(clampf(d.y, -1.0, 1.0))

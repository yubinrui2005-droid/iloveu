extends SceneTree
## 冒烟测试：不打开窗口自动打通好几间房，验证脚本没有运行时错误。
##
## 用法（在工程根目录执行）：
##   godot --headless --path . --fixed-fps 60 --script res://tools/smoke_test.gd
##   godot --headless --path . --fixed-fps 60 --script res://tools/smoke_test.gd -- --fast
##
## 它会自动完成一整套循环，覆盖到每一条主要代码路径：
##   瞄准射击 → 敌人死亡 → 清空一间房 → 三选一强化 → 门打开 → 走进门 → 换房
##   每 5 波刷 Boss（含弹幕、血条、死亡爆炸）→ 玩家死亡 → 写排行榜 → 重开
## 并且会单独校验导航网格是不是真的算得出路径（不只是"没报错"）。

const RUN_FRAMES := 3600

var _frames := 0
var _paused_frames := 0
var _rooms_seen := 0
var _nav_probed := {}
var _nav_failures := 0
var _main: Node = null

var _kill_every := 40          ## 每多少帧秒掉一个小怪
var _walk_step := 0.35         ## 每帧朝门口移动的距离
var _run_frames := RUN_FRAMES  ## 可被 --frames=N 覆盖（录画面/录音频时用得上）
var _shots_fired := 0
var _last_shot := -999
var _problems := 0
var _min_rooms := 2

var _last_progress_key := Vector2i.ZERO   ## (房间号, 击杀数)，用来判断有没有在推进
var _last_progress_frame := 0
var _stall_reported := false
var _max_rooms := 0                       ## 本次测试里走到过的最深房间
var _restarts := 0                        ## 玩家阵亡后重开的次数

var _boss_seen := false
var _boss_ever := false
var _boss_reported := false
var _boss_frame := 0
var _max_projectiles := 0


func _initialize() -> void:
	# 用独立存档，别把测试成绩写进玩家真实的排行榜
	SaveData.set_profile("user://smoke_test_save.json")
	SaveData.clear()

	for a in OS.get_cmdline_user_args():
		if a == "--fast":
			_kill_every = 5
			_walk_step = 1.0
			# --fast 下正常能走到第 13 间房（约等于第 13 波），所以敢把及格线抬到 6
			# ——第 5 波会刷首领，走到第 6 间才说明首领那条路径真的被覆盖到了。
			_min_rooms = 6
		elif a.begins_with("--frames="):
			# 配合 --write-movie 用：录 15 秒画面/音频只需要 900 帧，
			# 不必等满 3600 帧（movie writer 比实时慢 5 倍）。
			_run_frames = maxi(int(a.split("=")[1]), 60)

	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		printerr("[smoke] 主场景加载失败")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)
	current_scene = _main
	print("[smoke] 主场景已加载，开始跑 %d 帧…" % _run_frames)


func _process(_delta: float) -> bool:
	if _main == null or not is_instance_valid(_main):
		_main = current_scene

	_frames += 1

	if paused:
		_paused_frames += 1
		# 每 20 帧重试一次，而不是只在第 20 帧试一次：
		# 万一那一次按钮没生效（比如强化面板刚弹出来、节点还没就绪），
		# 只试一次就会永远卡在暂停里，而测试最后还是会报"通过"。
		if _paused_frames % 20 == 0:
			_handle_paused()
		if _paused_frames % 300 == 0:
			# 一直退不出暂停 —— 说明 _handle_paused 没能把局面推回去
			_problem("暂停卡住 %d 帧没恢复（HUD状态=%s）" % [
				_paused_frames, str(_main.hud.state) if _main != null else "?"
			])
		if _frames >= _run_frames:
			_finish()
			return true
		return false
	_paused_frames = 0

	if _main == null:
		return false

	_probe_navigation()
	_track_boss()
	_watch_progress()

	# 1) 让玩家一直朝敌人开火（覆盖射击 / 命中 / 弹匣 / 换弹 / 切枪路径）。
	#    有首领时优先瞄首领，这样血条会真的往下掉。
	#    注意要按武器射速节流：shoot() 自己不检查射速（射速是在 _physics_process
	#    里按 _fire_timer 判的），每帧都调就成了 60 发/秒，比真实步枪快 8 倍，
	#    录出来的音频也是假的密集——那样测混音余量会偏悲观。
	var enemies := get_nodes_in_group("enemy")
	var aim = null
	for e in enemies:
		if e.is_boss():
			aim = e
			break
	if aim == null and enemies.size() > 0:
		aim = enemies[0]
	if aim != null:
		_aim_at(aim)
		if _main.player.can_control and _frames - _last_shot >= _shot_gap():
			_main.player.shoot()
			_shots_fired += 1
			_last_shot = _frames

	# 每 120 帧换一把枪，确保四把枪的射击代码都被真的执行过。
	# 别换太勤：换枪后 0.3 秒开不了火，空枪还会自动装弹，
	# 换太快会让这个"假玩家"几乎没有输出，整局推进不下去。
	if _frames % 120 == 0 and _main.player.can_control:
		_main.player.cycle_weapon(1)

	# 2) 每隔几帧秒掉一个小怪，加速走完一波。
	#    首领给 300 帧（5 秒）宽限期，让它真的把弹幕打出来再被带走。
	if _frames % _kill_every == 0:
		for e in enemies:
			if e.is_boss() and (_frames - _boss_frame) < 300:
				continue
			e.take_damage(99999.0)
			break

	# 3) 门开了就往门口走（覆盖换房 + 淡黑过渡 + 新房间重建）
	if _main._door_open and not _main._transition and _main.player.can_control:
		_walk_to(_main._door_pos, _walk_step)

	# 4) 每 30 帧检查玩家有没有掉出地图
	if _frames % 30 == 0:
		var p: Vector3 = _main.player.global_position
		if p.y < -3.0:
			printerr("[smoke] 玩家掉出地图：%s" % str(p))

	if _frames % 400 == 0:
		var live := get_nodes_in_group("enemy")
		var dnf := 0
		for e in live:
			if e.is_dead:
				dnf += 1
		print("[smoke] 第 %d 帧 · 波次 %d · 房间 %d · 场上敌人 %d（已死未回收 %d）· alive=%d · 生命 %.0f · 击杀 %d" % [
			_frames, _main.wave, _main.room_index, live.size(), dnf,
			_main.enemies_alive, _main.player.health, _main.player.kills
		])

	if _frames >= _run_frames:
		_finish()
		return true
	return false


## 当前这把枪两发之间要隔多少帧（60fps 下）。射速是 upgrade 乘过的有效值。
func _shot_gap() -> int:
	var rate: float = maxf(_main.player.fire_rate, 0.1)
	return maxi(int(60.0 / rate), 1)


func _finish() -> void:
	_max_rooms = maxi(_max_rooms, _main.room_index)
	print("[smoke] 走过房间数：最深到第 %d 间（当前这一局在第 %d 间）" % [
		_max_rooms, _main.room_index
	])
	print("[smoke] 共开火 %d 次 · 击杀 %d · 最终波次 %d · 阵亡重开 %d 次" % [
		_shots_fired, _main.player.kills, _main.wave, _restarts
	])
	# 注意比的是「走到过的最深房间」，不是结束时所在的房间：
	# 玩家阵亡后测试会主动重开一局（这条路径本身也要覆盖），
	# 重开会把 room_index 归零，拿结束时的值去比会误报失败。
	if _max_rooms < _min_rooms:
		_problem("最深只走到第 %d 间房（及格线 %d）—— 房间流没跑起来或者中途卡住了" % [
			_max_rooms, _min_rooms
		])
	if _shots_fired < 20:
		_problem("只开了 %d 枪 —— 射击路径覆盖不足" % _shots_fired)
	if _nav_failures > 0:
		_problem("有 %d 次导航路径为空（敌人会退化到直线追击）" % _nav_failures)
	else:
		print("[smoke] 导航路径全部有效")
	if not _boss_ever:
		_problem("一局里都没刷出首领 —— 检查每 5 波刷 Boss 的逻辑")

	print("[smoke] 跑满 %d 帧，没有脚本错误。" % _frames)
	if _problems > 0:
		printerr("[smoke] ★ 有 %d 项不通过，测试失败" % _problems)
	# 必须显式给退出码：这个脚本是 MainLoop，光 return true 只会以 0 退出，
	# 那样 CI 里上面这些 printerr 就形同虚设了。
	quit(1 if _problems > 0 else 0)


## 记一项不通过。既打到 stderr（人看得见），也计入退出码（CI 看得见）。
func _problem(msg: String) -> void:
	_problems += 1
	printerr("[smoke] ✗ %s" % msg)


## 卡死看门狗。
##
## 为什么需要：这个测试靠"每几帧秒一只怪"推进，正常情况下几百帧就换一间房。
## 但偶尔会真的卡住——实测出现过跑满 3600 帧只走到第 2 间房、打印却依然像"通过"
## 的情况。那种静默假通过比直接失败还糟：你会以为逻辑是好的。
## 所以这里盯住「房间号 + 击杀数」，长时间不动就打印现场状态并记一次失败。
func _watch_progress() -> void:
	if _main == null or _main.player == null:
		return
	_max_rooms = maxi(_max_rooms, _main.room_index)
	var key := Vector2i(_main.room_index + _main.wave * 100, _main.player.kills)
	if key != _last_progress_key:
		_last_progress_key = key
		_last_progress_frame = _frames
		return
	# 阈值要给足：--fast 下首领会先免疫 300 帧（见上面秒怪的宽限期），
	# 那段时间里如果场上只剩首领，击杀数是不动的。
	if _stall_reported or _frames - _last_progress_frame < 600:
		return
	_stall_reported = true
	var stalled := get_nodes_in_group("enemy")
	var dead_not_freed := 0
	for e in stalled:
		if e.is_dead:
			dead_not_freed += 1
	_problem("卡住了：连续 %d 帧没推进（房间 %d · 波次 %d · 击杀 %d）" % [
		_frames - _last_progress_frame, _main.room_index, _main.wave, _main.player.kills
	])
	print("[smoke] 现场排查：暂停=%s · HUD状态=%s · enemies_alive=%d · 组内敌人=%d（其中已死未回收 %d）· 门开=%s · 血量=%.0f" % [
		paused, str(_main.hud.state), _main.enemies_alive,
		stalled.size(), dead_not_freed, _main._door_open, _main.player.health
	])


## 暂停时不方便做的事：这里代替玩家点按钮
func _handle_paused() -> void:
	if _main == null:
		return
	var hud = _main.hud
	match hud.state:
		hud.State.UPGRADE:
			var entry: Dictionary = Upgrades.DATA[_frames % Upgrades.DATA.size()]
			var id: String = entry["id"]
			print("[smoke] 选择强化：%s" % id)
			hud.upgrade_chosen.emit(id)
		hud.State.DEAD:
			print("[smoke] 玩家阵亡，测试重开流程")
			_restarts += 1
			_boss_seen = false
			_boss_reported = false
			_boss_frame = 0
			hud.restart_requested.emit()
		_:
			pass


# ============================================================
#  首领跟踪
# ============================================================
func _track_boss() -> void:
	if _main._boss != null:
		_max_projectiles = maxi(_max_projectiles, get_nodes_in_group("projectile").size())
		if not _boss_seen:
			_boss_seen = true
			_boss_ever = true
			_boss_frame = _frames
			print("[smoke] 第 %d 波刷出首领：血量 %.0f，屏幕顶部应该出现血条" % [
				_main.wave, _main._boss.max_health
			])
	elif _boss_seen and not _boss_reported:
		_boss_reported = true
		print("[smoke] 首领已被击杀（弹幕峰值 %d 发），血条应当已隐藏" % _max_projectiles)


# ============================================================
#  导航校验：确认 NavMesh 真的算出一条通路，而不只是"没报错"
# ============================================================
func _probe_navigation() -> void:
	if _main == null or _main.room_index <= 0:
		return
	var room: int = _main.room_index
	var tries: int = int(_nav_probed.get(room, 0))
	if tries >= 8:
		return
	# 导航服务器要过一个物理帧才会把 region 同步进地图，所以隔一段再试
	if _frames % 45 != 0:
		return
	_nav_probed[room] = tries + 1

	var region = _main._nav_region
	if region == null:
		printerr("[smoke] 第 %d 间房没有生成 NavigationRegion3D" % room)
		return
	var nm: NavigationMesh = region.navigation_mesh
	if nm == null or nm.get_polygon_count() == 0:
		printerr("[smoke] 第 %d 间房的 NavigationMesh 是空的" % room)
		return

	var map: RID = _main.get_world_3d().navigation_map
	var from: Vector3 = _main._spawn_pos + Vector3.UP * 0.6
	var to: Vector3 = _main._door_pos + Vector3.UP * 0.6
	var path: PackedVector3Array = NavigationServer3D.map_get_path(map, from, to, true)

	if path.size() >= 2:
		print("[smoke] 房间 %d 导航 OK：navmesh 顶点 %d / 多边形 %d，出生点→门 路径 %d 个点" % [
			room, nm.vertices.size(), nm.get_polygon_count(), path.size()
		])
		_nav_probed[room] = 999          # 通过，不再重试
		return

	if tries + 1 >= 8:
		_nav_failures += 1
		printerr("[smoke] 房间 %d 导航失败：地图里 %d 个 region，路径为空" % [
			room, NavigationServer3D.map_get_regions(map).size()
		])


# ============================================================
#  工具
# ============================================================
func _walk_to(target: Vector3, step: float) -> void:
	var cur: Vector3 = _main.player.global_position
	var to := Vector3(target.x - cur.x, 0.0, target.z - cur.z)
	if to.length() < 0.001:
		return
	var s := to.normalized() * step
	_main.player.global_position = Vector3(cur.x + s.x, cur.y, cur.z + s.z)


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

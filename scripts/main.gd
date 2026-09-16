extends Node3D
## 关卡管理器（工程的主场景脚本）
##
## 一局的流程：
##   生成一间房 → 刷第 N 波敌人（每 5 波是 Boss 波）→ 全部清空 → 三选一强化
##   → 出口的门打开 → 走进门 → 淡黑 → 下一间房（重新随机）→ …
##
## 「房间流」是这个原型的核心循环：不是一张打不完的竞技场，
## 而是"清完一间、开门、进下一间"，这也是《枪火重生》《Risk of Rain》的体感来源。
##
## 导航说明：房间的 NavMesh 不是"烘焙"出来的，而是按障碍物占位直接
## 手工拼出一格格四边形（见 _build_navmesh）。理由：
##   1. 运行时 bake_navigation_mesh() 是同步阻塞的，每换一间房都会卡一下；
##   2. 我们的障碍物本来就是轴对齐方块，用格子拼完全够用，而且结果可预期。

const ROOM_HALF := 19.0         ## 房间半径（边长 = 2 * ROOM_HALF）
const WALL_H := 5.0
const WALL_T := 0.9             ## 墙厚
const CELL := 5.4               ## 障碍物网格间距
const DOOR_W := 4.6             ## 门洞宽度
const DOOR_H := 3.4             ## 门洞高度
const OBSTACLE_MARGIN := 4.0    ## 障碍物离墙最小距离

const NAV_CELL := 2.0           ## 导航网格格子大小
const NAV_CLEARANCE := 0.75     ## 障碍物外扩量（等价于导航代理的半径）

const COL_FLOOR := Color(0.16, 0.17, 0.20)
const COL_WALL := Color(0.24, 0.25, 0.30)
const COL_COVER := Color(0.27, 0.26, 0.24)
const COL_PILLAR := Color(0.21, 0.23, 0.28)
const COL_DOOR_LOCKED := Color(0.34, 0.17, 0.18)
const COL_DOOR_OPEN := Color(0.20, 0.62, 0.46)

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const ENEMY_SCENE := preload("res://scenes/enemy.tscn")
const HUD_SCENE := preload("res://scenes/hud.tscn")

var player: Node = null
var hud: CanvasLayer = null
var touch: TouchUI = null

var wave := 0
var room_index := 0
var rooms_cleared := 0
var enemies_alive := 0
var wave_running := false

var _room: Node3D = null
var _nav_region: NavigationRegion3D = null
var _door_body: StaticBody3D = null
var _door_marker: MeshInstance3D = null
var _door_open := false
var _door_pos := Vector3.ZERO
var _exit_axis := 0            ## 0 = 北(-Z)，1 = 东(+X)，2 = 西(-X)
var _spawn_pos := Vector3.ZERO
var _boss: Enemy = null
var _transition := false

var _obstacle_pos: Array[Vector3] = []
var _obstacle_radius: Array[float] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	Sfx.create(self)
	_setup_environment()
	_spawn_player()
	_spawn_hud()
	touch = TouchUI.create(self)
	if _touch_expected():
		touch.request_enable()
	_enter_room(1)


func _touch_expected() -> bool:
	if DisplayServer.is_touchscreen_available() or OS.has_feature("mobile"):
		return true
	# 桌面端想手动验证触屏 UI：godot --path . -- --touch
	for a in OS.get_cmdline_user_args():
		if a == "--touch":
			return true
	return false


# ============================================================
#  场景搭建
# ============================================================
func _setup_environment() -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.04, 0.05, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.72)
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.10, 0.11, 0.15)
	env.fog_density = 0.016
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.light_energy = 0.85
	sun.shadow_enabled = true
	add_child(sun)


func _spawn_player() -> void:
	player = PLAYER_SCENE.instantiate()
	add_child(player)
	player.position = Vector3(0.0, 0.4, ROOM_HALF - 3.5)
	player.died.connect(_on_player_died)


func _spawn_hud() -> void:
	hud = HUD_SCENE.instantiate()
	add_child(hud)
	hud.bind(player)
	hud.upgrade_chosen.connect(_on_upgrade_chosen)
	hud.restart_requested.connect(_on_restart_requested)


func _process(_delta: float) -> void:
	# 只在"正常游玩"状态显示触屏控件：强化三选一 / 暂停 / 结算时让位给 HUD 的按钮
	if hud != null:
		TouchUI.set_allowed(hud.is_playing())


func _physics_process(_delta: float) -> void:
	if player == null:
		return
	if player.global_position.y < -10.0:
		player.global_position = _spawn_pos      # 兜底：万一掉出地图
	if not _door_open or _transition or not player.can_control:
		return
	var d := Vector2(player.global_position.x - _door_pos.x,
			player.global_position.z - _door_pos.z).length()
	if d < 2.4:
		_next_room()


# ============================================================
#  房间
# ============================================================
func _enter_room(index: int) -> void:
	room_index = index
	_build_room()
	player.reset_view()
	player.global_position = _spawn_pos
	player.velocity = Vector3.ZERO
	_start_next_wave()


func _build_room() -> void:
	if _room != null and is_instance_valid(_room):
		_room.queue_free()
	_obstacle_pos.clear()
	_obstacle_radius.clear()
	_door_body = null
	_door_marker = null
	_door_open = false

	_room = Node3D.new()
	_room.name = "Room"
	add_child(_room)

	_spawn_pos = Vector3(0.0, 0.4, ROOM_HALF - 3.5)
	_exit_axis = _rng.randi_range(0, 2)
	_door_pos = _door_center()

	_build_shell()
	_build_obstacles()
	_build_lights()
	_build_navmesh()


func _door_center() -> Vector3:
	match _exit_axis:
		0: return Vector3(0.0, 0.0, -ROOM_HALF)
		1: return Vector3(ROOM_HALF, 0.0, 0.0)
		_: return Vector3(-ROOM_HALF, 0.0, 0.0)


func _build_shell() -> void:
	_add_box(Vector3(0, -0.5, 0),
			Vector3(ROOM_HALF * 2.0, 1.0, ROOM_HALF * 2.0), COL_FLOOR)
	# 南墙（z = +R）永远实心：玩家从这边进场
	_add_wall(true, ROOM_HALF, false)
	_add_wall(true, -ROOM_HALF, _exit_axis == 0)
	_add_wall(false, -ROOM_HALF, _exit_axis == 2)
	_add_wall(false, ROOM_HALF, _exit_axis == 1)

	# 门：一块可以"沉入地面"的实心板
	var horizontal := _exit_axis == 0
	var size := Vector3(DOOR_W, DOOR_H, WALL_T) if horizontal else Vector3(WALL_T, DOOR_H, DOOR_W)
	_door_body = _add_box(Vector3(_door_pos.x, DOOR_H * 0.5, _door_pos.z),
			size, COL_DOOR_LOCKED)


## horizontal = true 表示这面墙沿 X 方向延伸（位于 z = plane）
func _add_wall(horizontal: bool, plane: float, gap: bool) -> void:
	var half := ROOM_HALF
	if not gap:
		if horizontal:
			_add_box(Vector3(0.0, WALL_H * 0.5, plane),
					Vector3(half * 2.0, WALL_H, WALL_T), COL_WALL)
		else:
			_add_box(Vector3(plane, WALL_H * 0.5, 0.0),
					Vector3(WALL_T, WALL_H, half * 2.0), COL_WALL)
		return

	# 带门洞：左右两段 + 门楣
	var seg := (half * 2.0 - DOOR_W) * 0.5
	var off := DOOR_W * 0.5 + seg * 0.5
	var lintel_h := WALL_H - DOOR_H
	if horizontal:
		_add_box(Vector3(-off, WALL_H * 0.5, plane), Vector3(seg, WALL_H, WALL_T), COL_WALL)
		_add_box(Vector3(off, WALL_H * 0.5, plane), Vector3(seg, WALL_H, WALL_T), COL_WALL)
		_add_box(Vector3(0.0, DOOR_H + lintel_h * 0.5, plane),
				Vector3(DOOR_W, lintel_h, WALL_T), COL_WALL)
	else:
		_add_box(Vector3(plane, WALL_H * 0.5, -off), Vector3(WALL_T, WALL_H, seg), COL_WALL)
		_add_box(Vector3(plane, WALL_H * 0.5, off), Vector3(WALL_T, WALL_H, seg), COL_WALL)
		_add_box(Vector3(plane, DOOR_H + lintel_h * 0.5, 0.0),
				Vector3(WALL_T, lintel_h, DOOR_W), COL_WALL)


func _build_obstacles() -> void:
	var limit := ROOM_HALF - OBSTACLE_MARGIN
	var count := int(limit / CELL)
	for gx in range(-count, count + 1):
		for gz in range(-count, count + 1):
			var cx := float(gx) * CELL
			var cz := float(gz) * CELL
			if _too_close_to_lane(cx, cz):
				continue
			var roll := _rng.randf()
			if roll < 0.38:
				var sx := _rng.randf_range(2.0, 3.6)
				var sz := _rng.randf_range(2.0, 3.6)
				var h := _rng.randf_range(3.0, 5.0)
				var p := Vector3(cx + _rng.randf_range(-1.1, 1.1), h * 0.5,
						cz + _rng.randf_range(-1.1, 1.1))
				_add_box(p, Vector3(sx, h, sz), COL_PILLAR)
				_register_obstacle(p, maxf(sx, sz) * 0.5)
			elif roll < 0.66:
				var sx2 := _rng.randf_range(2.4, 4.0)
				var sz2 := _rng.randf_range(2.4, 4.0)
				var h2 := _rng.randf_range(0.9, 1.3)
				var p2 := Vector3(cx + _rng.randf_range(-0.9, 0.9), h2 * 0.5,
						cz + _rng.randf_range(-0.9, 0.9))
				_add_box(p2, Vector3(sx2, h2, sz2), COL_COVER)
				_register_obstacle(p2, maxf(sx2, sz2) * 0.5)


## 保证「出生点 → 房间中心 → 出口门」这条主线畅通，否则玩家一进场就被柱子堵死
func _too_close_to_lane(cx: float, cz: float) -> bool:
	var p := Vector2(cx, cz)
	if p.distance_to(Vector2(_spawn_pos.x, _spawn_pos.z)) < 5.0:
		return true
	if p.distance_to(Vector2.ZERO) < 3.6:
		return true
	var door := Vector2(_door_pos.x, _door_pos.z)
	if p.distance_to(door) < 4.6:
		return true
	# 点到线段距离：出生点 → 门
	var a := Vector2(_spawn_pos.x, _spawn_pos.z)
	var ab := door - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.001), 0.0, 1.0)
	return p.distance_to(a + ab * t) < 3.4


func _build_lights() -> void:
	for i in 6:
		var light := OmniLight3D.new()
		light.light_energy = 3.4
		light.omni_range = 17.0
		light.light_color = Color(1.0, 0.86, 0.66) if i % 2 == 0 else Color(0.62, 0.74, 1.0)
		light.shadow_enabled = false
		_room.add_child(light)
		light.position = Vector3(
			_rng.randf_range(-ROOM_HALF + 4.0, ROOM_HALF - 4.0), 3.6,
			_rng.randf_range(-ROOM_HALF + 4.0, ROOM_HALF - 4.0))


func _add_box(center: Vector3, size: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = center

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	mesh.material_override = mat
	body.add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	_room.add_child(body)
	return body


func _register_obstacle(center: Vector3, radius: float) -> void:
	_obstacle_pos.append(center)
	_obstacle_radius.append(radius)


# ============================================================
#  导航网格（手工拼格子，不烘焙）
# ============================================================
func _build_navmesh() -> void:
	# 起点对齐到 0.25 的整数倍，避免顶点被导航服务器吸附后错位
	var nav_min := ceil((-ROOM_HALF + WALL_T * 0.5 + 0.35) / 0.25) * 0.25
	var nav_max := floor((ROOM_HALF - WALL_T * 0.5 - 0.35) / 0.25) * 0.25
	var n := int(floor((nav_max - nav_min) / NAV_CELL))
	if n < 2:
		return

	var free := PackedByteArray()
	free.resize(n * n)
	for j in n:
		for i in n:
			var cx := nav_min + (float(i) + 0.5) * NAV_CELL
			var cz := nav_min + (float(j) + 0.5) * NAV_CELL
			free[j * n + i] = 0 if _blocked_for_nav(cx, cz) else 1

	var verts := PackedVector3Array()
	var index_of := {}
	var polys: Array[PackedInt32Array] = []
	var y := 0.12
	for j in n:
		for i in n:
			if free[j * n + i] == 0:
				continue
			# 角点顺序 0(i,j) → 3(i,j+1) → 2(i+1,j+1) → 1(i+1,j)，保证法线朝 +Y
			var order := [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, 0)]
			var poly := PackedInt32Array()
			for o in order:
				var key := Vector2i(i + o.x, j + o.y)
				var vi: int = index_of.get(key, -1)
				if vi < 0:
					vi = verts.size()
					verts.append(Vector3(nav_min + float(key.x) * NAV_CELL, y,
							nav_min + float(key.y) * NAV_CELL))
					index_of[key] = vi
				poly.append(vi)
			polys.append(poly)

	if polys.is_empty():
		return

	var nav_mesh := NavigationMesh.new()
	nav_mesh.vertices = verts
	for p in polys:
		nav_mesh.add_polygon(p)

	_nav_region = NavigationRegion3D.new()
	_nav_region.navigation_mesh = nav_mesh
	_room.add_child(_nav_region)


func _blocked_for_nav(cx: float, cz: float) -> bool:
	for i in _obstacle_pos.size():
		var d := Vector2(cx - _obstacle_pos[i].x, cz - _obstacle_pos[i].z).length()
		if d < _obstacle_radius[i] + NAV_CLEARANCE:
			return true
	return false


# ============================================================
#  波次
# ============================================================
func _start_next_wave() -> void:
	wave += 1
	wave_running = true
	enemies_alive = 0
	_boss = null

	for w in player.update_unlocks(wave):
		hud.show_toast("解锁新武器：%s   ← 按 %d 切换" % [w.display_name, _weapon_slot(w)])
		Sfx.play("level_up", -7.0)

	var boss_wave := wave % 5 == 0
	var count := mini(2 + int(round(float(wave) * 1.5)), 20)
	if boss_wave:
		count = maxi(int(round(float(count) * 0.55)), 2)
		_spawn_boss()
	for i in count:
		_spawn_enemy()

	hud.set_wave_info(wave, enemies_alive, room_index)
	hud.show_banner(("第 %d 波  ·  首领来袭" % wave) if boss_wave else ("第 %d 波" % wave))
	if boss_wave:
		Sfx.play("boss_spawn", -6.0)


func _weapon_slot(w: WeaponData) -> int:
	return player.weapons.find(w) + 1


func _spawn_enemy() -> void:
	var enemy = ENEMY_SCENE.instantiate()
	add_child(enemy)
	enemy.add_to_group("enemy")
	enemy.position = _find_spawn_point()
	enemy.target = player
	enemy.died.connect(_on_enemy_died)
	enemies_alive += 1
	enemy.setup(_pick_kind(), wave)


func _spawn_boss() -> void:
	var boss = ENEMY_SCENE.instantiate()
	add_child(boss)
	boss.add_to_group("enemy")
	boss.position = _find_spawn_point(16.0)
	boss.target = player
	boss.died.connect(_on_enemy_died)
	boss.health_changed.connect(_on_boss_health)
	boss.setup(Enemy.Kind.BOSS, wave)
	_boss = boss
	enemies_alive += 1
	hud.show_boss("第 %d 只首领" % (wave / 5), boss.health, boss.max_health)


func _pick_kind() -> int:
	var r := _rng.randf()
	if wave >= 5 and r < 0.18:
		return Enemy.Kind.TANK
	elif wave >= 3 and r < 0.45:
		return Enemy.Kind.RUNNER
	return Enemy.Kind.GRUNT


func _find_spawn_point(min_dist := 12.0) -> Vector3:
	var limit := ROOM_HALF - 3.0
	for attempt in 60:
		var p := Vector3(_rng.randf_range(-limit, limit), 0.6, _rng.randf_range(-limit, limit))
		if player != null and Vector2(p.x - player.global_position.x,
				p.z - player.global_position.z).length() < min_dist:
			continue
		if Vector2(p.x - _door_pos.x, p.z - _door_pos.z).length() < 3.6:
			continue
		var blocked := false
		for i in _obstacle_pos.size():
			var flat := Vector2(p.x - _obstacle_pos[i].x, p.z - _obstacle_pos[i].z)
			if flat.length() < _obstacle_radius[i] + 1.6:
				blocked = true
				break
		if not blocked:
			return p
	# 兜底：在出生点附近随便找个位置
	return Vector3(_spawn_pos.x + _rng.randf_range(-2.5, 2.5), 0.6,
			_spawn_pos.z + _rng.randf_range(-2.5, 2.5))


func _on_enemy_died(enemy) -> void:
	enemies_alive = maxi(enemies_alive - 1, 0)
	player.add_kill()
	if enemy == _boss:
		_boss = null
		hud.hide_boss()
	hud.set_wave_info(wave, enemies_alive, room_index)
	if enemies_alive <= 0 and wave_running:
		wave_running = false
		_finish_wave()


func _on_boss_health(hp: float, max_hp: float) -> void:
	hud.update_boss(hp, max_hp)


func _finish_wave() -> void:
	rooms_cleared += 1
	Sfx.play("room_clear", -5.0)
	await get_tree().create_timer(0.7).timeout
	if not is_inside_tree():
		return
	_offer_upgrades()


func _offer_upgrades() -> void:
	var choices := Upgrades.roll(3, player.upgrade_counts)
	if choices.is_empty():
		# 词条全部叠满了，直接放行
		player.heal(20.0)
		_open_door()
		return
	hud.show_upgrade_choices(choices)


func _on_upgrade_chosen(id: String) -> void:
	var title := Upgrades.apply(player, id)
	hud.close_upgrade_choices()
	hud.show_toast("获得强化：%s   —— 出口的门开了" % title)
	Sfx.play("pickup", -6.0)
	player.heal(12.0)
	_open_door()


# ============================================================
#  开门 / 换房
# ============================================================
func _open_door() -> void:
	if _door_open or _door_body == null:
		return
	_door_open = true
	_door_body.collision_layer = 0            # 立刻可通行，视觉上让它沉下去
	var mesh := _door_body.get_node_or_null("Mesh") as MeshInstance3D
	if mesh != null:
		var mat := mesh.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = COL_DOOR_OPEN
	var tw := create_tween()
	tw.tween_property(_door_body, "position:y", -DOOR_H * 0.55, 0.9) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	Sfx.play_at("door_open", _door_pos)

	# 门框上加一层发光标记，告诉玩家"从这里走"
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(DOOR_W * 0.95, DOOR_H * 0.92, 0.16) \
			if _exit_axis == 0 else Vector3(0.16, DOOR_H * 0.92, DOOR_W * 0.95)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.35, 1.5, 1.0, 0.16)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_room.add_child(mi)
	mi.position = Vector3(_door_pos.x, DOOR_H * 0.5, _door_pos.z)
	_door_marker = mi


func _next_room() -> void:
	_transition = true
	hud.fade_out(0.30)
	Sfx.play("door_open", -6.0, 0.8)
	await get_tree().create_timer(0.34).timeout
	if not is_inside_tree():
		return
	_enter_room(room_index + 1)
	hud.fade_in(0.36)
	await get_tree().create_timer(0.40).timeout
	if is_inside_tree():
		_transition = false


# ============================================================
#  结束 / 重开
# ============================================================
func _on_player_died() -> void:
	wave_running = false
	var result := SaveData.submit_run({
		"wave": wave,
		"rooms": rooms_cleared,
		"kills": player.kills,
		"time": hud.elapsed_time(),
		"weapon": player.current_weapon().display_name,
	})
	hud.show_game_over({
		"wave": wave,
		"rooms": rooms_cleared,
		"kills": player.kills,
		"time": hud.elapsed_time(),
		"rank": result["rank"],
		"is_best": result["is_best"],
		"entries": result["entries"],
		"runs": result["runs"],
	})


func _on_restart_requested() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()

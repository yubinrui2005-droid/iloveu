extends Node3D
## 关卡管理器（工程的主场景脚本）
##
## 一局的流程：
##   随机生成场地 → 刷第 N 波敌人 → 全部清空 → 三选一强化 → 第 N+1 波（更强）→ … → 玩家死亡
## 死亡后按 R / 点按钮重开 = reload_current_scene()，场地也会重新随机（这就是「肉鸽」的部分）。

const ARENA_HALF := 22.0        ## 场地半径（边长 = 2 * ARENA_HALF）
const WALL_HEIGHT := 4.5
const CELL := 6.0               ## 柱子网格间距
const SPAWN_MIN_DIST := 13.0    ## 刷怪点与玩家的最小距离

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const ENEMY_SCENE := preload("res://scenes/enemy.tscn")
const HUD_SCENE := preload("res://scenes/hud.tscn")

var player: Node = null
var hud: CanvasLayer = null

var wave := 0
var enemies_alive := 0
var wave_running := false

var _obstacle_pos: Array[Vector3] = []
var _obstacle_radius: Array[float] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_setup_environment()
	_build_arena()
	_spawn_player()
	_spawn_hud()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_start_next_wave()


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
	env.fog_density = 0.018
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.light_energy = 0.85
	sun.shadow_enabled = true
	add_child(sun)


func _build_arena() -> void:
	# 地面
	_add_box(Vector3(0, -0.5, 0), Vector3(ARENA_HALF * 2.0, 1.0, ARENA_HALF * 2.0), Color(0.16, 0.17, 0.20))

	# 四面外墙
	var w := ARENA_HALF
	_add_box(Vector3(0, WALL_HEIGHT * 0.5, -w), Vector3(w * 2.0, WALL_HEIGHT, 1.0), Color(0.24, 0.25, 0.30))
	_add_box(Vector3(0, WALL_HEIGHT * 0.5, w), Vector3(w * 2.0, WALL_HEIGHT, 1.0), Color(0.24, 0.25, 0.30))
	_add_box(Vector3(-w, WALL_HEIGHT * 0.5, 0), Vector3(1.0, WALL_HEIGHT, w * 2.0), Color(0.24, 0.25, 0.30))
	_add_box(Vector3(w, WALL_HEIGHT * 0.5, 0), Vector3(1.0, WALL_HEIGHT, w * 2.0), Color(0.24, 0.25, 0.30))

	# 网格状随机柱子和掩体 —— 每局都不一样
	var count := int(ARENA_HALF / CELL)
	for gx in range(-count, count + 1):
		for gz in range(-count, count + 1):
			var cx := float(gx) * CELL
			var cz := float(gz) * CELL
			if Vector2(cx, cz).length() < 9.0:
				continue  # 中心留出空地，避免玩家一出生就被墙糊脸
			var roll := _rng.randf()
			if roll < 0.40:
				# 高柱子
				var sx := _rng.randf_range(2.0, 3.6)
				var sz := _rng.randf_range(2.0, 3.6)
				var h := _rng.randf_range(3.0, 5.0)
				var p := Vector3(cx + _rng.randf_range(-1.2, 1.2), h * 0.5, cz + _rng.randf_range(-1.2, 1.2))
				_add_box(p, Vector3(sx, h, sz), Color(0.21, 0.23, 0.28))
				_register_obstacle(p, maxf(sx, sz) * 0.5)
			elif roll < 0.68:
				# 矮掩体
				var sx2 := _rng.randf_range(2.4, 4.0)
				var sz2 := _rng.randf_range(2.4, 4.0)
				var h2 := _rng.randf_range(0.9, 1.3)
				var p2 := Vector3(cx + _rng.randf_range(-1.0, 1.0), h2 * 0.5, cz + _rng.randf_range(-1.0, 1.0))
				_add_box(p2, Vector3(sx2, h2, sz2), Color(0.27, 0.26, 0.24))
				_register_obstacle(p2, maxf(sx2, sz2) * 0.5)

	# 几盏灯，纯粹为了氛围
	for i in 7:
		var light := OmniLight3D.new()
		light.light_energy = 3.2
		light.omni_range = 16.0
		light.light_color = Color(1.0, 0.86, 0.66) if i % 2 == 0 else Color(0.62, 0.74, 1.0)
		light.shadow_enabled = false
		add_child(light)
		light.position = Vector3(
			_rng.randf_range(-ARENA_HALF + 4.0, ARENA_HALF - 4.0),
			3.4,
			_rng.randf_range(-ARENA_HALF + 4.0, ARENA_HALF - 4.0)
		)


func _add_box(center: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = center

	var mesh := MeshInstance3D.new()
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

	add_child(body)


func _register_obstacle(center: Vector3, radius: float) -> void:
	_obstacle_pos.append(center)
	_obstacle_radius.append(radius)


func _spawn_player() -> void:
	player = PLAYER_SCENE.instantiate()
	add_child(player)
	player.position = Vector3(0.0, 0.3, 0.0)
	player.died.connect(_on_player_died)


func _spawn_hud() -> void:
	hud = HUD_SCENE.instantiate()
	add_child(hud)
	hud.bind(player)
	hud.upgrade_chosen.connect(_on_upgrade_chosen)
	hud.restart_requested.connect(_on_restart_requested)


# ============================================================
#  波次
# ============================================================
func _start_next_wave() -> void:
	wave += 1
	wave_running = true
	enemies_alive = 0

	var count := mini(2 + int(round(float(wave) * 1.7)), 24)
	for i in count:
		_spawn_enemy()

	hud.set_wave_info(wave, enemies_alive)
	hud.show_banner("第 %d 波" % wave)


func _spawn_enemy() -> void:
	var enemy = ENEMY_SCENE.instantiate()
	add_child(enemy)
	enemy.add_to_group("enemy")
	enemy.position = _find_spawn_point()
	enemy.target = player
	enemy.setup(_pick_kind(), wave)
	enemy.died.connect(_on_enemy_died)
	enemies_alive += 1


func _pick_kind() -> int:
	var r := _rng.randf()
	if wave >= 5 and r < 0.18:
		return 2                       # Kind.TANK
	elif wave >= 3 and r < 0.45:
		return 1                       # Kind.RUNNER
	return 0                           # Kind.GRUNT


func _find_spawn_point() -> Vector3:
	var limit := ARENA_HALF - 3.0
	for attempt in 40:
		var p := Vector3(
			_rng.randf_range(-limit, limit),
			0.6,
			_rng.randf_range(-limit, limit)
		)
		if player != null and p.distance_to(player.global_position) < SPAWN_MIN_DIST:
			continue
		var blocked := false
		for i in _obstacle_pos.size():
			var flat := Vector2(p.x - _obstacle_pos[i].x, p.z - _obstacle_pos[i].z)
			if flat.length() < _obstacle_radius[i] + 1.3:
				blocked = true
				break
		if not blocked:
			return p
	# 兜底：站在离玩家最远的角落
	return Vector3(limit * signf(-player.position.x), 0.6, limit * signf(-player.position.z))


func _on_enemy_died(_enemy) -> void:
	enemies_alive = maxi(enemies_alive - 1, 0)
	player.add_kill()
	hud.set_wave_info(wave, enemies_alive)
	if enemies_alive <= 0 and wave_running:
		wave_running = false
		_finish_wave()


func _finish_wave() -> void:
	await get_tree().create_timer(0.7).timeout
	if not is_inside_tree():
		return
	_offer_upgrades()


func _offer_upgrades() -> void:
	var choices := Upgrades.roll(3, player.upgrade_counts)
	if choices.is_empty():
		# 词条全部叠满了，直接进下一波
		player.heal(20.0)
		_start_next_wave()
		return
	hud.show_upgrade_choices(choices)


func _on_upgrade_chosen(id: String) -> void:
	var title := Upgrades.apply(player, id)
	hud.close_upgrade_choices()
	hud.show_toast("获得强化：%s" % title)
	player.heal(12.0)
	_start_next_wave()


# ============================================================
#  结束 / 重开
# ============================================================
func _on_player_died() -> void:
	wave_running = false
	hud.show_game_over({
		"wave": wave,
		"kills": player.kills,
		"time": hud.elapsed_time(),
	})


func _on_restart_requested() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()

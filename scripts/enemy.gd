extends CharacterBody3D
class_name Enemy
## 敌人：导航寻路追击玩家 + 接触伤害（Boss 额外发射弹幕）。
##
## 移动分三层，逐级兜底，任何一层失效游戏都还能玩：
##   1. NavigationAgent3D 沿 NavMesh 求路（正常情况走这条）
##   2. 直线朝玩家冲 + 射线贴墙滑行（没有 navmesh 或路径为空时）
##   3. 什么都不动（玩家已死）
##
## 四个种类通过 setup() 配置，数值随波次成长（肉鸽常见的「难度爬坡」）。

signal died(enemy: Enemy)
signal health_changed(hp: float, max_hp: float)

enum Kind { GRUNT, RUNNER, TANK, BOSS }

const GRAVITY := 24.0
const PROJECTILE_SCENE := preload("res://scenes/projectile.tscn")

var kind: Kind = Kind.GRUNT
var max_health := 60.0
var health := 60.0
var move_speed := 3.2
var contact_damage := 9.0
var attack_interval := 0.9
var shoot_interval := 2.8          ## 仅 Boss 用

var target: Node3D = null
var is_dead := false

var _attack_timer := 0.0
var _shoot_timer := 0.0
var _repath_timer := 0.0
var _sep_timer := 0.0
var _flash := 0.0
var _final_scale := Vector3.ONE
var _base_color := Color(0.78, 0.24, 0.26)
var _mat: StandardMaterial3D = null
var _model: Node3D = null
var _agent: NavigationAgent3D = null
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_model = get_node_or_null("Model")
	var mesh := get_node_or_null("Model/Mesh") as MeshInstance3D
	if mesh != null:
		var src := mesh.get_surface_override_material(0)
		if src != null:
			_mat = src.duplicate() as StandardMaterial3D
			mesh.set_surface_override_material(0, _mat)
			_base_color = _mat.albedo_color

	_agent = get_node_or_null("Agent") as NavigationAgent3D
	if _agent != null:
		_agent.avoidance_enabled = false     # 避障交给下面 _separate() 手写，行为更可控
		_agent.path_desired_distance = 0.9
		_agent.target_desired_distance = 1.1
		_agent.path_max_distance = 8.0
		_agent.debug_enabled = false


func is_boss() -> bool:
	return kind == Kind.BOSS


## 由关卡管理器调用：配置种类、强度，并播放出场动画
func setup(p_kind: int, wave: int) -> void:
	kind = p_kind
	var dmg_scale := 1.0 + float(wave - 1) * 0.10

	match kind:
		Kind.GRUNT:
			max_health = 55.0 * (1.0 + float(wave - 1) * 0.19)
			move_speed = 3.3 + float(wave) * 0.06
			contact_damage = 9.0 * dmg_scale
			attack_interval = 0.9
			_final_scale = Vector3.ONE
			_tint(Color(0.78, 0.24, 0.26))            # 红：普通
		Kind.RUNNER:
			max_health = 32.0 * (1.0 + float(wave - 1) * 0.19)
			move_speed = 5.4 + float(wave) * 0.10
			contact_damage = 7.0 * dmg_scale
			attack_interval = 0.75
			_final_scale = Vector3(0.82, 0.82, 0.82)
			_tint(Color(0.88, 0.62, 0.18))            # 黄：冲锋
		Kind.TANK:
			max_health = 150.0 * (1.0 + float(wave - 1) * 0.19)
			move_speed = 2.1 + float(wave) * 0.04
			contact_damage = 17.0 * dmg_scale
			attack_interval = 1.25
			_final_scale = Vector3(1.25, 1.25, 1.25)
			_tint(Color(0.42, 0.36, 0.72))            # 紫：重装
		Kind.BOSS:
			# 每 5 波一只，血量按「第几只」指数增长，不是按波次线性
			var tier := maxi(wave / 5, 1)
			max_health = 850.0 * pow(1.65, float(tier - 1))
			move_speed = 2.5 + float(tier) * 0.22
			contact_damage = 20.0 * dmg_scale
			attack_interval = 1.5
			shoot_interval = maxf(1.3, 2.9 - float(tier) * 0.20)
			_final_scale = Vector3(2.1, 2.1, 2.1)
			_tint(Color(0.74, 0.13, 0.21), true)      # 深红 + 自发光：首领

	health = max_health
	health_changed.emit(health, max_health)

	if _agent != null:
		_agent.radius = 0.45 * _final_scale.x
		_agent.height = 1.7 * _final_scale.y

	scale = _final_scale * 0.12
	var tw := create_tween()
	tw.tween_property(self, "scale", _final_scale, 0.22) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	if kind == Kind.BOSS:
		_shoot_timer = 2.2
		Sfx.play_at("boss_spawn", global_position)


func _tint(c: Color, glow := false) -> void:
	_base_color = c
	if _mat != null:
		_mat.albedo_color = c
		_mat.emission_enabled = glow
		_mat.emission = c * 0.45 if glow else Color.BLACK
		_mat.emission_energy_multiplier = 1.2


# ============================================================
#  每帧
# ============================================================
func _physics_process(delta: float) -> void:
	if is_dead or target == null:
		return

	if _flash > 0.0:
		_flash = maxf(_flash - delta * 9.0, 0.0)
		if _mat != null:
			_mat.albedo_color = _base_color.lerp(Color(1.5, 1.5, 1.5), _flash * 0.85)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	var to_target := target.global_position - global_position
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var dist := flat.length()

	var dir := _path_dir(delta)
	if dir == Vector3.ZERO:
		dir = _direct_dir(flat, dist)
	dir = _separate(dir, delta)

	# 贴到约 2 米就站住，不再往前挤。
	# 不加这个判断的话敌人会一路走到玩家身体里，整个模型糊在摄像机上（非常难看）。
	var stop_dist := 1.9 + (_final_scale.x - 1.0) * 0.6
	if dist < stop_dist - 0.25:
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
	move_and_slide()

	# 朝向玩家（只转表现层，不影响碰撞与移动方向）
	if _model != null and dir != Vector3.ZERO:
		var yaw := atan2(-dir.x, -dir.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, yaw, clampf(delta * 8.0, 0.0, 1.0))

	# 接触伤害
	_attack_timer -= delta
	if dist < stop_dist + 0.55 and _attack_timer <= 0.0:
		_attack_timer = attack_interval
		if target.has_method("take_damage"):
			target.take_damage(contact_damage)

	# Boss 弹幕
	if kind == Kind.BOSS:
		_shoot_timer -= delta
		if _shoot_timer <= 0.0 and dist < 46.0:
			_shoot_timer = shoot_interval
			_fire_volley()


## 第一层：沿 NavMesh 求路。路径为空时返回 ZERO，交给第二层
func _path_dir(delta: float) -> Vector3:
	if _agent == null:
		return Vector3.ZERO
	_repath_timer -= delta
	var tp := target.global_position
	if _repath_timer <= 0.0 or _agent.target_position.distance_to(tp) > 1.6:
		_agent.target_position = tp
		_repath_timer = 0.30
	var np := _agent.get_next_path_position()
	var d := np - global_position
	d.y = 0.0
	if d.length() < 0.2:
		return Vector3.ZERO
	return d.normalized()


## 第二层：直线追击 + 前方有墙就沿法线蹭过去
func _direct_dir(flat: Vector3, dist: float) -> Vector3:
	var dir := Vector3.ZERO
	if dist > 0.05:
		dir = flat / dist
	if dir == Vector3.ZERO:
		return dir
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * 0.9
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 1.5, 1, [get_rid()])
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		var normal: Vector3 = hit["normal"]
		normal.y = 0.0
		if normal.length() > 0.01:
			dir = (dir + normal.normalized() * 1.6).normalized()
	return dir


## 第三层：同类互斥，避免一堆怪完全重叠成一个点（比 RVO 避障便宜得多）
func _separate(dir: Vector3, delta: float) -> Vector3:
	_sep_timer -= delta
	if _sep_timer > 0.0 or dir == Vector3.ZERO:
		return dir
	_sep_timer = 0.20
	var push := Vector3.ZERO
	for other in get_tree().get_nodes_in_group("enemy"):
		if other == self or not is_instance_valid(other):
			continue
		var d: Vector3 = global_position - other.global_position
		d.y = 0.0
		var l := d.length()
		if l > 0.001 and l < 1.7:
			push += d / l * (1.7 - l)
	if push.length() < 0.001:
		return dir
	# 块头越大越不容易被推开，否则 Boss 会被小怪挤走
	var weight := clampf(0.75 / _final_scale.x, 0.15, 0.75)
	return (dir + push.normalized() * weight).normalized()


func _fire_volley() -> void:
	if target == null or _dead_or_gone():
		return
	var from := global_position + Vector3.UP * (1.1 * _final_scale.y)
	var to := target.global_position + Vector3.UP * 0.9
	var base := (to - from)
	if base.length() < 0.1:
		return
	base = base.normalized()

	var count := 3
	var dmg := 11.0 + float(maxi(int(max_health / 700.0), 1)) * 2.0
	for i in count:
		var spread := deg_to_rad(-11.0 + 11.0 * float(i))
		var dir := base.rotated(Vector3.UP, spread)
		var p = PROJECTILE_SCENE.instantiate()
		get_tree().current_scene.add_child(p)
		p.setup(from, dir, dmg, 16.0 + move_speed)
	Sfx.play_at("boss_shot", global_position)


func _dead_or_gone() -> bool:
	return not is_inside_tree() or get_tree() == null


# ============================================================
#  受伤 / 死亡
# ============================================================
func take_damage(amount: float) -> void:
	if is_dead:
		return
	health -= amount
	_flash = 1.0
	health_changed.emit(maxf(health, 0.0), max_health)
	if health <= 0.0:
		_die()
		return
	# 命中回弹感：短暂放大（Boss 太重，不给回弹）
	if not is_boss():
		var s := scale
		scale = s * 1.08
		var pop := create_tween()
		pop.tween_property(self, "scale", s, 0.08)


func _die() -> void:
	is_dead = true
	set_physics_process(false)
	velocity = Vector3.ZERO

	var boss := is_boss()
	if boss:
		Sfx.play_at("boss_die", global_position, 2.0)
		_boss_explosion()
	else:
		Sfx.play_at("enemy_die", global_position, 0.0, _rng.randf_range(0.9, 1.15))

	if _mat != null:
		_mat.emission_enabled = false
		_mat.albedo_color = _base_color.lerp(Color(1.6, 1.6, 1.6), 0.5)

	var s0 := scale
	var dur := 0.55 if boss else 0.18
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "scale", Vector3(s0.x * 1.4, s0.y * 0.12, s0.z * 1.4), dur)
	tw.tween_property(self, "rotation:y", rotation.y + PI * (0.5 if not boss else 2.0), dur)
	tw.chain().tween_callback(func() -> void:
		died.emit(self)
		queue_free()
	)


func _boss_explosion() -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	for i in 12:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.32
		sm.height = 0.64
		mi.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(2.0, 0.9, 0.35)
		mi.material_override = mat
		root.add_child(mi)
		var ang := TAU * float(i) / 12.0
		mi.global_position = global_position + Vector3.UP * 1.4
		var dir := Vector3(cos(ang), 0.6, sin(ang)).normalized()
		var dist := _rng.randf_range(2.5, 6.0)
		var tw := mi.create_tween()
		tw.set_parallel(true)
		tw.tween_property(mi, "global_position", mi.global_position + dir * dist, 0.6)
		tw.tween_property(mi, "scale", Vector3.ONE * 0.1, 0.6)
		tw.chain().tween_callback(mi.queue_free)

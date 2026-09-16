extends CharacterBody3D
## 玩家控制器
## 负责：第一人称移动、鼠标视角、射线枪射击、换弹、受伤与死亡。
## 所有武器/移动数值都是 @export 的，肉鸽强化会直接改这些数值（见 upgrades.gd）。

signal health_changed(hp: float, max_hp: float)
signal ammo_changed(ammo: int, mag: int)
signal reload_changed(reloading: bool)
signal died
signal hit_confirmed(crit: bool)

const GRAVITY := 24.0

# ---------------- 移动 ----------------
@export var base_speed := 6.2
@export var sprint_multiplier := 1.45
@export var jump_velocity := 5.6
@export var mouse_sensitivity := 0.0022
@export var max_pitch_deg := 89.0

# ---------------- 生命 ----------------
@export var max_health := 100.0

# ---------------- 武器 ----------------
@export var weapon_damage := 18.0
@export var fire_rate := 7.5          ## 每秒射击次数
@export var pellets := 1              ## 每次射击的弹丸数（霰弹流靠它）
@export var spread_deg := 2.0         ## 散布角度
@export var mag_size := 24
@export var reload_time := 1.2
@export var max_range := 90.0
@export var crit_chance := 0.0
@export var lifesteal := 0.0          ## 每次命中回血
@export var kill_heal := 0.0          ## 每次击杀回血
@export var ricochet := false         ## 预留：穿透（本原型未启用）

var health: float
var ammo: int
var is_reloading := false
var can_control := true
var kills := 0
var upgrade_counts := {}              ## { 词条id: 已获得层数 }

var _fire_timer := 0.0
var _reload_timer := 0.0
var _pitch := 0.0
var _recoil := 0.0
var _bob_time := 0.0
var _gun_base_pos := Vector3.ZERO

@onready var neck: Node3D = $Neck
@onready var camera: Camera3D = $Neck/Camera3D
@onready var gun: Node3D = $Neck/Camera3D/Gun


func _ready() -> void:
	health = max_health
	ammo = mag_size
	_gun_base_pos = gun.position
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# 等一帧再发信号，保证 HUD 已经连上
	call_deferred("sync_stats")


# ============================================================
#  输入 / 视角
# ============================================================
func _input(event: InputEvent) -> void:
	if not can_control:
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		var sens := mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * sens, -deg_to_rad(max_pitch_deg), deg_to_rad(max_pitch_deg))
		neck.rotation.x = _pitch
		rotate_y(-event.relative.x * sens)


func _physics_process(delta: float) -> void:
	# 重力
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	if can_control:
		_move(delta)
		_weapon(delta)

	move_and_slide()
	_animate_gun(delta)


func _move(delta: float) -> void:
	# get_vector(负X, 正X, 负Z, 正Z) —— 前进是 -Z，所以把 move_forward 放在"负Z"位
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := (global_transform.basis * Vector3(input.x, 0.0, input.y))
	dir.y = 0.0
	dir = dir.normalized()

	var speed := base_speed
	if Input.is_action_pressed("sprint"):
		speed *= sprint_multiplier

	if dir.length() > 0.01:
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		_bob_time += delta * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed * 8.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, speed * 8.0 * delta)

	if is_on_floor() and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity


# ============================================================
#  武器
# ============================================================
func _weapon(delta: float) -> void:
	_fire_timer -= delta

	if is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			is_reloading = false
			ammo = mag_size
			reload_changed.emit(false)
			ammo_changed.emit(ammo, mag_size)
		return

	if Input.is_action_just_pressed("reload"):
		start_reload()
		return

	if Input.is_action_pressed("shoot") and _fire_timer <= 0.0:
		shoot()
		_fire_timer = 1.0 / maxf(fire_rate, 0.1)


func shoot() -> void:
	if ammo <= 0:
		start_reload()
		return

	ammo -= 1
	ammo_changed.emit(ammo, mag_size)
	_recoil = minf(_recoil + 0.055, 0.18)
	_pitch = clampf(_pitch - deg_to_rad(0.55), -deg_to_rad(max_pitch_deg), deg_to_rad(max_pitch_deg))
	neck.rotation.x = _pitch

	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	var space := get_world_3d().direct_space_state
	var any_hit := false
	var any_crit := false

	for i in pellets:
		var dir := forward
		if spread_deg > 0.0:
			var rad := deg_to_rad(spread_deg)
			dir = dir.rotated(camera.global_transform.basis.x, randf_range(-rad, rad))
			dir = dir.rotated(camera.global_transform.basis.y, randf_range(-rad, rad))

		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_range, 1 | 4, [get_rid()])
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue

		var collider = hit.get("collider")
		if collider != null and collider.has_method("take_damage"):
			var is_crit := randf() < crit_chance
			var dmg := weapon_damage * (2.0 if is_crit else 1.0)
			collider.take_damage(dmg)
			_spawn_impact(hit["position"], is_crit)
			if lifesteal > 0.0:
				heal(lifesteal)
			any_hit = true
			any_crit = any_crit or is_crit

	if any_hit:
		hit_confirmed.emit(any_crit)

	if ammo <= 0:
		start_reload()


func start_reload() -> void:
	if is_reloading or ammo >= mag_size:
		return
	is_reloading = true
	_reload_timer = reload_time
	reload_changed.emit(true)


func _spawn_impact(pos: Vector3, is_crit: bool) -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.8, 1.7, 0.9) if is_crit else Color(1.1, 0.8, 0.45)

	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.09
	sphere.height = 0.18
	mi.mesh = sphere
	mi.material_override = mat
	root.add_child(mi)
	mi.global_position = pos

	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", Vector3.ONE * 2.4, 0.1)
	tw.tween_callback(mi.queue_free)


func _animate_gun(delta: float) -> void:
	if gun == null:
		return
	_recoil = move_toward(_recoil, 0.0, delta * 0.9)
	var bob := Vector3.ZERO
	if is_on_floor() and Vector2(velocity.x, velocity.z).length() > 0.5:
		bob = Vector3(sin(_bob_time * 2.0) * 0.012, absf(cos(_bob_time * 2.0)) * -0.012, 0.0)
	var target := _gun_base_pos + bob + Vector3(0.0, _recoil * 0.25, _recoil)
	gun.position = gun.position.lerp(target, clampf(delta * 18.0, 0.0, 1.0))
	gun.rotation.x = lerp(gun.rotation.x, _recoil * 2.0, clampf(delta * 18.0, 0.0, 1.0))


# ============================================================
#  生命 / 统计
# ============================================================
func take_damage(amount: float) -> void:
	if not can_control:
		return
	health -= amount
	health_changed.emit(maxf(health, 0.0), max_health)
	if health <= 0.0:
		health = 0.0
		can_control = false
		died.emit()


func heal(amount: float) -> void:
	if amount <= 0.0:
		return
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)


func add_kill() -> void:
	kills += 1
	if kill_heal > 0.0:
		heal(kill_heal)


## 数值被强化改动后调用，刷新 HUD 并做边界处理
func sync_stats() -> void:
	health = minf(health, max_health)
	ammo = mini(ammo, mag_size)
	health_changed.emit(health, max_health)
	ammo_changed.emit(ammo, mag_size)


## 供外部（HUD）读取当前武器概况
func weapon_summary() -> String:
	var s := "伤害 %.0f  射速 %.1f/s  弹匣 %d" % [weapon_damage, fire_rate, mag_size]
	if pellets > 1:
		s += "  x%d" % pellets
	if crit_chance > 0.0:
		s += "  暴击 %d%%" % roundi(crit_chance * 100.0)
	return s

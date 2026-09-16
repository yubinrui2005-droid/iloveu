extends CharacterBody3D
## 玩家控制器（第一人称）
##
## 负责：移动、视角、射击、换弹、切枪、受伤与死亡。
##
## 数值分成两层：
##   1. 【基础值】来自当前武器 WeaponData（weapons.gd 里定义）
##   2. 【乘数】来自肉鸽强化（upgrades.gd 只改这里）
## 两者相乘才是实际生效的数值。好处是切枪时强化不会丢，
## 而且做"霰弹枪 +30% 伤害"这类词条不用改任何武器数据。

signal health_changed(hp: float, max_hp: float)
signal ammo_changed(ammo: int, mag: int)
signal reload_changed(reloading: bool)
signal died
signal hit_confirmed(crit: bool)
signal weapon_changed(index: int, data: WeaponData)
signal weapon_locked(index: int, data: WeaponData)

const GRAVITY := 24.0

# ---------------- 移动 ----------------
@export var base_speed := 6.2
@export var sprint_multiplier := 1.45
@export var jump_velocity := 5.6
@export var mouse_sensitivity := 0.0022
@export var max_pitch_deg := 89.0

# ---------------- 生命 ----------------
@export var max_health := 100.0

# ---------------- 强化乘数（作用于所有武器）----------------
var dmg_mult := 1.0
var rate_mult := 1.0
var mag_mult := 1.0
var reload_mult := 1.0
var spread_mult := 1.0
var pellets_bonus := 0
var pierce_bonus := 0
var crit_chance := 0.0
var lifesteal := 0.0
var kill_heal := 0.0
var damage_reduction := 0.0        ## 0~0.75，减伤比例

# ---------------- 武器状态 ----------------
var weapons: Array[WeaponData] = Weapons.all()
var weapon_index := 0
var ammo := 0
var is_reloading := false

var health: float
var can_control := true
var kills := 0
var upgrade_counts := {}              ## { 词条id: 已获得层数 }

var _unlocked_wave := 1
var _mag_left: Array[int] = []        ## 每把枪各自记住弹匣余量

var _fire_timer := 0.0
var _reload_timer := 0.0
var _swap_timer := 0.0
var _fire_prev := false
var _pitch := 0.0
var _recoil := 0.0
var _bob_time := 0.0
var _flash_time := 0.0
var _gun_base_pos := Vector3.ZERO

@onready var neck: Node3D = $Neck
@onready var camera: Camera3D = $Neck/Camera3D
@onready var gun: Node3D = $Neck/Camera3D/Gun


# ============================================================
#  只读的"当前实际数值"（基础值 × 强化乘数）
#  写成属性而不是函数，是为了让 HUD / 词条表沿用原来的读法
# ============================================================
var weapon_damage: float:
	get: return _cur().damage * dmg_mult

var fire_rate: float:
	get: return _cur().fire_rate * rate_mult

var mag_size: int:
	get: return maxi(1, roundi(float(_cur().mag_size) * mag_mult))

var reload_time: float:
	get: return maxf(0.25, _cur().reload_time * reload_mult)

var spread_deg: float:
	get: return _cur().spread_deg * spread_mult

var pellets: int:
	get: return maxi(1, _cur().pellets + pellets_bonus)


func _cur() -> WeaponData:
	return weapons[clampi(weapon_index, 0, weapons.size() - 1)]


func current_weapon() -> WeaponData:
	return _cur()


# ============================================================
#  初始化
# ============================================================
func _ready() -> void:
	health = max_health
	for w in weapons:
		_mag_left.append(w.mag_size)
	ammo = _mag_left[0]
	_gun_base_pos = gun.position
	_prepare_gun_meshes()
	_apply_weapon_visual()
	if not TouchUI.is_active():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# 等一帧再发信号，保证 HUD 已经连上
	call_deferred("sync_stats")
	call_deferred("_announce_weapon")


func _announce_weapon() -> void:
	weapon_changed.emit(weapon_index, _cur())


## 换房间时把视角复位，否则会带着上一间房的俯仰角进场
func reset_view() -> void:
	_pitch = 0.0
	neck.rotation.x = 0.0
	rotation.y = 0.0
	velocity = Vector3.ZERO


## 子资源在 PackedScene 的多个实例之间是共享的，改颜色/尺寸前必须复制一份。
## 注意 tscn 里用的是 surface_material_override/0，所以要走 get/set_surface_override_material。
func _prepare_gun_meshes() -> void:
	for part in ["Body", "Grip"]:
		var mi := gun.get_node_or_null(part) as MeshInstance3D
		if mi == null:
			continue
		mi.mesh = (mi.mesh as BoxMesh).duplicate()
		var mat := mi.get_surface_override_material(0)
		if mat != null:
			mi.set_surface_override_material(0, (mat as StandardMaterial3D).duplicate())


func _set_mat_color(mi: MeshInstance3D, c: Color) -> void:
	var m := mi.get_surface_override_material(0) as StandardMaterial3D
	if m != null:
		m.albedo_color = c


# ============================================================
#  解锁
# ============================================================
func is_unlocked(index: int) -> bool:
	if index < 0 or index >= weapons.size():
		return false
	return weapons[index].unlock_wave <= _unlocked_wave


## 返回本次新解锁的武器列表（main.gd 拿去弹提示）
func update_unlocks(wave: int) -> Array[WeaponData]:
	var fresh: Array[WeaponData] = []
	for w in weapons:
		if w.unlock_wave > _unlocked_wave and w.unlock_wave <= wave:
			fresh.append(w)
	_unlocked_wave = maxi(_unlocked_wave, wave)
	return fresh


# ============================================================
#  输入 / 视角
# ============================================================
func _input(event: InputEvent) -> void:
	if not can_control:
		return
	if TouchUI.is_active():
		return                       # 触屏模式下视角由 TouchUI 的拖动接管
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		_look(-event.relative.x * mouse_sensitivity, -event.relative.y * mouse_sensitivity)


func _look(yaw: float, pitch_delta: float) -> void:
	var lim := deg_to_rad(max_pitch_deg)
	_pitch = clampf(_pitch + pitch_delta, -lim, lim)
	neck.rotation.x = _pitch
	rotate_y(yaw)


## 键盘/鼠标动作的入口。触屏模式下全部返回 false，把控制权让给 TouchUI。
##
## 为什么必须让：Godot 默认开着 input_devices/pointing/emulate_mouse_from_touch，
## 手指一碰屏幕，引擎会顺手补一个鼠标事件；而 shoot 绑的正是鼠标左键。
## 结果就是——玩家一摸左边摇杆就在开枪（真机上一样会中，实测轻拖摇杆 2.4 秒
## 打空了 18 发子弹）。视角和移动早就让位了（见 _input / _move），
## 这几个开关当初漏了，现在统一走这里。
func _key_pressed(action: String) -> bool:
	return not TouchUI.is_active() and Input.is_action_pressed(action)


func _key_just(action: String) -> bool:
	return not TouchUI.is_active() and Input.is_action_just_pressed(action)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	if can_control:
		_apply_touch_look()
		_move(delta)
		_weapon(delta)

	move_and_slide()
	_animate_gun(delta)


func _apply_touch_look() -> void:
	if not TouchUI.is_active():
		return
	var d := TouchUI.consume_look()
	if d == Vector2.ZERO:
		return
	var s := mouse_sensitivity * 2.1        # 手指划屏比鼠标迟钝，乘一个系数
	_look(-d.x * s, -d.y * s)


# ============================================================
#  移动
# ============================================================
func _move(delta: float) -> void:
	var input := Vector2.ZERO
	if TouchUI.is_active():
		input = TouchUI.move_vector()
	else:
		# get_vector(负X, 正X, 负Z, 正Z) —— 前进是 -Z，所以 move_forward 放在"负Z"位
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	var dir := global_transform.basis * Vector3(input.x, 0.0, input.y)
	dir.y = 0.0
	dir = dir.normalized()

	var speed := base_speed
	if _key_pressed("sprint") or TouchUI.sprint_held():
		speed *= sprint_multiplier

	if dir.length() > 0.01:
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		_bob_time += delta * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed * 8.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, speed * 8.0 * delta)

	var want_jump := _key_just("jump") or TouchUI.consume_jump()
	if is_on_floor() and want_jump:
		velocity.y = jump_velocity


# ============================================================
#  武器
# ============================================================
func _weapon(delta: float) -> void:
	_fire_timer = maxf(_fire_timer - delta, 0.0)
	_swap_timer = maxf(_swap_timer - delta, 0.0)

	if is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			is_reloading = false
			ammo = mag_size
			_mag_left[weapon_index] = ammo
			reload_changed.emit(false)
			ammo_changed.emit(ammo, mag_size)
		return

	_handle_switch_input()

	if _key_just("reload") or TouchUI.consume_reload():
		start_reload()
		return

	# 自动武器按住连发，半自动武器每次点击一发。
	# 用"上一帧是否按下"手动算边沿，这样键盘鼠标和触屏按钮走同一套逻辑。
	var want := _key_pressed("shoot") or TouchUI.fire_held()
	var edge := want and not _fire_prev
	_fire_prev = want

	var ready := _fire_timer <= 0.0 and _swap_timer <= 0.0
	if ready and (_cur().automatic and want or not _cur().automatic and edge):
		shoot()


func _handle_switch_input() -> void:
	if _swap_timer > 0.0:
		return
	if TouchUI.consume_swap():
		cycle_weapon(1)
		return
	if _key_just("weapon_next"):
		cycle_weapon(1)
		return
	if _key_just("weapon_prev"):
		cycle_weapon(-1)
		return
	for i in mini(4, weapons.size()):
		if _key_just("weapon_%d" % (i + 1)):
			switch_weapon(i)
			return


func switch_weapon(index: int) -> void:
	if index < 0 or index >= weapons.size() or index == weapon_index:
		return
	if not is_unlocked(index):
		Sfx.play("denied", -8.0)
		weapon_locked.emit(index, weapons[index])
		return

	_mag_left[weapon_index] = ammo
	weapon_index = index
	ammo = clampi(_mag_left[index], 0, mag_size)
	_mag_left[index] = ammo

	is_reloading = false
	reload_changed.emit(false)
	_swap_timer = 0.30
	_apply_weapon_visual()
	Sfx.play("swap", -9.0, 1.0 + randf_range(-0.05, 0.05))
	ammo_changed.emit(ammo, mag_size)
	weapon_changed.emit(weapon_index, _cur())

	if ammo <= 0:
		start_reload()               # 换到空枪自动装弹，符合 FPS 习惯


func cycle_weapon(dir: int) -> void:
	var n := weapons.size()
	for step in range(1, n + 1):
		var idx := (weapon_index + dir * step + n * 4) % n
		if is_unlocked(idx):
			switch_weapon(idx)
			return
	Sfx.play("denied", -10.0)


func _apply_weapon_visual() -> void:
	var w := _cur()
	var body := gun.get_node_or_null("Body") as MeshInstance3D
	if body != null:
		(body.mesh as BoxMesh).size = w.body_size
		_set_mat_color(body, w.color)
	var grip := gun.get_node_or_null("Grip") as MeshInstance3D
	if grip != null:
		(grip.mesh as BoxMesh).size = w.grip_size
		_set_mat_color(grip, w.color.darkened(0.25))
	# 枪口跟着枪管长度走，否则长枪的枪口火光会从枪身中间冒出来
	var muzzle := gun.get_node_or_null("Muzzle") as Node3D
	if muzzle != null:
		muzzle.position = Vector3(0.0, 0.006, -(w.body_size.z * 0.5 + 0.02))


func shoot() -> void:
	if not can_control or is_reloading or _swap_timer > 0.0:
		return
	if ammo <= 0:
		Sfx.play("dry", -10.0)
		start_reload()
		return

	ammo -= 1
	_mag_left[weapon_index] = ammo
	ammo_changed.emit(ammo, mag_size)
	_fire_timer = 1.0 / maxf(fire_rate, 0.1)

	var w := _cur()
	_recoil = minf(_recoil + w.recoil_kick, 0.26)
	_pitch = clampf(_pitch - deg_to_rad(w.recoil_pitch),
			-deg_to_rad(max_pitch_deg), deg_to_rad(max_pitch_deg))
	neck.rotation.x = _pitch

	Sfx.play(w.sfx, -5.0, 1.0 + randf_range(-0.05, 0.05))
	_flash_time = 0.05

	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	var basis := camera.global_transform.basis
	var space := get_world_3d().direct_space_state
	var any_hit := false
	var any_crit := false
	var max_dist := maxf(w.max_range, 5.0)

	for _p in pellets:
		var dir := forward
		if spread_deg > 0.0:
			var rad := deg_to_rad(spread_deg)
			dir = dir.rotated(basis.x, randf_range(-rad, rad))
			dir = dir.rotated(basis.y, randf_range(-rad, rad))
			dir = dir.normalized()

		# 穿透：一次射击最多打穿 1 + pierce_bonus 个敌人
		var exclude: Array[RID] = [get_rid()]
		var left := 1 + pierce_bonus
		var from := origin
		var far := origin + dir * max_dist
		while left > 0:
			var query := PhysicsRayQueryParameters3D.create(from, far, 1 | 4, exclude)
			var hit := space.intersect_ray(query)
			if hit.is_empty():
				break
			var collider = hit.get("collider")
			var pos: Vector3 = hit["position"]
			if collider != null and collider.has_method("take_damage"):
				var is_crit := randf() < crit_chance
				collider.take_damage(weapon_damage * (2.0 if is_crit else 1.0))
				_spawn_impact(pos, is_crit)
				if lifesteal > 0.0:
					heal(lifesteal)
				any_hit = true
				any_crit = any_crit or is_crit
				exclude.append(collider.get_rid())
				from = pos + dir * 0.08
				left -= 1
			else:
				_spawn_impact(pos, false)
				break

	if any_hit:
		Sfx.play("crit" if any_crit else "hit", -13.0, 1.0 + randf_range(-0.08, 0.08))
		hit_confirmed.emit(any_crit)

	if ammo <= 0:
		start_reload()


func start_reload() -> void:
	if is_reloading or ammo >= mag_size:
		return
	is_reloading = true
	_reload_timer = reload_time
	reload_changed.emit(true)
	Sfx.play("reload", -9.0)


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


# ============================================================
#  枪械动画
# ============================================================
func _animate_gun(delta: float) -> void:
	if gun == null:
		return
	_recoil = move_toward(_recoil, 0.0, delta * 0.9)

	var bob := Vector3.ZERO
	if is_on_floor() and Vector2(velocity.x, velocity.z).length() > 0.5:
		bob = Vector3(sin(_bob_time * 2.0) * 0.012, absf(cos(_bob_time * 2.0)) * -0.012, 0.0)

	# 换枪时枪身下沉再抬起
	var swap := 0.0
	if _swap_timer > 0.0:
		swap = sin(_swap_timer / 0.30 * PI) * 0.16

	var target := _gun_base_pos + bob + Vector3(0.0, _recoil * 0.25 - swap, _recoil)
	var k := clampf(delta * 18.0, 0.0, 1.0)
	gun.position = gun.position.lerp(target, k)
	gun.rotation.x = lerp(gun.rotation.x, _recoil * 2.0 + (0.5 if _swap_timer > 0.0 else 0.0), k)

	_update_muzzle_flash(delta)


func _update_muzzle_flash(delta: float) -> void:
	var mesh := gun.get_node_or_null("Muzzle/Flash") as MeshInstance3D
	var light := gun.get_node_or_null("Muzzle/Light") as OmniLight3D
	if mesh == null:
		return
	if _flash_time > 0.0:
		_flash_time = maxf(_flash_time - delta, 0.0)
		var k := _flash_time / 0.05
		mesh.visible = k > 0.0
		mesh.scale = Vector3.ONE * (0.55 + k * 0.75)
		if light != null:
			light.light_energy = 3.4 * k
	else:
		mesh.visible = false
		if light != null:
			light.light_energy = 0.0


# ============================================================
#  生命 / 统计
# ============================================================
func take_damage(amount: float) -> void:
	if not can_control:
		return
	var dmg := amount * (1.0 - clampf(damage_reduction, 0.0, 0.75))
	health -= dmg
	health_changed.emit(maxf(health, 0.0), max_health)
	if health <= 0.0:
		health = 0.0
		can_control = false
		Sfx.play("player_die", -4.0)
		died.emit()
	else:
		Sfx.play("hurt", -12.0, 1.0 + randf_range(-0.07, 0.07))


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
	ammo = clampi(ammo, 0, mag_size)
	_mag_left[weapon_index] = ammo
	health_changed.emit(health, max_health)
	ammo_changed.emit(ammo, mag_size)


## 供外部（HUD）读取当前武器概况
func weapon_summary() -> String:
	var w := _cur()
	var s := "伤害 %.0f  射速 %.1f/s  弹匣 %d" % [weapon_damage, fire_rate, mag_size]
	if pellets > 1:
		s += "  x%d" % pellets
	if crit_chance > 0.0:
		s += "  暴击 %d%%" % roundi(crit_chance * 100.0)
	if pierce_bonus > 0:
		s += "  穿透 %d" % pierce_bonus
	return s

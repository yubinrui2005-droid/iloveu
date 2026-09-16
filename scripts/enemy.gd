extends CharacterBody3D
class_name Enemy
## 敌人：直线追击玩家 + 接触伤害。
## 三种类型通过 setup() 配置，数值随波次成长（肉鸽常见的「难度爬坡」）。

signal died(enemy: Enemy)

enum Kind { GRUNT, RUNNER, TANK }

const GRAVITY := 24.0

var kind: Kind = Kind.GRUNT
var max_health := 60.0
var health := 60.0
var move_speed := 3.2
var contact_damage := 9.0
var attack_interval := 0.9

var target: Node3D = null
var is_dead := false

var _attack_timer := 0.0
var _flash := 0.0
var _final_scale := Vector3.ONE
var _base_color := Color(0.78, 0.24, 0.26)
var _mat: StandardMaterial3D = null
var _model: Node3D = null


func _ready() -> void:
	_model = get_node_or_null("Model")
	var mesh := get_node_or_null("Model/Mesh") as MeshInstance3D
	if mesh != null:
		var src := mesh.get_surface_override_material(0)
		if src != null:
			_mat = src.duplicate() as StandardMaterial3D
			mesh.set_surface_override_material(0, _mat)
			_base_color = _mat.albedo_color


## 由关卡管理器调用：配置种类、强度，并播放出场动画
func setup(p_kind: int, wave: int) -> void:
	kind = p_kind
	var hp_scale := 1.0 + float(wave - 1) * 0.19
	var dmg_scale := 1.0 + float(wave - 1) * 0.10

	match kind:
		Kind.GRUNT:
			max_health = 55.0 * hp_scale
			move_speed = 3.3 + float(wave) * 0.06
			contact_damage = 9.0 * dmg_scale
			attack_interval = 0.9
			_final_scale = Vector3.ONE
			_tint(Color(0.78, 0.24, 0.26))            # 红：普通
		Kind.RUNNER:
			max_health = 32.0 * hp_scale
			move_speed = 5.4 + float(wave) * 0.10
			contact_damage = 7.0 * dmg_scale
			attack_interval = 0.75
			_final_scale = Vector3(0.82, 0.82, 0.82)
			_tint(Color(0.88, 0.62, 0.18))            # 黄：冲锋
		Kind.TANK:
			max_health = 150.0 * hp_scale
			move_speed = 2.1 + float(wave) * 0.04
			contact_damage = 17.0 * dmg_scale
			attack_interval = 1.25
			_final_scale = Vector3(1.25, 1.25, 1.25)
			_tint(Color(0.42, 0.36, 0.72))            # 紫：重装

	health = max_health
	scale = _final_scale * 0.12
	var tw := create_tween()
	tw.tween_property(self, "scale", _final_scale, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _tint(c: Color) -> void:
	_base_color = c
	if _mat != null:
		_mat.albedo_color = c


func _physics_process(delta: float) -> void:
	if is_dead or target == null:
		return

	# 受击白闪衰减
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 9.0, 0.0)
		if _mat != null:
			_mat.albedo_color = _base_color.lerp(Color(1.5, 1.5, 1.5), _flash * 0.85)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	var to_target := target.global_position - global_position
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var dist := flat.length()
	var dir := Vector3.ZERO
	if dist > 0.05:
		dir = flat / dist

	# 简易避障：前方有墙就沿着法线蹭过去，避免卡死在柱子上
	if dir != Vector3.ZERO:
		var space := get_world_3d().direct_space_state
		var from := global_position + Vector3.UP * 0.9
		var query := PhysicsRayQueryParameters3D.create(from, from + dir * 1.5, 1, [get_rid()])
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			var normal: Vector3 = hit["normal"]
			normal.y = 0.0
			if normal.length() > 0.01:
				dir = (dir + normal.normalized() * 1.6).normalized()

	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed
	move_and_slide()

	# 朝向玩家（只转表现层，不影响碰撞与移动方向）
	if _model != null and dir != Vector3.ZERO:
		var yaw := atan2(-dir.x, -dir.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, yaw, clampf(delta * 8.0, 0.0, 1.0))

	# 接触伤害
	_attack_timer -= delta
	if dist < 1.7 and _attack_timer <= 0.0:
		_attack_timer = attack_interval
		if target.has_method("take_damage"):
			target.take_damage(contact_damage)


func take_damage(amount: float) -> void:
	if is_dead:
		return
	health -= amount
	_flash = 1.0
	if health <= 0.0:
		_die()
		return
	# 命中回弹感：短暂放大
	var s := scale
	scale = s * 1.08
	var pop := create_tween()
	pop.tween_property(self, "scale", s, 0.08)


func _die() -> void:
	is_dead = true
	set_physics_process(false)
	velocity = Vector3.ZERO
	if _mat != null:
		_mat.albedo_color = _base_color.lerp(Color(1.6, 1.6, 1.6), 0.5)
	var s0 := scale
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "scale", Vector3(s0.x * 1.4, s0.y * 0.12, s0.z * 1.4), 0.18)
	tw.tween_property(self, "rotation:y", rotation.y + PI * 0.5, 0.18)
	tw.chain().tween_callback(func() -> void:
		died.emit(self)
		queue_free()
	)

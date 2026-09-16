extends Node3D
class_name Projectile
## Boss 弹幕。
##
## 刻意不用 RigidBody / Area3D：每帧从「上一帧位置 → 新位置」打一条射线，
## 自己判断有没有打中。这样既不会因为速度过快而穿透目标，
## 也不会被物理引擎的固定步长搞出抖动，开销还几乎为零。

var speed := 17.0
var damage := 12.0
var life := 5.0

var _dir := Vector3.FORWARD
var _dead := false


func _ready() -> void:
	add_to_group("projectile")


func setup(from: Vector3, dir: Vector3, p_damage: float, p_speed: float) -> void:
	global_position = from
	_dir = dir.normalized()
	damage = p_damage
	speed = p_speed


func _physics_process(delta: float) -> void:
	if _dead:
		return
	life -= delta
	if life <= 0.0:
		_burst()
		return

	var from := global_position
	var to := from + _dir * speed * delta
	var space := get_world_3d().direct_space_state
	# 层 1 = 场景几何体，层 2 = 玩家
	var query := PhysicsRayQueryParameters3D.create(from, to, 1 | 2)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		global_position = to
		return

	var collider = hit.get("collider")
	if collider != null and collider.has_method("take_damage"):
		collider.take_damage(damage)
	global_position = hit["position"]
	_burst()


func _burst() -> void:
	_dead = true
	var root := get_tree().current_scene
	if root != null:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.4
		sm.height = 0.8
		mi.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(2.0, 0.75, 1.4)
		mi.material_override = mat
		root.add_child(mi)
		mi.global_position = global_position
		var tw := mi.create_tween()
		tw.tween_property(mi, "scale", Vector3.ONE * 2.2, 0.13)
		tw.tween_callback(mi.queue_free)
	queue_free()

class_name WeaponData
extends Resource
## 单把武器的数值定义。
##
## 这是一个纯数据 Resource：把它当成"一张配置卡"。
## 想加第五把枪？在 weapons.gd 里照着现有几把再写一个 make() 就行，
## player.gd 完全不用改。
##
## 注意：这里的数值是「基础值」。玩家的强化（upgrades.gd）不改这些数字，
## 而是改 player.gd 里的乘数（dmg_mult / rate_mult / ...），
## 所以切枪时强化效果对每把枪都仍然生效 —— 这是武器 Resource 化的关键。

@export var id := "rifle"
@export var display_name := "武器"
@export var short_name := "枪"
@export var sfx := "gun_rifle"

@export_group("伤害")
@export var damage := 18.0
@export var fire_rate := 7.5          ## 每秒射击次数
@export var pellets := 1              ## 单次射击的弹丸数（霰弹枪靠它）
@export var spread_deg := 2.0         ## 散布半角（度）
@export var max_range := 90.0

@export_group("弹药")
@export var mag_size := 24
@export var reload_time := 1.2
@export var automatic := true         ## 按住是否连发

@export_group("手感")
@export var recoil_kick := 0.055      ## 枪身后座位移
@export var recoil_pitch := 0.55      ## 抬枪角度（度）

@export_group("解锁与外观")
@export var unlock_wave := 1          ## 第几波解锁
@export var body_size := Vector3(0.05, 0.06, 0.30)
@export var grip_size := Vector3(0.045, 0.10, 0.06)
@export var color := Color(0.26, 0.27, 0.31)


static func make(d: Dictionary) -> WeaponData:
	var w := WeaponData.new()
	for k in d:
		w.set(k, d[k])
	return w


## 一句话描述，给 HUD 用
func summary() -> String:
	var s := "伤害 %.0f · 射速 %.1f/s · 弹匣 %d" % [damage, fire_rate, mag_size]
	if pellets > 1:
		s += " · %d 弹丸" % pellets
	return s

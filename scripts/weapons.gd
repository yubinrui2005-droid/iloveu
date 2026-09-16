class_name Weapons
extends RefCounted
## 武器库。全部是代码里的静态数据，没有 .tres 文件要维护。
##
## 加一把新枪的完整步骤：
##   1. 在下面写一个 _xxx() 返回 WeaponData.make({...})；
##   2. 加进 all() 的数组；
##   3. 没了。player.gd / HUD 会自动认得它。

## 数组顺序 = 玩家按 1/2/3/4 的顺序
static func all() -> Array[WeaponData]:
	var out: Array[WeaponData] = []
	out.append(rifle())
	out.append(smg())
	out.append(shotgun())
	out.append(sniper())
	return out


## 1 号位 · 突击步枪：全能起手枪
static func rifle() -> WeaponData:
	return WeaponData.make({
		"id": "rifle",
		"display_name": "突击步枪",
		"short_name": "步枪",
		"sfx": "gun_rifle",
		"damage": 18.0,
		"fire_rate": 7.5,
		"pellets": 1,
		"spread_deg": 2.0,
		"max_range": 90.0,
		"mag_size": 24,
		"reload_time": 1.2,
		"automatic": true,
		"recoil_kick": 0.055,
		"recoil_pitch": 0.55,
		"unlock_wave": 1,
		"body_size": Vector3(0.050, 0.062, 0.30),
		"grip_size": Vector3(0.045, 0.100, 0.06),
		"color": Color(0.26, 0.27, 0.31),
	})


## 2 号位 · 冲锋枪：泼水，近中距离
static func smg() -> WeaponData:
	return WeaponData.make({
		"id": "smg",
		"display_name": "冲锋枪",
		"short_name": "冲锋枪",
		"sfx": "gun_smg",
		"damage": 8.5,
		"fire_rate": 14.0,
		"pellets": 1,
		"spread_deg": 4.5,
		"max_range": 62.0,
		"mag_size": 40,
		"reload_time": 1.4,
		"automatic": true,
		"recoil_kick": 0.032,
		"recoil_pitch": 0.32,
		"unlock_wave": 2,
		"body_size": Vector3(0.050, 0.070, 0.21),
		"grip_size": Vector3(0.045, 0.115, 0.06),
		"color": Color(0.34, 0.31, 0.24),
	})


## 3 号位 · 霰弹枪：贴脸神器，8 弹丸
static func shotgun() -> WeaponData:
	return WeaponData.make({
		"id": "shotgun",
		"display_name": "霰弹枪",
		"short_name": "霰弹枪",
		"sfx": "gun_shotgun",
		"damage": 9.5,
		"fire_rate": 1.35,
		"pellets": 8,
		"spread_deg": 7.5,
		"max_range": 34.0,
		"mag_size": 6,
		"reload_time": 1.9,
		"automatic": false,
		"recoil_kick": 0.14,
		"recoil_pitch": 1.6,
		"unlock_wave": 3,
		"body_size": Vector3(0.062, 0.075, 0.38),
		"grip_size": Vector3(0.050, 0.105, 0.07),
		"color": Color(0.32, 0.23, 0.16),
	})


## 4 号位 · 狙击步枪：单发高伤，几乎无散布
static func sniper() -> WeaponData:
	return WeaponData.make({
		"id": "sniper",
		"display_name": "狙击步枪",
		"short_name": "狙击枪",
		"sfx": "gun_sniper",
		"damage": 95.0,
		"fire_rate": 0.85,
		"pellets": 1,
		"spread_deg": 0.25,
		"max_range": 200.0,
		"mag_size": 5,
		"reload_time": 2.4,
		"automatic": false,
		"recoil_kick": 0.22,
		"recoil_pitch": 2.4,
		"unlock_wave": 5,
		"body_size": Vector3(0.045, 0.058, 0.46),
		"grip_size": Vector3(0.042, 0.095, 0.06),
		"color": Color(0.16, 0.21, 0.19),
	})

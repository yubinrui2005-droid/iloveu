class_name Upgrades
extends RefCounted
## 肉鸽强化词条池。
##
## 想加新词条？两步：
##   1. 往 DATA 里加一条字典（id 唯一）；
##   2. 在 apply() 的 match 里加一个分支，直接改 player 的数值。
## 每层效果是乘算还是加算由你自己决定，这里采用了「乘算保证收益递减、加算保证手感」的混合策略。

const DATA := [
	{"id": "damage",    "name": "穿甲弹头",   "desc": "子弹伤害 +25%",          "rarity": 1, "max": 8},
	{"id": "firerate",  "name": "竞速扳机",   "desc": "射速 +20%",              "rarity": 1, "max": 8},
	{"id": "mag",       "name": "扩容弹匣",   "desc": "弹匣容量 +30%",          "rarity": 1, "max": 6},
	{"id": "reload",    "name": "战术换弹",   "desc": "换弹时间 -25%",          "rarity": 1, "max": 5},
	{"id": "spread",    "name": "稳定枪管",   "desc": "散布 -40%",              "rarity": 2, "max": 4},
	{"id": "pellets",   "name": "多重射击",   "desc": "每次射击弹丸 +1",        "rarity": 3, "max": 5},
	{"id": "speed",     "name": "轻型战靴",   "desc": "移动速度 +12%",          "rarity": 1, "max": 6},
	{"id": "jump",      "name": "弹跳肌腱",   "desc": "跳跃高度 +15%",          "rarity": 1, "max": 4},
	{"id": "maxhp",     "name": "强化外骨骼", "desc": "生命上限 +25 并立即回满该值", "rarity": 2, "max": 8},
	{"id": "lifesteal", "name": "吸血弹",     "desc": "每次命中回复 0.6 点生命", "rarity": 2, "max": 5},
	{"id": "crit",      "name": "弱点瞄准镜", "desc": "暴击率 +12%（暴击双倍伤害）", "rarity": 2, "max": 6},
	{"id": "killheal",  "name": "猎杀本能",   "desc": "每次击杀回复 3 点生命",   "rarity": 2, "max": 5},
]


## 随机抽 count 个「还没叠满」的词条
static func roll(count: int, taken: Dictionary) -> Array:
	var candidates := []
	for entry in DATA:
		var id: String = entry["id"]
		var stacks: int = int(taken.get(id, 0))
		if stacks < int(entry["max"]):
			candidates.append(entry)
	candidates.shuffle()

	var picked := []
	for i in mini(count, candidates.size()):
		picked.append(candidates[i])
	return picked


## 把词条效果作用到玩家身上。返回一份「已生效」的说明文本。
static func apply(player: Node, id: String) -> String:
	var title := ""
	match id:
		"damage":
			player.weapon_damage = player.weapon_damage * 1.25
			title = "穿甲弹头"
		"firerate":
			player.fire_rate = player.fire_rate * 1.20
			title = "竞速扳机"
		"mag":
			player.mag_size = maxi(1, int(round(player.mag_size * 1.3)))
			title = "扩容弹匣"
		"reload":
			player.reload_time = maxf(0.35, player.reload_time * 0.75)
			title = "战术换弹"
		"spread":
			player.spread_deg = maxf(0.2, player.spread_deg * 0.6)
			title = "稳定枪管"
		"pellets":
			player.pellets = player.pellets + 1
			title = "多重射击"
		"speed":
			player.base_speed = player.base_speed * 1.12
			title = "轻型战靴"
		"jump":
			player.jump_velocity = player.jump_velocity * 1.15
			title = "弹跳肌腱"
		"maxhp":
			player.max_health = player.max_health + 25.0
			player.health = player.health + 25.0
			title = "强化外骨骼"
		"lifesteal":
			player.lifesteal = player.lifesteal + 0.6
			title = "吸血弹"
		"crit":
			player.crit_chance = minf(1.0, player.crit_chance + 0.12)
			title = "弱点瞄准镜"
		"killheal":
			player.kill_heal = player.kill_heal + 3.0
			title = "猎杀本能"

	player.upgrade_counts[id] = int(player.upgrade_counts.get(id, 0)) + 1
	if player.has_method("sync_stats"):
		player.sync_stats()
	return title

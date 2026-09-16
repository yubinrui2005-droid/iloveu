class_name Upgrades
extends RefCounted
## 肉鸽强化词条池。
##
## 想加新词条？两步：
##   1. 往 DATA 里加一条字典（id 唯一）；
##   2. 在 apply() 的 match 里加一个分支。
##
## 关键约定：apply() 只改 player 的**乘数**，绝不直接改武器数值。
## 因为武器是 Resource（weapons.gd），改了它就意味着"只强化当前这把枪"，
## 切枪后强化就丢了 —— 而乘数对四把枪同时生效，这才符合肉鸽的预期。
##
## 每层是乘算还是加算由你决定，这里采用「乘算保证收益递减、加算保证手感」的混合策略。

const DATA := [
	# ---- 输出 ----
	{"id": "damage",    "name": "穿甲弹头",   "desc": "全部武器伤害 +25%",       "rarity": 1, "max": 8},
	{"id": "firerate",  "name": "竞速扳机",   "desc": "全部武器射速 +20%",       "rarity": 1, "max": 8},
	{"id": "crit",      "name": "弱点瞄准镜", "desc": "暴击率 +12%（暴击双倍伤害）", "rarity": 2, "max": 6},
	{"id": "pellets",   "name": "多重射击",   "desc": "每次射击弹丸 +1",          "rarity": 3, "max": 5},
	{"id": "pierce",    "name": "穿透弹",     "desc": "子弹可多穿透 1 个敌人",    "rarity": 3, "max": 3},
	{"id": "spread",    "name": "稳定枪管",   "desc": "散布 -40%",               "rarity": 2, "max": 4},

	# ---- 弹药 ----
	{"id": "mag",       "name": "扩容弹匣",   "desc": "弹匣容量 +30%",           "rarity": 1, "max": 6},
	{"id": "reload",    "name": "战术换弹",   "desc": "换弹时间 -25%",           "rarity": 1, "max": 5},

	# ---- 生存 ----
	{"id": "maxhp",     "name": "强化外骨骼", "desc": "生命上限 +25 并立即回满该值", "rarity": 2, "max": 8},
	{"id": "armor",     "name": "复合装甲",   "desc": "受到伤害 -12%",           "rarity": 2, "max": 4},
	{"id": "lifesteal", "name": "吸血弹",     "desc": "每次命中回复 0.6 点生命", "rarity": 2, "max": 5},
	{"id": "killheal",  "name": "猎杀本能",   "desc": "每次击杀回复 3 点生命",   "rarity": 2, "max": 5},

	# ---- 机动 ----
	{"id": "speed",     "name": "轻型战靴",   "desc": "移动速度 +12%",           "rarity": 1, "max": 6},
	{"id": "jump",      "name": "弹跳肌腱",   "desc": "跳跃高度 +15%",           "rarity": 1, "max": 4},
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
			player.dmg_mult *= 1.25
			title = "穿甲弹头"
		"firerate":
			player.rate_mult *= 1.20
			title = "竞速扳机"
		"crit":
			player.crit_chance = minf(1.0, player.crit_chance + 0.12)
			title = "弱点瞄准镜"
		"pellets":
			player.pellets_bonus += 1
			title = "多重射击"
		"pierce":
			player.pierce_bonus += 1
			title = "穿透弹"
		"spread":
			player.spread_mult = maxf(0.08, player.spread_mult * 0.6)
			title = "稳定枪管"
		"mag":
			player.mag_mult *= 1.30
			title = "扩容弹匣"
		"reload":
			player.reload_mult = maxf(0.18, player.reload_mult * 0.75)
			title = "战术换弹"
		"maxhp":
			player.max_health += 25.0
			player.health += 25.0
			title = "强化外骨骼"
		"armor":
			player.damage_reduction = minf(0.6, player.damage_reduction + 0.12)
			title = "复合装甲"
		"lifesteal":
			player.lifesteal += 0.6
			title = "吸血弹"
		"killheal":
			player.kill_heal += 3.0
			title = "猎杀本能"
		"speed":
			player.base_speed *= 1.12
			title = "轻型战靴"
		"jump":
			player.jump_velocity *= 1.15
			title = "弹跳肌腱"

	player.upgrade_counts[id] = int(player.upgrade_counts.get(id, 0)) + 1
	if player.has_method("sync_stats"):
		player.sync_stats()
	return title

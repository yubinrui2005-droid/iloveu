class_name SaveData
extends RefCounted
## 存档 / 排行榜。用 FileAccess 读写 user:// 下的一个 JSON 文件。
##
## user:// 在桌面端是 %APPDATA%\Godot\app_userdata\<项目名>\，
## 在 Web 导出里映射到浏览器的 IndexedDB —— 同一个文件路径两端都能用，
## 所以线上玩的人也能留下自己的成绩。

const DEFAULT_PATH := "user://rogue_fps_save.json"
const MAX_ENTRIES := 10

## 当前存档文件。可切换（冒烟测试用它写到另一个文件，免得污染真实排行榜）
static var _path := DEFAULT_PATH


static func set_profile(p: String) -> void:
	_path = p


static func _default() -> Dictionary:
	return {
		"version": 1,
		"runs": 0,              # 累计游玩局数
		"entries": [],          # 排行榜（已按成绩排好序）
		"best": {},             # entries[0] 的快捷引用
	}


static func load_all() -> Dictionary:
	if not FileAccess.file_exists(_path):
		return _default()
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return _default()
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return _default()
	var d: Dictionary = parsed
	if typeof(d.get("entries")) != TYPE_ARRAY:
		d["entries"] = []
	return d


static func save_all(d: Dictionary) -> void:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("[save] 无法写入 %s" % _path)
		return
	f.store_string(JSON.stringify(d, "\t"))
	f.close()


static func best() -> Dictionary:
	var d := load_all()
	var e: Array = d.get("entries", [])
	return e[0] if e.size() > 0 else {}


## 记录一局成绩。返回 { rank, is_best, entries, best, runs }
## rank = 0 表示没进前 MAX_ENTRIES。
static func submit_run(run: Dictionary) -> Dictionary:
	var d := load_all()
	d["runs"] = int(d.get("runs", 0)) + 1
	run["id"] = d["runs"]                       # 单调递增，用来在排序后找回自己
	run["date"] = Time.get_datetime_string_from_system(false, true)

	var entries: Array = d.get("entries", [])
	entries.append(run)
	entries.sort_custom(_better)
	if entries.size() > MAX_ENTRIES:
		entries.resize(MAX_ENTRIES)

	var rank := 0
	for i in entries.size():
		if int(entries[i].get("id", -1)) == int(run["id"]):
			rank = i + 1
			break

	d["entries"] = entries
	d["best"] = entries[0] if entries.size() > 0 else {}
	save_all(d)
	return {
		"rank": rank,
		"is_best": rank == 1,
		"entries": entries,
		"best": d["best"],
		"runs": d["runs"],
	}


static func clear() -> void:
	DirAccess.remove_absolute(_path)


## 排序规则：波次 > 击杀 > 用时（越短越好）
static func _better(a, b) -> bool:
	var wa := int(a.get("wave", 0))
	var wb := int(b.get("wave", 0))
	if wa != wb:
		return wa > wb
	var ka := int(a.get("kills", 0))
	var kb := int(b.get("kills", 0))
	if ka != kb:
		return ka > kb
	return float(a.get("time", 0.0)) < float(b.get("time", 0.0))

class_name Sfx
extends Node3D
## 程序化音效：整个游戏没有一个音频素材文件，所有声音都在启动时用代码合成。
##
## 原理：Godot 的 AudioStreamWAV 允许直接塞一段 PCM 采样数据。
## 我们按「低频扫频 + 低通噪声」的配方算出采样点，归一化后编码成 16bit 单声道，
## 就得到一个可播放的音效。想改音色只要调参数，不用去找素材。
##
## 为什么不用 autoload 单例：用 `godot --script` 跑冒烟测试时，autoload 的加载时机
## 并不保证（主循环被脚本接管）。用静态入口 + null 检查更稳，
## 也不会因为场景 reload 而指向已经释放的节点。

const RATE := 22050          ## 采样率。够用，且内存占用只有 44.1k 的一半
const VOICES := 16           ## 非定位音源池（枪声、UI）
const VOICES_3D := 10        ## 定位音源池（敌人死亡、爆炸）

## 波形枚举
const WAVE_SINE := 0
const WAVE_SAW := 1
const WAVE_SQUARE := 2

static var _inst: Sfx = null

var enabled := true
## 整体混音余量。每个音效在 _encode() 里都归一化到 0.9 峰值（单听才够劲），
## 但枪声是每 0.13s 一发、命中/死亡还会往上叠，两个音源重合就正好冲破 0 dBFS。
## 这里统一压 6.5dB：0.9 × 0.473 ≈ 0.43，两个同时响也才 0.85，不会削顶。
## 代价只是把系统音量拧大一点，换来的是枪战时不再有"噼"的破音。
var master_db := -6.5
var _bank: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
var _voices3d: Array[AudioStreamPlayer3D] = []
var _next := 0
var _next3d := 0


# ============================================================
#  对外入口（静态，调用点不需要判空）
# ============================================================
static func create(parent: Node) -> Sfx:
	if _inst != null and is_instance_valid(_inst):
		return _inst
	var s := Sfx.new()
	s.name = "Sfx"
	parent.add_child(s)
	return s


static func play(sound: String, volume_db := 0.0, pitch := 1.0) -> void:
	if _inst != null and is_instance_valid(_inst):
		_inst._play(sound, volume_db, pitch)


static func play_at(sound: String, pos: Vector3, volume_db := 0.0, pitch := 1.0) -> void:
	if _inst != null and is_instance_valid(_inst):
		_inst._play_at(sound, pos, volume_db, pitch)


static func available() -> bool:
	return _inst != null and is_instance_valid(_inst)


# ============================================================
#  生命周期
# ============================================================
func _ready() -> void:
	_inst = self
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = &"Master"
		add_child(p)
		_voices.append(p)
	for i in VOICES_3D:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 9.0
		p.max_distance = 60.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_voices3d.append(p)
	_build_bank()
	_setup_master_bus()


## 给 Master 总线挂一条「压缩 + 限幅」链。
##
## 为什么需要：_encode() 把每个音效都归一化到 0.9 峰值（单个听起来才够响），
## 但枪声 0.13s 一发、命中/死亡还会往上叠，几个音源一重合就冲破 0 dBFS，
## 听感就是枪战时"噼"的破音。实测（把游戏跑一遍、录下 Master 输出再统计）
## 无余量时约有 1.35% 的采样被削平，属于听得出来的失真。
## 所以先用压缩器把密集瞬态压下来，再用硬限幅器兜底，同时 master_db 再留 6.5dB 余量。
##
## 幂等：每次重载房间都会重新 create() 一个 Sfx，这里按效果器名字查重，
## 避免在 Master 总线上叠加一串效果器。
func _setup_master_bus() -> void:
	var idx := AudioServer.get_bus_index(&"Master")
	if idx < 0:
		return
	for i in AudioServer.get_bus_effect_count(idx):
		var existing := AudioServer.get_bus_effect(idx, i)
		if existing != null and existing.resource_name == "sfx_glue":
			return  # 已经装过了

	var comp := AudioEffectCompressor.new()
	comp.resource_name = "sfx_glue"
	comp.threshold = -15.0      # 超过 -15dB 开始压
	comp.ratio = 3.5
	comp.attack_us = 2000.0     # 2ms：短到能留住枪声的瞬态，又来得及压住叠加
	comp.release_ms = 150.0
	comp.gain = 0.0             # 不做补偿增益，宁可整体小一点也不破音
	AudioServer.add_bus_effect(idx, comp)

	if ClassDB.class_exists("AudioEffectHardLimiter"):
		var lim := ClassDB.instantiate("AudioEffectHardLimiter") as AudioEffect
		if lim != null:
			lim.resource_name = "sfx_ceiling"
			lim.set("ceiling_db", -0.8)
			lim.set("pre_gain_db", 0.0)
			AudioServer.add_bus_effect(idx, lim)


func _exit_tree() -> void:
	if _inst == self:
		_inst = null


func _play(sound: String, volume_db: float, pitch: float) -> void:
	if not enabled:
		return
	var stream: AudioStream = _bank.get(sound)
	if stream == null:
		return
	var p := _voices[_next]
	_next = (_next + 1) % _voices.size()
	p.stream = stream
	p.volume_db = volume_db + master_db
	p.pitch_scale = clampf(pitch, 0.2, 4.0)
	p.play()


func _play_at(sound: String, pos: Vector3, volume_db: float, pitch: float) -> void:
	if not enabled:
		return
	var stream: AudioStream = _bank.get(sound)
	if stream == null:
		return
	var p := _voices3d[_next3d]
	_next3d = (_next3d + 1) % _voices3d.size()
	p.stream = stream
	p.volume_db = volume_db + master_db
	p.pitch_scale = clampf(pitch, 0.2, 4.0)
	p.global_position = pos
	p.play()


# ============================================================
#  音色表
# ============================================================
func _build_bank() -> void:
	_bank.clear()

	# ---- 枪声：四把枪音色各不相同 ----
	_bank["gun_rifle"] = _impact(0.15, 340.0, 60.0, 46.0, 0.55, 0.42, 11)
	_bank["gun_smg"] = _impact(0.085, 430.0, 150.0, 68.0, 0.50, 0.55, 12)
	_bank["gun_shotgun"] = _impact(0.34, 190.0, 34.0, 20.0, 0.70, 0.22, 13, 0.10)
	_bank["gun_sniper"] = _impact(0.46, 520.0, 48.0, 15.0, 0.50, 0.50, 14, 0.14)
	_bank["dry"] = _impact(0.07, 900.0, 500.0, 90.0, 0.80, 0.85, 15)

	# ---- 命中 ----
	_bank["hit"] = _impact(0.075, 1100.0, 520.0, 78.0, 0.35, 0.75, 21)
	_bank["crit"] = _impact(0.20, 1500.0, 260.0, 30.0, 0.30, 0.80, 22)

	# ---- 角色 ----
	_bank["enemy_die"] = _tone(0.30, 420.0, 60.0, 11.0, WAVE_SAW, 31, 0.25)
	_bank["hurt"] = _tone(0.42, 170.0, 62.0, 9.0, WAVE_SINE, 32, 0.35)
	_bank["player_die"] = _tone(1.05, 300.0, 42.0, 3.4, WAVE_SAW, 33, 0.18)

	# ---- 交互 / 反馈 ----
	_bank["reload"] = _reload_sound()
	_bank["swap"] = _impact(0.11, 760.0, 380.0, 46.0, 0.60, 0.70, 41)
	_bank["denied"] = _tone(0.16, 190.0, 140.0, 24.0, WAVE_SQUARE, 42)
	_bank["pickup"] = _sequence([660.0, 880.0, 1320.0], 0.075, 16.0)
	_bank["room_clear"] = _sequence([523.0, 659.0, 784.0, 1046.0], 0.085, 11.0)
	_bank["level_up"] = _sequence([784.0, 988.0, 1175.0], 0.08, 14.0)

	# ---- Boss ----
	_bank["boss_spawn"] = _rumble(1.5, 62.0, 30.0, 1.6, 51)
	_bank["boss_die"] = _rumble(1.8, 200.0, 26.0, 1.5, 52)
	_bank["boss_shot"] = _impact(0.26, 260.0, 90.0, 22.0, 0.50, 0.35, 53)

	# ---- 场景 ----
	_bank["door_open"] = _tone(0.70, 240.0, 620.0, 4.5, WAVE_SINE, 61)


# ============================================================
#  合成器
# ============================================================
## 把浮点采样归一化后编码成 16bit 单声道 WAV
func _encode(samples: PackedFloat32Array, gain := 0.9) -> AudioStreamWAV:
	var peak := 0.0
	for v in samples:
		peak = maxf(peak, absf(v))
	var k := (gain / peak) if peak > 0.0001 else 0.0
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i] * k, -1.0, 1.0) * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	return wav


## 冲击类：低频扫频（"砰"）+ 低通白噪声（"啪"）
## f0/f1 起止频率、decay 包络衰减速度、noise_amt 噪声占比、lp 噪声低通系数（越大越闷）
func _impact(dur: float, f0: float, f1: float, decay: float,
		noise_amt: float, lp: float, seed_v: int, tail := 0.0) -> AudioStreamWAV:
	var n := maxi(int(dur * RATE), 8)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var lp_state := 0.0
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var p := float(i) / float(n)
		var f := lerpf(f0, f1, p * p)          # 二次扫频，起音更"炸"
		phase += TAU * f / RATE
		lp_state += (rng.randf_range(-1.0, 1.0) - lp_state) * lp
		var env := exp(-t * decay)
		if tail > 0.0:
			env += exp(-t * decay * 0.10) * tail   # 拖尾：远处回荡的感觉
		var atk := minf(t / 0.0012, 1.0)           # 起音斜坡，避免爆音
		buf[i] = (sin(phase) * (1.0 - noise_amt) + lp_state * 3.0 * noise_amt) * env * atk
	return _encode(buf)


## 音调类：扫频振荡器，可选叠一点噪声
func _tone(dur: float, f0: float, f1: float, decay: float, wave: int,
		seed_v: int, noise_amt := 0.0) -> AudioStreamWAV:
	var n := maxi(int(dur * RATE), 8)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var phase := 0.0
	var lp_state := 0.0
	for i in n:
		var t := float(i) / RATE
		var p := float(i) / float(n)
		phase += TAU * lerpf(f0, f1, p) / RATE
		var v := 0.0
		match wave:
			WAVE_SAW:
				v = fposmod(phase / TAU, 1.0) * 2.0 - 1.0
			WAVE_SQUARE:
				v = 1.0 if fposmod(phase / TAU, 1.0) < 0.5 else -1.0
			_:
				v = sin(phase)
		lp_state += (rng.randf_range(-1.0, 1.0) - lp_state) * 0.35
		buf[i] = (v * (1.0 - noise_amt) + lp_state * 2.0 * noise_amt) \
				* exp(-t * decay) * minf(t / 0.004, 1.0)
	return _encode(buf)


## 低频轰鸣：带 7.5Hz 颤音，用在 Boss 出场 / 死亡
func _rumble(dur: float, f0: float, f1: float, decay: float, seed_v: int) -> AudioStreamWAV:
	var n := maxi(int(dur * RATE), 8)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var phase := 0.0
	var lp_state := 0.0
	for i in n:
		var t := float(i) / RATE
		var p := float(i) / float(n)
		phase += TAU * lerpf(f0, f1, p) / RATE
		lp_state += (rng.randf_range(-1.0, 1.0) - lp_state) * 0.08
		var trem := 0.72 + 0.28 * sin(TAU * 7.5 * t)
		buf[i] = (sin(phase) * 0.85 + lp_state * 2.2) * trem \
				* exp(-t * decay) * minf(t / 0.02, 1.0)
	return _encode(buf)


## 音符序列：用于"强化到手""清空一间"这类上行提示音
func _sequence(freqs: Array, note_len: float, decay: float, wave := WAVE_SINE) -> AudioStreamWAV:
	var dur := note_len * float(freqs.size()) + 0.20
	var n := int(dur * RATE)
	var buf := PackedFloat32Array()
	buf.resize(n)
	for k in freqs.size():
		var start := int(float(k) * note_len * RATE)
		var phase := 0.0
		for i in range(start, n):
			var t := float(i - start) / RATE
			phase += TAU * float(freqs[k]) / RATE
			var v := sin(phase) if wave == WAVE_SINE else fposmod(phase / TAU, 1.0) * 2.0 - 1.0
			buf[i] += v * exp(-t * decay) * minf(t / 0.004, 1.0) * 0.5
	return _encode(buf)


## 换弹：三声机械响（退匣 / 上匣 / 拉栓）
func _reload_sound() -> AudioStreamWAV:
	var n := int(0.9 * RATE)
	var buf := PackedFloat32Array()
	buf.resize(n)
	_click_into(buf, 0.00, 1500.0, 120.0, 71)
	_click_into(buf, 0.34, 820.0, 95.0, 72)
	_click_into(buf, 0.72, 2100.0, 150.0, 73)
	return _encode(buf)


func _click_into(buf: PackedFloat32Array, at_sec: float, freq: float,
		decay: float, seed_v: int) -> void:
	var start := int(at_sec * RATE)
	if start >= buf.size():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var phase := 0.0
	var lp := 0.0
	for i in range(start, buf.size()):
		var t := float(i - start) / RATE
		phase += TAU * freq / RATE
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.5
		buf[i] += (sin(phase) * 0.6 + lp * 1.6) * exp(-t * decay) * minf(t / 0.0008, 1.0)

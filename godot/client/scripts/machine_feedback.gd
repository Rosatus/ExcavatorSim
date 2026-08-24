class_name MachineFeedback
extends Node

const MIX_RATE := 11025.0
const LOOP_NAMES := ["engine", "tracks", "work"]
const PROFILE_BUDGETS := {
	"low": {"loops": 1, "voices": 2},
	"balanced": {"loops": 3, "voices": 4},
	"high": {"loops": 3, "voices": 6},
}
const EVENT_COOLDOWNS := {"cut": 0.10, "dump": 0.12, "spill": 0.16, "settle": 0.18, "impact": 0.28, "warning": 0.75, "lifecycle": 0.12}

@export var product_session_path := NodePath("../ProductSession")
@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")
@export var chassis_path := NodePath("../ChassisMotionRoot")
@export var visual_quality_path := NodePath("../VisualQualityController")
@export var profile := "balanced"

var _session: ProductSession
var _excavation: ExcavationWorld
var _chassis: TrackedChassisController
var _loops := {}
var _loop_state := {}
var _loop_phase := {}
var _voices: Array[AudioStreamPlayer] = []
var _voice_remaining: Array[float] = []
var _cue_streams := {}
var _cooldowns := {}
var _last_transaction_id := ""
var _last_batch_key := ""
var _generation := -1
var _lifecycle := "stopped"
var _focused := true
var _muted := false
var _last_event := ""
var _event_count := 0
var _noise_state := 0x13579bdf
var _device_available := true


func _ready() -> void:
	_ensure_audio_buses()
	_build_loop_players()
	_build_voice_pool(6)
	_build_cue_streams()
	_session = get_node_or_null(product_session_path) as ProductSession
	_excavation = get_node_or_null(excavation_world_path) as ExcavationWorld
	_chassis = get_node_or_null(chassis_path) as TrackedChassisController
	if _session != null:
		_session.status_changed.connect(_on_session_status)
		_session.model_changed.connect(_on_model_changed)
		_on_session_status(_session.get_status_snapshot())
	var quality := get_node_or_null(visual_quality_path)
	if quality != null and quality.has_method("get_quality_snapshot"):
		profile = String((quality.call("get_quality_snapshot") as Dictionary).get("profile", profile))
	set_quality_profile(profile)
	apply_mix_config()


func _exit_tree() -> void:
	stop_all("teardown")


func _process(_delta: float) -> void:
	_fill_loop_buffers()


func _physics_process(delta: float) -> void:
	_tick_timers(delta)
	if _session == null:
		return
	var session_status := _session.get_status_snapshot()
	var soil_status := _excavation.get_soil_visual_snapshot() if _excavation != null else {}
	var chassis_status := _chassis.get_status_snapshot() if _chassis != null else {}
	_apply_snapshots(session_status, soil_status, chassis_status)


func set_quality_profile(profile_name: String) -> bool:
	if not PROFILE_BUDGETS.has(profile_name):
		return false
	profile = profile_name
	_apply_loop_players()
	return true


func set_muted(value: bool) -> void:
	_muted = value
	for loop_name in _loops:
		(_loops[loop_name] as AudioStreamPlayer).volume_db = -80.0 if _muted else float((_loop_state[loop_name] as Dictionary).get("gain_db", -80.0))
	for voice in _voices:
		voice.volume_db = -80.0 if _muted else -6.0


func is_muted() -> bool:
	return _muted


func apply_mix_config() -> void:
	_set_bus_volume("Master", float(ProjectSettings.get_setting("feedback_audio/master_db", 0.0)))
	_set_bus_volume("Machine", float(ProjectSettings.get_setting("feedback_audio/machine_db", -4.0)))
	_set_bus_volume("Effects", float(ProjectSettings.get_setting("feedback_audio/effects_db", -2.0)))


func stop_all(reason: String = "stop") -> void:
	for loop_name in _loops:
		var player := _loops[loop_name] as AudioStreamPlayer
		player.stop()
		var state := _loop_state[loop_name] as Dictionary
		state["active"] = false
		state["gain_db"] = -80.0
		state["pitch"] = 1.0
		_loop_state[loop_name] = state
	for index in _voices.size():
		_voices[index].stop()
		_voice_remaining[index] = 0.0
	_cooldowns.clear()
	_last_batch_key = ""
	_last_transaction_id = ""
	_last_event = reason


func get_feedback_snapshot() -> Dictionary:
	var active_loops := {}
	var skips := 0
	for loop_name in LOOP_NAMES:
		active_loops[loop_name] = (_loop_state.get(loop_name, {}) as Dictionary).duplicate(true)
		var player := _loops.get(loop_name) as AudioStreamPlayer
		if player != null and player.playing:
			var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
			if playback != null:
				skips += playback.get_skips()
	return {
		"enabled": true,
		"device_available": _device_available,
		"muted": _muted,
		"generation": _generation,
		"lifecycle": _lifecycle,
		"focused": _focused,
		"profile": profile,
		"active_loops": active_loops,
		"active_loop_count": _active_loop_count(),
		"active_one_shots": _active_voice_count(),
		"loop_cap": int((PROFILE_BUDGETS[profile] as Dictionary)["loops"]),
		"voice_cap": int((PROFILE_BUDGETS[profile] as Dictionary)["voices"]),
		"last_event": _last_event,
		"event_count": _event_count,
		"generator_skips": skips,
		"buses": {"master": "Master", "machine": "Machine", "effects": "Effects"},
	}


func apply_snapshots_for_test(session_status: Dictionary, soil_status: Dictionary, chassis_status: Dictionary, delta := 1.0 / 60.0) -> void:
	_tick_timers(delta)
	_apply_snapshots(session_status, soil_status, chassis_status)


func _apply_snapshots(session_status: Dictionary, soil_status: Dictionary, chassis_status: Dictionary) -> void:
	var generation := int(session_status.get("generation", -1))
	var lifecycle := String(session_status.get("lifecycle", "stopped"))
	var focused := bool(session_status.get("focused", true))
	if generation != _generation:
		stop_all("generation_reset")
		_generation = generation
	var lifecycle_changed := lifecycle != _lifecycle
	_lifecycle = lifecycle
	_focused = focused
	if lifecycle != "running" or not focused:
		if _active_loop_count() > 0 or _active_voice_count() > 0:
			stop_all("focus_loss" if not focused else lifecycle)
		return
	if lifecycle_changed:
		_play_cue("lifecycle")
	_update_loop_targets(soil_status, chassis_status)
	_apply_loop_players()
	_consume_events(soil_status, chassis_status)


func _update_loop_targets(soil: Dictionary, chassis: Dictionary) -> void:
	var response := soil.get("digging_response", {}) as Dictionary
	var raw_commands := response.get("raw_commands", Vector4.ZERO) as Vector4
	var work_command := maxf(maxf(absf(raw_commands.x), absf(raw_commands.y)), maxf(absf(raw_commands.z), absf(raw_commands.w)))
	var intensity := clampf(float(response.get("intensity", 0.0)), 0.0, 1.0)
	var left_speed := absf(float(chassis.get("left_speed_mps", chassis.get("left_speed_m_s", 0.0))))
	var right_speed := absf(float(chassis.get("right_speed_mps", chassis.get("right_speed_m_s", 0.0))))
	var track_speed := clampf(maxf(left_speed, right_speed), 0.0, 3.5)
	var slip := clampf(maxf(absf(float(chassis.get("left_slip_ratio", 0.0))), absf(float(chassis.get("right_slip_ratio", 0.0)))), 0.0, 1.0)
	_set_loop_target("engine", true, -20.0 + 5.0 * maxf(work_command, track_speed / 3.5), 0.84 + 0.22 * maxf(work_command, track_speed / 3.5))
	_set_loop_target("tracks", track_speed > 0.05, -25.0 + 10.0 * track_speed / 3.5 + 3.0 * slip, 0.72 + 0.42 * track_speed / 3.5 + 0.12 * slip)
	_set_loop_target("work", work_command > 0.04, -27.0 + 11.0 * work_command + 4.0 * intensity, 0.78 + 0.28 * work_command - 0.08 * intensity)


func _set_loop_target(loop_name: String, active: bool, gain_db: float, pitch: float) -> void:
	var state := _loop_state[loop_name] as Dictionary
	state["active"] = active
	state["gain_db"] = clampf(gain_db, -80.0, -4.0)
	state["pitch"] = clampf(pitch, 0.62, 1.45)
	_loop_state[loop_name] = state


func _apply_loop_players() -> void:
	if _loops.is_empty() or not PROFILE_BUDGETS.has(profile):
		return
	var loop_cap := int((PROFILE_BUDGETS[profile] as Dictionary)["loops"])
	for index in LOOP_NAMES.size():
		var loop_name: String = LOOP_NAMES[index]
		var state := _loop_state[loop_name] as Dictionary
		var allowed := index < loop_cap and bool(state["active"]) and _lifecycle == "running" and _focused
		var player := _loops[loop_name] as AudioStreamPlayer
		if allowed and not player.playing:
			player.play()
		elif not allowed and player.playing:
			player.stop()
		player.volume_db = -80.0 if _muted or not allowed else float(state["gain_db"])
		player.pitch_scale = float(state["pitch"])
		state["active"] = allowed
		_loop_state[loop_name] = state


func _consume_events(soil: Dictionary, chassis: Dictionary) -> void:
	var transaction := soil.get("last_transaction", {}) as Dictionary
	var transaction_id := String(transaction.get("transaction_id", ""))
	if not transaction_id.is_empty() and transaction_id != _last_transaction_id:
		_last_transaction_id = transaction_id
		var kind := String(transaction.get("kind", ""))
		if kind in ["cut", "side_cut", "scrape", "grade"]:
			_play_cue("cut")
		elif kind in ["dump", "spill", "settle"]:
			_play_cue(kind)
	var batch_key := String(soil.get("interaction_batch_key", ""))
	var phase := String((soil.get("digging_response", {}) as Dictionary).get("phase", "free"))
	if not batch_key.is_empty() and batch_key != _last_batch_key:
		_last_batch_key = batch_key
		if phase in ["contact", "blocked"] and float(soil.get("interaction_penetration_m", 0.0)) > 0.01:
			_play_cue("impact")
	var slip := maxf(absf(float(chassis.get("left_slip_ratio", 0.0))), absf(float(chassis.get("right_slip_ratio", 0.0))))
	if slip > 0.82:
		_play_cue("warning")


func _play_cue(kind: String) -> bool:
	if float(_cooldowns.get(kind, 0.0)) > 0.0:
		return false
	var voice_cap := int((PROFILE_BUDGETS[profile] as Dictionary)["voices"])
	for index in mini(voice_cap, _voices.size()):
		if _voice_remaining[index] <= 0.0:
			var voice := _voices[index]
			voice.stream = _cue_streams.get(kind, _cue_streams["impact"])
			voice.volume_db = -80.0 if _muted else (-8.0 if kind in ["warning", "lifecycle"] else -5.0)
			voice.pitch_scale = 1.0
			voice.play()
			_voice_remaining[index] = 0.15
			_cooldowns[kind] = float(EVENT_COOLDOWNS.get(kind, 0.12))
			_last_event = kind
			_event_count += 1
			return true
	return false


func _tick_timers(delta: float) -> void:
	for kind in _cooldowns.keys():
		_cooldowns[kind] = maxf(0.0, float(_cooldowns[kind]) - delta)
	for index in _voice_remaining.size():
		_voice_remaining[index] = maxf(0.0, _voice_remaining[index] - delta)


func _fill_loop_buffers() -> void:
	for loop_name in LOOP_NAMES:
		var player := _loops.get(loop_name) as AudioStreamPlayer
		if player == null or not player.playing:
			continue
		var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
		if playback == null:
			_device_available = false
			continue
		var state := _loop_state[loop_name] as Dictionary
		var phase := float(_loop_phase.get(loop_name, 0.0))
		var frequency: float = float({"engine": 58.0, "tracks": 43.0, "work": 92.0}[loop_name]) * float(state["pitch"])
		var frames := mini(playback.get_frames_available(), 1024)
		for _index in frames:
			phase = fmod(phase + frequency / MIX_RATE, 1.0)
			var tone := sin(phase * TAU)
			var sample := tone * 0.16
			if loop_name == "engine":
				sample += sin(phase * TAU * 2.0) * 0.05
			elif loop_name == "tracks":
				sample = tone * 0.08 + _next_noise() * 0.12
			else:
				sample = tone * 0.09 + _next_noise() * 0.035
			playback.push_frame(Vector2(sample, sample))
		_loop_phase[loop_name] = phase


func _ensure_audio_buses() -> void:
	for bus_name in ["Machine", "Effects"]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			var index := AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, bus_name)
			AudioServer.set_bus_send(index, "Master")


func _set_bus_volume(bus_name: String, volume_db: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index >= 0:
		AudioServer.set_bus_volume_db(index, clampf(volume_db, -60.0, 6.0))


func _build_loop_players() -> void:
	for loop_name in LOOP_NAMES:
		var generator := AudioStreamGenerator.new()
		generator.mix_rate = MIX_RATE
		generator.buffer_length = 0.24
		var player := AudioStreamPlayer.new()
		player.name = "%sLoop" % loop_name.capitalize()
		player.stream = generator
		player.bus = "Machine"
		add_child(player)
		_loops[loop_name] = player
		_loop_state[loop_name] = {"active": false, "gain_db": -80.0, "pitch": 1.0}
		_loop_phase[loop_name] = 0.0


func _build_voice_pool(count: int) -> void:
	for index in count:
		var voice := AudioStreamPlayer.new()
		voice.name = "EffectVoice%02d" % index
		voice.bus = "Effects"
		add_child(voice)
		_voices.append(voice)
		_voice_remaining.append(0.0)


func _build_cue_streams() -> void:
	_cue_streams = {
		"cut": _make_cue(0.13, 72.0, 0.42, 11),
		"dump": _make_cue(0.16, 48.0, 0.58, 17),
		"spill": _make_cue(0.12, 62.0, 0.52, 23),
		"settle": _make_cue(0.14, 42.0, 0.65, 31),
		"impact": _make_cue(0.10, 54.0, 0.48, 41),
		"warning": _make_cue(0.14, 220.0, 0.08, 47),
		"lifecycle": _make_cue(0.11, 132.0, 0.12, 53),
	}


func _make_cue(duration: float, frequency: float, noise_mix: float, seed: int) -> AudioStreamWAV:
	var sample_count := maxi(1, roundi(duration * MIX_RATE))
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	var local_state := seed
	for index in sample_count:
		local_state = int((local_state * 1103515245 + 12345) & 0x7fffffff)
		var noise := (float(local_state & 0xffff) / 32767.5) - 1.0
		var envelope := pow(1.0 - float(index) / float(sample_count), 2.2)
		var tone := sin(TAU * frequency * float(index) / MIX_RATE)
		var sample := clampf((tone * (1.0 - noise_mix) + noise * noise_mix) * envelope * 0.7, -1.0, 1.0)
		data.encode_s16(index * 2, roundi(sample * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = roundi(MIX_RATE)
	stream.stereo = false
	stream.data = data
	return stream


func _next_noise() -> float:
	_noise_state = int((_noise_state * 1103515245 + 12345) & 0x7fffffff)
	return (float(_noise_state & 0xffff) / 32767.5) - 1.0


func _active_loop_count() -> int:
	var count := 0
	for state_value in _loop_state.values():
		if bool((state_value as Dictionary).get("active", false)):
			count += 1
	return count


func _active_voice_count() -> int:
	var count := 0
	for remaining in _voice_remaining:
		if remaining > 0.0:
			count += 1
	return count


func _on_session_status(status: Dictionary) -> void:
	var generation := int(status.get("generation", -1))
	if generation != _generation:
		stop_all("generation_reset")
		_generation = generation
	_lifecycle = String(status.get("lifecycle", "stopped"))
	_focused = bool(status.get("focused", true))
	if _lifecycle != "running" or not _focused:
		stop_all("focus_loss" if not _focused else _lifecycle)


func _on_model_changed(_model_id: String) -> void:
	stop_all("model_switch")

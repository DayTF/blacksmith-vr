extends Node3D
## Positional cues for committed impacts and the room's thermal presentation.

const Hearth := preload("res://assets/forge_room/audio/hearth.wav")
const Hiss := preload("res://assets/forge_room/audio/quench_hiss.wav")
const Ping := preload("res://assets/forge_room/audio/hammer_ping.wav")
const Thunk := preload("res://assets/forge_room/audio/hammer_thunk.wav")

var _tuning: Dictionary
var _hiss: AudioStreamPlayer3D
var _playback_enabled := false


func _ready() -> void:
	_playback_enabled = DisplayServer.get_name() != "headless"
	_tuning = JSON.parse_string(FileAccess.get_file_as_string("res://data/preview/station_audio.json"))


func _exit_tree() -> void:
	for player: AudioStreamPlayer3D in get_children():
		player.stop()


func start_stations(hearth: Vector3, bath: Vector3) -> void:
	var fire := _source(Hearth, hearth, _tuning.station_unit_size_m, _tuning.hearth_db, true)
	fire.name = "HearthCrackle"
	if _playback_enabled:
		fire.play()
	_hiss = _source(Hiss, bath, _tuning.station_unit_size_m, -80.0, true)
	_hiss.name = "QuenchHiss"


func set_quench_intensity(intensity: float) -> void:
	if intensity <= 0.0:
		_hiss.stop()
		_hiss.volume_db = -80.0
		return
	_hiss.volume_db = float(_tuning.hiss_db) + linear_to_db(clampf(intensity, 0.001, 1.0))
	if _playback_enabled and not _hiss.playing:
		_hiss.play()


func play_strike(billet: RefCounted, contact: Vector3) -> void:
	if not _playback_enabled:
		return
	var plastic := plastic_mix(billet)
	var impulse: float = billet.last_impulse.length()
	var level := clampf(impulse / float(_tuning.impulse_full_gain_ns), 0.0, 1.0)
	_play_hit_layer(Ping, contact, _tuning.ping_db, sqrt(1.0 - plastic) * level)
	_play_hit_layer(Thunk, contact, _tuning.thunk_db, sqrt(plastic) * level)


func _play_hit_layer(stream: AudioStreamWAV, contact: Vector3, gain_db: float, amplitude: float) -> void:
	if amplitude < 0.001:
		return
	var player := _source(stream, contact, _tuning.strike_unit_size_m,
		gain_db + linear_to_db(amplitude), false)
	player.finished.connect(player.queue_free)
	player.play()


func _source(stream: AudioStreamWAV, location: Vector3, unit: float,
		gain_db: float, looping: bool) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	if looping:
		var loop := stream.duplicate() as AudioStreamWAV
		loop.loop_mode = AudioStreamWAV.LOOP_FORWARD
		loop.loop_end = roundi(loop.get_length() * loop.mix_rate)
		player.stream = loop
	player.position = location
	player.unit_size = unit
	player.volume_db = gain_db
	add_child(player)
	return player


static func plastic_mix(billet: RefCounted) -> float:
	var nodes: Array[Dictionary] = billet.nodes
	var permanent := 0.0
	var mass := 0.0
	for point in nodes:
		permanent += float(point.mass) * float(point.plastic_strain_increment)
		mass += float(point.mass)
	permanent /= mass
	var elastic := 0.0
	var volume := 0.0
	for link: Dictionary in billet.connections:
		if link.broken:
			continue
		var a: Vector3 = nodes[link.a].position
		var b: Vector3 = nodes[link.b].position
		var weight: float = link.area * link.initial_length
		elastic += absf(a.distance_to(b) / float(link.rest_length) - 1.0) * weight
		volume += weight
	if volume > 0.0:
		elastic /= volume
	return permanent / (elastic + permanent) if permanent > 0.0 else 0.0

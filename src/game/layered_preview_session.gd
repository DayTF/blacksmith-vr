extends "res://src/game/preview_session.gd"
## Desktop inspection timeline driven by the same folding and welding operators as M0.

const Layered = preload("res://src/sim/layered_forging.gd")

var contacting_patches := 0
var bonded_patches := 0
var stage := ""
var weld_marker_nodes := PackedInt32Array()
var _layout: Dictionary
var _layered: RefCounted
var _pivot := Vector3.ZERO
var _leaf := PackedInt32Array()
var _pairs: Array[Vector2i] = []
var _angle := 0.0
var _ready_to_strike := false


func reset(prescribed_temperature: float) -> bool:
	_layout = JSON.parse_string(FileAccess.get_file_as_string("res://data/preview/layered.json"))
	config.emission_scale = _layout.emission_scale
	config.purification_marker_color = _layout.weld_marker_color
	config.temperature_presets_c = [_layout.hot_temperatures_c[0], _layout.cold_temperature_c]
	var hot: bool = prescribed_temperature > _layout.cold_temperature_c
	if hot:
		prescribed_temperature = _layout.hot_temperatures_c[0]
	if not super.reset(prescribed_temperature):
		return false
	billet = Billet.new(materials, billet.tuning)
	var surface_parameters: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/surface.json"))
	_layered = Layered.new(surface_parameters,
		JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/welding.json")))
	var side: int = _layout.cross_section_points
	var length: int = _layout.length_points
	var spacing: float = _layout.spacing_m
	var width := (side - 1) * spacing
	var origin := Vector3(-width * 0.5, 0.0, -(length - 1) * spacing * 0.5)
	var dimensions := Vector3i(side, side, length)
	_pivot = origin + Vector3(width, width, 0.0)
	var base: PackedInt32Array = _layered.stack_grid(billet, dimensions, spacing, origin,
		_layout.base_material, _layout.hot_temperatures_c[0] if hot else prescribed_temperature, "base")
	_leaf = _layered.stack_grid(billet, dimensions, spacing, origin + Vector3.RIGHT * width,
		_layout.leaf_material, _layout.hot_temperatures_c[1] if hot else prescribed_temperature, "leaf")
	if base.is_empty() or _leaf.is_empty():
		errors = _layered.errors
		return false
	_pairs.clear()
	for z in length:
		var top_row := side * (side - 1 + side * z)
		for x in side:
			_pairs.append(Vector2i(base[top_row + x], _leaf[top_row + side - 1 - x]))
	contact = Vector3(0.0, width * 2.0, 0.0)
	purified_nodes.resize(billet.nodes.size())
	purified_nodes.fill(0)
	_angle = 0.0
	_ready_to_strike = false
	contacting_patches = 0
	bonded_patches = 0
	weld_marker_nodes.clear()
	stage = "Two separate leaves"
	return true


func advance(delta: float) -> bool:
	if solidified or paused or finished or not errors.is_empty():
		return false
	elapsed += minf(delta, config.step_s)
	var progress := clampf((elapsed - float(_layout.start_hold_s)) / float(_layout.fold_duration_s), 0.0, 1.0)
	var angle := smoothstep(0.0, 1.0, progress) * PI
	if angle > _angle:
		if not _layered.fold(billet, _leaf, _pivot, Vector3.BACK, angle - _angle):
			errors = _layered.errors
			return false
		_angle = angle
		stage = "Folding the leaf"
	if progress >= 1.0 and not _ready_to_strike:
		_ready_to_strike = true
		stage = "Folded · awaiting impact"
	var strike_time: float = _layout.start_hold_s + _layout.fold_duration_s + _layout.strike_delay_s
	if elapsed >= strike_time and strikes == 0:
		var velocity: Array = config.hammer_velocity_m_s
		if not _layered.hammer(billet, contact, Vector3.UP, config.hammer_radius_m,
				config.hammer_mass_kg, Vector3(velocity[0], velocity[1], velocity[2]), _pairs):
			errors = _layered.errors
			errors.append("Scripted welding strike did not contact the stack.")
			return false
		strikes = 1
		contacting_patches = _layered.weld_attempts.size()
		for event: Dictionary in _layered.weld_attempts:
			if event.link >= 0:
				bonded_patches += 1
				weld_marker_nodes.append(event.pair.x)
		stage = "Weld bonded" if bonded_patches > 0 else "Cold interface stayed unbonded"
	finished = elapsed >= strike_time + float(_layout.finish_hold_s)
	return true


func hammer_height() -> float:
	var start: float = _layout.start_hold_s + _layout.fold_duration_s
	if elapsed <= start:
		return 0.095
	var progress := clampf((elapsed - start) / float(_layout.strike_delay_s), 0.0, 1.0)
	return 0.01 + 0.085 * (1.0 - progress * progress) + (0.033 if strikes > 0 else 0.0)

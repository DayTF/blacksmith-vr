extends RefCounted
## Synthetic mechanics inspection plus optional live thermal inspection.

const Library = preload("res://src/sim/material_library.gd")
const Billet = preload("res://src/sim/granular_billet.gd")
const Grid = preload("res://src/sim/billet_grid.gd")
const Thermal = preload("res://src/sim/thermal_model.gd")
const NamedSnapshot := preload("res://src/sim/named_billet_snapshot.gd")
const Purification = preload("res://src/sim/forging_purification.gd")
var materials := Library.new()
var billet_backend: Script = Billet
var billet: RefCounted
var config: Dictionary
var errors := PackedStringArray()
var paused := false
var finished := false
var solidified: bool:
	get: return _solidified
var _solidified := false
var elapsed := 0.0
var strikes := 0
var step_ms := 0.0
var contact := Vector3.ZERO
var temperature := 1000.0
var _accumulator := 0.0
var thermal: RefCounted
var thermal_inspection := false
var environments: Dictionary
var boundary: Dictionary
var exposed_areas := PackedFloat64Array()
var phase_count: int:
	get: return _thermal_crossings.size()
var thermal_elapsed_s := 0.0
var peak_cooling_rate_c_s := PackedFloat64Array()
var _thermal_crossings: Array[Dictionary] = []
var purification: RefCounted
var purified_nodes := PackedByteArray()
var initial_impurity_mass := 0.0
var _next_strike_at := 0.0
var _last_sequence_strike := 0
var _sequence_end_at := 0.0


func initialize() -> bool:
	config = JSON.parse_string(FileAccess.get_file_as_string("res://data/preview/billet.json"))
	environments = JSON.parse_string(FileAccess.get_file_as_string("res://data/preview/environments.json"))
	if not materials.load_directory("res://data/materials"):
		errors = materials.errors
		return false
	return reset(float(config.temperature_presets_c[0]))


func reset(prescribed_temperature: float) -> bool:
	errors.clear()
	temperature = prescribed_temperature
	thermal = Thermal.new(materials, JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/thermal.json")))
	thermal_inspection = false
	boundary = environments.environments[0]
	thermal_elapsed_s = 0.0
	peak_cooling_rate_c_s.clear()
	_thermal_crossings.clear()
	purification = Purification.new(JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/surface.json")))
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/mechanics.json"))
	billet = billet_backend.new(materials, tuning)
	var d: Array = config.dimensions
	var o: Array = config.origin_m
	if not billet.build_grid(Vector3i(d[0], d[1], d[2]), config.spacing_m,
			Vector3(o[0], o[1], o[2]), config.material_id, temperature, "preview-layer"):
		errors = billet.errors
		return false
	exposed_areas = Grid.reference_exposed_areas(Vector3i(d[0], d[1], d[2]), config.spacing_m)
	purified_nodes.resize(billet.nodes.size())
	purified_nodes.fill(0)
	initial_impurity_mass = 0.0
	for node: Dictionary in billet.nodes:
		for amount: float in node.impurity_mass.values():
			initial_impurity_mass += amount
	paused = false
	finished = false
	_solidified = false
	elapsed = 0.0
	strikes = 0
	_next_strike_at = config.strike_interval_s
	_last_sequence_strike = int(config.strike_count)
	_sequence_end_at = 0.0
	_accumulator = 0.0
	contact = Vector3(0, float(d[1] - 1) * config.spacing_m, config.strike_z_m[0])
	return true


func advance(delta: float) -> bool:
	if solidified or paused or finished or not errors.is_empty():
		return false
	# One step at most per render; a slow machine slows the demo rather than
	# accumulating an unbounded catch-up queue or changing the physical timestep.
	_accumulator = minf(_accumulator + delta, config.step_s)
	if _accumulator < config.step_s:
		return false
	_accumulator = 0.0
	elapsed += config.step_s
	if not thermal_inspection and strikes < _last_sequence_strike and elapsed >= _next_strike_at:
		var z: float = config.strike_z_m[strikes % config.strike_z_m.size()]
		var top := 0.0
		for node: Dictionary in billet.nodes:
			if absf(node.position.z - z) <= float(config.hammer_radius_m):
				top = maxf(top, node.position.y)
		contact = Vector3(0, top, z)
		var v: Array = config.hammer_velocity_m_s
		if not billet.hammer(contact, Vector3.UP, config.hammer_radius_m,
				config.hammer_mass_kg, Vector3(v[0], v[1], v[2])):
			errors.append("Synthetic hammer did not contact the billet.")
			return false
		strikes += 1
		_next_strike_at += float(config.strike_interval_s)
		if strikes == _last_sequence_strike:
			_sequence_end_at = elapsed + float(config.settle_s)
	var started := Time.get_ticks_usec()
	if thermal_inspection and not step_thermal([{"areas": exposed_areas, "boundary": boundary}], config.step_s):
		return false
	if not billet.step(config.step_s):
		errors = billet.errors
		return false
	if not thermal_inspection:
		if not purification.apply(billet):
			errors = purification.errors
			return false
		for event: Dictionary in purification.events:
			purified_nodes[event.node] = 1
	step_ms = float(Time.get_ticks_usec() - started) / 1000.0
	finished = not thermal_inspection and strikes >= _last_sequence_strike and elapsed >= _sequence_end_at
	return true


func resume_forging() -> void:
	if solidified:
		return
	# Continue the same matter/history after reheating or a completed sequence.
	thermal_inspection = false
	paused = false
	finished = false
	_next_strike_at = elapsed + float(config.strike_interval_s)
	_last_sequence_strike = strikes + int(config.strike_count)


func inspect_environment(index: int) -> void:
	if solidified:
		return
	thermal_inspection = true
	boundary = environments.environments[index]
	paused = false
	finished = false


func step_thermal(contacts: Array[Dictionary], dt: float) -> bool:
	if solidified or billet == null:
		return false
	if not thermal.step_with_boundaries(billet.nodes, billet.connections, contacts, dt):
		errors = thermal.errors
		return false
	for event: Dictionary in thermal.phase_events:
		var record := event.duplicate(true)
		record["thermal_time_s"] = thermal_elapsed_s + float(event.step_offset_s)
		_thermal_crossings.append(record)
	var rates: PackedFloat64Array = thermal.peak_cooling_rate_c_s
	peak_cooling_rate_c_s.resize(rates.size())
	for index in rates.size():
		peak_cooling_rate_c_s[index] = maxf(peak_cooling_rate_c_s[index], rates[index])
	thermal_elapsed_s += dt
	return true


func solidify(item_name: String) -> RefCounted:
	var name := item_name.strip_edges()
	if solidified or billet == null or name.is_empty() or not errors.is_empty():
		return null
	var item := NamedSnapshot.new(name, billet, {
		"strikes": strikes, "elapsed_s": elapsed, "phase_events": phase_count,
		"thermal_elapsed_s": thermal_elapsed_s, "thermal_crossings": _thermal_crossings,
		"peak_cooling_rate_c_s": peak_cooling_rate_c_s,
	})
	_solidified = true
	return item


func summary() -> Dictionary:
	var broken := 0
	var strain := 0.0
	var minimum := INF
	var maximum := -INF
	var total := 0.0
	var impurity_mass := 0.0
	for link: Dictionary in billet.connections:
		broken += int(link.broken)
	for node: Dictionary in billet.nodes:
		strain += float(node.plastic_strain)
		minimum = minf(minimum, node.temperature)
		maximum = maxf(maximum, node.temperature)
		total += node.temperature
		for amount: float in node.impurity_mass.values():
			impurity_mass += amount
	return {"broken": broken, "strain": strain / billet.nodes.size(), "nodes": billet.nodes.size(),
		"temperature_min": minimum, "temperature_max": maximum, "temperature_mean": total / billet.nodes.size(),
		"impurity_mass_kg": impurity_mass, "discarded_mass_kg": billet.discarded_mass,
		"purified_nodes": purified_nodes.count(1), "mass_accounted_kg": billet.total_mass()}

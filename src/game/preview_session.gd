extends RefCounted
## Synthetic mechanics inspection plus optional live thermal inspection.

const Library = preload("res://src/sim/material_library.gd")
const Billet = preload("res://src/sim/granular_billet.gd")
const Grid = preload("res://src/sim/billet_grid.gd")
const Thermal = preload("res://src/sim/thermal_model.gd")
var materials := Library.new()
var billet: RefCounted
var config: Dictionary
var errors := PackedStringArray()
var paused := false
var finished := false
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
var phase_count := 0


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
	phase_count = 0
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/mechanics.json"))
	billet = Billet.new(materials, tuning)
	var d: Array = config.dimensions
	var o: Array = config.origin_m
	if not billet.build_grid(Vector3i(d[0], d[1], d[2]), config.spacing_m,
			Vector3(o[0], o[1], o[2]), config.material_id, temperature, "preview-layer"):
		errors = billet.errors
		return false
	exposed_areas = Grid.reference_exposed_areas(Vector3i(d[0], d[1], d[2]), config.spacing_m)
	paused = false
	finished = false
	elapsed = 0.0
	strikes = 0
	_accumulator = 0.0
	contact = Vector3(0, float(d[1] - 1) * config.spacing_m, config.strike_z_m[0])
	return true


func advance(delta: float) -> bool:
	if paused or finished or not errors.is_empty():
		return false
	# One step at most per render; a slow machine slows the demo rather than
	# accumulating an unbounded catch-up queue or changing the physical timestep.
	_accumulator = minf(_accumulator + delta, config.step_s)
	if _accumulator < config.step_s:
		return false
	_accumulator = 0.0
	elapsed += config.step_s
	if not thermal_inspection and strikes < int(config.strike_count) and elapsed >= (strikes + 1) * config.strike_interval_s:
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
	var started := Time.get_ticks_usec()
	if thermal_inspection:
		if not thermal.step(billet.nodes, billet.connections, exposed_areas, config.step_s, boundary):
			errors = thermal.errors
			return false
		phase_count += thermal.phase_events.size()
	if not billet.step(config.step_s):
		errors = billet.errors
		return false
	step_ms = float(Time.get_ticks_usec() - started) / 1000.0
	finished = not thermal_inspection and elapsed >= config.strike_count * config.strike_interval_s + config.settle_s
	return true


func inspect_environment(index: int) -> void:
	thermal_inspection = true
	boundary = environments.environments[index]
	paused = false
	finished = false


func summary() -> Dictionary:
	var broken := 0
	var strain := 0.0
	var minimum := INF
	var maximum := -INF
	var total := 0.0
	for link: Dictionary in billet.connections:
		broken += int(link.broken)
	for node: Dictionary in billet.nodes:
		strain += float(node.plastic_strain)
		minimum = minf(minimum, node.temperature)
		maximum = maxf(maximum, node.temperature)
		total += node.temperature
	return {"broken": broken, "strain": strain / billet.nodes.size(), "nodes": billet.nodes.size(),
		"temperature_min": minimum, "temperature_max": maximum, "temperature_mean": total / billet.nodes.size()}

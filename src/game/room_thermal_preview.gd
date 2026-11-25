extends Node3D
## Scripted desktop fixture for the room's data-defined thermal boundaries.

const PreviewSession := preload("res://src/game/preview_session.gd")
const Contacts := preload("res://src/game/forge_thermal_contacts.gd")
const COOLING_RATE_FOR_FULL_EFFECT := 340.0

signal cooling_changed(intensity: float)

var _session := PreviewSession.new()
var _metal := StandardMaterial3D.new()
var _heating := false
var _smoke := false
var _initial_temperature := 0.0
var _mean_temperature := 0.0
var _simulated_seconds := 0.0
var _contacts: Array[Dictionary] = []


func start(boundary_id: String, smoke: bool, charge_center: Vector3) -> void:
	_smoke = smoke
	_heating = boundary_id == "forge"
	if not _session.initialize():
		_fail(_session.errors)
		return
	for index in _session.environments.environments.size():
		var boundary: Dictionary = _session.environments.environments[index]
		if boundary.id != boundary_id:
			continue
		if _heating:
			var start_temperature := float(_session.config.temperature_presets_c[1])
			if _smoke:
				# A near-cap charge also exercises the clamp in a short headless run.
				start_temperature = float(boundary.maximum_temperature_c) - 5.0
			if not _session.reset(start_temperature):
				_fail(_session.errors)
				return
		_session.inspect_environment(index)
		break
	if not _session.thermal_inspection:
		_fail(PackedStringArray(["Missing thermal boundary for " + boundary_id]))
		return
	_initial_temperature = _session.temperature
	_mean_temperature = _initial_temperature

	var charge := MeshInstance3D.new()
	charge.name = "ThermalCharge"
	var shape := BoxMesh.new()
	var dimensions: Array = _session.config.dimensions
	shape.size = (Vector3(dimensions[0], dimensions[1], dimensions[2]) - Vector3.ONE) * _session.config.spacing_m
	charge.mesh = shape
	charge.position = charge_center
	charge.rotation.y = PI * 0.5
	var origin: Array = _session.config.origin_m
	var model_center := Vector3(origin[0], origin[1], origin[2]) + shape.size * 0.5
	var room_from_billet := charge.transform
	room_from_billet.origin -= room_from_billet.basis * model_center
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/surface.json"))
	var allocator := Contacts.new(tuning)
	var areas := allocator.areas_by_station(_session.billet, room_from_billet)
	if areas.is_empty():
		charge.free()
		_fail(allocator.errors)
		return
	for boundary: Dictionary in _session.environments.environments:
		if boundary.id == "air":
			_contacts.append({"boundary": boundary, "areas": areas.air})
	var station := "forge" if _heating else "bath"
	_contacts.append({"boundary": _session.boundary, "areas": areas[station]})
	_metal.metallic = 0.62
	_metal.roughness = 0.46
	_metal.emission_enabled = true
	charge.material_override = _metal
	add_child(charge)
	_update_charge_material()


func _physics_process(delta: float) -> void:
	if not _session.thermal.step_with_boundaries(_session.billet.nodes, _session.billet.connections,
			_contacts, delta):
		_fail(_session.thermal.errors)
		return
	var total := 0.0
	var mass := 0.0
	var maximum := -INF
	for point: Dictionary in _session.billet.nodes:
		var temperature: float = point.temperature
		total += temperature * float(point.mass)
		mass += float(point.mass)
		maximum = maxf(maximum, temperature)

	var cooling_rate := (_mean_temperature - total / mass) / delta
	_mean_temperature = total / mass
	_update_charge_material()
	_simulated_seconds += delta
	if _heating:
		var cap: float = _session.boundary.maximum_temperature_c
		if maximum > cap:
			_fail(PackedStringArray(["Forge charge exceeded the equipment cap."]))
			return
		if _smoke and _simulated_seconds >= 1.0:
			if _mean_temperature <= _initial_temperature:
				_fail(PackedStringArray(["Forge equipment did not warm the charge."]))
				return
			print("Room heat ready: %.1f °C to %.1f °C, peak %.1f °C, cap %.1f °C" %
				[_initial_temperature, _mean_temperature, maximum, cap])
			get_tree().quit()
	else:
		cooling_changed.emit(clampf(cooling_rate / COOLING_RATE_FOR_FULL_EFFECT, 0.0, 1.0))


func _update_charge_material() -> void:
	var state := {"temperature": _mean_temperature}
	var material_id: String = _session.config.material_id
	var rgb: PackedFloat64Array = _session.materials.sample(material_id, "color", state)
	var energy: float = _session.materials.sample(material_id, "emission_energy", state)
	var finish := Color(rgb[0], rgb[1], rgb[2]).linear_to_srgb()
	_metal.albedo_color = finish
	_metal.emission = finish
	_metal.emission_energy_multiplier = energy


func _fail(errors: PackedStringArray) -> void:
	set_physics_process(false)
	cooling_changed.emit(0.0)
	push_error("Room thermal preview failed: " + "\n".join(errors))
	if _smoke:
		get_tree().quit(1)

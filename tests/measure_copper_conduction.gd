extends SceneTree
## Insulated two-volume copper coupon with source-backed thermal properties.

const MaterialData := preload("res://src/sim/material_definition.gd")
const Thermal := preload("res://src/sim/thermal_model.gd")
const MATERIAL_ID := "research_copper"
const MASS_KG := 0.05
const SPACING_M := 0.01
const AREA_M2 := 0.0004
const STEP_S := 0.01
const STEPS := 1200


class CouponMaterials:
	extends RefCounted
	var copper: RefCounted

	func get_material(material_id: String) -> RefCounted:
		return copper if material_id == MATERIAL_ID else null

	func sample(material_id: String, property: String, state: Dictionary) -> Variant:
		var material := get_material(material_id)
		return material.sample(property, state) if material != null else null


func _initialize() -> void:
	var reference: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://data/research/copper_thermal_reference.json"))
	var temperatures := _temperatures(reference.valid_temperature_c)
	if temperatures.is_empty():
		_fail("Supply cold and hot temperatures in Celsius within %s, cold first." %
			str(reference.valid_temperature_c))
		return
	var curves: Dictionary = reference.curves.duplicate()
	# This fixture isolates conduction, so there is no radiating surface or working strain.
	curves["emissivity"] = {"constant": 0.0}
	curves["work_hardening_recovery"] = {"constant": 0.0}
	var library := CouponMaterials.new()
	library.copper = MaterialData.new(
		{"schema_version": 1, "id": MATERIAL_ID, "name": reference.name, "impurities": []},
		{"schema_version": 1, "curves": curves})
	if not library.copper.errors.is_empty():
		_fail(str(library.copper.errors))
		return
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/thermal.json"))
	var model := Thermal.new(library, tuning)
	var nodes: Array[Dictionary] = [
		_point(temperatures[0], Vector3.ZERO), _point(temperatures[1], Vector3.RIGHT * SPACING_M),
	]
	var links: Array[Dictionary] = [{"a": 0, "b": 1, "area": AREA_M2}]
	var capacity_keys: Array = reference.curves.specific_heat.keys
	var initial_energy := _internal_energy(nodes, capacity_keys)
	var gap := temperatures[1] - temperatures[0]
	for step in STEPS:
		if not model.step_with_boundaries(nodes, links, [], STEP_S):
			_fail(str(model.errors))
			return
		var next_gap: float = nodes[1].temperature - nodes[0].temperature
		if next_gap < -0.000001 or next_gap > gap + 0.000001 or model.boundary_energy_j != 0.0:
			_fail("Insulated coupon must approach equilibrium without external heat or overshoot.")
			return
		gap = next_gap
	if gap > 0.01 or nodes[0].temperature <= temperatures[0] or nodes[1].temperature >= temperatures[1]:
		_fail("Copper coupon did not approach thermal equilibrium.")
		return
	var energy_error := _internal_energy(nodes, capacity_keys) - initial_energy
	if absf(energy_error) > 0.002 * initial_energy:
		_fail("Integrated heat capacity showed excessive energy drift.")
		return
	print(JSON.stringify({"initial_c": temperatures, "final_c": [nodes[0].temperature, nodes[1].temperature],
		"duration_s": STEPS * STEP_S, "external_energy_j": model.boundary_energy_j,
		"internal_energy_drift_j": energy_error}))
	quit()


func _internal_energy(nodes: Array[Dictionary], keys: Array) -> float:
	# Integrate the piecewise-linear specific heat from the lower bound.
	var total := 0.0
	for node in nodes:
		var temperature: float = node.temperature
		for index in range(1, keys.size()):
			var lower: Array = keys[index - 1]
			var upper: Array = keys[index]
			var width := clampf(temperature - float(lower[0]), 0.0, float(upper[0]) - float(lower[0]))
			var fraction := width / (float(upper[0]) - float(lower[0]))
			var endpoint := lerpf(float(lower[1]), float(upper[1]), fraction)
			total += float(node.mass) * width * (float(lower[1]) + endpoint) * 0.5
	return total


func _temperatures(bounds: Array) -> PackedFloat64Array:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return PackedFloat64Array([100.0, 900.0])
	if args.size() != 2 or not args[0].is_valid_float() or not args[1].is_valid_float():
		return PackedFloat64Array()
	var cold := args[0].to_float()
	var hot := args[1].to_float()
	if not is_finite(cold) or not is_finite(hot) or cold < float(bounds[0]) or hot > float(bounds[1]) or hot <= cold:
		return PackedFloat64Array()
	return PackedFloat64Array([cold, hot])


func _point(temperature: float, position: Vector3) -> Dictionary:
	return {"material_id": MATERIAL_ID, "position": position, "temperature": temperature,
		"mass": MASS_KG, "plastic_strain": 0.0}


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

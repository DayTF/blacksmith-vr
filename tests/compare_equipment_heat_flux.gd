extends SceneTree
## Initial boundary heat flux for published conditions and the playable tuning.

const Materials := preload("res://src/sim/material_library.gd")
const Thermal := preload("res://src/sim/thermal_model.gd")
const MATERIAL := "prototype_mithril"
const AREA_M2 := 0.0001
const STEP_S := 0.0001
const POINT_MASS_KG := 0.05


func _initialize() -> void:
	var materials := Materials.new()
	if not materials.load_directory("res://data/materials"):
		_fail(str(materials.errors))
		return
	var research := _read_json("res://data/research/quench_equipment_sources.json")
	var settings := _read_json("res://data/preview/environments.json")
	var tuning := _read_json("res://data/sim/thermal.json")
	var preview_baths := {}
	for boundary: Dictionary in settings.environments:
		preview_baths[boundary.id] = boundary
	var model := Thermal.new(materials, tuning)
	for station in ["anvil", "water"]:
		var reference: Dictionary = research[station].boundary
		var preview: Dictionary = settings.anvil_contact if station == "anvil" else preview_baths.water
		var coefficient: float = reference.get("contact_conductance_w_m2k",
			reference.get("coefficient_curve", {}).get("constant", NAN))
		var temperature: float = research[station].comparison_surface_temperature_c
		if not _compare(model, station, reference, preview, temperature, coefficient):
			return
	for point: Dictionary in research.oil.comparison_points:
		var coefficient: float = point.coefficient_w_m2k
		var reference := {"temperature_c": research.oil.bath_temperature_c,
			"coefficient_curve": {"constant": coefficient}}
		var label: String = "oil_%s_%s" % [point.face, point.regime]
		if not _compare(model, label, reference, preview_baths.oil, point.surface_temperature_c, coefficient):
			return
	quit()


func _compare(model: Thermal, label: String, reference: Dictionary, preview: Dictionary,
		temperature: float, coefficient: float) -> bool:
	var reference_flux := _heat_flux(model, reference, temperature)
	var preview_flux := _heat_flux(model, preview, temperature)
	var expected: float = coefficient * (temperature - reference.temperature_c)
	if not is_finite(preview_flux) or not is_finite(reference_flux) or preview_flux <= 0.0 			or reference_flux <= 0.0 or not is_equal_approx(reference_flux, expected):
		_fail("Invalid %s comparison. %s" % [label, str(model.errors)])
		return false
	print(JSON.stringify({"station": label, "surface_c": temperature,
		"reference_boundary_c": reference.temperature_c, "preview_boundary_c": preview.temperature_c,
		"reference_flux_w_m2": reference_flux, "preview_flux_w_m2": preview_flux,
		"preview_to_reference_flux": preview_flux / reference_flux}))
	return true


func _heat_flux(model: Thermal, boundary: Dictionary, temperature: float) -> float:
	# Compare convection/contact only. The water study also models radiation.
	boundary = boundary.duplicate()
	boundary.include_radiation = false
	var nodes: Array[Dictionary] = [{"material_id": MATERIAL, "position": Vector3.ZERO,
		"mass": POINT_MASS_KG, "plastic_strain": 0.0, "temperature": temperature}]
	if not model.step(nodes, [], PackedFloat64Array([AREA_M2]), STEP_S, boundary):
		push_error(str(model.errors))
		return NAN
	return -model.boundary_energy_j / (STEP_S * AREA_M2)


func _read_json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

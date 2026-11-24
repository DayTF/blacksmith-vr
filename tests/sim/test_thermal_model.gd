extends RefCounted

const Thermal = preload("res://src/sim/thermal_model.gd")
const Definition = preload("res://src/sim/material_definition.gd")
const Grid = preload("res://src/sim/billet_grid.gd")
var failures := PackedStringArray()
var _no_links: Array[Dictionary] = []

class Fixture:
	extends RefCounted
	var material: RefCounted
	func sample(_id: String, property: String, state: Dictionary) -> Variant:
		return material.sample(property, state)
	func get_material(id: String) -> RefCounted:
		return material if id == "fixture" else null


func run() -> PackedStringArray:
	failures.clear()
	_test_conservation_and_equilibrium()
	_test_boundaries_and_caps()
	_test_phase_recovery_and_atomicity()
	_test_exposure()
	return failures


func _fixture(overrides: Dictionary = {}) -> RefCounted:
	var curves := {}
	var values := {"specific_heat": 10.0, "thermal_conductivity": 5.0, "emissivity": 0.0,
		"work_hardening_recovery": 0.0, "quench_air": 1.0, "quench_water": 100.0, "quench_oil": 20.0}
	values.merge(overrides, true)
	for property: String in values:
		curves[property] = {"constant": values[property]}
	var fixture := Fixture.new()
	fixture.material = Definition.new({"schema_version": 1, "id": "fixture", "name": "Thermal fixture", "impurities": [],
		"phase_transitions": [{"id": "test-phase", "temperature": 50, "modifiers": {"thermal_conductivity": {"scale": 0.5}}}]},
		{"schema_version": 1, "curves": curves})
	_expect(fixture.material.errors.is_empty(), "Thermal fixture valid")
	return fixture


func _model(fixture: RefCounted) -> RefCounted:
	return Thermal.new(fixture, JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/thermal.json")))


func _node(temperature: float, position: Vector3 = Vector3.ZERO) -> Dictionary:
	return {"material_id": "fixture", "position": position, "temperature": temperature, "mass": 1.0,
		"plastic_strain": 0.5, "impurity_mass": {"inclusion": 0.01}}


func _boundary(property: String = "quench_air", temperature: float = 20.0) -> Dictionary:
	return {"temperature_c": temperature, "coefficient_property": property, "coefficient_scale": 1.0}


func _test_conservation_and_equilibrium() -> void:
	var model := _model(_fixture())
	var nodes: Array[Dictionary] = [_node(0), _node(100, Vector3.RIGHT)]
	var links: Array[Dictionary] = [{"a": 0, "b": 1, "area": 1.0}]
	for frame in 1000:
		_expect(model.step(nodes, links, PackedFloat64Array([0, 0]), 0.02, _boundary()), "Isolated conduction step")
		_near((nodes[0].temperature + nodes[1].temperature) * 10.0, 1000, 1e-8, "Pairwise conduction conserves energy")
		_expect(nodes[0].temperature >= 0 and nodes[1].temperature <= 100, "Conduction cannot overshoot extrema")
	_near(nodes[0].temperature, 50, 0.001, "Equal-mass equilibrium")
	_near(model.boundary_energy_j, 0, 1e-12, "Insulated boundary transfers no energy")
	links[0].broken = true
	nodes[0].temperature = 10.0
	nodes[1].temperature = 90.0
	_expect(model.step(nodes, links, PackedFloat64Array([0, 0]), 0.02, _boundary()), "Broken heat link step")
	_near(nodes[0].temperature, 10, 1e-12, "Broken connection cannot conduct")
	links[0].broken = false
	links[0].thermal_area_m2 = 0.0
	_expect(model.step(nodes, links, PackedFloat64Array([0, 0]), 0.02, _boundary()), "Mechanical brace heat isolation")
	_near(nodes[0].temperature, 10, 1e-12, "Mechanical bracing cannot add spurious conduction")


func _test_boundaries_and_caps() -> void:
	var final: Array[float] = []
	for medium in ["quench_water", "quench_oil", "quench_air"]:
		var model := _model(_fixture({"thermal_conductivity": 0.0}))
		var nodes: Array[Dictionary] = [_node(100), _node(100, Vector3.RIGHT)]
		_expect(model.step(nodes, _no_links, PackedFloat64Array([1, 0]), 0.02, _boundary(medium)), "Medium-dependent cooling")
		_near(nodes[1].temperature, 100, 1e-12, "Only exposed matter exchanges with medium")
		_near(model.boundary_energy_j, (nodes[0].temperature - 100) * 10, 1e-8, "Boundary energy accounting")
		final.append(nodes[0].temperature)
	_expect(final[0] < final[1] and final[1] < final[2] and final[2] < 100, "Authored water/oil/air responses differ")
	var model := _model(_fixture())
	var nodes: Array[Dictionary] = [_node(20)]
	var heater := _boundary("quench_water", 1600)
	heater.maximum_temperature_c = 1400.0
	for frame in 200:
		_expect(model.step(nodes, _no_links, PackedFloat64Array([1]), 0.02, heater), "Equipment-limited heating")
		_expect(nodes[0].temperature >= 20 and nodes[0].temperature <= 1400, "Equipment cap cannot be exceeded")
	_expect(nodes[0].temperature > 1399, "Capped forge still heats")
	nodes[0].temperature = 1500.0
	_expect(model.step(nodes, _no_links, PackedFloat64Array([1]), 0.02, heater), "Already-hotter billet exchanges with forge")
	_expect(nodes[0].temperature > 1400 and nodes[0].temperature < 1500, "Cap is a heat-source limit, not a temperature teleport")
	model = _model(_fixture({"emissivity": 1.0, "quench_air": 0.0}))
	nodes[0].temperature = 1000.0
	_expect(model.step(nodes, _no_links, PackedFloat64Array([0.1]), 0.02, _boundary()), "Radiation-only cooling")
	_expect(nodes[0].temperature < 1000, "Radiation works without Newton cooling")


func _test_phase_recovery_and_atomicity() -> void:
	var model := _model(_fixture({"work_hardening_recovery": 2.0}))
	var nodes: Array[Dictionary] = [_node(49)]
	_expect(model.step(nodes, _no_links, PackedFloat64Array([1]), 0.02, _boundary("quench_water", 100)), "Heat through phase threshold")
	_expect(model.phase_events.size() == 1 and model.phase_events[0].active and model.phase_events[0].node == 0, "Local phase entry emitted")
	_near(nodes[0].plastic_strain, 0.5 * exp(-0.04), 1e-12, "Curve-defined recovery rate")
	_near(nodes[0].impurity_mass.inclusion, 0.01, 1e-12, "Heat cannot remove impurities")
	_expect(model.step(nodes, _no_links, PackedFloat64Array([1]), 0.02, _boundary("quench_water", 0)), "Cool through phase threshold")
	_expect(model.phase_events.size() == 1 and not model.phase_events[0].active, "Local phase exit emitted")
	var before: Array = nodes.duplicate(true)
	_expect(not model.step(nodes, _no_links, PackedFloat64Array([-1]), 0.02, _boundary()) and nodes == before, "Invalid surface area is atomic")
	model.tuning.maximum_substeps = 1
	var boundary := _boundary("quench_water", 100)
	boundary.coefficient_scale = 1000000.0
	_expect(not model.step(nodes, _no_links, PackedFloat64Array([1]), 0.02, boundary) and nodes == before, "Excessive stiffness fails atomically")
	_expect(model.phase_events.is_empty() and model.boundary_energy_j == 0, "Failed steps expose no partial events or energy")


func _test_exposure() -> void:
	_expect(Grid.reference_exposed_areas(Vector3i(1, 3, 3), 0.015).is_empty(), "Degenerate grids have no valid reference surface")
	var areas := Grid.reference_exposed_areas(Vector3i(3, 3, 9), 0.015)
	var total := 0.0
	for area: float in areas:
		total += area
	_near(total, 2 * (0.03 * 0.03 + 2 * 0.03 * 0.12), 1e-12, "Dual surface areas sum to billet area")
	_near(areas[1 + 3 * (1 + 3 * 4)], 0, 1e-12, "Interior nodes have no boundary exposure")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _near(actual: float, expected: float, tolerance: float, message: String) -> void:
	_expect(absf(actual - expected) <= tolerance, message + ": " + str(actual))

extends RefCounted

const Billet = preload("res://src/sim/granular_billet.gd")
const Native = preload("res://src/sim/native_granular_billet.gd")
const Library = preload("res://src/sim/material_library.gd")
const Definition = preload("res://src/sim/material_definition.gd")
const Thermal = preload("res://src/sim/thermal_model.gd")
const Separation = preload("res://src/sim/melt_separation.gd")

var failures := PackedStringArray()
var materials := Library.new()
var equipment: Dictionary


class SingleMaterialCatalog:
	extends RefCounted
	var definition: RefCounted

	func get_material(id: String) -> RefCounted:
		return definition if id == definition.id else null


func run() -> PackedStringArray:
	failures.clear()
	_expect(materials.load_directory("res://data/materials"), "Refining catalog loads")
	equipment = _data("refining_equipment")
	_test_authored_materials(Billet)
	_test_authored_materials(Native)
	_test_two_destinations()
	_test_cooling_reset()
	return failures


func _test_authored_materials(backend: Script) -> void:
	var billet: RefCounted = backend.new(materials, _data("mechanics"))
	var process := Separation.new()
	billet.add_node(Vector3.ZERO, 1.0, "prototype_mithril", 2200)
	billet.add_node(Vector3.UP, 1.0, "prototype_embersteel", 2200)
	billet.add_node(Vector3.RIGHT, 1.0, "prototype_mithril", 1800)
	var nodes: Array[Dictionary] = billet.nodes
	var before: Array[Dictionary] = nodes.duplicate(true)
	var total: float = billet.total_mass()
	var cool_equipment: Dictionary = equipment.refining_crucible.duplicate()
	cool_equipment.maximum_temperature_c = equipment.forge.maximum_temperature_c
	_expect(process.advance(billet, cool_equipment, 10.0) and process.moved_mass == 0.0
		and nodes == before, "An insufficient equipment temperature cap prevents migration")
	_expect(process.skim(billet, equipment.refining_crucible) and process.removed_mass == 0.0,
		"Skimming without migration removes nothing")
	_expect(process.advance(billet, equipment.refining_crucible, 5.0), "Molten migration succeeds")
	var expected: float = before[0].impurity_mass.void_residue * (1.0 - exp(-1.0))
	_near(process.moved_mass, expected, "Mithril migration follows its authored rate")
	_expect(nodes[0].impurity_mass == before[0].impurity_mass and billet.total_mass() == total
		and billet.discarded_mass == 0.0 and nodes[1] == before[1] and nodes[2] == before[2],
		"Migration retains matter and skips the disabled alloy and unmelted point")
	_expect(not process.skim(billet, equipment.forge) and billet.discarded_mass == 0.0,
		"Equipment without a surface outlet cannot skim")
	if billet.has_method("commit_state"):
		_expect(billet.commit_state() and billet.step(0.001), "Staged impurity metadata survives native ownership")
	_expect(process.skim(billet, equipment.refining_crucible), "Explicit skimming succeeds")
	nodes = billet.nodes
	_near(process.removed_mass, expected, "Skimming only releases the migrated fraction")
	_near(nodes[0].mass, 1.0 - expected, "Skimming debits originating matter")
	_near(nodes[0].impurity_mass.void_residue, before[0].impurity_mass.void_residue - expected,
		"Skimming debits only the separated impurity")
	_expect(nodes[0].impurity_mass.bound_ash == before[0].impurity_mass.bound_ash,
		"An ineligible impurity is retained")
	_near(billet.discarded_impurity_mass.prototype_mithril.void_residue, expected,
		"Skimming writes the constituent and impurity discard ledger")
	_near(billet.total_mass(), total, "Live plus discarded mass is conserved")
	_expect(process.skim(billet, equipment.refining_crucible) and process.removed_mass == 0.0,
		"Repeated skimming cannot double-discard a spent pool")


func _test_two_destinations() -> void:
	var catalog := SingleMaterialCatalog.new()
	catalog.definition = Definition.new({"schema_version": 1, "id": "refining_fixture", "name": "Fixture",
		"curves": {"melt_fraction": {"constant": 1.0}}, "processes": {"melting": {"enabled": true,
			"curves": {"separation_efficiency": {"constant": 0.5}}}},
		"impurities": [_impurity("floating", "surface"), _impurity("sinking", "bottom")]},
		JSON.parse_string(FileAccess.get_file_as_string("res://data/materials/defaults.json")))
	var billet := Billet.new(catalog, _data("mechanics"))
	billet.add_node(Vector3.ZERO, 1.0, "refining_fixture", 2000)
	billet.add_node(Vector3.UP, 1.0, "refining_fixture", 2000)
	var process := Separation.new()
	var vessel: Dictionary = equipment.refining_crucible
	_expect(process.advance(billet, vessel, 1.0), "Both separation destinations can migrate")
	var mass := 0.1 * (1.0 - exp(-0.5))
	var node := billet.nodes[0]
	_near(node.separated_impurities.floating.mass_kg, mass, "Float pool receives rate-based migration")
	_near(node.separated_impurities.sinking.mass_kg, mass, "Sink pool receives rate-based migration")
	var before: Array = billet.nodes.duplicate(true)
	billet.nodes[1].mass = 0.01
	_expect(not process.drain(billet, vessel) and billet.nodes[0] == before[0]
		and billet.discarded_mass == 0.0, "Invalid later state makes explicit removal atomic")
	billet.nodes[1].mass = 1.0
	_expect(process.drain(billet, vessel), "Explicit bottom drain succeeds")
	_near(process.removed_mass, 2.0 * mass, "Drain releases only the sink pool")
	_near(node.impurity_mass.floating, 0.1, "Drain leaves floating material in the billet")
	_expect(process.skim(billet, vessel), "Explicit surface skim succeeds independently")
	_near(process.removed_mass, 2.0 * mass, "Skim releases the remaining float pool")
	_near(billet.total_mass(), 2.0, "Both removal paths conserve accounted mass")


func _test_cooling_reset() -> void:
	var billet := Billet.new(materials, _data("mechanics"))
	billet.add_node(Vector3.ZERO, 1.0, "prototype_mithril", 2200)
	var node := billet.nodes[0]
	var original: Dictionary = node.impurity_mass.duplicate()
	var process := Separation.new()
	var vessel: Dictionary = equipment.refining_crucible
	_expect(process.advance(billet, vessel, 5.0) and process.moved_mass > 0.0, "Charge separates before cooling")
	var thermal := Thermal.new(materials, _data("thermal"))
	var area := PackedFloat64Array([1.0])
	var water := {"temperature_c": 20.0, "coefficient_property": "quench_water", "coefficient_scale": 10.0}
	for step in 30:
		if node.temperature <= 2100.0:
			break
		_expect(thermal.step(billet.nodes, billet.connections, area, 0.03, water), "Quench succeeds")
	_expect(node.temperature <= 2100.0 and not node.has("separated_impurities"),
		"Solidification clears the staged impurity pools")
	_expect(node.impurity_mass == original and billet.discarded_mass == 0.0,
		"Solidification retains all unskimmed impurity mass")
	var heat := {"temperature_c": 2200.0, "coefficient_property": "quench_air", "coefficient_scale": 5000.0}
	for step in 12:
		if node.temperature > 2100.0:
			break
		_expect(thermal.step(billet.nodes, billet.connections, area, 0.03, heat), "Reheat succeeds")
	_expect(node.temperature > 2100.0 and process.skim(billet, vessel) and process.removed_mass == 0.0,
		"Remelting leaves nothing immediately available for skimming")
	_expect(process.advance(billet, vessel, 5.0) and process.moved_mass > 0.0
		and process.skim(billet, vessel) and process.removed_mass > 0.0, "Remelted charge can separate again")
	_near(billet.total_mass(), 1.0, "Refining across a thermal cycle conserves accounted mass")


func _impurity(id: String, destination: String) -> Dictionary:
	return {"id": id, "base_concentration": 0.1, "processes": {"melting": {
		"enabled": true, "separates_to": destination, "curves": {"separation_rate": {"constant": 1.0}}}}}


func _data(name: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/" + name + ".json"))


func _near(actual: float, expected: float, message: String) -> void:
	_expect(absf(actual - expected) < 1e-12, message + " (got %s, expected %s)" % [actual, expected])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

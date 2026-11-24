extends RefCounted

const Library = preload("res://src/sim/material_library.gd")
const Definition = preload("res://src/sim/material_definition.gd")
var _failures := PackedStringArray()


func run() -> PackedStringArray:
	_failures.clear()
	_test_supplied_data()
	_test_phases()
	_test_validation()
	_test_transactional_reload()
	return _failures


func _test_supplied_data() -> void:
	var library := Library.new()
	_expect(library.load_directory("res://data/materials"), "Supplied data must load: " + str(library.errors))
	if not library.errors.is_empty():
		return
	_expect(library.material_ids().size() >= 2, "Layered-billet prototype needs contrasting constituents")
	var material := library.get_material("prototype_mithril")
	_expect(material != null, "Mithril prototype discovered by file")
	if material == null:
		return
	var cold := {"temperature": 20, "plastic_strain": 0}
	var hot := {"temperature": 1000, "plastic_strain": 0}
	_expect(material.sample("youngs_modulus", hot) < material.sample("youngs_modulus", cold), "Prototype softens when hot")
	_expect(material.sample("thermal_conductivity", cold) > 0, "Omitted property inherits a default")
	_expect(material.sample("hardness", {"temperature": 1000, "plastic_strain": 0.5}) > material.sample("hardness", hot), "Strain curve increases hardness")
	_expect(material.sample("work_hardening_recovery", hot) > material.sample("work_hardening_recovery", cold), "Hotter material recovers strain faster")
	_expect(material.sample("hardness", {"temperature": 1000}) == null, "Hardness does not invent missing strain")
	_expect(material.sample("unknown", cold) == null, "Unknown properties are explicit")
	_expect(library.sample("unknown", "hardness", cold) == null, "Unknown materials are explicit")
	_near(material.sample("melt_fraction", {"temperature": 2000}), 0, "Insufficient furnace temperature cannot melt mithril")
	_near(material.sample("melt_fraction", {"temperature": 2200}), 1, "Mithril reaches its authored liquid state")
	var fraction: Variant = material.sample("impurities.void_residue.forging.removal_fraction", {"temperature": 1100, "plastic_strain_increment": 0.5})
	_expect(fraction != null and fraction > 0 and fraction < 1, "Impurity process graph gives a bounded fraction")
	_near(material.sample("impurities.void_residue.forging.removal_fraction", {"temperature": 20, "plastic_strain_increment": 0.5}), 0, "Cold purification curve is inactive")
	_near(material.sample("impurities.void_residue.forging.removal_fraction", {"temperature": 1100, "plastic_strain_increment": 0, "plastic_strain": 10}), 0, "Accumulated strain alone cannot keep purifying")
	_expect(not material.raw_data.impurities[1].processes.melting.enabled, "Bound impurity disables melt separation")
	var alloy := library.get_material("prototype_embersteel")
	_expect(alloy != null and not alloy.raw_data.processes.melting.enabled, "An alloy can disable melt purification")
	_expect(material.sample("color", hot) is PackedFloat64Array, "Color stays rendering-independent numeric data")
	_expect(material.sample("emission_energy", hot) > 1, "Authored hot emission supports HDR")


func _test_phases() -> void:
	var data := _fixture()
	data.phase_transitions = [
		{"id": "replacement", "temperature": 800, "modifiers": {"hardness": {"curve": {"constant": 30}, "scale": 2, "offset": 3}}},
		{"id": "soften", "temperature": 500, "modifiers": {"hardness": {"scale": 0.5, "offset": 1}}}
	]
	var material := Definition.new(data, _defaults())
	_expect(material.errors.is_empty(), "Valid phase graph rejected: " + str(material.errors))
	_near(material.sample("hardness", {"temperature": 499}), 10, "Before phase threshold")
	_near(material.sample("hardness", {"temperature": 500}), 6, "Threshold activates scale then offset")
	_near(material.sample("hardness", {"temperature": 800}), 63, "Later phase replaces curve before scale/offset")
	_near(material.sample("hardness", {"temperature": 799}), 6, "Cooling deactivates threshold modifier")
	var events := material.phase_events(0, 900)
	_expect(events.size() == 2, "Large heating step emits every crossed phase")
	if events.size() == 2:
		_expect(events[0].id == "soften" and events[1].id == "replacement" and events[0].active, "Heating events follow crossing order")
	var cooling := material.phase_events(900, 0)
	_expect(cooling.size() == 2, "Large cooling step emits both phase exits")
	if cooling.size() == 2:
		_expect(cooling[0].id == "replacement" and not cooling[0].active and cooling[0].direction == "cooling", "Cooling events reverse crossing order")
	_expect(material.phase_events(500, 600).is_empty(), "Do not re-emit an already active phase")
	_expect(material.phase_events(499, 500).size() == 1, "Exact threshold entry emits once")
	_expect(material.phase_events(500, 499).size() == 1, "Exact threshold exit emits once")
	_expect(material.phase_events(NAN, 1000).is_empty(), "Invalid phase query emits nothing")


func _test_validation() -> void:
	var invalids: Array[Dictionary] = []
	var missing := _fixture()
	missing.erase("impurities")
	invalids.append(missing)
	for concentration in [-0.1, 1.1, NAN, "bad"]:
		var data := _fixture()
		data.impurities = [{"id": "bad", "base_concentration": concentration}]
		invalids.append(data)
	var duplicates := _fixture()
	duplicates.impurities = [{"id": "x", "base_concentration": 0.6}, {"id": "x", "base_concentration": 0.6}]
	invalids.append(duplicates)
	var bad_process := _fixture()
	bad_process.processes = {"melting": {"enabled": "yes"}}
	invalids.append(bad_process)
	var unknown_property := _fixture()
	unknown_property.phase_transitions = [{"id": "bad", "temperature": 500, "modifiers": {"unknown": {"scale": 1}}}]
	invalids.append(unknown_property)
	var duplicate_threshold := _fixture()
	duplicate_threshold.phase_transitions = [
		{"id": "a", "temperature": 500, "modifiers": {}},
		{"id": "b", "temperature": 500, "modifiers": {}}
	]
	invalids.append(duplicate_threshold)
	var bad_modifier := _fixture()
	bad_modifier.phase_transitions = [{"id": "bad", "temperature": 500, "modifiers": {"hardness": {"typo": 1}}}]
	invalids.append(bad_modifier)
	var wrong_shape := _fixture()
	wrong_shape.curves.hardness = {"constant": [1, 2]}
	invalids.append(wrong_shape)
	var phase_shape := _fixture()
	phase_shape.phase_transitions = [{"id": "bad", "temperature": 500, "modifiers": {"hardness": {"curve": {"constant": [1, 2]}}}}]
	invalids.append(phase_shape)
	for index in invalids.size():
		var material := Definition.new(invalids[index], _defaults())
		_expect(not material.errors.is_empty(), "Invalid material %d accepted" % index)
		_expect(material.sample("hardness", {"temperature": 20}) == null, "Invalid material %d sampled" % index)


func _test_transactional_reload() -> void:
	var path := "user://material-suite-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if DirAccess.make_dir_recursive_absolute(path) != OK:
		_failures.append("Cannot create isolated material fixture directory")
		return
	_write_json(path.path_join("defaults.json"), _defaults())
	_write_json(path.path_join("first.json"), _fixture())
	var library := Library.new()
	_expect(library.load_directory(path), "Initial fixture load")
	var extra := _fixture()
	extra.id = "added_by_file"
	_write_json(path.path_join("extra.json"), extra)
	_expect(library.load_directory(path), "Adding a material requires only a file")
	_expect(library.material_ids().size() == 2 and library.get_material(extra.id) != null, "New material is discovered on reload")
	_write_json(path.path_join("duplicate.json"), extra)
	_expect(not library.load_directory(path), "Duplicate ids reject reload")
	DirAccess.remove_absolute(path.path_join("duplicate.json"))
	var corrupt := FileAccess.open(path.path_join("bad.json"), FileAccess.WRITE)
	corrupt.store_string("{ not valid JSON")
	corrupt.close()
	_expect(not library.load_directory(path) and not library.errors.is_empty(), "Malformed JSON rejects reload with diagnostics")
	_expect(library.material_ids().size() == 2, "Invalid reload retains prior catalog")
	DirAccess.remove_absolute(path.path_join("bad.json"))
	_write_json(path.path_join("defaults.json"), {"schema_version": 1, "curves": {"hardness": {"constant": "invalid"}}})
	_expect(not library.load_directory(path), "Invalid defaults reject reload even when overridden")
	_near(library.sample("fixture", "hardness", {"temperature": 20}), 10, "Failed reload preserves compiled old data")
	var directory := DirAccess.open(path)
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	DirAccess.remove_absolute(path)


func _fixture() -> Dictionary:
	return {"schema_version": 1, "id": "fixture", "name": "Fixture", "impurities": [], "curves": {"hardness": {"constant": 10}}}


func _defaults() -> Dictionary:
	return {"schema_version": 1, "curves": {"hardness": {"constant": 5}, "density": {"constant": 1000}}}


func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("Cannot write fixture: " + path)
		return
	file.store_string(JSON.stringify(data))
	file.close()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _near(actual: Variant, expected: float, message: String) -> void:
	_expect((actual is int or actual is float) and is_equal_approx(float(actual), expected), message + " (got %s)" % str(actual))

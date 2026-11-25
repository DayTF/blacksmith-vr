extends RefCounted

const Library := preload("res://src/sim/material_library.gd")
const Model := preload("res://src/sim/thermal_model.gd")
const Session := preload("res://src/game/preview_session.gd")
const Hardening := preload("res://src/sim/quench_hardening.gd")


func run() -> PackedStringArray:
	var library := Library.new()
	if not library.load_directory("res://data/materials"):
		return library.errors
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/thermal.json"))
	var fractions := []
	for medium in ["air", "oil", "water"]:
		var nodes: Array[Dictionary] = [{
			"position": Vector3.ZERO, "temperature": 1000.0, "mass": 0.03,
			"material_id": "prototype_embersteel", "plastic_strain": 0.0,
		}]
		var model := Model.new(library, tuning)
		var evaluator := Hardening.new(library)
		evaluator.prepare(nodes)
		var dt := 0.03
		var boundary := {"temperature_c": 20.0, "coefficient_property": "quench_" + medium,
			"coefficient_scale": 1.0}
		var areas := PackedFloat64Array([0.003])
		for step in 6000:
			if not model.step(nodes, [], areas, dt, boundary):
				return model.errors
			for event in model.phase_events:
				evaluator.observe(event, step * dt + float(event.step_offset_s))
			if nodes[0].temperature < 500.0:
				break
		var outcomes := evaluator.outcomes()
		if not outcomes.has(0):
			return PackedStringArray(["Cooling in %s did not complete the material window." % medium])
		fractions.append(float(outcomes[0].fraction))
		evaluator.observe({"id": "quench_heat", "node": 0, "active": true}, 181.0)
		if evaluator.outcomes().has(0):
			return PackedStringArray(["Reheating through the heat marker must clear the prior outcome."])
	if fractions[0] != 0.0 or not (fractions[0] < fractions[1] and fractions[1] < fractions[2]):
		return PackedStringArray(["The fantasy fixture should respond differently to air, oil and water, got %s." % str(fractions)])
	return _test_named_outcome()


func _test_named_outcome() -> PackedStringArray:
	var session := Session.new()
	if not session.initialize():
		return session.errors
	session.config.material_id = "prototype_embersteel"
	session.config.dimensions = [2, 2, 2]
	if not session.reset(1000.0):
		return session.errors
	var boundary: Dictionary = session.environments.environments[2].duplicate()
	boundary.coefficient_scale = 20.0
	var contacts: Array[Dictionary] = [{"areas": session.exposed_areas, "boundary": boundary}]
	for frame in 120:
		if not session.step_thermal(contacts, 0.03):
			return session.errors
	var item := session.solidify("Hardened sample")
	var results: Dictionary = item.terminal_state().history.quench_hardening_by_point
	if results.size() != 8 or float(results[0].fraction) <= 0.0:
		return PackedStringArray(["A completed local hardening response must survive naming."])
	return PackedStringArray()

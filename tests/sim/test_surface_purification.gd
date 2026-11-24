extends RefCounted

const Library = preload("res://src/sim/material_library.gd")
const Definition = preload("res://src/sim/material_definition.gd")
const Billet = preload("res://src/sim/granular_billet.gd")
const Native = preload("res://src/sim/native_granular_billet.gd")
const Surface = preload("res://src/sim/billet_surface.gd")
const Purifier = preload("res://src/sim/forging_purification.gd")
const Preview = preload("res://src/game/preview_session.gd")
var failures := PackedStringArray()
var library := Library.new()
var parameters: Dictionary

class LocalLibrary:
	extends RefCounted
	var definition: RefCounted
	func get_material(id: String) -> RefCounted:
		return definition if id == definition.id else null
	func sample(_id: String, property: String, context: Dictionary) -> Variant:
		return definition.sample(property, context)


func run() -> PackedStringArray:
	failures.clear()
	_expect(library.load_directory("res://data/materials"), "Purification materials load")
	parameters = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/surface.json"))
	_test_surface_geometry()
	_test_contact_and_fold()
	_test_local_fractional_removal()
	_test_eligibility_and_atomicity()
	_test_native_accounting()
	_test_preview_process_continuation()
	return failures


func _test_preview_process_continuation() -> void:
	var session := Preview.new()
	_expect(session.initialize(), "Preview purification harness initializes")
	# Short synthetic fixture: verify continuity without replaying a full demo.
	session.config.strike_count = 1
	session.config.strike_interval_s = 0.05
	session.config.settle_s = 0.02
	session.resume_forging()
	for frame in 10:
		session.advance(session.config.step_s)
	_expect(session.errors.is_empty() and session.finished and session.strikes == 1, "First synthetic sequence completes")
	var matter: RefCounted = session.billet
	var discarded: float = matter.discarded_mass
	var before: float = session.initial_impurity_mass
	session.inspect_environment(1)
	for frame in 3:
		session.advance(session.config.step_s)
	_expect(matter.discarded_mass == discarded, "Heating a worked billet cannot forge away impurities")
	session.resume_forging()
	session.advance(session.config.step_s)
	_expect(session.strikes == 1, "Resumed strikes retain their configured interval")
	for frame in 10:
		session.advance(session.config.step_s)
	_expect(session.errors.is_empty() and session.finished and session.strikes == 2, "Repeated synthetic sequence completes")
	_expect(session.billet == matter and session.initial_impurity_mass == before and matter.discarded_mass >= discarded, "Heat/strike mode changes preserve matter and purification history")


func _billet(catalog: RefCounted = null, native: bool = false) -> RefCounted:
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/mechanics.json"))
	tuning.gravity_m_s2 = [0, 0, 0]
	var source: RefCounted = library if catalog == null else catalog
	var billet: RefCounted = Native.new(source, tuning) if native else Billet.new(source, tuning)
	var built: bool = billet.build_grid(Vector3i(3, 3, 3), 0.01, Vector3.ZERO, "prototype_mithril", 1000, "original-layer")
	_expect(built, "Purification billet builds: " + str(billet.errors))
	return billet


func _test_surface_geometry() -> void:
	var billet := _billet()
	var surface := Surface.new(parameters)
	var result := surface.evaluate(billet.nodes, billet.cells)
	_expect(not result.is_empty() and result.unresolved_cells == 0, "Valid grid surface")
	var exposed := 0
	var area := 0.0
	for index in billet.nodes.size():
		exposed += result.exposed[index]
		area += result.areas[index]
	_expect(exposed == 26 and result.exposed[13] == 0, "Interior matter is not an exposed surface")
	_near(area, 6 * 0.02 * 0.02, 1e-9, "Current boundary area")
	for node: Dictionary in billet.nodes:
		node.position = node.position * Vector3(1.4, 0.5, 1.4)
	for cell: Dictionary in billet.cells:
		cell.active = false
	result = surface.evaluate(billet.nodes, billet.cells)
	area = 0.0
	for value: float in result.areas:
		area += value
	_near(area, 2 * (0.028 * 0.028 + 2 * 0.028 * 0.01), 1e-9, "Deformation changes surface geometry without deleting inactive cells")
	_expect(result.exposed[13] == 0, "Disabled volume constraints do not turn matter into empty space")
	for node: Dictionary in billet.nodes:
		node.position.y = 0.0
	result = surface.evaluate(billet.nodes, billet.cells)
	_expect(result.unresolved_cells == 8 and result.exposed.count(1) == 0, "Collapsed cells are unresolved, never a purification shortcut")


func _test_contact_and_fold() -> void:
	var billet := _billet()
	var other := _billet()
	for node: Dictionary in other.nodes:
		node.position.x += 0.02
	var offset: int = billet.nodes.size()
	billet.nodes.append_array(other.nodes)
	for cell: Dictionary in other.cells:
		var copy := cell.duplicate(true)
		for index in copy.nodes.size():
			copy.nodes[index] += offset
		billet.cells.append(copy)
	var surface := Surface.new(parameters)
	var before := surface.evaluate(billet.nodes, billet.cells)
	_expect(before.exposed[16] == 1, "Upper surface exposed before folding")
	var hinge := Vector3(0.02, 0.02, 0)
	var rotation := Basis(Vector3.BACK, PI)
	for index in range(offset, billet.nodes.size()):
		billet.nodes[index].position = hinge + rotation * (billet.nodes[index].position - hinge)
		billet.nodes[index].orientation = rotation
	var original: Array = billet.nodes.duplicate(true)
	var folded := surface.evaluate(billet.nodes, billet.cells)
	_expect(folded.exposed[16] == 0, "Folded contacting layer buries a formerly exposed interior patch")
	_expect(billet.nodes == original, "Exposure queries preserve layers, orientations and impurities")
	var area := 0.0
	for value: float in folded.areas:
		area += value
	_near(area, 2 * (0.02 * 0.02 + 2 * 0.02 * 0.04), 1e-9, "Unbonded contacting layers have no exposed interface")
	for node: Dictionary in billet.nodes:
		node.position.y *= 0.00001
	var thin := surface.evaluate(billet.nodes, billet.cells)
	_expect(thin.unresolved_cells == 0 and thin.exposed[16] == 0, "Surface probes cannot jump through a contacting layer thinner than the configured offset")
	for index in range(offset, billet.nodes.size()):
		billet.nodes[index].position.y += 0.01
	var reopened := surface.evaluate(billet.nodes, billet.cells)
	_expect(reopened.exposed[16] == 1, "Separating matter exposes the buried patch again")


func _test_local_fractional_removal() -> void:
	var billet := _billet()
	var purifier := Purifier.new(parameters)
	var initial: Array = billet.nodes.duplicate(true)
	var total: float = billet.total_mass()
	for node: Dictionary in billet.nodes:
		node.plastic_strain_increment = 0.2
		node.plastic_spreading_increment = 0.1
	billet.step_id = 1
	_expect(purifier.apply(billet), "Surface purification succeeds")
	_near(billet.nodes[13].impurity_mass.void_residue, initial[13].impurity_mass.void_residue, 1e-16, "Internal plastic strain cannot purify")
	_near(billet.nodes[0].impurity_mass.void_residue, initial[0].impurity_mass.void_residue * 0.998, 1e-16, "Fraction uses eligible spreading, not total compression/strain")
	_near(billet.nodes[0].impurity_mass.bound_ash, initial[0].impurity_mass.bound_ash * 0.999, 1e-16, "Each impurity uses its own graph")
	_near(billet.total_mass(), total, 1e-12, "Live plus discarded matter is conserved")
	var ledger := 0.0
	for amount: float in billet.discarded_impurity_mass.prototype_mithril.values():
		ledger += amount
	_near(ledger, billet.discarded_mass, 1e-15, "Discard ledger preserves impurity identities and total mass")
	for event: Dictionary in purifier.events:
		_expect(event.mass_kg > 0 and event.node != 13, "Debris events identify only actual expelled surface matter")
	var once: Array = billet.nodes.duplicate(true)
	var discarded: float = billet.discarded_mass
	_expect(purifier.apply(billet) and Purifier.new(parameters).apply(billet), "Repeated calls and new adapters cannot replay a strain event")
	_expect(billet.nodes == once and billet.discarded_mass == discarded, "Purification is once per successful mechanical step")
	billet.step_id += 1
	_expect(purifier.apply(billet), "New spreading event purifies remaining impurities")
	_near(billet.nodes[0].impurity_mass.void_residue, initial[0].impurity_mass.void_residue * 0.998 * 0.998, 1e-16, "Repeated fractional removal is geometric")
	_near(billet.total_mass(), total, 1e-12, "Repeated mass balance")
	_near(billet.nodes[0].velocity.length(), 0, 1e-12, "Discarding co-moving matter creates no extra impulse")


func _test_eligibility_and_atomicity() -> void:
	for temperature in [20.0, 1350.0]:
		var billet := _billet()
		for node: Dictionary in billet.nodes:
			node.temperature = temperature
			node.plastic_spreading_increment = 0.1
		billet.step_id = 1
		_expect(Purifier.new(parameters).apply(billet) and billet.discarded_mass == 0, "Temperature-window graph blocks removal")
	var billet := _billet()
	billet.nodes[0].plastic_strain = 100.0
	billet.nodes[0].plastic_strain_increment = 0.5
	billet.step_id = 1
	_expect(Purifier.new(parameters).apply(billet) and billet.discarded_mass == 0, "Accumulated hardening or compression without spreading cannot purify")
	for mode in ["material-disabled", "impurity-disabled", "bad-fraction", "exhaustion"]:
		var data: Dictionary = library.get_material("prototype_mithril").raw_data.duplicate(true)
		if mode == "material-disabled":
			data.processes["forging"] = {"enabled": false}
		elif mode == "impurity-disabled":
			for impurity: Dictionary in data.impurities:
				impurity.processes.forging.enabled = false
		elif mode == "bad-fraction":
			data.impurities[1].processes.forging.curves.removal_fraction = {"constant": 1.2}
		else:
			data.impurities[0].base_concentration = 1.0
			data.impurities[1].base_concentration = 0.0
			data.impurities[0].processes.forging.curves.removal_fraction = {"constant": 1.0}
		var catalog := LocalLibrary.new()
		catalog.definition = Definition.new(data, JSON.parse_string(FileAccess.get_file_as_string("res://data/materials/defaults.json")))
		_expect(catalog.definition.errors.is_empty(), "Process fixture: " + mode + ": " + str(catalog.definition.errors))
		billet = _billet(catalog)
		if billet.nodes.is_empty():
			failures.append("Cannot construct process fixture: " + mode)
			continue
		billet.nodes[0].plastic_spreading_increment = 0.1
		billet.step_id = 1
		var original: Array = billet.nodes.duplicate(true)
		var purifier := Purifier.new(parameters)
		var success: bool = purifier.apply(billet)
		_expect(success == mode.ends_with("disabled"), "Eligibility/invalid fraction behavior: " + mode)
		_expect(billet.nodes == original and billet.discarded_mass == 0 and billet.discarded_impurity_mass.is_empty(), "Rejected/disabled processes retain all local matter: " + mode)
		if not success:
			_expect(billet.purification_step_id == 0 and purifier.events.is_empty(), "Rejected processing is atomic and retryable")


func _test_native_accounting() -> void:
	var billet := _billet(null, true)
	_expect(billet.commit_state() and billet.step(1.0 / 90), "Native mechanical step increments process token")
	_expect(billet.step_id == 1, "Native successful-step identity")
	billet.nodes[0].plastic_spreading_increment = 0.1
	var total: float = billet.total_mass()
	var held: Dictionary = billet.nodes[0].impurity_mass
	_expect(Purifier.new(parameters).apply(billet), "Purification through native compatibility views")
	_expect(held.void_residue == billet.nodes[0].impurity_mass.void_residue, "Retained impurity views remain attached")
	_expect(billet.commit_state() and billet.step(1.0 / 90), "Purified state transfers back to native resident mechanics")
	_near(billet.total_mass(), total, 1e-12, "Native live-plus-discarded mass")
	_expect(billet.purification_step_id == 1 and billet.step_id == 2, "Processing history survives native ownership transfer")
	_expect(not billet.step(NAN) and billet.step_id == 2, "Failed native step creates no purification event")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _near(actual: float, expected: float, tolerance: float, message: String) -> void:
	_expect(absf(actual - expected) <= tolerance, message + ": " + str(actual))

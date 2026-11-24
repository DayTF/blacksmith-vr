extends RefCounted
const Reference = preload("res://src/sim/granular_billet.gd")
const Native = preload("res://src/sim/native_granular_billet.gd")
const Library = preload("res://src/sim/material_library.gd")
var failures := PackedStringArray()

func run() -> PackedStringArray:
	failures.clear()
	var library = Library.new()
	_expect(library.load_directory("res://data/materials"), "Native fixture materials load")
	var probe = Native.new(library, _tuning())
	if not ClassDB.class_exists("BlacksmithNativeCore"):
		failures.append("Native library must be built; this suite cannot be skipped")
		return failures
	_test_pairs(library)
	_test_grid(library, false)
	_test_grid(library, true)
	_test_views(library)
	_test_impulse_parity(library)
	_test_curves(library)
	_test_reload()
	_test_resting_gravity(library)
	return failures

func _test_resting_gravity(library: RefCounted) -> void:
	var tuning := _tuning()
	tuning.gravity_m_s2 = [0, -9.81, 0]
	for temperature in [20.0, 1000.0]:
		var reference = Reference.new(library, tuning)
		var native = Native.new(library, tuning)
		for billet: RefCounted in [reference, native]:
			_expect(billet.build_grid(Vector3i(3, 3, 9), 0.015, Vector3(-0.015, 0, -0.06), "prototype_mithril", temperature), "Native/reference resting braced grid")
		var original: PackedVector3Array = native.positions_snapshot()
		_expect(native.commit_state(), "Resting native resident ownership")
		for frame in 72:
			_expect(reference.step(1.0 / 90) and native.step(1.0 / 90), "Native/reference gravity-only steps")
			var positions: PackedVector3Array = native.positions_snapshot()
			for index in positions.size():
				_expect(positions[index].distance_to(original[index]) < 0.0001, "Native unstruck billet stays intact and in place")
		_compare(reference, native, "Resting gravity parity")
		for link: Dictionary in native.connections:
			_expect(not link.broken and link.fracture_damage == 0, "Native own weight cannot cause fracture")
		for node: Dictionary in native.nodes:
			_expect(node.plastic_strain == 0, "Native own weight cannot cause plastic strain")

func _tuning() -> Dictionary:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/mechanics.json"))
	data.gravity_m_s2 = [0, 0, 0]
	return data

func _test_pairs(library: RefCounted) -> void:
	for temperature in [20.0, 1000.0]:
		for length in [0.0098, 0.0100001, 0.0102]:
			var reference = Reference.new(library, _tuning())
			var native = Native.new(library, _tuning())
			for billet: RefCounted in [reference, native]:
				billet.add_node(Vector3(0, 0.02, 0), 0.0025, "prototype_mithril", temperature)
				billet.add_node(Vector3(0.01, 0.02, 0), 0.0025, "prototype_mithril", temperature)
				billet.connect_nodes(0, 1, 0.0001, 0.1)
				billet.nodes[1].position.x = length
			_expect(reference.step(1.0 / 90) and native.step(1.0 / 90), "Native/reference centimetre steps")
			_compare(reference, native, "Pair")
			var before: Array = native.nodes.duplicate(true)
			var links: Array = native.connections.duplicate(true)
			_expect(not native.step(NAN), "Native rejects invalid timestep")
			_expect(native.nodes == before and native.connections == links, "Native rejected timestep is atomic")

func _test_grid(library: RefCounted, resident: bool) -> void:
	var reference = Reference.new(library, _tuning())
	var native = Native.new(library, _tuning())
	for billet: RefCounted in [reference, native]:
		_expect(billet.build_grid(Vector3i(3, 3, 3), 0.01, Vector3.ZERO, "prototype_mithril", 1000, "layer"), "Native/reference grid construction")
		for node: Dictionary in billet.nodes:
			node.position.y *= 0.9
	if resident:
		_expect(native.commit_state(), "Explicit resident ownership transfer")
	for frame in 10:
		_expect(reference.step(1.0 / 90) and native.step(1.0 / 90), "Native/reference hot grid steps")
	_compare(reference, native, "Grid resident=%s" % resident)
	_expect(absf(reference.total_mass() - native.total_mass()) < 1e-9, "Native mass parity")

func _test_views(library: RefCounted) -> void:
	var native = Native.new(library, _tuning())
	native.add_node(Vector3(0, 1, 0), 1, "prototype_mithril", 1000)
	var held: Dictionary = native.nodes[0]
	var held_array: Array = native.nodes
	var held_impurities: Dictionary = held.impurity_mass
	held.velocity = Vector3.RIGHT
	_expect(native.step(0.01) and held.position.x > 0, "Retained dictionary is updated in place")
	held.velocity = Vector3(2, 0, 0)
	held_impurities.void_residue *= 0.5
	_expect(native.positions_snapshot()[0] == held.position, "Compatibility snapshot sees current view")
	_expect(native.step(0.01), "Retained dictionary edits reach native state")
	_expect(absf(held.velocity.x - 2) < 1e-6, "Edited velocity preserved")
	_expect(absf(held.impurity_mass.void_residue - 0.0015) < 1e-9, "Retained nested impurity edits remain authoritative")
	_expect(held_array[0] == held and held.impurity_mass == held_impurities, "Legacy outer/nested references remain attached")
	_expect(native.commit_state(), "Release legacy views explicitly")
	held.velocity = Vector3.ZERO
	held_array.clear()
	_expect(native.step(0.01), "Resident step after releasing views")
	_expect(native.positions_snapshot()[0].x > 0.04, "Released stale references cannot overwrite resident state")
	_expect(native.nodes.size() == 1 and native.nodes[0].velocity.x > 1.9, "Snapshot restores canonical resident views after released-array mutation")
	_expect(native.hammer(native.positions_snapshot()[0], Vector3.UP, 0.1, 2, Vector3.DOWN), "Native impact")
	_expect(native.last_impulse.y < 0, "Native delivered impulse reported")
	_expect(not native.hammer(Vector3.ZERO, Vector3.ZERO, 0.1, 2, Vector3.DOWN) and native.last_impulse == Vector3.ZERO, "Rejected impact clears delivered impulse")
	var before: Array = native.nodes.duplicate(true)
	var old_mass: float = native.nodes[0].mass
	native.nodes[0].mass = -1
	_expect(not native.step(0.01), "Native rejects invalid node mass without engine errors")
	native.nodes[0].mass = old_mass
	_expect(native.nodes == before, "Invalid upload did not modify other node state")

func _test_impulse_parity(library: RefCounted) -> void:
	var reference = Reference.new(library, _tuning())
	var native = Native.new(library, _tuning())
	for billet: RefCounted in [reference, native]:
		billet.add_node(Vector3(-0.05, 1, 0), 1, "prototype_mithril", 1000)
		billet.add_node(Vector3(0, 0.995, 0), 1, "prototype_mithril", 1000)
		billet.add_node(Vector3(0.05, 1, 0), 3, "prototype_mithril", 1000)
		_expect(billet.hammer(Vector3(0, 1, 0), Vector3.UP, 0.2, 2, Vector3.DOWN), "Weighted front-face native/reference impulse")
	_expect(reference.last_impulse.distance_to(native.last_impulse) < 1e-6, "Delivered impulse matches reference")
	for index in 3:
		_expect(reference.nodes[index].velocity.distance_to(native.nodes[index].velocity) < 1e-6, "Contact velocity matches reference")

func _test_curves(library: RefCounted) -> void:
	var native = Native.new(library, _tuning())
	for id: String in library.material_ids():
		for temperature in [20, 500, 999, 1399, 1400, 1800, 2200, 2500]:
			for strain in [0.0, 0.3, 1.0]:
				var context := {"temperature": temperature, "plastic_strain": strain, "plastic_strain_increment": 0.2}
				for property in ["youngs_modulus", "hardness", "color", "ductility", "melt_fraction", "thermal_conductivity", "bulk_modulus"]:
					var expected: Variant = library.sample(id, property, context)
					var actual: Variant = native.sample_material(id, property, context)
					_compare_value(expected, actual, "Native graph %s/%s" % [id, property])
	_expect(native.sample_material("prototype_mithril", "hardness", {"temperature": 1000}) == null, "Native graphs reject missing strain")
	_expect(native.sample_material("missing", "hardness", {"temperature": 1000}) == null, "Native graphs reject missing material")
	_expect(not native._core.set_materials({"bad": {"curves": {"hardness": {"keys": []}}}}), "Malformed native graph upload rejected")
	_compare_value(library.sample("prototype_mithril", "hardness", {"temperature": 1000, "plastic_strain": 0.3}), native.sample_material("prototype_mithril", "hardness", {"temperature": 1000, "plastic_strain": 0.3}), "Invalid native catalog retains prior curves")

func _test_reload() -> void:
	var path := "user://native-material-suite-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_expect(DirAccess.make_dir_recursive_absolute(path) == OK, "Native reload fixture directory")
	_write(path.path_join("defaults.json"), {"schema_version": 1, "curves": {
		"youngs_modulus": {"constant": 100}, "yield_strength": {"constant": 10}, "ductility": {"constant": 1},
		"hardness": {"op": "multiply", "inputs": [
			{"interpolation": "step", "keys": [[20, 1], [100, 2]]},
			{"axis": "plastic_strain", "keys": [[0, 1], [1, 2]]}]},
		"color": {"interpolation": "cubic", "keys": [[0, [0, 0]], [1, [1, 2]], [3, [9, 18]], [4, [16, 32]]]},
		"test_pressure": {"axis": "pressure", "keys": [[0, 1], [100, 2]]}
	}})
	var data := {"schema_version": 1, "id": "z", "name": "fixture", "impurities": []}
	_write(path.path_join("z.json"), data)
	var library = Library.new()
	_expect(library.load_directory(path), "Initial native reload catalog")
	var native = Native.new(library, _tuning())
	native.add_node(Vector3(0, 1, 0), 1, "z", 20)
	_expect(native.commit_state() and native.step(0.01), "Initial resident fixture")
	_compare_value(1.5, native.sample_material("z", "hardness", {"temperature": 50, "plastic_strain": 0.5}), "Native step graph before threshold")
	_compare_value(3.0, native.sample_material("z", "hardness", {"temperature": 100, "plastic_strain": 0.5}), "Native exact step threshold")
	_compare_value(PackedFloat64Array([4, 8]), native.sample_material("z", "color", {"temperature": 2}), "Native nonuniform cubic vector")
	_compare_value(1.5, native.sample_material("z", "test_pressure", {"temperature": 20, "pressure": 50}), "Native arbitrary context axis")
	_expect(native.sample_material("z", "test_pressure", {"temperature": 20}) == null, "Native missing optional context fails explicitly")
	var revision: int = library.get_revision()
	data.id = "a"
	data.curves = {"youngs_modulus": {"constant": 50}}
	_write(path.path_join("a.json"), data)
	_expect(library.load_directory(path) and library.get_revision() > revision, "Successful reload advances revision")
	_expect(native.step(0.01), "Existing node remapped when new sorted material id is inserted")
	_compare_value(100.0, native.sample_material("z", "youngs_modulus", {"temperature": 20}), "Resident material identity survives reload")
	data.id = "z"
	data.curves.youngs_modulus.constant = 200
	_write(path.path_join("z.json"), data)
	_expect(library.load_directory(path) and native.step(0.01), "Live material curve reload reaches native solver")
	_compare_value(200.0, native.sample_material("z", "youngs_modulus", {"temperature": 20}), "Native material cache invalidated on revision")
	data.curves.youngs_modulus = {"axis": "plastic_strain", "interpolation": "step", "keys": [[0, 100], [0.01, 0]]}
	_write(path.path_join("z.json"), data)
	_expect(library.load_directory(path), "Zero-modulus transition fixture")
	var elastic_reference = Reference.new(library, _tuning())
	var elastic_native = Native.new(library, _tuning())
	for billet: RefCounted in [elastic_reference, elastic_native]:
		billet.add_node(Vector3(0, 1, 0), 1, "z", 20)
		billet.add_node(Vector3(1, 1, 0), 1, "z", 20)
		billet.connect_nodes(0, 1, 1, 0.1)
		billet.nodes[1].position.x = 1.3
		_expect(billet.step(0.01) and billet.connections[0].stiffness == 0, "Zero modulus clears stiffness between substeps")
	_compare(elastic_reference, elastic_native, "Strain-dependent modulus transition")
	revision = library.get_revision()
	_write(path.path_join("bad.json"), {})
	_expect(not library.load_directory(path) and library.get_revision() == revision, "Rejected reload retains revision")
	_expect(native.step(0.01), "Rejected catalog cannot poison resident solver")
	for filename in DirAccess.open(path).get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	DirAccess.remove_absolute(path)

func _write(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _compare(reference: RefCounted, native: RefCounted, label: String) -> void:
	_expect(reference.nodes.size() == native.nodes.size(), label + " node count")
	for index in reference.nodes.size():
		var a: Dictionary = reference.nodes[index]
		var b: Dictionary = native.nodes[index]
		_expect(a.position.distance_to(b.position) < 0.00002, label + " position parity")
		_expect(a.velocity.distance_to(b.velocity) < 0.02, label + " velocity parity")
		_expect(absf(a.plastic_strain - b.plastic_strain) < 0.002, label + " strain parity")
		_expect(a.impurity_mass == b.impurity_mass and a.layer_id == b.layer_id, label + " matter identity")
		_expect(a.orientation.x.dot(b.orientation.x) > 0.999, label + " orientation parity")
	for index in reference.connections.size():
		var a: Dictionary = reference.connections[index]
		var b: Dictionary = native.connections[index]
		_expect(a.broken == b.broken, label + " fracture parity")
		_expect(absf(a.rest_length - b.rest_length) < 0.00002, label + " plastic rest parity")
		_expect(absf(a.fracture_damage - b.fracture_damage) < 0.005, label + " damage parity")

func _compare_value(expected: Variant, actual: Variant, label: String) -> void:
	if expected is PackedFloat64Array:
		_expect(actual is PackedFloat64Array and actual.size() == expected.size(), label + " vector shape")
		if actual is PackedFloat64Array and actual.size() == expected.size():
			for index in expected.size():
				_expect(is_equal_approx(expected[index], actual[index]), label + " vector value")
	else:
		_expect(actual != null and is_equal_approx(float(expected), float(actual)), label + " scalar value")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

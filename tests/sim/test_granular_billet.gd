extends RefCounted

const Billet = preload("res://src/sim/granular_billet.gd")
const Library = preload("res://src/sim/material_library.gd")
const Geometry = preload("res://src/sim/billet_geometry.gd")
var failures := PackedStringArray()

class MaterialFixture:
	extends RefCounted
	var yield_value := 10.0
	var ductility_value := 1.0
	var raw_data := {"impurities": [{"id": "inclusion", "base_concentration": 0.1}]}
	func get_material(id: String) -> Variant:
		return self if id == "test" else null
	func sample(_id: String, property: String, _state: Dictionary) -> Variant:
		match property:
			"youngs_modulus": return 100.0
			"yield_strength": return yield_value
			"ductility": return ductility_value
		return null


func run() -> PackedStringArray:
	failures.clear()
	_test_elastic_and_plastic()
	_test_damage()
	_test_impact()
	_test_actual_materials_and_grid()
	_test_invalid_updates()
	_test_volume_gradients()
	_test_layer_rotation_and_crack_volume()
	_test_resting_billet()
	return failures


func _tuning() -> Dictionary:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/mechanics.json"))
	data.gravity_m_s2 = [0, 0, 0]
	data.grid_bracing_area_scale = 0.0
	return data


func _test_resting_billet() -> void:
	var library = Library.new()
	_expect(library.load_directory("res://data/materials"), "Resting fixture loads")
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/mechanics.json"))
	for temperature in [20.0, 1000.0]:
		var billet = Billet.new(library, tuning)
		_expect(billet.build_grid(Vector3i(3, 3, 9), 0.015, Vector3(-0.015, 0, -0.06), "prototype_mithril", temperature), "Resting braced billet builds")
		var original: Array = billet.nodes.duplicate(true)
		var mass: float = billet.total_mass()
		for frame in 72:
			_expect(billet.step(1.0 / 90), "Gravity-only resting step")
			for index in billet.nodes.size():
				var node: Dictionary = billet.nodes[index]
				_expect(node.position.distance_to(original[index].position) < 0.0001, "Gravity cannot collapse or translate an unstruck billet")
				_near(node.plastic_strain, 0, 1e-8, "Own weight cannot plastically forge the fixture")
		for link: Dictionary in billet.connections:
			_expect(not link.broken and link.fracture_damage == 0, "Own weight cannot crack the fixture")
		_near(billet.total_mass(), mass, 1e-9, "Bracing preserves matter mass")


func _pair(material: Variant) -> Variant:
	var billet = Billet.new(material, _tuning())
	billet.add_node(Vector3(0, 1, 0), 1.0, "test", 20.0, Basis.IDENTITY, null, "layer-a")
	billet.add_node(Vector3(1, 1, 0), 1.0, "test", 20.0)
	billet.connect_nodes(0, 1, 1.0, 0.1)
	return billet


func _test_elastic_and_plastic() -> void:
	var billet = _pair(MaterialFixture.new())
	billet.nodes[1].position.x = 1.05
	_expect(billet.step(0.01), "Elastic step")
	_expect(billet.nodes[0].velocity.x > 0 and billet.nodes[1].velocity.x < 0, "Stretched spring restores inward")
	_near(billet.nodes[0].velocity.x + billet.nodes[1].velocity.x, 0, 1e-5, "Internal momentum conservation")
	_near(billet.connections[0].rest_length, 1, 1e-6, "Elastic rest length unchanged")
	var recovered := false
	for index in 160:
		_expect(billet.step(0.01), "Elastic recovery step")
		if billet.nodes[0].position.distance_to(billet.nodes[1].position) <= 1:
			recovered = true
	_expect(recovered, "Elastic spring returns through rest length")
	billet.nodes[0].position = Vector3(0, 1, 0)
	billet.nodes[1].position = Vector3(1.3, 1, 0)
	billet.nodes[0].velocity = Vector3.ZERO
	billet.nodes[1].velocity = Vector3.ZERO
	_expect(billet.step(0.001), "Plastic step")
	_expect(billet.connections[0].rest_length > 1 and billet.nodes[0].plastic_strain > 0, "Plasticity permanently changes rest length and strain")
	_near(billet.total_mass(), 2, 1e-6, "Mechanical mass conservation")
	_near(billet.nodes[0].impurity_mass.inclusion, 0.1, 1e-6, "Raw impurity initialization and conservation")
	_expect(billet.nodes[0].layer_id == "layer-a" and billet.nodes[0].composition.test == 1.0, "Material/layer identity preserved")


func _test_damage() -> void:
	for end in [0.7, 1.3]:
		var material := MaterialFixture.new()
		material.ductility_value = 0.01
		var billet = _pair(material)
		billet.nodes[1].position.x = end
		_expect(billet.step(0.001), "Fracture step")
		_expect(billet.connections[0].broken, "Compression and tension both fracture")
		_near(billet.connections[0].rest_length, 1, 1e-6, "Breaking increment cannot plastically change rest length")
		_near(billet.nodes[0].plastic_strain, 0, 1e-6, "Breaking increment cannot work-harden")
	var material := MaterialFixture.new()
	material.yield_value = 0.0
	var billet = _pair(material)
	billet.nodes[1].position.x = 1.2
	_expect(billet.step(0.001), "Subcritical damage step")
	var damage: float = billet.connections[0].fracture_damage
	_expect(damage > 0 and damage < 1, "Subcritical damage accumulates")
	for node: Dictionary in billet.nodes:
		node.plastic_strain = 0.0
		node.temperature = 1000.0
		node.velocity = Vector3.ZERO
	_expect(billet.step(0.001), "Reheated state step")
	_near(billet.connections[0].fracture_damage, damage, 1e-5, "Reheating/recovering hardening cannot heal fracture damage")
	billet.nodes[1].position.x = 0.9
	_expect(billet.step(0.001), "Reverse plasticity step")
	_expect(billet.connections[0].fracture_damage > damage, "Damage accumulates across reversed strain")
	material.ductility_value = 0.0
	var brittle = _pair(material)
	brittle.nodes[1].position.x = 0.99
	_expect(brittle.step(0.001) and brittle.connections[0].broken, "Zero ductility breaks on any plastic increment")


func _test_impact() -> void:
	var billet = Billet.new(MaterialFixture.new(), _tuning())
	billet.add_node(Vector3(-0.05, 1, 0), 1, "test", 20)
	billet.add_node(Vector3(0, 0.995, 0), 1, "test", 20)
	billet.add_node(Vector3(0.05, 1, 0), 3, "test", 20)
	billet.add_node(Vector3(2, 1, 0), 1, "test", 20)
	_expect(billet.hammer(Vector3(0, 1, 0), Vector3.UP, 0.2, 2, Vector3.DOWN), "Covered approaching face contacts")
	_near(billet.nodes[0].velocity.y, billet.nodes[2].velocity.y, 1e-6, "Contact distributes momentum by grain mass")
	var momentum: Vector3 = billet.nodes[0].velocity + billet.nodes[2].velocity * 3
	_near(momentum.y, billet.last_impulse.y, 1e-6, "Applied impulse equals node momentum change")
	_expect(billet.nodes[1].velocity == Vector3.ZERO and billet.nodes[3].velocity == Vector3.ZERO, "Buried and out-of-face nodes do not receive direct hammer impulse")
	_expect(billet.nodes[0].velocity.y > -1 and billet.nodes[0].velocity.y < 0, "Inelastic contact remains bounded by approaching hammer speed")
	_expect(not billet.hammer(Vector3(0, 1, 0), Vector3.UP, 0.2, 2, Vector3.UP), "Receding hammer does not contact")
	billet.nodes[0].position.y = 0.001
	billet.nodes[0].velocity = Vector3.DOWN
	_expect(billet.step(0.01), "Anvil crossing step")
	_near(billet.nodes[0].position.y, 0, 1e-6, "Anvil prevents penetration")
	_expect(billet.nodes[0].velocity.y >= 0, "Anvil removes inward normal velocity")


func _test_actual_materials_and_grid() -> void:
	var library := Library.new()
	_expect(library.load_directory("res://data/materials"), "Actual materials load")
	for temperature in [20.0, 1000.0]:
		var pair = Billet.new(library, _tuning())
		pair.add_node(Vector3(0, 0.02, 0), 0.0025, "prototype_mithril", temperature)
		pair.add_node(Vector3(0.01, 0.02, 0), 0.0025, "prototype_mithril", temperature)
		pair.connect_nodes(0, 1, 0.0001, 0.1)
		pair.nodes[1].position.x = 0.0098
		_expect(pair.step(1.0 / 90), "Centimetre link at authored stiffness steps")
		_expect(pair.nodes[0].position.distance_to(pair.nodes[1].position) < 0.02, "Shipped stiffness cannot explode a centimetre link to kilometres")
		_expect(pair.connections[0].broken == (temperature == 20), "Cold compression cracks while hot compression deforms")
	var grid = Billet.new(library, _tuning())
	_expect(grid.build_grid(Vector3i(3, 3, 3), 0.01, Vector3.ZERO, "prototype_mithril", 1000, "hot-layer"), "Construct granular billet")
	_expect(grid.nodes.size() == 27 and grid.connections.size() == 54 and grid.cells.size() == 8, "Regular grid has axial links and local volume cells")
	var density: float = library.sample("prototype_mithril", "density", {"temperature": 1000})
	var original_mass: float = grid.total_mass()
	_near(original_mass, density * pow(0.02, 3), 1e-8, "Boundary dual-volume masses match billet volume")
	var impurity_mass := 0.0
	for node: Dictionary in grid.nodes:
		for amount: float in node.impurity_mass.values():
			impurity_mass += amount
	_near(impurity_mass, original_mass * 0.004, 1e-9, "Material impurity fractions are local mass")
	for node: Dictionary in grid.nodes:
		node.position.y *= 0.9
	var has_spread := false
	for frame in 20:
		_expect(grid.step(1.0 / 90), "Hot compressed grid remains stable")
		for node: Dictionary in grid.nodes:
			has_spread = has_spread or node.plastic_spreading_increment > 0
	var minimum := INF
	var maximum := -INF
	var positions: Array[Vector3] = []
	for node: Dictionary in grid.nodes:
		positions.append(node.position)
		minimum = minf(minimum, node.position.x)
		maximum = maxf(maximum, node.position.x)
		_expect(node.position.is_finite() and node.position.length() < 0.2, "Finite, bounded deformed grid")
		_expect(node.orientation.is_finite(), "Local layer orientation remains finite")
	_expect(maximum - minimum > 0.0201 and has_spread, "Flattening causes lateral plastic spreading")
	var volume := 0.0
	for cell: Dictionary in grid.cells:
		volume += Geometry.volume_state(positions, cell.nodes).volume
	_near(volume, pow(0.02, 3), pow(0.02, 3) * 0.03, "Hot plastic flow approximately conserves volume")
	_near(grid.total_mass(), original_mass, 1e-9, "No material or impurities disappear during deformation")


func _test_invalid_updates() -> void:
	var material := MaterialFixture.new()
	var billet = _pair(material)
	var before: Array = billet.nodes.duplicate(true)
	var links: Array = billet.connections.duplicate(true)
	_expect(not billet.step(NAN) and not billet.step(1.0), "Reject invalid/oversized timesteps")
	_expect(billet.nodes == before and billet.connections == links, "Rejected timestep preserves all state")
	material.yield_value = -1.0
	_expect(not billet.step(0.01), "Reject invalid material response")
	_expect(billet.nodes == before and billet.connections == links, "Missing/bad curve cannot partially mutate state")
	_expect(billet.add_node(Vector3.ZERO, -1, "test", 20) == -1, "Reject negative node mass")
	_expect(billet.add_node(Vector3.ZERO, 1, "test", 20, Basis.IDENTITY, {"bad": 2}) == -1, "Reject impurity mass exceeding matter mass")
	var empty = Billet.new(material, _tuning())
	_expect(not empty.build_grid(Vector3i.ONE, 0.01, Vector3.ZERO, "test", 20), "Reject invalid grid dimensions")
	_expect(empty.nodes.is_empty() and empty.connections.is_empty(), "Failed grid construction is transactional")


func _test_volume_gradients() -> void:
	var positions: Array[Vector3] = []
	for z in 2:
		for y in 2:
			for x in 2:
				positions.append(Vector3(x, y, z))
	positions[7] += Vector3(0.2, 0.1, -0.1)
	var ids := PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7])
	var state := Geometry.volume_state(positions, ids)
	var sum := Vector3.ZERO
	for id in 8:
		sum += state.gradients[id]
		for axis in 3:
			var displaced := positions.duplicate()
			displaced[id][axis] += 0.001
			var difference: float = (Geometry.volume_state(displaced, ids).volume - state.volume) / 0.001
			_near(difference, state.gradients[id][axis], 0.0002, "Analytic volume gradient matches finite difference")
	_near(sum.length(), 0, 1e-6, "Volume constraint cannot add net internal force")


func _test_layer_rotation_and_crack_volume() -> void:
	var library := Library.new()
	_expect(library.load_directory("res://data/materials"), "Orientation fixture materials load")
	var grid = Billet.new(library, _tuning())
	_expect(grid.build_grid(Vector3i(2, 2, 2), 0.01, Vector3.ZERO, "prototype_mithril", 1000, "layer"), "Orientation fixture grid")
	var rotation := Basis(Vector3.UP, PI / 2)
	for node: Dictionary in grid.nodes:
		node.position = rotation * node.position + Vector3(0.1, 0.1, 0.1)
	_expect(grid.step(1.0 / 90), "Rigidly rotated grid steps")
	for node: Dictionary in grid.nodes:
		_expect(node.orientation.x.dot(rotation.x) > 0.999, "Local layer direction follows material rotation")
	grid.connections[0].broken = true
	_expect(grid.step(1.0 / 90) and not grid.cells[0].active, "Broken edges disable bridging volume constraints")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _near(actual: float, expected: float, tolerance: float, message: String) -> void:
	_expect(absf(actual - expected) <= tolerance, "%s (got %s, expected %s)" % [message, actual, expected])

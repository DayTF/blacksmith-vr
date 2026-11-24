extends RefCounted
## Engine-light elastoplastic lattice. XPBD compliance follows Macklin et al. (2016):
## https://mmacklin.com/xpbd.pdf . Fracture behavior is the user-approved #27 model.

const Geometry = preload("res://src/sim/billet_geometry.gd")
const Grid = preload("res://src/sim/billet_grid.gd")

var nodes: Array[Dictionary] = []
var connections: Array[Dictionary] = []
var cells: Array[Dictionary] = []
var discarded_mass := 0.0
var last_impulse := Vector3.ZERO
var errors := PackedStringArray()
var materials: Variant
var tuning: Dictionary


func _init(material_library: Variant, parameters: Dictionary) -> void:
	materials = material_library
	tuning = parameters.duplicate(true)


func add_node(position: Vector3, mass: float, material_id: String, temperature: float,
		orientation: Basis = Basis.IDENTITY, impurity_mass: Variant = null, layer_id: String = "") -> int:
	if not _number(mass) or mass <= 0.0 or not position.is_finite() or not is_finite(temperature):
		return -1
	if not orientation.is_finite() or orientation.determinant() <= 0.0:
		return -1
	var material: Variant = materials.get_material(material_id)
	if material == null:
		return -1
	var impurities: Dictionary = {}
	if impurity_mass == null:
		for impurity: Dictionary in material.raw_data.impurities:
			impurities[impurity.id] = mass * float(impurity.base_concentration)
	elif impurity_mass is Dictionary:
		impurities = impurity_mass.duplicate(true)
	else:
		return -1
	var total := 0.0
	for amount: Variant in impurities.values():
		if not _number(amount) or amount < 0.0:
			return -1
		total += float(amount)
	if total > mass:
		return -1
	nodes.append({"position": position, "velocity": Vector3.ZERO, "mass": mass,
		"material_id": material_id, "composition": {material_id: 1.0}, "temperature": temperature,
		"orientation": orientation, "reference_orientation": orientation,
		"impurity_mass": impurities, "layer_id": layer_id,
		"plastic_strain": 0.0, "plastic_strain_increment": 0.0,
		"plastic_spreading_increment": 0.0})
	return nodes.size() - 1


func connect_nodes(a: int, b: int, area: float, damping: float) -> int:
	if a < 0 or b < 0 or a >= nodes.size() or b >= nodes.size() or a == b:
		return -1
	if not _number(area) or area <= 0.0 or not _number(damping) or damping < 0.0:
		return -1
	var length: float = nodes[a].position.distance_to(nodes[b].position)
	if not is_finite(length) or length <= 0.0:
		return -1
	connections.append({"a": a, "b": b, "rest_length": length, "initial_length": length,
		"area": area, "damping": damping, "stiffness": 0.0,
		"reference_direction": (nodes[b].position - nodes[a].position) / length,
		"fracture_damage": 0.0, "broken": false})
	return connections.size() - 1


func build_grid(dimensions: Vector3i, spacing: float, origin: Vector3,
		material_id: String, temperature: float, layer_id: String = "") -> bool:
	errors.clear()
	if not nodes.is_empty() or not _parameters_valid():
		errors.append("Build a grid on an empty, configured billet.")
		return false
	var candidate: Variant = get_script().new(materials, tuning)
	if not Grid.populate(candidate, dimensions, spacing, origin, material_id, temperature, layer_id):
		errors.append_array(candidate.errors)
		return false
	nodes = candidate.nodes
	connections = candidate.connections
	cells = candidate.cells
	return true


func hammer(center: Vector3, normal: Vector3, radius: float, hammer_mass: float, velocity: Vector3) -> bool:
	last_impulse = Vector3.ZERO
	if not center.is_finite() or not normal.is_finite() or not velocity.is_finite() or normal.length_squared() == 0.0:
		return false
	if not _number(radius) or radius <= 0.0 or not _number(hammer_mass) or hammer_mass <= 0.0:
		return false
	for key in ["hammer_impulse_transfer", "hammer_contact_depth_m", "contact_tolerance_m"]:
		if not _number(tuning.get(key)) or tuning[key] < 0.0:
			return false
	if tuning.hammer_impulse_transfer > 1.0:
		return false
	var direction := normal.normalized()
	var candidates: Array[int] = []
	var depths := PackedFloat64Array()
	var front := -INF
	for index in nodes.size():
		var node := nodes[index]
		if not _node_valid(node):
			return false
		var offset: Vector3 = node.position - center
		var depth := offset.dot(direction)
		if depth <= tuning.contact_tolerance_m and depth >= -tuning.hammer_contact_depth_m and (offset - direction * depth).length_squared() <= radius * radius:
			candidates.append(index)
			depths.append(depth)
			front = maxf(front, depth)
	var contact: Array[int] = []
	var contact_mass := 0.0
	var momentum := Vector3.ZERO
	for index in candidates.size():
		if front - depths[index] <= tuning.contact_tolerance_m:
			var id := candidates[index]
			contact.append(id)
			contact_mass += nodes[id].mass
			momentum += nodes[id].velocity * nodes[id].mass
	if contact.is_empty() or not is_finite(contact_mass):
		return false
	var closing_speed: float = (velocity - momentum / contact_mass).dot(direction)
	if closing_speed >= 0.0:
		return false
	# Inelastic contact effective mass avoids transferring an entire hammer's
	# momentum into a single grain while the untracked hammer continues moving.
	var effective_mass := 1.0 / (1.0 / hammer_mass + 1.0 / contact_mass)
	var impulse: Vector3 = direction * closing_speed * effective_mass * tuning.hammer_impulse_transfer
	var change := impulse / contact_mass
	for id in contact:
		if not (nodes[id].velocity + change).is_finite():
			return false
	for id in contact:
		nodes[id].velocity += change
	last_impulse = impulse
	return true


func step(dt: float) -> bool:
	errors.clear()
	if not _parameters_valid() or not _number(dt) or dt < tuning.minimum_step_s or dt > tuning.maximum_step_s:
		errors.append("Invalid timestep or mechanics tuning.")
		return false
	var positions: Array[Vector3] = []
	var velocities: Array[Vector3] = []
	var strains := PackedFloat64Array()
	var increments := PackedFloat64Array()
	var spreading := PackedFloat64Array()
	for node in nodes:
		if not _node_valid(node):
			errors.append("Invalid node state.")
			return false
		positions.append(node.position)
		velocities.append(node.velocity)
		strains.append(node.plastic_strain)
		increments.append(0.0)
		spreading.append(0.0)
	var rests := PackedFloat64Array()
	var damages := PackedFloat64Array()
	var stiffnesses := PackedFloat64Array()
	var broken := PackedByteArray()
	for link in connections:
		if not _link_valid(link):
			errors.append("Invalid connection state.")
			return false
		rests.append(link.rest_length)
		damages.append(link.fracture_damage)
		stiffnesses.append(0.0)
		broken.append(int(link.broken))
	var active := PackedByteArray()
	for cell in cells:
		if not _cell_valid(cell):
			errors.append("Invalid cell state.")
			return false
		active.append(1)
	var h := dt / int(tuning.substeps)
	var gravity := Vector3(tuning.gravity_m_s2[0], tuning.gravity_m_s2[1], tuning.gravity_m_s2[2])
	for substep in int(tuning.substeps):
		var properties := _properties(strains)
		if properties.size() != nodes.size():
			return false
		for index in nodes.size():
			velocities[index] += gravity * h
			positions[index] += velocities[index] * h
		_project_anvil(positions, velocities, h)
		_plasticity(positions, properties, rests, damages, stiffnesses, broken, strains, increments, spreading)
		var lambdas := PackedFloat64Array()
		lambdas.resize(connections.size())
		var volume_lambdas := PackedFloat64Array()
		volume_lambdas.resize(cells.size())
		for index in cells.size():
			active[index] = 1
			for edge in cells[index].edges:
				if broken[edge] != 0:
					active[index] = 0
		for iteration in int(tuning.iterations):
			_solve_links(positions, velocities, rests, stiffnesses, broken, lambdas, h)
			_solve_volumes(positions, velocities, properties, active, volume_lambdas, h)
			_project_anvil(positions, velocities, h)
		_damp(positions, velocities, broken, h)
		for index in nodes.size():
			if positions[index].y <= tuning.anvil_height_m and velocities[index].y < 0.0:
				velocities[index].y = 0.0
	# Candidate arrays make failed updates transactional, including fracture/strain.
	for index in nodes.size():
		if not positions[index].is_finite() or not velocities[index].is_finite() or not is_finite(strains[index]):
			errors.append("Non-finite mechanical result; state retained.")
			return false
	for index in connections.size():
		if not is_finite(rests[index]) or not is_finite(damages[index]) or not is_finite(stiffnesses[index]):
			errors.append("Non-finite connection result; state retained.")
			return false
	for index in nodes.size():
		nodes[index].position = positions[index]
		nodes[index].velocity = velocities[index]
		nodes[index].plastic_strain = strains[index]
		nodes[index].plastic_strain_increment = increments[index]
		nodes[index].plastic_spreading_increment = spreading[index]
	for index in connections.size():
		connections[index].rest_length = rests[index]
		connections[index].fracture_damage = damages[index]
		connections[index].stiffness = stiffnesses[index]
		connections[index].broken = broken[index] != 0
	for index in cells.size():
		cells[index].active = active[index] != 0
	Geometry.update_orientations(nodes, cells, positions, active)
	return true


func _plasticity(positions: Array[Vector3], properties: Array[Dictionary], rests: PackedFloat64Array,
		damages: PackedFloat64Array, stiffnesses: PackedFloat64Array, broken: PackedByteArray,
		strains: PackedFloat64Array, increments: PackedFloat64Array, spreading: PackedFloat64Array) -> void:
	var weights := PackedFloat64Array()
	var changes := PackedFloat64Array()
	var spreads := PackedFloat64Array()
	weights.resize(nodes.size())
	changes.resize(nodes.size())
	spreads.resize(nodes.size())
	for index in connections.size():
		if broken[index] != 0:
			continue
		var link := connections[index]
		var a: int = link.a
		var b: int = link.b
		var modulus: float = minf(properties[a].youngs_modulus, properties[b].youngs_modulus)
		var yield_strength: float = minf(properties[a].yield_strength, properties[b].yield_strength)
		var ductility: float = minf(properties[a].ductility, properties[b].ductility)
		if modulus == 0.0:
			stiffnesses[index] = 0.0
			continue
		var length := maxf(positions[a].distance_to(positions[b]), tuning.minimum_length_m)
		var strain := (length - rests[index]) / rests[index]
		var yield_strain := yield_strength / modulus
		var increment := 0.0
		var extension := 0.0
		if absf(strain) > yield_strain:
			var target := length / (1.0 + signf(strain) * yield_strain)
			increment = absf(target - rests[index]) / link.initial_length
			var trial_damage := 1.0 if ductility == 0.0 else damages[index] + increment / ductility
			damages[index] = minf(trial_damage, 1.0)
			if trial_damage >= 1.0:
				broken[index] = 1
				stiffnesses[index] = 0.0
				continue
			extension = maxf(target - rests[index], 0.0) / link.initial_length
			rests[index] = maxf(target, tuning.minimum_length_m)
		stiffnesses[index] = modulus * link.area / rests[index]
		var weight: float = link.area * link.initial_length
		for id in [a, b]:
			weights[id] += weight
			changes[id] += increment * weight
			spreads[id] += extension * weight
	for index in nodes.size():
		if weights[index] > 0.0:
			var increment := changes[index] / weights[index]
			strains[index] += increment
			increments[index] += increment
			spreading[index] += spreads[index] / weights[index]


func _solve_links(positions: Array[Vector3], velocities: Array[Vector3], rests: PackedFloat64Array,
		stiffnesses: PackedFloat64Array, broken: PackedByteArray, lambdas: PackedFloat64Array, h: float) -> void:
	for index in connections.size():
		if broken[index] != 0 or stiffnesses[index] == 0.0:
			continue
		var link := connections[index]
		var a: int = link.a
		var b: int = link.b
		var delta := positions[b] - positions[a]
		var length := delta.length()
		var direction: Vector3 = delta / length if length > tuning.minimum_length_m else link.reference_direction
		var alpha := 1.0 / (stiffnesses[index] * h * h)
		var wa: float = 1.0 / nodes[a].mass
		var wb: float = 1.0 / nodes[b].mass
		var change := (-(length - rests[index]) - alpha * lambdas[index]) / (wa + wb + alpha)
		var correction_a := direction * wa * change
		var correction_b := direction * wb * change
		positions[a] -= correction_a
		positions[b] += correction_b
		# Accumulate analytic increments, avoiding cancellation of float positions.
		velocities[a] -= correction_a / h
		velocities[b] += correction_b / h
		lambdas[index] += change


func _solve_volumes(positions: Array[Vector3], velocities: Array[Vector3], properties: Array[Dictionary],
		active: PackedByteArray, lambdas: PackedFloat64Array, h: float) -> void:
	for index in cells.size():
		if active[index] == 0:
			continue
		var cell := cells[index]
		var bulk := INF
		for id in cell.nodes:
			bulk = minf(bulk, properties[id].bulk_modulus)
		if bulk == 0.0:
			continue
		var state := Geometry.volume_state(positions, cell.nodes)
		# E = K/(2 V0) * (V - V0)^2, so compliance = V0/K.
		var alpha: float = cell.rest_volume / (bulk * h * h)
		var denominator := alpha
		for local in 8:
			denominator += state.gradients[local].length_squared() / nodes[cell.nodes[local]].mass
		if denominator == 0.0:
			continue
		var change: float = (-(state.volume - cell.rest_volume) - alpha * lambdas[index]) / denominator
		for local in 8:
			var id: int = cell.nodes[local]
			var correction: Vector3 = state.gradients[local] * (change / nodes[id].mass)
			positions[id] += correction
			velocities[id] += correction / h
		lambdas[index] += change


func _damp(positions: Array[Vector3], velocities: Array[Vector3], broken: PackedByteArray, h: float) -> void:
	for index in connections.size():
		if broken[index] != 0:
			continue
		var link := connections[index]
		var delta := positions[link.b] - positions[link.a]
		if delta.length() <= tuning.minimum_length_m:
			continue
		var direction := delta.normalized()
		var relative_speed := (velocities[link.b] - velocities[link.a]).dot(direction)
		var wa: float = 1.0 / nodes[link.a].mass
		var wb: float = 1.0 / nodes[link.b].mass
		var impulse: float = link.damping * h * relative_speed / (1.0 + link.damping * h * (wa + wb))
		velocities[link.a] += direction * impulse * wa
		velocities[link.b] -= direction * impulse * wb


func _project_anvil(positions: Array[Vector3], velocities: Array[Vector3], h: float) -> void:
	for index in positions.size():
		if positions[index].y < tuning.anvil_height_m:
			velocities[index].y += (tuning.anvil_height_m - positions[index].y) / h
			positions[index].y = tuning.anvil_height_m


func _properties(strains: PackedFloat64Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var cache: Dictionary = {}
	var keys := ["youngs_modulus", "yield_strength", "ductility"]
	if not cells.is_empty():
		keys.append("bulk_modulus")
	for index in nodes.size():
		var node := nodes[index]
		var cache_key := [node.material_id, node.temperature, strains[index]]
		if not cache.has(cache_key):
			var state := {"temperature": node.temperature, "plastic_strain": strains[index]}
			var properties: Dictionary = {}
			for key in keys:
				var value: Variant = materials.sample(node.material_id, key, state)
				if not _number(value) or value < 0.0:
					errors.append("Invalid or unavailable %s for %s." % [key, node.material_id])
					return []
				properties[key] = float(value)
			cache[cache_key] = properties
		result.append(cache[cache_key])
	return result


func _parameters_valid() -> bool:
	for key in ["minimum_step_s", "maximum_step_s", "minimum_length_m", "spring_area_m2"]:
		if not _number(tuning.get(key)) or tuning[key] <= 0.0:
			return false
	for key in ["substeps", "iterations"]:
		if not _number(tuning.get(key)) or tuning[key] < 1 or tuning[key] != floorf(tuning[key]):
			return false
	if not _number(tuning.get("anvil_height_m")) or not _number(tuning.get("damping_ns_per_m")) or tuning.damping_ns_per_m < 0.0:
		return false
	var gravity: Variant = tuning.get("gravity_m_s2")
	if not gravity is Array or gravity.size() != 3:
		return false
	for component: Variant in gravity:
		if not _number(component):
			return false
	return tuning.minimum_step_s <= tuning.maximum_step_s


func _node_valid(node: Dictionary) -> bool:
	if not node.position.is_finite() or not node.velocity.is_finite() or not _number(node.mass) or node.mass <= 0.0:
		return false
	if not _number(node.temperature) or not _number(node.plastic_strain) or node.plastic_strain < 0.0:
		return false
	if not node.orientation.is_finite() or node.orientation.determinant() <= 0.0:
		return false
	# A lattice point is a single constituent; layered billets use distinct points.
	if node.composition.size() != 1 or node.composition.get(node.material_id) != 1.0:
		return false
	var impurity_total := 0.0
	for amount: Variant in node.impurity_mass.values():
		if not _number(amount) or amount < 0.0:
			return false
		impurity_total += amount
	return impurity_total <= node.mass


func _link_valid(link: Dictionary) -> bool:
	if link.a < 0 or link.b < 0 or link.a >= nodes.size() or link.b >= nodes.size() or link.a == link.b:
		return false
	for key in ["rest_length", "initial_length", "area"]:
		if not _number(link[key]) or link[key] <= 0.0:
			return false
	return (
		_number(link.damping) and link.damping >= 0.0
		and _number(link.fracture_damage) and link.fracture_damage >= 0.0
		and (link.broken or link.fracture_damage < 1.0)
		and link.reference_direction.is_finite()
	)


func _cell_valid(cell: Dictionary) -> bool:
	if not _number(cell.rest_volume) or cell.rest_volume <= 0.0 or cell.nodes.size() != 8 or cell.edges.size() != 12:
		return false
	for id in cell.nodes:
		if id < 0 or id >= nodes.size():
			return false
	for edge in cell.edges:
		if edge < 0 or edge >= connections.size():
			return false
	return true


func total_mass() -> float:
	var total := discarded_mass
	for node in nodes:
		total += node.mass
	return total


static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

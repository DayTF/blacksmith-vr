extends RefCounted
## Scripted M0 placement, folding and hammer-driven interface bonds.
const Reference = preload("res://src/sim/granular_billet.gd")
const Surface = preload("res://src/sim/billet_surface.gd")

var errors := PackedStringArray()
var weld_attempts: Array[Dictionary] = []
var _surface: RefCounted
var _tuning: Dictionary


func _init(surface_tuning: Dictionary, weld_tuning: Dictionary) -> void:
	_surface = Surface.new(surface_tuning)
	_tuning = weld_tuning.duplicate(true)


func stack_grid(billet: Variant, dimensions: Vector3i, spacing: float, origin: Vector3,
		material_id: String, temperature: float, layer_id: String) -> PackedInt32Array:
	errors.clear()
	var layer := Reference.new(billet.materials, billet.tuning)
	if not layer.build_grid(dimensions, spacing, origin, material_id, temperature, layer_id):
		errors.append_array(layer.errors)
		return PackedInt32Array()
	var nodes: Array[Dictionary] = billet.nodes
	var links: Array[Dictionary] = billet.connections
	var cells: Array[Dictionary] = billet.cells
	var added := PackedInt32Array()
	var first_node := nodes.size()
	var first_link := links.size()
	for node in layer.nodes:
		added.append(nodes.size())
		nodes.append(node)
	for link in layer.connections:
		link.a += first_node
		link.b += first_node
		links.append(link)
	for cell in layer.cells:
		var ids: PackedInt32Array = cell.nodes
		var edges: PackedInt32Array = cell.edges
		for i in ids.size():
			ids[i] += first_node
		for i in edges.size():
			edges[i] += first_link
		cell.nodes = ids
		cell.edges = edges
		cells.append(cell)
	return added


func fold(billet: Variant, indices: PackedInt32Array, pivot: Vector3, axis: Vector3,
		angle: float) -> bool:
	errors.clear()
	if indices.is_empty() or not pivot.is_finite() or not axis.is_finite() or axis.is_zero_approx() or not is_finite(angle):
		return _fail("A scripted fold needs valid points, pivot, axis and angle.")
	var rotation := Basis(axis.normalized(), angle)
	var nodes: Array[Dictionary] = billet.nodes
	var staged: Array[Dictionary] = nodes.duplicate()
	var selected := {}
	var in_cells := {}
	for cell: Dictionary in billet.cells:
		for id: int in cell.nodes:
			in_cells[id] = true
	for id in indices:
		if id < 0 or id >= nodes.size() or selected.has(id):
			return _fail("Invalid or repeated fold point.")
		selected[id] = true
		var node := nodes[id].duplicate()
		node.position = pivot + rotation * (node.position - pivot)
		node.velocity = rotation * node.velocity
		node.orientation = rotation * node.orientation
		if not in_cells.has(id):
			node.reference_orientation = rotation * node.reference_orientation
		if not node.velocity.is_finite() or not node.orientation.is_finite() or not node.reference_orientation.is_finite():
			return _fail("Fold geometry exceeds representable scale.")
		staged[id] = node
	var surface: Dictionary = _surface.evaluate(staged, billet.cells)
	if surface.is_empty() or surface.unresolved_cells != 0:
		return _fail("The scripted fold would leave unresolved matter cells.")
	for id in indices:
		nodes[id].merge(staged[id], true)
	for link: Dictionary in billet.connections:
		if selected.has(link.a) and selected.has(link.b):
			link.reference_direction = rotation * link.reference_direction
	return true


func hammer(billet: Variant, center: Vector3, normal: Vector3, radius: float,
		mass: float, velocity: Vector3, pairs: Array[Vector2i]) -> bool:
	errors.clear()
	weld_attempts.clear()
	if pairs.is_empty():
		return billet.hammer(center, normal, radius, mass, velocity)
	var tolerance: Variant = _tuning.get("contact_gap_m")
	if not _number(tolerance) or tolerance <= 0.0:
		return _fail("Welding needs a positive interface gap tolerance.")
	if not center.is_finite() or not normal.is_finite() or normal.is_zero_approx():
		return _fail("Welding needs a finite hammer center and direction.")
	var nodes: Array[Dictionary] = billet.nodes
	var links: Array[Dictionary] = billet.connections
	var surface: Dictionary = _surface.evaluate(nodes, billet.cells, true)
	if surface.is_empty():
		return _fail("Invalid interface geometry.")
	var direction := normal.normalized()
	var candidates: Array[Dictionary] = []
	var existing := {}
	for link in links:
		existing[Vector2i(mini(link.a, link.b), maxi(link.a, link.b))] = true
	for pair in pairs:
		var key := Vector2i(mini(pair.x, pair.y), maxi(pair.x, pair.y))
		if key.x < 0 or key.y >= nodes.size() or key.x == key.y:
			return _fail("Invalid scripted interface pair.")
		if existing.has(key):
			continue
		existing[key] = true
		var first := nodes[key.x]
		var second := nodes[key.y]
		var delta: Vector3 = second.position - first.position
		var offset: Vector3 = first.position + delta * 0.5 - center
		if delta.length() > tolerance or offset.dot(direction) > tolerance or offset.slide(direction).length() > radius:
			continue
		var contact := _contact(surface.boundary, key, direction)
		if contact.is_empty():
			continue
		var anchors: Vector2i = contact.anchors
		var anchor_key := Vector2i(mini(anchors.x, anchors.y), maxi(anchors.x, anchors.y))
		if existing.has(anchor_key):
			continue
		existing[anchor_key] = true
		# Back the contact with the opposite corner from each cell. The
		# spring spans matter and has a finite gauge length at zero gap.
		var span: Vector3 = nodes[anchors.y].position - nodes[anchors.x].position
		if not span.is_finite() or span.length() <= billet.tuning.minimum_length_m:
			return _fail("Collapsed weld span.")
		var quality := 1.0
		for node in [first, second]:
			var material: Variant = billet.materials.get_material(node.material_id)
			if material == null:
				return _fail("Unknown weld material.")
			var process: Dictionary = material.raw_data.get("processes", {}).get("welding", {})
			if not process.get("enabled", true):
				quality = 0.0
				continue
			var value: Variant = material.sample("weldability", {"temperature": node.temperature,
				"plastic_strain": node.plastic_strain})
			if not _number(value) or value < 0.0 or value > 1.0:
				return _fail("Weldability must be a ratio in [0, 1].")
			quality = minf(quality, value)
		candidates.append({"pair": key, "area": contact.area, "quality": quality, "span": span, "anchors": anchors})
	if not billet.hammer(center, normal, radius, mass, velocity):
		return false
	if billet.last_impulse == Vector3.ZERO:
		return true
	for weld in candidates:
		var pair: Vector2i = weld.pair
		var quality: float = weld.quality
		var index := -1
		if quality > 0.0:
			var span: Vector3 = weld.span
			var length := span.length()
			var anchors: Vector2i = weld.anchors
			var area: float = weld.area * quality
			index = links.size()
			links.append({"a": anchors.x, "b": anchors.y, "rest_length": length, "initial_length": length,
				"area": area, "thermal_area_m2": area, "damping": billet.tuning.damping_ns_per_m * quality,
				"stiffness": 0.0, "reference_direction": span / length,
				"fracture_damage": 0.0, "broken": false, "weld_quality": quality})
		weld_attempts.append({"pair": pair, "quality": quality, "link": index})
	return true


func _contact(boundary: Array[Dictionary], pair: Vector2i, direction: Vector3) -> Dictionary:
	var best := {}
	var largest_area := 0.0
	for first in boundary:
		var first_neighbors: Array = first.touching.get(pair.x, [])
		for second in boundary:
			if not first_neighbors.has(second.owner) or not second.touching.get(pair.y, []).has(first.owner):
				continue
			var opposition: float = maxf(0.0, -first.normal.dot(second.normal))
			var compression: float = absf(first.normal.dot(direction))
			var area: float = minf(first.area, second.area) * opposition * compression / 4.0
			if area > largest_area:
				largest_area = area
				best = {"area": area, "anchors": Vector2i(first.backing[pair.x], second.backing[pair.y])}
	return best

func _fail(message: String) -> bool:
	errors.append(message)
	return false


func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(value)

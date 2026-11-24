extends RefCounted

const Materials = preload("res://src/sim/material_library.gd")
const Reference = preload("res://src/sim/granular_billet.gd")
const Native = preload("res://src/sim/native_granular_billet.gd")
const Geometry = preload("res://src/sim/billet_geometry.gd")
const Hammer = preload("res://src/sim/tracked_hammer.gd")


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var materials := Materials.new()
	if not materials.load_directory("res://data/materials"):
		return materials.errors
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/mechanics.json"))
	tuning.maximum_density_multiplier = 1.25
	tuning.anvil_friction_coefficient = 0.45
	for backend in [Reference, Native]:
		var billet: RefCounted = backend.new(materials, tuning)
		if not billet.build_grid(Vector3i(3, 2, 5), 0.015, Vector3(-0.015, 0, -0.06), "prototype_mithril", 1000):
			failures.append("Density-limited fixture must build.")
			continue
		var mass: float = billet.total_mass()
		var sweep := Hammer.new()
		var failed := false
		for hit in 8:
			var x := 0.005 if hit % 2 else -0.005
			var top := 0.0
			for node: Dictionary in billet.nodes:
				var offset := Vector2(node.position.x - x, node.position.z + 0.03)
				if offset.length_squared() <= 0.023 * 0.023:
					top = maxf(top, node.position.y)
			sweep.reset_tracking()
			sweep.apply(billet, Vector3(x, top + 0.02, -0.03), 0.01, 0.023, 0.5, 0.1, 0.25)
			if not sweep.apply(billet, Vector3(x, top - 0.02, -0.03), 0.01, 0.023, 0.5, 0.1, 0.25):
				failures.append("Repeated-strike fixture missed at hit %d." % (hit + 1))
				failed = true
				break
			for step in 8:
				if not billet.step(1.0 / 90.0) or _minimum_volume_ratio(billet) < 0.792:
					failures.append("Density bound failed after hit %d: %s" % [hit + 1, billet.errors])
					failed = true
					break
			if failed:
				break
		if failed:
			continue
		var has_fracture := false
		for cell: Dictionary in billet.cells:
			has_fracture = has_fracture or not cell.active
		if not has_fracture or not is_equal_approx(billet.total_mass(), mass):
			failures.append("Compression protection must retain fracture and conserve mass.")
		billet = backend.new(materials, tuning)
		billet.build_grid(Vector3i(2, 2, 2), 0.015, Vector3.ZERO, "prototype_mithril", 1000)
		for node: Dictionary in billet.nodes:
			node.position = Vector3.ZERO
			node.velocity = Vector3.ZERO
		for link: Dictionary in billet.connections:
			link.rest_length = tuning.minimum_length_m
			link.initial_length = tuning.minimum_length_m
			link.reference_direction = Vector3.ZERO
		var before: Array = billet.nodes.duplicate(true)
		if billet.step(1.0 / 90.0) or billet.nodes != before:
			failures.append("An unresolvable collapsed cell must fail without committing a step.")
		_test_detached_corner(backend, materials, tuning, failures)
	return failures


func _test_detached_corner(backend: Script, materials: RefCounted, tuning: Dictionary, failures: PackedStringArray) -> void:
	var billet: RefCounted = backend.new(materials, tuning)
	billet.tuning.gravity_m_s2 = [0, 0, 0]
	billet.build_grid(Vector3i(2, 2, 2), 0.015, Vector3.UP, "prototype_mithril", 1000)
	for link: Dictionary in billet.connections:
		if link.a == 0 or link.b == 0:
			link.broken = true
	billet.nodes[0].velocity = Vector3.RIGHT
	var before: Array = billet.nodes.duplicate(true)
	if not billet.step(0.01):
		failures.append("A separated corner should not trigger a density failure.")
		return
	if not billet.nodes[0].position.is_equal_approx(before[0].position + Vector3.RIGHT * 0.01):
		failures.append("A severed corner must move without volume coupling to its old cell.")
	for id in range(1, billet.nodes.size()):
		if not billet.nodes[id].position.is_equal_approx(before[id].position):
			failures.append("Severed material must not push the old cell through a virtual tetrahedron.")
			break


func _minimum_volume_ratio(billet: RefCounted) -> float:
	var minimum := INF
	var links: Array[Dictionary] = billet.connections
	var broken := PackedByteArray()
	for link in links:
		broken.append(int(link.broken))
	var components := Geometry.connected_components(billet.nodes.size(), links, broken)
	for cell: Dictionary in billet.cells:
		for tetra: Array in Geometry.TETRAHEDRA:
			var component := components[cell.nodes[tetra[0]]]
			if not [tetra[1], tetra[2], tetra[3]].all(func(local: int): return components[cell.nodes[local]] == component):
				continue
			var root: Vector3 = billet.nodes[cell.nodes[tetra[0]]].position
			var a: Vector3 = billet.nodes[cell.nodes[tetra[1]]].position - root
			var b: Vector3 = billet.nodes[cell.nodes[tetra[2]]].position - root
			var c: Vector3 = billet.nodes[cell.nodes[tetra[3]]].position - root
			minimum = minf(minimum, a.dot(b.cross(c)) / cell.rest_volume)
	return minimum

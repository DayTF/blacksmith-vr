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
			var top := 0.0
			for node: Dictionary in billet.nodes:
				top = maxf(top, node.position.y)
			var x := 0.005 if hit % 2 else -0.005
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
		for node: Dictionary in billet.nodes:
			node.position = Vector3.ZERO
			node.velocity = Vector3.ZERO
		var before: Array = billet.nodes.duplicate(true)
		if billet.step(1.0 / 90.0) or billet.nodes != before:
			failures.append("An unresolvable collapsed cell must fail without committing a step.")
	return failures


func _minimum_volume_ratio(billet: RefCounted) -> float:
	var minimum := INF
	for cell: Dictionary in billet.cells:
		for tetra: Array in Geometry.TETRAHEDRA:
			var root: Vector3 = billet.nodes[cell.nodes[tetra[0]]].position
			var a: Vector3 = billet.nodes[cell.nodes[tetra[1]]].position - root
			var b: Vector3 = billet.nodes[cell.nodes[tetra[2]]].position - root
			var c: Vector3 = billet.nodes[cell.nodes[tetra[3]]].position - root
			minimum = minf(minimum, a.dot(b.cross(c)) / cell.rest_volume)
	return minimum

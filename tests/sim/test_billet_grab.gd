extends RefCounted

const Materials = preload("res://src/sim/material_library.gd")
const Reference = preload("res://src/sim/granular_billet.gd")
const Native = preload("res://src/sim/native_granular_billet.gd")
const Grab = preload("res://src/sim/billet_grab.gd")


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var materials := Materials.new()
	if not materials.load_directory("res://data/materials"):
		return materials.errors
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/mechanics.json"))
	for backend in [Reference, Native]:
		var billet: RefCounted = backend.new(materials, tuning)
		if not billet.build_grid(Vector3i(2, 2, 2), 0.015, Vector3.ZERO, "prototype_mithril", 1000.0):
			failures.append("Grab fixture could not build.")
			continue
		var debris: int = billet.add_node(Vector3(0.10, 0, 0), 0.0001, "prototype_embersteel", 700.0)
		var original_mass: float = billet.total_mass()
		var original: Array[Dictionary] = billet.nodes.duplicate(true)
		var grab := Grab.new()
		if grab.acquire(billet, Transform3D(Basis.IDENTITY, Vector3.UP), 0.05):
			failures.append("An off-hand grip out of reach must not acquire the billet.")
			grab.release()
		var initial := Transform3D(Basis.IDENTITY, Vector3.ZERO)
		if not grab.acquire(billet, initial, 0.025):
			failures.append("A nearby grip must acquire the connected piece.")
			continue
		var rotation := Basis(Vector3.BACK, PI * 0.5)
		var pose := Transform3D(rotation, Vector3(0.02, -0.005, 0.03))
		if not grab.move(pose):
			failures.append("Valid held pose should move and rotate the billet.")
			continue
		var nodes: Array[Dictionary] = billet.nodes
		if nodes[debris] != original[debris] or not is_equal_approx(billet.total_mass(), original_mass):
			failures.append("Grabbing should conserve mass and leave disconnected debris alone.")
		for id in debris:
			var point := nodes[id]
			var expected: Vector3 = pose * original[id].position + Vector3.UP * 0.005
			if not point.position.is_equal_approx(expected) or not point.orientation.is_equal_approx(rotation):
				failures.append("Placement must preserve rigid shape and align with the anvil top.")
				break
			if point.impurity_mass != original[id].impurity_mass or point.temperature != original[id].temperature:
				failures.append("Placement must preserve local material state.")
				break
		var last_position: Vector3 = nodes[0].position
		grab.release()
		if grab.held or grab.move(initial) or nodes[0].position != last_position:
			failures.append("Release or tracking loss must stop following the grip without a teleport.")
		if not billet.step(1.0 / 90.0):
			failures.append("Released material must resume mechanics: " + str(billet.errors))
	return failures

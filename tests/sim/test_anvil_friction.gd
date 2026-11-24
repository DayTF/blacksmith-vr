extends RefCounted

const Materials = preload("res://src/sim/material_library.gd")
const Reference = preload("res://src/sim/granular_billet.gd")
const Native = preload("res://src/sim/native_granular_billet.gd")

func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var materials := Materials.new()
	if not materials.load_directory("res://data/materials"):
		return materials.errors
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/mechanics.json"))
	var results: Array[Vector3] = []
	for backend in [Reference, Native]:
		for coefficient in [0.0, 0.45]:
			var billet: RefCounted = backend.new(materials, tuning)
			billet.tuning.anvil_friction_coefficient = coefficient
			# Opposite tangential velocities represent the two sides of a yawing billet.
			billet.add_node(Vector3(-0.02, 0.0, 0.0), 0.01, "prototype_mithril", 1000.0)
			billet.add_node(Vector3(0.02, 0.0, 0.0), 0.01, "prototype_mithril", 1000.0)
			billet.add_node(Vector3.UP, 0.01, "prototype_mithril", 1000.0)
			billet.nodes[0].velocity = Vector3(0.1, 0.0, 0.2)
			billet.nodes[1].velocity = Vector3(0.1, 0.0, -0.2)
			billet.nodes[2].velocity = Vector3(0.1, 0.0, 0.2)
			for step in 8:
				if not billet.step(1.0 / 90.0):
					failures.append("Anvil friction fixture could not step: " + str(billet.errors))
					break
			var expected := Vector3(0.1, 0.0, 0.2) if coefficient == 0.0 else Vector3.ZERO
			var left: Vector3 = billet.nodes[0].velocity
			var right: Vector3 = billet.nodes[1].velocity
			var airborne: Vector3 = billet.nodes[2].velocity
			if not left.is_equal_approx(expected) or not right.is_equal_approx(expected * Vector3(1, 1, -1)):
				failures.append("Normal support must stop contact slip without reversing its direction.")
			if not Vector2(airborne.x, airborne.z).is_equal_approx(Vector2(0.1, 0.2)):
				failures.append("Airborne points must retain tangential velocity.")
			results.append(left)
	if not results[0].is_equal_approx(results[2]) or not results[1].is_equal_approx(results[3]):
		failures.append("Contact friction requires native/reference parity.")
	return failures

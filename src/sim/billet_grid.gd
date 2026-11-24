extends RefCounted
## Regular-grid construction; nodes are dual volumes around lattice vertices.

const Geometry = preload("res://src/sim/billet_geometry.gd")


static func populate(billet: Variant, dimensions: Vector3i, spacing: float,
		origin: Vector3, material_id: String, temperature: float, layer_id: String) -> bool:
	if dimensions.x < 2 or dimensions.y < 2 or dimensions.z < 2 or not spacing > 0.0 or not is_finite(spacing) or not origin.is_finite():
		billet.errors.append("A grid needs at least 2 nodes per axis and finite positive spacing.")
		return false
	var bracing: Variant = billet.tuning.get("grid_bracing_area_scale", 0.0)
	if not (bracing is float or bracing is int) or not is_finite(bracing) or bracing < 0.0:
		billet.errors.append("Grid bracing area scale must be finite and nonnegative.")
		return false
	var density: Variant = billet.materials.sample(material_id, "density", {"temperature": temperature, "plastic_strain": 0.0})
	if not (density is float or density is int) or not is_finite(density) or density <= 0.0:
		billet.errors.append("Grid construction requires a positive density curve.")
		return false
	for z in dimensions.z:
		for y in dimensions.y:
			for x in dimensions.x:
				var weight := 1.0
				for pair in [[x, dimensions.x], [y, dimensions.y], [z, dimensions.z]]:
					if pair[0] == 0 or pair[0] == pair[1] - 1:
						weight *= 0.5
				var mass: float = density * spacing * spacing * spacing * weight
				if billet.add_node(origin + Vector3(x, y, z) * spacing, mass, material_id,
					temperature, Basis.IDENTITY, null, layer_id) < 0:
					billet.errors.append("Invalid grid node state.")
					return false
	var links: Dictionary = {}
	for z in dimensions.z:
		for y in dimensions.y:
			for x in dimensions.x:
				var point := Vector3i(x, y, z)
				var a := _index(point, dimensions)
				for axis in [Vector3i.RIGHT, Vector3i.UP, Vector3i.BACK]:
					var neighbor: Vector3i = point + axis
					if neighbor.x >= dimensions.x or neighbor.y >= dimensions.y or neighbor.z >= dimensions.z:
						continue
					var b := _index(neighbor, dimensions)
					var area: float = billet.tuning.spring_area_m2
					for component in 3:
						if axis[component] == 0 and (point[component] == 0 or point[component] == dimensions[component] - 1):
							area *= 0.5
					var link: int = billet.connect_nodes(a, b, area, billet.tuning.damping_ns_per_m)
					if link < 0:
						billet.errors.append("Grid links collapsed or exceeded representable geometry.")
						return false
					links[Vector2i(a, b)] = link
	var positions: Array[Vector3] = []
	for node: Dictionary in billet.nodes:
		positions.append(node.position)
	for z in dimensions.z - 1:
		for y in dimensions.y - 1:
			for x in dimensions.x - 1:
				var ids := PackedInt32Array()
				for dz in 2:
					for dy in 2:
						for dx in 2:
							ids.append(_index(Vector3i(x + dx, y + dy, z + dz), dimensions))
				var edges := PackedInt32Array()
				for pair in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3],
					[4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
					edges.append(links[Vector2i(ids[pair[0]], ids[pair[1]])])
				var volume: float = Geometry.volume_state(positions, ids).volume
				if not is_finite(volume) or volume <= 0.0:
					billet.errors.append("Grid cells need positive finite volume.")
					return false
				billet.cells.append({"nodes": ids, "edges": edges, "rest_volume": volume, "active": true})
	# Axial springs plus volume alone have almost no linear shear resistance.
	# Face/body diagonals brace that mechanism without pinning nodes to the scene.
	if bracing > 0.0:
		for z in dimensions.z:
			for y in dimensions.y:
				for x in dimensions.x:
					var point := Vector3i(x, y, z)
					var a := _index(point, dimensions)
					for dz in range(-1, 2):
						for dy in range(-1, 2):
							for dx in range(-1, 2):
								if absi(dx) + absi(dy) + absi(dz) < 2:
									continue
								var neighbor := point + Vector3i(dx, dy, dz)
								if neighbor.x < 0 or neighbor.y < 0 or neighbor.z < 0 or neighbor.x >= dimensions.x or neighbor.y >= dimensions.y or neighbor.z >= dimensions.z:
									continue
								var b := _index(neighbor, dimensions)
								if b > a and billet.connect_nodes(a, b, billet.tuning.spring_area_m2 * bracing, billet.tuning.damping_ns_per_m) < 0:
									billet.errors.append("Invalid diagonal brace geometry.")
									return false
	return true


static func _index(point: Vector3i, dimensions: Vector3i) -> int:
	return point.x + dimensions.x * (point.y + dimensions.y * point.z)

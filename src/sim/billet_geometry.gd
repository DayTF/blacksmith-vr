extends RefCounted
## Numerical cell geometry only; gradients are analytic derivatives of signed volume.

const TETRAHEDRA = [[0, 1, 3, 7], [0, 3, 2, 7], [0, 2, 6, 7],
	[0, 6, 4, 7], [0, 4, 5, 7], [0, 5, 1, 7]]


static func volume_state(positions: Array[Vector3], ids: PackedInt32Array) -> Dictionary:
	var gradients: Array[Vector3] = []
	gradients.resize(8)
	gradients.fill(Vector3.ZERO)
	var volume := 0.0
	for tetra in TETRAHEDRA:
		var a: Vector3 = positions[ids[tetra[1]]] - positions[ids[tetra[0]]]
		var b: Vector3 = positions[ids[tetra[2]]] - positions[ids[tetra[0]]]
		var c: Vector3 = positions[ids[tetra[3]]] - positions[ids[tetra[0]]]
		volume += a.dot(b.cross(c)) / 6.0
		var g1 := b.cross(c) / 6.0
		var g2 := c.cross(a) / 6.0
		var g3 := a.cross(b) / 6.0
		gradients[tetra[0]] -= g1 + g2 + g3
		gradients[tetra[1]] += g1
		gradients[tetra[2]] += g2
		gradients[tetra[3]] += g3
	return {"volume": volume, "gradients": gradients}


static func connected_components(node_count: int, links: Array[Dictionary], broken: PackedByteArray) -> PackedInt32Array:
	var roots := PackedInt32Array()
	roots.resize(node_count)
	for id in node_count:
		roots[id] = id
	for index in links.size():
		if broken[index]:
			continue
		var a := _root(roots, links[index].a)
		var b := _root(roots, links[index].b)
		roots[maxi(a, b)] = mini(a, b)
	for id in node_count:
		roots[id] = _root(roots, id)
	return roots


static func _root(roots: PackedInt32Array, id: int) -> int:
	while roots[id] != id:
		roots[id] = roots[roots[id]]
		id = roots[id]
	return id


static func update_orientations(nodes: Array[Dictionary], cells: Array[Dictionary],
		positions: Array[Vector3], active: PackedByteArray) -> void:
	var x_axes: Array[Vector3] = []
	var y_axes: Array[Vector3] = []
	var z_axes: Array[Vector3] = []
	x_axes.resize(nodes.size())
	y_axes.resize(nodes.size())
	z_axes.resize(nodes.size())
	x_axes.fill(Vector3.ZERO)
	y_axes.fill(Vector3.ZERO)
	z_axes.fill(Vector3.ZERO)
	for index in cells.size():
		if active[index] == 0:
			continue
		var ids: PackedInt32Array = cells[index].nodes
		var x := Vector3.ZERO
		var y := Vector3.ZERO
		var z := Vector3.ZERO
		for offset in [0, 2, 4, 6]:
			x += positions[ids[offset + 1]] - positions[ids[offset]]
		for offset in [0, 1, 4, 5]:
			y += positions[ids[offset + 2]] - positions[ids[offset]]
		for offset in [0, 1, 2, 3]:
			z += positions[ids[offset + 4]] - positions[ids[offset]]
		for id in ids:
			x_axes[id] += x
			y_axes[id] += y
			z_axes[id] += z
	for index in nodes.size():
		var basis := Basis(x_axes[index], y_axes[index], z_axes[index])
		if basis.is_finite() and basis.determinant() > 0.0:
			var candidate: Basis = basis.orthonormalized() * nodes[index].reference_orientation
			if candidate.is_finite() and candidate.determinant() > 0.0:
				nodes[index].orientation = candidate

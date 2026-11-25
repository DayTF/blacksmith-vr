extends RefCounted

const Rounded = preload("res://src/game/rounded_billet_surface.gd")


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var nodes: Array[Dictionary] = [
		{"position": Vector3.ZERO, "orientation": Basis.IDENTITY},
		{"position": Vector3.RIGHT, "orientation": Basis.IDENTITY},
		{"position": Vector3(1, 0, 1), "orientation": Basis.IDENTITY},
		{"position": Vector3.ONE, "orientation": Basis.IDENTITY},
	]
	var rounded := Rounded.new(nodes, 0.2)
	var arrays := _sample(rounded, nodes)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indexes: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if positions.size() != 6 or indexes.size() != 12:
		return PackedStringArray(["Rounded preview must subdivide one supported triangle into four."])
	if positions[0].x <= 0.0 or positions[0].y <= 0.0 or positions[0].z <= 0.0:
		failures.append("Rounding should remove the sharp original corner.")
	if not is_zero_approx(positions[5].y):
		failures.append("Rounding should keep a flat footprint at face interiors.")
	var transform := Transform3D(Basis(Vector3.FORWARD, PI * 0.35), Vector3(2, 3, 4))
	for node in nodes:
		node.position = transform * node.position
		node.orientation = transform.basis
	var moved: PackedVector3Array = _sample(rounded, nodes)[Mesh.ARRAY_VERTEX]
	for index in positions.size():
		if not moved[index].is_equal_approx(transform * positions[index]):
			failures.append("Rounding must follow the billet's tracked orientation and position.")
			break
	return failures


func _sample(rounded: RefCounted, nodes: Array[Dictionary]) -> Array:
	var mesh := SurfaceTool.new()
	mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	rounded.append(mesh, [0, 1, 2], nodes, PackedColorArray([Color.RED, Color.RED, Color.RED]),
		PackedFloat32Array([1.0, 1.0, 1.0]), 0)
	return mesh.commit_to_arrays()

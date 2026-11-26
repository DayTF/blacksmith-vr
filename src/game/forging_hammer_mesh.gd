extends RefCounted
## Cross-peen head and oval wooden handle in the tracked hammer's local space.

const FACE_DROP_M := 0.01


static func build(hammer: MeshInstance3D, face_radius: float, grip: Vector3) -> void:
	# Each ring specifies height and the half-widths along X and Z.
	var head := [
		Vector3(-FACE_DROP_M, face_radius * 0.90, face_radius * 0.90),
		Vector3(-0.007, face_radius, face_radius),
		Vector3(0.004, face_radius, face_radius),
		Vector3(0.018, 0.017, 0.018),
		Vector3(0.038, 0.019, 0.018),
		Vector3(0.057, 0.022, 0.006),
		Vector3(0.060, 0.021, 0.004),
	]
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.set_smooth_group(-1)
	hammer.mesh = _profile(tool, head, 8, 0.68, _material(Color("9da4a9"), 0.90, 0.30),
		_material(Color("52585a"), 0.82, 0.48))
	hammer.material_override = null

	var handle := MeshInstance3D.new()
	handle.name = "Oval hardwood handle"
	var length := grip.length()
	var shaft := [
		Vector3(0.006, 0.010, 0.008),
		Vector3(length * 0.30, 0.013, 0.010),
		Vector3(length * 0.65, 0.010, 0.008),
		Vector3(length, 0.012, 0.009),
		Vector3(length + 0.062, 0.014, 0.010),
		Vector3(length + 0.073, 0.010, 0.007),
	]
	tool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wood := _material(Color("9e6640"), 0.0, 0.78)
	handle.mesh = _profile(tool, shaft, 16, -1.0, wood, wood)
	handle.quaternion = Quaternion(Vector3.UP, grip.normalized())
	hammer.add_child(handle)


static func _profile(tool: SurfaceTool, profile: Array, sides: int, corner: float,
		end_material: StandardMaterial3D, side_material: StandardMaterial3D) -> ArrayMesh:
	var rings: Array[PackedVector3Array] = []
	for section: Vector3 in profile:
		var ring := PackedVector3Array()
		for index in sides:
			var angle := (index + 0.5) * TAU / sides
			var outline := Vector2(cos(angle), sin(angle))
			if corner > 0.0:
				# Octagonal outline with long straight sides and clipped corners.
				outline = (outline / maxf(absf(outline.x), absf(outline.y)))
				if absf(outline.x) < 1.0:
					outline.x = signf(outline.x) * corner
				if absf(outline.y) < 1.0:
					outline.y = signf(outline.y) * corner
			ring.append(Vector3(section.y * outline.x, section.x, section.z * outline.y))
		rings.append(ring)
	for level in rings.size() - 1:
		var lower := rings[level]
		var upper := rings[level + 1]
		for index in sides:
			var next := (index + 1) % sides
			_triangle(tool, lower[index], lower[next], upper[next])
			_triangle(tool, lower[index], upper[next], upper[index])
	tool.set_material(side_material)
	tool.generate_normals()
	var mesh := tool.commit()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.set_smooth_group(-1)
	var bottom := rings[0]
	var top := rings[-1]
	for index in sides:
		var next := (index + 1) % sides
		_triangle(tool, Vector3(0, bottom[0].y, 0), bottom[next], bottom[index])
		_triangle(tool, Vector3(0, top[0].y, 0), top[index], top[next])
	tool.set_material(end_material)
	tool.generate_normals()
	return tool.commit(mesh)


static func _triangle(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	tool.add_vertex(a)
	tool.add_vertex(b)
	tool.add_vertex(c)


static func _material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	return material

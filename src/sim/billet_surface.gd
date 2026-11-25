extends RefCounted
## Current geometric boundary, including burial by contacting, unbonded matter.
## A disabled volume constraint is not empty space: damaged cells still occlude.

const Geometry = preload("res://src/sim/billet_geometry.gd")
const FACES = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4],
	[2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
var tuning: Dictionary
var errors := PackedStringArray()


func _init(parameters: Dictionary) -> void:
	tuning = parameters.duplicate(true)


func evaluate(nodes: Array[Dictionary], cells: Array[Dictionary], include_boundary: bool = false) -> Dictionary:
	errors.clear()
	for key in ["probe_offset_m", "probe_cell_fraction", "minimum_tetra_volume_m3", "minimum_face_area_m2", "barycentric_tolerance"]:
		var value: Variant = tuning.get(key)
		if not (value is float or value is int) or not is_finite(value) or value <= 0:
			return _fail("Invalid surface tolerance: " + key)
	for node: Dictionary in nodes:
		if not node.get("position") is Vector3 or not node.position.is_finite():
			return _fail("Surface evaluation requires finite local positions.")
	var bodies: Array[Dictionary] = []
	var faces := {}
	var unresolved := 0
	var probe: float = tuning.probe_offset_m
	for index in cells.size():
		var ids: Variant = cells[index].get("nodes")
		if not ids is PackedInt32Array or ids.size() != 8:
			return _fail("Surface evaluation requires eight-node matter cells.")
		var unique := {}
		var center := Vector3.ZERO
		var lower := Vector3(INF, INF, INF)
		var upper := Vector3(-INF, -INF, -INF)
		for id: int in ids:
			if id < 0 or id >= nodes.size() or unique.has(id):
				return _fail("Invalid surface cell index.")
			unique[id] = true
			var p: Vector3 = nodes[id].position
			center += p / 8.0
			lower = lower.min(p)
			upper = upper.max(p)
		var tetrahedra: Array[Dictionary] = []
		var valid := true
		if not center.is_finite() or not (upper - lower).is_finite():
			return _fail("Matter geometry exceeds representable scale.")
		for tetra: Array in Geometry.TETRAHEDRA:
			var origin: Vector3 = nodes[ids[tetra[0]]].position
			var basis := Basis(nodes[ids[tetra[1]]].position - origin,
				nodes[ids[tetra[2]]].position - origin, nodes[ids[tetra[3]]].position - origin)
			var volume := basis.determinant() / 6.0
			if not is_finite(volume) or volume <= float(tuning.minimum_tetra_volume_m3):
				valid = false
				break
			var inverse := basis.inverse()
			if not inverse.is_finite():
				valid = false
				break
			# Cap the probe below every represented tetrahedron's thickness, so
			# contacting thin Damascus layers cannot be skipped by a fixed offset.
			var gx := Vector3(inverse.x.x, inverse.y.x, inverse.z.x)
			var gy := Vector3(inverse.x.y, inverse.y.y, inverse.z.y)
			var gz := Vector3(inverse.x.z, inverse.y.z, inverse.z.z)
			var largest := maxf(maxf(gx.length(), gy.length()), maxf(gz.length(), (gx + gy + gz).length()))
			probe = minf(probe, float(tuning.probe_cell_fraction) / largest)
			tetrahedra.append({"origin": origin, "inverse": inverse})
		bodies.append({"bounds": AABB(lower, upper - lower).grow(tuning.probe_offset_m),
			"tetrahedra": tetrahedra, "valid": valid, "center": center})
		unresolved += int(not valid)
		for face_index in FACES.size():
			var corners: Array = FACES[face_index]
			var face := PackedInt32Array()
			for corner: int in corners:
				face.append(ids[corner])
			var key := Array(face)
			key.sort()
			if not faces.has(key):
				faces[key] = []
			faces[key].append({"owner": index, "nodes": face, "face_index": face_index})
	var boundary: Array[Dictionary] = []
	var patches: Array[Dictionary] = []
	var areas := PackedFloat64Array()
	areas.resize(nodes.size())
	for entries: Array in faces.values():
		if entries.size() > 2:
			return _fail("Non-manifold matter face.")
		if entries.size() != 1:
			continue
		var owner: int = entries[0].owner
		if not bodies[owner].valid:
			continue
		var ids: PackedInt32Array = entries[0].nodes
		var points: Array[Vector3] = []
		var center := Vector3.ZERO
		for id: int in ids:
			points.append(nodes[id].position)
			center += nodes[id].position / 4.0
		var first := (points[1] - points[0]).cross(points[2] - points[0])
		var second := (points[2] - points[0]).cross(points[3] - points[0])
		var area := (first.length() + second.length()) * 0.5
		var normal := first + second
		if not is_finite(area) or not normal.is_finite():
			return _fail("Nonfinite boundary geometry.")
		if area <= float(tuning.minimum_face_area_m2) or normal.length_squared() == 0:
			continue
		normal = normal.normalized()
		if normal.dot(center - bodies[owner].center) < 0:
			normal = -normal
		var touching := {}
		for corner in 4:
			# One probe per nodal dual-face patch, not one all-or-nothing face test.
			var point: Vector3 = points[corner] * 0.5625 + points[(corner + 1) % 4] * 0.1875 + points[(corner + 3) % 4] * 0.1875 + points[(corner + 2) % 4] * 0.0625
			point += normal * probe
			var buried := false
			for other in bodies.size():
				if other != owner and _contains(bodies[other], point):
					buried = true
					if not include_boundary:
						break
					if not touching.has(ids[corner]):
						touching[ids[corner]] = []
					touching[ids[corner]].append(other)
			if not buried:
				areas[ids[corner]] += area / 4.0
				if include_boundary:
					patches.append({"node": ids[corner], "center": point - normal * probe,
						"normal": normal, "area": area / 4.0})
		if include_boundary:
			var backing := {}
			var face_index: int = entries[0].face_index
			var cell_ids: PackedInt32Array = cells[owner].nodes
			var perpendicular_bit := 4 >> (face_index / 2)
			for corner: int in FACES[face_index]:
				backing[cell_ids[corner]] = cell_ids[corner ^ perpendicular_bit]
			boundary.append({"normal": normal, "area": area,
				"owner": owner, "touching": touching, "backing": backing})
	var exposed := PackedByteArray()
	for area: float in areas:
		exposed.append(int(area > 0))
	var result := {"areas": areas, "exposed": exposed, "unresolved_cells": unresolved}
	if include_boundary:
		result["boundary"] = boundary
		result["patches"] = patches
	return result


func _contains(body: Dictionary, point: Vector3) -> bool:
	if not body.bounds.has_point(point):
		return false
	if not body.valid:
		# Under-resolved fractured/inverted matter is conservatively opaque.
		return true
	var tolerance: float = tuning.barycentric_tolerance
	for tetra: Dictionary in body.tetrahedra:
		var p: Vector3 = tetra.inverse * (point - tetra.origin)
		if p.x >= -tolerance and p.y >= -tolerance and p.z >= -tolerance and p.x + p.y + p.z <= 1.0 + tolerance:
			return true
	return false


func _fail(message: String) -> Dictionary:
	errors.append(message)
	return {}

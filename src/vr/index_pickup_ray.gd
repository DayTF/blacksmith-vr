extends RefCounted
## Headless ray geometry for pointing and targeting loose props.


static func points(proximal: Vector3, middle: Vector3, tip: Vector3) -> bool:
	var first := middle - proximal
	var second := tip - middle
	return first.length_squared() > 0.000001 and second.length_squared() > 0.000001 \
		and first.normalized().dot(second.normalized()) >= 0.85


static func nearest(ray: Transform3D, tools: Array[Dictionary], reach: float, unavailable: int,
		blockers: Array[Dictionary] = []) -> Dictionary:
	var result := {"target": -1, "distance": reach}
	if not ray.is_finite() or ray.basis.z.length_squared() < 0.000001:
		return result
	var direction := -ray.basis.z.normalized()
	for blocker in blockers:
		result.distance = minf(result.distance, _box_distance(ray.origin, direction, blocker))
	for index in tools.size():
		if index == unavailable:
			continue
		var tool := tools[index]
		var pose: Transform3D = tool.pose
		if tool.has("aim_bounds"):
			var distance := _box_distance(ray.origin, direction, tool)
			if distance < float(result.distance):
				result = {"target": index, "distance": distance}
			continue
		var center := pose * Vector3(tool.get("aim_offset", Vector3.ZERO))
		var offset := center - ray.origin
		var along := offset.dot(direction)
		var radius: float = tool.get("aim_radius", 0.06)
		var discriminant := radius * radius - (offset.length_squared() - along * along)
		if discriminant < 0.0 or along + sqrt(discriminant) < 0.0:
			continue
		var distance := maxf(0.0, along - sqrt(discriminant))
		if distance < float(result.distance):
			result = {"target": index, "distance": distance}
	return result


static func _box_distance(origin: Vector3, direction: Vector3, entry: Dictionary) -> float:
	var pose: Transform3D = entry.pose
	var inverse := pose.affine_inverse()
	var box: AABB = entry.aim_bounds
	var local_origin := inverse * origin
	if box.has_point(local_origin):
		return 0.0
	var hit: Variant = box.intersects_ray(local_origin, inverse.basis * direction)
	return origin.distance_to(pose * hit) if hit is Vector3 else INF

extends RefCounted
## Headless ray geometry for pointing and targeting loose props.


static func points(proximal: Vector3, middle: Vector3, tip: Vector3) -> bool:
	var first := middle - proximal
	var second := tip - middle
	return first.length_squared() > 0.000001 and second.length_squared() > 0.000001 \
		and first.normalized().dot(second.normalized()) >= 0.85


static func nearest(ray: Transform3D, tools: Array[Dictionary], reach: float, unavailable: int) -> Dictionary:
	var result := {"target": -1, "distance": reach}
	if not ray.is_finite() or ray.basis.z.length_squared() < 0.000001:
		return result
	var direction := -ray.basis.z.normalized()
	for index in tools.size():
		if index == unavailable:
			continue
		var tool := tools[index]
		var pose: Transform3D = tool.pose
		if tool.has("aim_bounds"):
			var inverse := pose.affine_inverse()
			var box: AABB = tool.aim_bounds
			var local_origin := inverse * ray.origin
			var hit: Variant = local_origin if box.has_point(local_origin) else box.intersects_ray(local_origin, inverse.basis * direction)
			if hit is Vector3:
				var distance: float = (pose * hit).distance_to(ray.origin)
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

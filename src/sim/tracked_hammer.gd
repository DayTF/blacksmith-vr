extends RefCounted
## Continuous downward tip sweep against the existing flat-anvil hammer contact.

var _previous: Vector3
var _tracking := false


func reset_tracking() -> void:
	_tracking = false


func apply(billet: RefCounted, tip: Vector3, delta: float, radius: float, mass: float,
		maximum_gap: float, maximum_travel: float) -> bool:
	if not tip.is_finite() or not is_finite(delta) or delta <= 0.0:
		reset_tracking()
		return false
	var previous := _previous
	_previous = tip
	var had_tracking := _tracking
	_tracking = true
	var travel := tip - previous
	if not had_tracking or delta > maximum_gap or travel.length_squared() > maximum_travel * maximum_travel or travel.y >= 0.0:
		return false
	var radius_squared := radius * radius
	var earliest := INF
	var center := Vector3.ZERO
	for node: Dictionary in billet.nodes:
		var point: Vector3 = node.position
		var fraction := (point.y - previous.y) / travel.y
		if fraction <= 0.0 or fraction >= earliest or fraction > 1.0:
			continue
		var candidate := previous + travel * fraction
		var offset := Vector2(candidate.x - point.x, candidate.z - point.z)
		if offset.length_squared() <= radius_squared and _is_frontmost(billet.nodes, candidate, point.y, radius_squared):
			earliest = fraction
			center = Vector3(candidate.x, point.y, candidate.z)
	return earliest < INF and billet.hammer(center, Vector3.UP, radius, mass, travel / delta)


func _is_frontmost(nodes: Array[Dictionary], center: Vector3, height: float, radius_squared: float) -> bool:
	for node in nodes:
		if node.position.y > height:
			var offset := Vector2(node.position.x - center.x, node.position.z - center.z)
			if offset.length_squared() <= radius_squared:
				return false
	return true

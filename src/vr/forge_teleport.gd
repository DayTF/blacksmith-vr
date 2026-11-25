extends RefCounted
## Flat floor targeting and translation in the single forge-room study.

# Room coordinates here are relative to the anvil surface.
const FLOOR := -0.90
const MAX_DISTANCE := 7.0
const FLOOR_BOUNDS := Rect2(-1.75, -2.58, 3.5, 5.46)
const STATIONS := [
	AABB(Vector3(-1.35, FLOOR, -2.81), Vector3(1.74, 2.6, 1.08)),
	AABB(Vector3(-0.30, FLOOR, -0.32), Vector3(0.91, 0.91, 0.64)),
	AABB(Vector3(0.99, FLOOR, -1.62), Vector3(0.80, 1.0, 0.88)),
	AABB(Vector3(-1.90, FLOOR, -0.36), Vector3(0.70, 0.91, 1.43)),
]
const CLEARANCE := 0.22


const STICK_PRESS := 0.60
const STICK_RELEASE := 0.35

var landing: Variant
var active_hand := -1


func update(inputs: Array[Dictionary]) -> Variant:
	if active_hand < 0:
		for hand in inputs.size():
			if not inputs[hand].is_empty() and _engaged(inputs[hand], STICK_PRESS):
				active_hand = hand
				break
	if active_hand < 0:
		return null

	var sample := inputs[active_hand]
	if not sample.is_empty() and _engaged(sample, STICK_RELEASE):
		landing = target(sample.pose)
		return null

	# Commit the marker the player saw while aiming, rather than sampling a
	# new destination from the wrist movement that returns the stick to center.
	var chosen: Variant = null
	if not sample.is_empty() and sample.stick.length() <= STICK_RELEASE:
		chosen = landing
	landing = null
	active_hand = -1
	return chosen


func _engaged(sample: Dictionary, threshold: float) -> bool:
	return sample.click or sample.stick.y >= threshold


static func target(ray: Transform3D) -> Variant:
	if not ray.is_finite() or absf(ray.origin.x) >= 2.0 or ray.origin.z <= -2.82 or ray.origin.z >= 3.18:
		return null
	var direction := -ray.basis.z.normalized()
	if direction.y >= 0.0:
		return null
	var distance := (FLOOR - ray.origin.y) / direction.y
	if distance <= 0.0 or distance > MAX_DISTANCE:
		return null
	var hit := ray.origin + direction * distance
	var floor_point := Vector2(hit.x, hit.z)
	if not FLOOR_BOUNDS.has_point(floor_point):
		return null
	for station: AABB in STATIONS:
		var footprint := Rect2(station.position.x, station.position.z, station.size.x, station.size.z)
		if footprint.grow(CLEARANCE).has_point(floor_point) or station.intersects_segment(ray.origin, hit) != null:
			return null
	return hit


static func room_shift(destination: Vector3, head: Vector3) -> Vector3:
	return Vector3(destination.x - head.x, 0.0, destination.z - head.z)

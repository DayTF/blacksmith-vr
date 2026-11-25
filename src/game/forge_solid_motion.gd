extends RefCounted
## Swept room-local bounds for the fixed forge pieces in build_room.py.

const SOLIDS := [
	AABB(Vector3(-1.30, 0.0, -2.92), Vector3(1.64, 0.885, 0.94)),
	AABB(Vector3(-1.225, 0.885, -2.82), Vector3(0.35, 0.546, 0.74)),
	AABB(Vector3(-0.085, 0.885, -2.82), Vector3(0.35, 0.546, 0.74)),
	AABB(Vector3(-1.19, 0.795, -2.955), Vector3(1.42, 0.65, 0.17)),
	AABB(Vector3(-1.28, 1.45, -2.955), Vector3(1.60, 0.20, 0.95)),
	AABB(Vector3(-0.715, 1.62, -2.84), Vector3(0.47, 1.16, 0.44)),
]
const CONTACT_GAP := 0.0002


static func constrain(bounds: AABB, previous: Transform3D, desired: Transform3D,
		remote := false) -> Transform3D:
	if previous.is_equal_approx(desired):
		return previous
	var extents: AABB = Transform3D(desired.basis, Vector3.ZERO) * bounds
	if remote:
		for solid: AABB in SOLIDS:
			if solid.intersects(AABB(desired.origin + extents.position, extents.size)):
				return previous
		return desired

	# Preserve the last fitting orientation when the requested rotation would
	# overlap geometry before translation can begin.
	for solid: AABB in SOLIDS:
		if solid.grow(-CONTACT_GAP).intersects(AABB(previous.origin + extents.position, extents.size)):
			desired.basis = previous.basis
			extents = Transform3D(previous.basis, Vector3.ZERO) * bounds
			break

	var motion := desired.origin - previous.origin
	var distance := motion.length()
	if distance <= CONTACT_GAP:
		return Transform3D(desired.basis, previous.origin)
	var allowed := distance
	for solid: AABB in SOLIDS:
		var expanded := AABB(solid.position - extents.end, solid.size + extents.size)
		# Some props begin on or slightly inside the authored floor. Permit
		# motion out of an initial overlap and block further penetration.
		if expanded.grow(-CONTACT_GAP).has_point(previous.origin):
			if expanded.has_point(desired.origin):
				allowed = 0.0
			continue
		var hit: Variant = expanded.grow(-0.00001).intersects_segment(previous.origin, desired.origin)
		if hit != null:
			allowed = minf(allowed, maxf(0.0, previous.origin.distance_to(hit) - CONTACT_GAP))
	desired.origin = previous.origin + motion * (allowed / distance)
	return desired

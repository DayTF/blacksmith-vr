extends RefCounted

const Ray := preload("res://src/vr/index_pickup_ray.gd")
const Grip := preload("res://src/vr/world_tool_grip.gd")


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var right := Grip.new()
	var left := Grip.new()
	right.tools = [
		{"pose": Transform3D(Basis.IDENTITY, Vector3(0, 0, -2))},
		{"pose": Transform3D(Basis.IDENTITY, Vector3(0, 0, -4))},
		{"pose": Transform3D(Basis.IDENTITY, Vector3(0, 0, 1))},
	]
	left.tools = right.tools
	if Ray.nearest(Transform3D.IDENTITY, right.tools, 5.0, -1).target != 0:
		failures.append("Pointing selects the closest intersected prop in front of the finger.")
	if Ray.nearest(Transform3D.IDENTITY, right.tools, 5.0, 0).target != 1:
		failures.append("An already held prop is unavailable to the other hand.")
	if Ray.nearest(Transform3D.IDENTITY, right.tools, 1.0, -1).target != -1:
		failures.append("Props beyond pickup range are excluded.")
	var wall := {"pose": Transform3D(Basis.IDENTITY, Vector3(0, 0, -3)),
		"aim_bounds": AABB(Vector3(-1, -1, -0.1), Vector3(2, 2, 0.2))}
	if Ray.nearest(Transform3D.IDENTITY, right.tools, 5.0, -1, [wall]).target != 0:
		failures.append("A fixture behind a visible prop cannot hide it.")
	var blocked := Ray.nearest(Transform3D.IDENTITY, right.tools, 5.0, 0, [wall])
	if blocked.target != -1 or not is_equal_approx(blocked.distance, 2.9):
		failures.append("A fixture stops the pickup beam and hides props beyond it.")
	if not Ray.points(Vector3.ZERO, Vector3.FORWARD, 2.0 * Vector3.FORWARD) \
			or Ray.points(Vector3.ZERO, Vector3.FORWARD, Vector3.FORWARD + Vector3.DOWN):
		failures.append("Pointing requires an extended finger.")

	var right_sample := _sample(Vector3.RIGHT)
	var left_sample := _sample(Vector3.LEFT)
	right_sample.trigger = 1.0
	right.update(right_sample, 0.1, 0.6, 0.4)
	if right.held != -1:
		failures.append("Tracking acquired with a closed trigger cannot pull a tool.")
	right_sample.trigger = 0.0
	right.update(right_sample, 0.1, 0.6, 0.4)
	left.update(left_sample, 0.1, 0.6, 0.4)
	right_sample.trigger = 1.0
	left_sample.trigger = 1.0
	right.update(right_sample, 0.1, 0.6, 0.4)
	left.update(left_sample, 0.1, 0.6, 0.4, right.held)
	if right.held != 0 or left.held != -1 or right.tools[0].pose != right_sample.pose:
		failures.append("Trigger draws the selected prop into one hand and grants exclusive ownership.")
	left_sample.trigger = 0.0
	left.update(left_sample, 0.1, 0.6, 0.4, right.held)
	left_sample.trigger = 1.0
	left_sample.remote_target = 1
	left.update(left_sample, 0.1, 0.6, 0.4, right.held)
	if left.held != 1 or left.tools[1].pose != left_sample.pose:
		failures.append("The other hand independently acquires and holds a second prop.")
	right_sample.trigger = 0.0
	right_sample.pressure = 1.0
	right.update(right_sample, 0.1, 0.6, 0.4, left.held)
	if right.held != 0:
		failures.append("A grip can take over from a held trigger.")
	right_sample.pressure = 0.0
	right.update(right_sample, 0.1, 0.6, 0.4, left.held)
	if right.held != -1 or left.held != 1:
		failures.append("Opening one hand releases only its own prop.")
	left.update({}, 0.1, 0.6, 0.4)
	if left.held != -1:
		failures.append("Tracking loss releases the prop.")
	return failures


func _sample(position: Vector3) -> Dictionary:
	return {"source": "controller", "pose": Transform3D(Basis.IDENTITY, position),
		"trigger": 0.0, "pressure": 0.0, "remote_target": 0}

extends RefCounted

const Teleport = preload("res://src/vr/forge_teleport.gd")
const Tools = preload("res://src/vr/world_tool_grip.gd")
const Fingers = preload("res://src/vr/tracked_hand_display.gd")


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var origin := Vector3(0, 0.55, 2.4)
	var floor := Vector3(-0.62, Teleport.FLOOR, 1.2)
	var ray := Transform3D(Basis.IDENTITY, origin)
	var hit: Variant = Teleport.target(ray.looking_at(floor))
	if not hit is Vector3 or not hit.is_equal_approx(floor):
		failures.append("A clear aimed ray must land at its floor intersection.")
	if Teleport.target(ray.looking_at(Vector3(0.05, Teleport.FLOOR, 0.0))) != null:
		failures.append("The anvil and its landing clearance must block teleport.")
	if Teleport.target(ray.looking_at(Vector3(2.0, Teleport.FLOOR, 0.8))) != null:
		failures.append("Teleport must remain inside the room.")
	var head := Vector3(1.0, 0.7, 2.0)
	if not (head + Teleport.room_shift(floor, head)).is_equal_approx(Vector3(floor.x, head.y, floor.z)):
		failures.append("Teleport must preserve height and account for tracked headset offset.")
	_test_teleport_input(ray, floor, failures)
	_test_tools(failures)
	_test_fingers(failures)
	return failures


func _test_teleport_input(ray: Transform3D, floor: Vector3, failures: PackedStringArray) -> void:
	var control := Teleport.new()
	var right := {"pose": ray.looking_at(floor), "stick": Vector2(0.0, 0.8), "click": false}
	if control.update([right, {}]) != null or not control.landing is Vector3 or control.active_hand != 0:
		failures.append("A right-stick forward gesture must show a landing before moving.")
	right.pose = ray
	right.stick = Vector2.ZERO
	var destination: Variant = control.update([right, {}])
	if not destination is Vector3 or not destination.is_equal_approx(floor) or control.landing != null:
		failures.append("Releasing the right stick must use the last visible landing instead of re-aiming.")
	if control.update([right, {}]) != null:
		failures.append("Holding the stick neutral must not teleport again.")
	var left := {"pose": ray.looking_at(floor), "stick": Vector2.ZERO, "click": true}
	control.update([{}, left])
	if not control.landing is Vector3 or control.active_hand != 1:
		failures.append("The left stick click must also start aiming.")
	if control.update([{}, {}]) != null or control.landing != null:
		failures.append("Tracking loss must cancel an active teleport.")
	control.update([{}, left])
	left.pose = ray.looking_at(Vector3(0.05, Teleport.FLOOR, 0.0))
	control.update([{}, left])
	left.click = false
	if control.update([{}, left]) != null:
		failures.append("An obstructed aim must clear the landing before release.")


func _test_tools(failures: PackedStringArray) -> void:
	var tools := Tools.new()
	tools.tools = [{"pose": Transform3D.IDENTITY}, {"pose": Transform3D(Basis.IDENTITY, Vector3.RIGHT)}]
	var sample := {"source": "controller", "pose": Transform3D(Basis.IDENTITY, Vector3.RIGHT), "pressure": 1.0}
	tools.update(sample, 0.10, 0.60, 0.40)
	if tools.held != -1:
		failures.append("Tracking acquisition with a closed grip must not auto-pickup.")
	sample.pressure = 0.0
	tools.update(sample, 0.10, 0.60, 0.40)
	sample.pressure = 1.0
	tools.update(sample, 0.10, 0.60, 0.40)
	if tools.held != 1:
		failures.append("A grip must pick up the nearest world tool.")
	sample.pose = Transform3D(Basis.IDENTITY, Vector3.ONE)
	tools.update(sample, 0.10, 0.60, 0.40)
	tools.update({}, 0.10, 0.60, 0.40)
	if tools.held != -1 or tools.tools[1].pose != sample.pose or tools.tools[0].pose != Transform3D.IDENTITY:
		failures.append("Only the held tool should move, and tracking loss should release it at its last pose.")


func _test_fingers(failures: PackedStringArray) -> void:
	var display := Fingers.new()
	display._ready()
	var hand := XRHandTracker.new()
	hand.has_tracking_data = true
	for joint in XRHandTracker.HAND_JOINT_MAX:
		hand.set_hand_joint_flags(joint, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		hand.set_hand_joint_transform(joint, Transform3D(Basis.IDENTITY, Vector3.RIGHT * joint * 0.01))
	var shown: bool = display.show_joints(hand, Transform3D.IDENTITY)
	var segments: MultiMesh = display.get_child(0).multimesh
	if not shown or segments.visible_instance_count != 25:
		failures.append("Measured joints must articulate the palm and all five fingers.")
	hand.has_tracking_data = false
	if display.show_joints(hand, Transform3D.IDENTITY):
		failures.append("Invalid hand tracking must hide stale joint segments.")
	display.free()

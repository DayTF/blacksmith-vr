extends XROrigin3D
## OpenXR tracking adapter. Return a stage-space grip from either source.

const IndexRay := preload("res://src/vr/index_pickup_ray.gd")
const Fingers = preload("res://src/vr/tracked_hand_display.gd")

const HAND := &"/user/hand_tracker/right"
const OFF_HAND := &"/user/hand_tracker/left"
const INDEX_TIP := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
const THUMB_TIP := XRHandTracker.HAND_JOINT_THUMB_TIP
const POSITION_TRACKED := XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
const KNUCKLE := XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL
const TRACKED := XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_TRACKED
var _controller := XRController3D.new()
var _off_controller := XRController3D.new()
var _aim := XRController3D.new()
var _right_aim := XRController3D.new()
var _camera: XRCamera3D
var _right_fingers := Fingers.new()
var _left_fingers := Fingers.new()
var _left_models := OpenXRRenderModelManager.new()
var _models := OpenXRRenderModelManager.new()
var _controller_proxy := MeshInstance3D.new()
var _left_proxy := MeshInstance3D.new()


func _ready() -> void:
	_camera = XRCamera3D.new()
	add_child(_camera)
	_camera.make_current()
	add_child(_right_fingers)
	add_child(_left_fingers)
	_controller.tracker = &"right_hand"
	_controller.pose = &"grip"
	add_child(_controller)
	_off_controller.tracker = &"left_hand"
	_off_controller.pose = &"grip"
	add_child(_off_controller)
	_left_models.tracker = OpenXRRenderModelManager.RENDER_MODEL_TRACKER_LEFT_HAND
	add_child(_left_models)
	_aim.tracker = &"left_hand"
	_aim.pose = &"aim"
	add_child(_aim)
	_right_aim.tracker = &"right_hand"
	_right_aim.pose = &"aim"
	add_child(_right_aim)
	var grip_shape := CapsuleMesh.new()
	grip_shape.radius = 0.022
	grip_shape.height = 0.11
	_controller_proxy.mesh = grip_shape
	_controller_proxy.rotation.x = PI * 0.5
	_controller_proxy.hide()
	_controller.add_child(_controller_proxy)
	_left_proxy.mesh = grip_shape
	_left_proxy.rotation.x = PI * 0.5
	_left_proxy.hide()
	_off_controller.add_child(_left_proxy)
	_models.tracker = OpenXRRenderModelManager.RENDER_MODEL_TRACKER_RIGHT_HAND
	add_child(_models)
	_models.hide()


func update_hands() -> void:
	var reference := XRServer.get_reference_frame()
	var right := _right_fingers.show_joints(XRServer.get_tracker(HAND) as XRHandTracker, reference)
	var left := _left_fingers.show_joints(XRServer.get_tracker(OFF_HAND) as XRHandTracker, reference)
	_models.visible = not right and _controller.get_has_tracking_data()
	_left_models.visible = not left and _off_controller.get_has_tracking_data()
	_controller_proxy.visible = _models.visible and _models.get_child_count() == 0
	_left_proxy.visible = _left_models.visible and _left_models.get_child_count() == 0


func aim() -> Dictionary:
	if not _aim.get_has_tracking_data():
		return {}
	return {"pose": _aim.global_transform, "stick": _aim.get_vector2(&"primary").y}


func head_position() -> Vector3:
	return _camera.global_position


func off_hand(pinch_closed: float, pinch_open: float) -> Dictionary:
	return _sample(OFF_HAND, _off_controller, pinch_closed, pinch_open)


func tool_hand(pinch_closed: float, pinch_open: float) -> Dictionary:
	return _sample(HAND, _controller, pinch_closed, pinch_open)


func pickup_ray(left: bool) -> Dictionary:
	var controller := _off_controller if left else _controller
	var result := {}
	if controller.get_has_tracking_data():
		var trigger := controller.get_float(&"trigger")
		if is_zero_approx(trigger) and controller.is_button_pressed(&"trigger_click"):
			trigger = 1.0
		result.trigger = trigger
	var hand := XRServer.get_tracker(OFF_HAND if left else HAND) as XRHandTracker
	var joints := [XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE, INDEX_TIP,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP]
	var valid := hand != null and hand.has_tracking_data
	if valid:
		for joint in joints:
			if not (hand.get_hand_joint_flags(joint) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID):
				valid = false
				break
	if valid:
		var positions: Array[Vector3] = []
		for joint in joints:
			positions.append(hand.get_hand_joint_transform(joint).origin)
		if IndexRay.points(positions[0], positions[1], positions[2]) \
				and not IndexRay.points(positions[3], positions[4], positions[5]):
			var tip := Transform3D(Basis.IDENTITY, positions[2])
			var direction := (positions[2] - positions[1]).normalized()
			var up := Vector3.FORWARD if absf(direction.dot(Vector3.UP)) > 0.98 else Vector3.UP
			result.ray = global_transform * XRServer.get_reference_frame() * tip.looking_at(tip.origin + direction, up)
	else:
		var fallback := _aim if left else _right_aim
		if fallback.get_has_tracking_data():
			result.ray = fallback.global_transform
	return result


func _sample(path: StringName, controller: XRController3D, pinch_closed: float, pinch_open: float) -> Dictionary:
	var hand := XRServer.get_tracker(path) as XRHandTracker
	if hand and hand.has_tracking_data and hand.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER:
		if (hand.get_hand_joint_flags(KNUCKLE) & TRACKED) == TRACKED \
				and (hand.get_hand_joint_flags(INDEX_TIP) & POSITION_TRACKED) \
				and (hand.get_hand_joint_flags(THUMB_TIP) & POSITION_TRACKED):
			var index: Vector3 = hand.get_hand_joint_transform(INDEX_TIP).origin
			var thumb: Vector3 = hand.get_hand_joint_transform(THUMB_TIP).origin
			var pose := hand.get_hand_joint_transform(KNUCKLE)
			pose.origin = (index + thumb) * 0.5
			return {"pose": global_transform * XRServer.get_reference_frame() * pose,
				"pressure": 1.0 - clampf(inverse_lerp(pinch_closed, pinch_open, index.distance_to(thumb)), 0.0, 1.0),
				"source": "hand"}
	if controller.get_has_tracking_data():
		var pressure := controller.get_float(&"grip")
		if is_zero_approx(pressure) and controller.is_button_pressed(&"grip_click"):
			pressure = 1.0
		return {"pose": controller.global_transform, "pressure": pressure, "source": "controller"}
	return {}

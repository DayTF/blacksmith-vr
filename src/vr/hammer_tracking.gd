extends XROrigin3D
## OpenXR tracking adapter. Return a stage-space grip from either source.

const HAND := &"/user/hand_tracker/right"
const OFF_HAND := &"/user/hand_tracker/left"
const INDEX_TIP := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
const THUMB_TIP := XRHandTracker.HAND_JOINT_THUMB_TIP
const POSITION_TRACKED := XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
const KNUCKLE := XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL
const TRACKED := XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_TRACKED
var source := ""
var _controller := XRController3D.new()
var _off_controller := XRController3D.new()
var _models := OpenXRRenderModelManager.new()
var _controller_proxy := MeshInstance3D.new()


func _ready() -> void:
	var camera := XRCamera3D.new()
	add_child(camera)
	camera.make_current()
	_controller.tracker = &"right_hand"
	_controller.pose = &"grip"
	add_child(_controller)
	_off_controller.tracker = &"left_hand"
	_off_controller.pose = &"grip"
	add_child(_off_controller)
	var left_model := OpenXRRenderModelManager.new()
	left_model.tracker = OpenXRRenderModelManager.RENDER_MODEL_TRACKER_LEFT_HAND
	add_child(left_model)
	var grip_shape := CapsuleMesh.new()
	grip_shape.radius = 0.022
	grip_shape.height = 0.11
	_controller_proxy.mesh = grip_shape
	_controller_proxy.rotation.x = PI * 0.5
	_controller_proxy.hide()
	_controller.add_child(_controller_proxy)
	_models.tracker = OpenXRRenderModelManager.RENDER_MODEL_TRACKER_RIGHT_HAND
	add_child(_models)
	_models.hide()


func grip() -> Variant:
	source = ""
	_controller_proxy.hide()
	var hand := XRServer.get_tracker(HAND) as XRHandTracker
	if hand and hand.has_tracking_data and hand.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER:
		if (hand.get_hand_joint_flags(KNUCKLE) & TRACKED) == TRACKED:
			source = "Hand tracking"
			_models.hide()
			var joint := hand.get_hand_joint_transform(KNUCKLE)
			return global_transform * XRServer.get_reference_frame() * joint
	if _controller.get_has_tracking_data():
		source = "Controller grip"
		_models.show()
		_controller_proxy.visible = _models.get_child_count() == 0
		return _controller.global_transform
	_models.hide()
	return null


func off_hand(pinch_closed: float, pinch_open: float) -> Dictionary:
	var hand := XRServer.get_tracker(OFF_HAND) as XRHandTracker
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
	if _off_controller.get_has_tracking_data():
		return {"pose": _off_controller.global_transform, "pressure": _off_controller.get_float(&"grip"),
			"source": "controller"}
	return {}

extends XROrigin3D
## OpenXR tracking adapter. Return a stage-space grip from either source.

const HAND := &"/user/hand_tracker/right"
const KNUCKLE := XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL
const TRACKED := XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_TRACKED
var source := ""
var _controller := XRController3D.new()
var _models := OpenXRRenderModelManager.new()
var _controller_proxy := MeshInstance3D.new()


func _ready() -> void:
	var camera := XRCamera3D.new()
	add_child(camera)
	camera.make_current()
	_controller.tracker = &"right_hand"
	_controller.pose = &"grip"
	add_child(_controller)
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

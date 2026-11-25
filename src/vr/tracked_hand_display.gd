extends Node3D
## Lightweight articulated hand model. Segments follow measured joints.

const CHAINS := [
	[1, 0], [1, 2, 3, 4, 5], [0, 6, 7, 8, 9, 10], [0, 11, 12, 13, 14, 15],
	[0, 16, 17, 18, 19, 20], [0, 21, 22, 23, 24, 25],
]
const POSITION_VALID := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID

var _bones: Array[Vector2i] = []
var _instances := MultiMesh.new()


func _ready() -> void:
	var finish := StandardMaterial3D.new()
	finish.albedo_color = Color("738d9d")
	finish.roughness = 0.68
	var cylinder := CylinderMesh.new()
	cylinder.height = 1.0
	cylinder.top_radius = 0.004
	cylinder.bottom_radius = 0.005
	cylinder.radial_segments = 6
	cylinder.material = finish
	for chain: Array in CHAINS:
		for i in range(1, chain.size()):
			_bones.append(Vector2i(chain[i - 1], chain[i]))
	_instances.transform_format = MultiMesh.TRANSFORM_3D
	_instances.mesh = cylinder
	_instances.instance_count = _bones.size()
	_instances.visible_instance_count = 0
	var display := MultiMeshInstance3D.new()
	display.multimesh = _instances
	add_child(display)


func show_joints(hand: XRHandTracker, reference: Transform3D) -> bool:
	var shown := 0
	if hand != null and hand.has_tracking_data:
		for bone in _bones:
			if not (hand.get_hand_joint_flags(bone.x) & POSITION_VALID and hand.get_hand_joint_flags(bone.y) & POSITION_VALID):
				continue
			var start: Vector3 = reference * hand.get_hand_joint_transform(bone.x).origin
			var end: Vector3 = reference * hand.get_hand_joint_transform(bone.y).origin
			var axis := end - start
			if not axis.is_finite() or axis.length_squared() < 0.0000001:
				continue
			var basis := Basis(Quaternion(Vector3.UP, axis.normalized())).scaled_local(Vector3(1.0, axis.length(), 1.0))
			_instances.set_instance_transform(shown, Transform3D(basis, (start + end) * 0.5))
			shown += 1
	_instances.visible_instance_count = shown
	return shown > 0

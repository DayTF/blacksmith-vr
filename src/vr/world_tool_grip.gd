extends RefCounted
## Common pickup state for stage-space tools.

var tools: Array[Dictionary] = []
var held := -1
var pose_filter: Callable
var _source := ""
var _armed := false
var _trigger_armed := false
var _remote := false


func update(sample: Dictionary, reach: float, press: float, release: float, unavailable := -1) -> bool:
	var previous := held
	var source: String = sample.get("source", "")
	if source != _source:
		held = -1
		_armed = false
		_trigger_armed = false
		_remote = false
		_source = source
	if sample.is_empty():
		return held != previous
	var pose: Transform3D = sample.pose
	if not pose.is_finite() or pose.basis.determinant() <= 0.0:
		held = -1
		_armed = false
		_trigger_armed = false
		_remote = false
		return held != previous
	var pressure: float = sample.pressure
	var trigger: float = sample.get("trigger", 0.0)
	if held >= 0 and pressure <= release and (not _remote or trigger <= release):
		held = -1
		_remote = false
	if trigger <= release:
		_trigger_armed = true
	elif _trigger_armed and trigger >= press:
		_trigger_armed = false
		var target: int = sample.get("remote_target", -1)
		if held < 0 and target >= 0 and target < tools.size() and target != unavailable:
			held = target
			_remote = true
	if pressure <= release:
		_armed = true
	elif _armed and pressure >= press:
		_armed = false
		if held < 0:
			var nearest := INF
			for index in tools.size():
				if index == unavailable:
					continue
				var distance := _distance_squared(tools[index], pose.origin)
				var maximum: float = tools[index].get("reach_m", reach)
				if distance <= maximum * maximum and distance <= nearest:
					nearest = distance
					held = index
	if held >= 0:
		var desired := pose.orthonormalized()
		if pose_filter.is_valid():
			var filtered: Variant = pose_filter.call(tools[held], desired, _remote and held != previous, held != previous)
			if filtered == null:
				held = -1
				_remote = false
				return held != previous
			desired = filtered
		tools[held].pose = desired
	return held != previous

func _distance_squared(tool: Dictionary, point: Vector3) -> float:
	var pose: Transform3D = tool.pose
	if not tool.has("aim_bounds"):
		return pose.origin.distance_squared_to(point)
	var box: AABB = tool.aim_bounds
	var local := pose.affine_inverse() * point
	var nearest := local.clamp(box.position, box.end)
	return point.distance_squared_to(pose * nearest)

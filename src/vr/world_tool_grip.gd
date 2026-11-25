extends RefCounted
## Common pickup state for stage-space tools.

var tools: Array[Dictionary] = []
var held := -1
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
			var nearest := reach * reach
			for index in tools.size():
				if index == unavailable:
					continue
				var distance: float = tools[index].pose.origin.distance_squared_to(pose.origin)
				if distance <= nearest:
					nearest = distance
					held = index
	if held >= 0:
		tools[held].pose = pose.orthonormalized()
	return held != previous

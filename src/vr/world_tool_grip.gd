extends RefCounted
## Common pickup state for stage-space tools.

var tools: Array[Dictionary] = []
var held := -1
var _source := ""
var _armed := false


func update(sample: Dictionary, reach: float, press: float, release: float) -> bool:
	var previous := held
	var source: String = sample.get("source", "")
	if source != _source:
		held = -1
		_armed = false
		_source = source
	if sample.is_empty():
		return held != previous
	var pose: Transform3D = sample.pose
	if not pose.is_finite() or pose.basis.determinant() <= 0.0:
		held = -1
		_armed = false
		return held != previous
	var pressure: float = sample.pressure
	if pressure <= release:
		held = -1
		_armed = true
	elif held < 0 and _armed and pressure >= press:
		_armed = false
		var nearest := reach * reach
		for index in tools.size():
			var distance: float = tools[index].pose.origin.distance_squared_to(pose.origin)
			if distance <= nearest:
				nearest = distance
				held = index
	if held >= 0:
		tools[held].pose = pose.orthonormalized()
	return held != previous

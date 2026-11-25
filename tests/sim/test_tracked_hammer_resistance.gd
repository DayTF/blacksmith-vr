extends RefCounted

const Session = preload("res://src/game/preview_session.gd")
const Sweep = preload("res://src/sim/tracked_hammer.gd")


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var xr: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/preview/tracked_hammer.json"))
	var light := _strikes(xr, 0.5)
	var ordinary := _strikes(xr, 1.5)
	if light.is_empty() or ordinary.is_empty():
		return PackedStringArray(["Tracked resistance fixture must land and step all six strikes."])
	if light.strain <= 0.0 or ordinary.strain <= light.strain:
		failures.append("Light strikes work the billet incrementally and faster strikes work it more.")
	if ordinary.broken != 0 or ordinary.working_height < 0.9 * ordinary.initial_height:
		failures.append("Six fixture strikes at 1.5 m/s must retain thickness without fracture.")
	return failures


func _strikes(xr: Dictionary, speed: float) -> Dictionary:
	var session := Session.new()
	if not session.initialize():
		return {}
	session.config.dimensions = xr.dimensions
	if not session.reset(session.temperature):
		return {}
	session.billet.tuning.maximum_density_multiplier = xr.maximum_density_multiplier
	session.billet.tuning.anvil_friction_coefficient = xr.anvil_friction_coefficient
	session.billet.tuning.hammer_impulse_transfer = xr.hammer_impulse_transfer
	var radius: float = session.config.hammer_radius_m
	var mass: float = session.config.hammer_mass_kg
	var sweep := Sweep.new()
	for strike in 6:
		var x := 0.004 if strike % 2 else -0.004
		var top := _height(session.billet.nodes, x, radius)
		var half := speed * 0.005
		sweep.reset_tracking()
		sweep.apply(session.billet, Vector3(x, top + half, -0.03), 0.01, radius, mass, 0.1, 0.25)
		if not sweep.apply(session.billet, Vector3(x, top - half, -0.03), 0.01, radius, mass, 0.1, 0.25):
			return {}
		for step in 8:
			if not session.billet.step(session.config.step_s):
				return {}
	var result := session.summary()
	result["initial_height"] = (xr.dimensions[1] - 1) * session.config.spacing_m
	result["working_height"] = _height(session.billet.nodes, 0.0, 0.018)
	return result


func _height(nodes: Array[Dictionary], x: float, radius: float) -> float:
	var top := 0.0
	for node in nodes:
		var offset := Vector2(node.position.x - x, node.position.z + 0.03)
		if offset.length_squared() <= radius * radius:
			top = maxf(top, node.position.y)
	return top

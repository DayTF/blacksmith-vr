extends RefCounted
## Rigid placement of a connected piece for the tracked preview.

const Geometry = preload("res://src/sim/billet_geometry.gd")

var held: bool:
	get: return _billet != null

var _billet: RefCounted
var _initial_pose: Transform3D
var _points := {}
var _directions := {}


func acquire(billet: RefCounted, grip: Transform3D, radius: float) -> bool:
	if held or not _valid_grip(grip) or not is_finite(radius) or radius <= 0.0:
		return false
	var nodes: Array[Dictionary] = billet.nodes
	var nearest := -1
	var distance := radius * radius
	for id in nodes.size():
		var gap: float = grip.origin.distance_squared_to(nodes[id].position)
		if gap <= distance:
			nearest = id
			distance = gap
	if nearest < 0:
		return false
	var links: Array[Dictionary] = billet.connections
	var broken := PackedByteArray()
	for link in links:
		broken.append(int(link.broken))
	var components := Geometry.connected_components(nodes.size(), links, broken)
	for id in nodes.size():
		if components[id] == components[nearest]:
			_points[id] = [nodes[id].position, nodes[id].orientation]
	for id in links.size():
		var link := links[id]
		if not link.broken and _points.has(link.a):
			_directions[id] = link.reference_direction
	_initial_pose = grip.orthonormalized()
	_billet = billet
	if move(grip):
		return true
	release()
	return false


func move(grip: Transform3D) -> bool:
	if not held or not _valid_grip(grip):
		return false
	var delta := grip.orthonormalized() * _initial_pose.inverse()
	var lower := INF
	var positions := {}
	for id in _points:
		var position: Vector3 = delta * _points[id][0]
		if not position.is_finite():
			return false
		positions[id] = position
		lower = minf(lower, position.y)
	var lift := maxf(0.0, _billet.tuning.anvil_height_m - lower)
	if not is_finite(lift):
		return false
	var nodes: Array[Dictionary] = _billet.nodes
	for id in _points:
		var position: Vector3 = positions[id]
		position.y = maxf(position.y + lift, _billet.tuning.anvil_height_m)
		nodes[id].position = position
		nodes[id].velocity = Vector3.ZERO
		nodes[id].orientation = delta.basis * _points[id][1]
	var links: Array[Dictionary] = _billet.connections
	for id in _directions:
		links[id].reference_direction = delta.basis * _directions[id]
	return true


func release() -> void:
	_billet = null
	_points.clear()
	_directions.clear()


func _valid_grip(grip: Transform3D) -> bool:
	return grip.is_finite() and grip.basis.determinant() > 0.0

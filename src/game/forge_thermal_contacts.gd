extends RefCounted
## Room-local station footprints match the geometry authored in build_room.py.

const Surface := preload("res://src/sim/billet_surface.gd")
const FIRE := AABB(Vector3(-0.88, 0.885, -2.78), Vector3(0.80, 0.55, 0.67))
const BATH := AABB(Vector3(1.0725, 0.70, -1.7145), Vector3(0.635, 0.178, 0.749))
const ANVIL_FACE := Rect2(-0.24, -0.335, 0.48, 0.31)
const ANVIL_HEIGHT_M := 0.90
const CONTACT_TOLERANCE_M := 0.001

var errors := PackedStringArray()
var _surface: RefCounted


func _init(surface_tuning: Dictionary) -> void:
	_surface = Surface.new(surface_tuning)


func areas_by_station(billet: RefCounted, room_from_billet: Transform3D) -> Dictionary:
	var nodes: Array[Dictionary] = billet.nodes
	var exposed: Dictionary = _surface.evaluate(nodes, billet.cells, true)
	errors = _surface.errors
	if exposed.is_empty():
		return {}
	var air := PackedFloat64Array()
	var forge := PackedFloat64Array()
	var bath := PackedFloat64Array()
	var anvil := PackedFloat64Array()
	air.resize(nodes.size())
	forge.resize(nodes.size())
	bath.resize(nodes.size())
	anvil.resize(nodes.size())
	for patch: Dictionary in exposed.patches:
		var center: Vector3 = room_from_billet * patch.center
		var normal: Vector3 = room_from_billet.basis * patch.normal
		var node: int = patch.node
		var area: float = patch.area
		match _station_for_patch(center, normal):
			"forge": forge[node] += area
			"bath": bath[node] += area
			"anvil": anvil[node] += area
			_: air[node] += area
	return {"air": air, "forge": forge, "bath": bath, "anvil": anvil}


func _station_for_patch(center: Vector3, normal: Vector3) -> String:
	if BATH.has_point(center):
		return "bath"
	if FIRE.has_point(center):
		return "forge"
	if normal.y < 0.0 and absf(center.y - ANVIL_HEIGHT_M) <= CONTACT_TOLERANCE_M \
			and ANVIL_FACE.has_point(Vector2(center.x, center.z)):
		return "anvil"
	return "air"

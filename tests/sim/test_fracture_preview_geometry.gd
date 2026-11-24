extends RefCounted

const Geometry = preload("res://src/game/fracture_preview_geometry.gd")


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var face := [0, 1, 2, 3]
	var links: Array[Dictionary] = [{"a": 2, "b": 0, "broken": true}]
	var severed := Geometry.broken_pairs(links)
	if Geometry.visible_triangles(face, severed) != [[0, 1, 3], [1, 2, 3]]:
		failures.append("A broken diagonal should switch triangulation when the other diagonal is supported.")
	links.append({"a": 1, "b": 0, "broken": true})
	links.append({"a": 0, "b": 3, "broken": true})
	severed = Geometry.broken_pairs(links)
	if Geometry.visible_triangles(face, severed) != [[1, 2, 3]]:
		failures.append("The rendered skin must not stretch out to a detached corner.")
	return failures

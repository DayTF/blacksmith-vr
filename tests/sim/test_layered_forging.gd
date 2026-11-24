extends RefCounted

const Library = preload("res://src/sim/material_library.gd")
const Reference = preload("res://src/sim/granular_billet.gd")
const Native = preload("res://src/sim/native_granular_billet.gd")
const Layered = preload("res://src/sim/layered_forging.gd")
const Surface = preload("res://src/sim/billet_surface.gd")

var failures := PackedStringArray()
var materials := Library.new()


func run() -> PackedStringArray:
	failures.clear()
	_expect(materials.load_directory("res://data/materials"), "Welding material catalog loads")
	_test_fold()
	_test_connected_fold()
	for backend in [Reference, Native]:
		_test_weld(backend, 20.0, 20.0, 0.0)
		_test_weld(backend, 1300.0, 1300.0, 0.5)
		_test_weld(backend, 1500.0, 1200.0, 1.0)
	return failures


func _test_fold() -> void:
	var billet := _billet(Reference)
	var surface := Surface.new(_data("surface"))
	var process := Layered.new(_data("surface"), _data("welding"))
	var base := process.stack_grid(billet, Vector3i(3, 2, 3), 0.01,
		Vector3.ZERO, "prototype_mithril", 1200, "base")
	var leaf := process.stack_grid(billet, Vector3i(3, 2, 3), 0.01,
		Vector3(0.02, 0, 0), "prototype_mithril", 1300, "leaf")
	if base.size() != 18 or leaf.size() != 18:
		_expect(false, "Same-material leaves stack with separate topology")
		return
	var before: Array = billet.nodes.duplicate(true)
	var mass: float = billet.total_mass()
	var links: int = billet.connections.size()
	var pivot := Vector3(0.02, 0.01, 0)
	var area: Dictionary = surface.evaluate(billet.nodes, billet.cells)
	var base_center := base[10]
	_expect(area.exposed[base_center] == 1, "Unfolded interior of base top face is exposed")
	_expect(process.fold(billet, leaf, pivot, Vector3.BACK, PI), "Scripted half-turn places the leaf on the base")
	area = surface.evaluate(billet.nodes, billet.cells)
	_expect(area.exposed[base_center] == 0 and billet.connections.size() == links,
		"Folded contact buries the face without bonding")
	for i in leaf:
		var node: Dictionary = billet.nodes[i]
		_expect(node.layer_id == "leaf" and node.material_id == before[i].material_id
			and node.impurity_mass == before[i].impurity_mass and node.temperature == before[i].temperature
			and node.orientation.y.is_equal_approx(Vector3.DOWN), "Fold preserves local matter and rotates its layer frame")
	_expect(billet.step(0.001) and billet.nodes[leaf[0]].orientation.y.is_equal_approx(Vector3.DOWN),
		"The next mechanics step retains the folded material frame")
	_expect(process.fold(billet, leaf, pivot, Vector3.BACK, -PI), "Scripted unfolding succeeds")
	area = surface.evaluate(billet.nodes, billet.cells)
	_expect(area.exposed[base_center] == 1 and billet.total_mass() == mass, "Unfolding re-exposes the face and conserves mass")
	_expect(not process.fold(billet, PackedInt32Array([leaf[0], -1]), pivot, Vector3.BACK, PI)
		and billet.nodes[leaf[0]].position.is_equal_approx(before[leaf[0]].position), "Invalid fold leaves the billet unchanged")


func _test_connected_fold() -> void:
	var billet := _billet(Reference)
	var process := Layered.new(_data("surface"), _data("welding"))
	var points := process.stack_grid(billet, Vector3i(4, 2, 2), 0.01,
		Vector3.ZERO, "prototype_mithril", 1250, "continuous")
	var leaf := PackedInt32Array()
	for id in points:
		if billet.nodes[id].position.x > 0.015:
			leaf.append(id)
	var mass: float = billet.total_mass()
	var cells: Array = billet.cells.duplicate(true)
	var links: int = billet.connections.size()
	_expect(process.fold(billet, leaf, Vector3(0.015, 0, 0), Vector3.BACK, PI / 4),
		"Scripted bend preserves a connected hinge when the existing cells can represent it")
	_expect(billet.cells == cells and billet.connections.size() == links and billet.total_mass() == mass,
		"Connected fold retains cell, link and mass topology")


func _test_weld(backend: Script, bottom_temperature: float, top_temperature: float, quality: float) -> void:
	var billet := _billet(backend)
	var process := Layered.new(_data("surface"), _data("welding"))
	var bottom := process.stack_grid(billet, Vector3i(2, 2, 2), 0.01,
		Vector3.ZERO, "prototype_mithril", bottom_temperature, "bottom")
	var top := process.stack_grid(billet, Vector3i(2, 2, 2), 0.01,
		Vector3(0, 0.01, 0), "prototype_embersteel", top_temperature, "top")
	if bottom.size() != 8 or top.size() != 8:
		_expect(false, "Mixed-material layer assembly succeeds")
		return
	var before: Array = billet.nodes.duplicate(true)
	var mass: float = billet.total_mass()
	var links: int = billet.connections.size()
	var pairs: Array[Vector2i] = [Vector2i(bottom[2], top[0]), Vector2i(top[0], bottom[2])]
	var center := Vector3(0.005, 0.02, 0.005)
	var offset_center := Vector3(0.009, 0.02, 0.009)
	_expect(process.hammer(billet, offset_center, Vector3.UP, 0.002, 1.0, Vector3.DOWN * 0.01, pairs)
		and process.weld_attempts.is_empty() and billet.connections.size() == links,
		"A genuine hammer hit outside the interface footprint creates no weld")
	if billet.has_method("commit_state"):
		_expect(billet.commit_state(), "Native billet accepts stacked geometry")
	_expect(not process.hammer(billet, center, Vector3.UP, 0.01, 1.0, Vector3.UP, pairs)
		and billet.connections.size() == links, "Receding hammer creates no weld")
	_expect(process.hammer(billet, center, Vector3.UP, 0.01, 1.0, Vector3.DOWN * 0.01, pairs),
		"Approaching hammer hits the stacked billet")
	if process.weld_attempts.size() != 1:
		_expect(false, "Exactly one contacted weld attempt was recorded")
		return
	var event: Dictionary = process.weld_attempts[0]
	_expect(is_equal_approx(event.quality, quality), "Weld uses the weaker endpoint curve")
	if quality > 0.0:
		var link: Dictionary = billet.connections[event.link]
		_expect(link.area > 0.0 and is_equal_approx(link.area, 0.000025 * quality)
			and billet.nodes[link.a].material_id != billet.nodes[link.b].material_id, "Weld joins unlike layers through a scaled contact area")
	else:
		_expect(event.link == -1 and billet.connections.size() == links, "Cold hammer leaves the interface unbonded")
	_expect(billet.step(0.0001), "Welded or contacting stack remains valid for mechanics")
	if billet.has_method("commit_state"):
		_expect(billet.commit_state() and billet.step(0.0001), "Resident solver steps with the new topology")
	_expect(billet.total_mass() == mass, "Welding conserves total mass")
	for i in billet.nodes.size():
		var node: Dictionary = billet.nodes[i]
		_expect(node.impurity_mass == before[i].impurity_mass and node.composition == before[i].composition
			and node.layer_id == before[i].layer_id and node.temperature == before[i].temperature,
			"Welding preserves composition, layer identity, impurities and local temperature")


func _billet(backend: Script) -> RefCounted:
	var tuning := _data("mechanics")
	tuning.gravity_m_s2 = [0, 0, 0]
	return backend.new(materials, tuning)


func _data(name: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/" + name + ".json"))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

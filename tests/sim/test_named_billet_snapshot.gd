extends RefCounted

const PreviewSession := preload("res://src/game/preview_session.gd")
const LayeredSession := preload("res://src/game/layered_preview_session.gd")


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var session := LayeredSession.new()
	if not session.initialize():
		return session.errors
	if session.solidify("   ") != null or session.solidified:
		failures.append("An empty name leaves the billet active.")
	var item := session.solidify("  Layered study  ")
	if item == null:
		failures.append("A name freezes a layered billet.")
		return failures

	var record: Dictionary = item.terminal_state()
	if item.assigned_name() != "Layered study" or record.material_ids.size() != 2:
		failures.append("A named layered billet retains its name and both constituents.")
	if record.nodes.size() != session.billet.nodes.size() or record.cells.size() != session.billet.cells.size():
		failures.append("The named item retains terminal matter and cell geometry.")
	var live_nodes: Array[Dictionary] = session.billet.nodes
	live_nodes[0].impurity_mass.clear()
	if item.terminal_state().nodes[0].impurity_mass != record.nodes[0].impurity_mass:
		failures.append("Retained impurity maps are independent of live matter.")
	if session.advance(session.config.step_s) or session.solidify("Another name") != null:
		failures.append("Named matter cannot advance or be named twice.")
	failures.append_array(_test_thermal_archive())
	return failures

func _test_thermal_archive() -> PackedStringArray:
	var session := PreviewSession.new()
	if not session.initialize() or not session.reset(1401.0):
		return session.errors
	var dt: float = session.config.step_s
	if not session.step_thermal([], dt):
		return session.errors
	var bath: Dictionary = session.environments.environments[2]
	if not session.step_thermal([{"areas": session.exposed_areas, "boundary": bath}], dt):
		return session.errors
	var item := session.solidify("Quench history")
	var history: Dictionary = item.terminal_state().history
	if history.thermal_crossings.is_empty() or history.peak_cooling_rate_c_s.is_empty():
		return PackedStringArray(["Naming retained no cooling history."])
	var crossing: Dictionary = history.thermal_crossings[0]
	if crossing.thermal_time_s < dt or crossing.thermal_time_s > 2.0 * dt or crossing.temperature_rate_c_s >= 0.0:
		return PackedStringArray(["A cooling crossing must include the previous step in its timestamp."])
	session.reset(20.0)
	if item.terminal_state().history != history:
		return PackedStringArray(["Reset changed archived thermal history."])
	return PackedStringArray()

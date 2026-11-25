extends RefCounted

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
	return failures

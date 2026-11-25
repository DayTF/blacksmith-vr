extends RefCounted

const Contacts := preload("res://src/game/forge_thermal_contacts.gd")
const Session := preload("res://src/game/preview_session.gd")


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var session := Session.new()
	if not session.initialize():
		return session.errors
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/surface.json"))
	var contacts := Contacts.new(tuning)
	var placements := [
		[Vector3(0.0, 0.90, -0.18), "anvil"],
		[Vector3(1.39, 0.862, -1.34), "bath"],
		[Vector3(-0.49, 0.91, -2.45), "forge"],
	]
	for placement in placements:
		var groups := contacts.areas_by_station(session.billet, Transform3D(Basis.IDENTITY, placement[0]))
		if groups.is_empty():
			return contacts.errors
		if _sum(groups[placement[1]]) <= 0.0:
			failures.append("Room position exposes matter to " + placement[1])
		if placement[1] == "bath" and _sum(groups.air) <= 0.0:
			failures.append("Partial immersion leaves unimmersed patches exchanging with air.")
		var total := 0.0
		for areas: PackedFloat64Array in groups.values():
			total += _sum(areas)
		if not is_equal_approx(total, _sum(session.exposed_areas)):
			failures.append("Station assignment preserves exposed area.")
	return failures


func _sum(areas: PackedFloat64Array) -> float:
	var total := 0.0
	for area in areas:
		total += area
	return total

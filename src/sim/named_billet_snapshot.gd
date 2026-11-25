extends RefCounted
## Terminal billet data for a named item. The snapshot owns no live solver.

var _record: Dictionary


func _init(assigned_name: String, billet: RefCounted, history: Dictionary) -> void:
	var constituents := {}
	for point: Dictionary in billet.nodes:
		for material_id: String in point.composition:
			constituents[material_id] = true
	var material_ids := PackedStringArray(constituents.keys())
	material_ids.sort()
	_record = {
		"name": assigned_name,
		"material_ids": material_ids,
		"nodes": billet.nodes.duplicate(true),
		"connections": billet.connections.duplicate(true),
		"cells": billet.cells.duplicate(true),
		"discarded_mass_kg": billet.discarded_mass,
		"discarded_impurities_kg": billet.discarded_impurity_mass.duplicate(true),
		"history": history.duplicate(true),
	}


func assigned_name() -> String:
	return _record.name


func terminal_state() -> Dictionary:
	return _record.duplicate(true)

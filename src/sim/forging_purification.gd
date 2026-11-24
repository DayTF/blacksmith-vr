extends RefCounted
## Once-per-mechanical-step surface purification, with transactional mass transfer.

const Surface = preload("res://src/sim/billet_surface.gd")
var surface: RefCounted
var errors := PackedStringArray()
var events: Array[Dictionary] = []
var removed_mass := 0.0
var last_surface: Dictionary = {}


func _init(surface_parameters: Dictionary) -> void:
	surface = Surface.new(surface_parameters)


func apply(billet: RefCounted) -> bool:
	errors.clear()
	events.clear()
	removed_mass = 0.0
	if not _number(surface.tuning.get("mass_roundoff_tolerance_kg")) or surface.tuning.mass_roundoff_tolerance_kg < 0:
		return _fail("Invalid mass roundoff tolerance.")
	if billet.step_id < 0 or billet.purification_step_id < 0 or billet.purification_step_id > billet.step_id:
		return _fail("Invalid purification step history.")
	if billet.step_id == billet.purification_step_id:
		return true
	if not _number(billet.discarded_mass) or billet.discarded_mass < 0:
		return _fail("Invalid discarded matter mass.")
	var ledger: Dictionary = billet.discarded_impurity_mass.duplicate(true)
	var ledger_mass := 0.0
	for material_id: Variant in ledger:
		if not material_id is String or not ledger[material_id] is Dictionary:
			return _fail("Invalid discarded impurity ledger.")
		for impurity_id: Variant in ledger[material_id]:
			if not impurity_id is String or not _number(ledger[material_id][impurity_id]) or ledger[material_id][impurity_id] < 0:
				return _fail("Invalid discarded impurity mass.")
			ledger_mass += ledger[material_id][impurity_id]
	if not is_finite(ledger_mass) or ledger_mass - billet.discarded_mass > float(surface.tuning.mass_roundoff_tolerance_kg):
		return _fail("Impurity ledger exceeds total discarded mass.")
	var nodes: Array[Dictionary] = billet.nodes
	var has_spreading := false
	for node: Dictionary in nodes:
		for key in ["mass", "temperature", "plastic_strain", "plastic_strain_increment", "plastic_spreading_increment"]:
			if not _number(node.get(key)) or (key != "temperature" and node[key] < 0):
				return _fail("Invalid local purification state.")
		if node.mass <= 0 or not node.get("impurity_mass") is Dictionary:
			return _fail("Purification requires positive matter mass and local impurities.")
		if not node.get("position") is Vector3 or not node.position.is_finite() or not node.get("velocity") is Vector3 or not node.velocity.is_finite():
			return _fail("Invalid matter position or velocity.")
		var material: RefCounted = billet.materials.get_material(node.get("material_id", ""))
		if material == null:
			return _fail("Unknown purification material.")
		var known := {}
		for impurity: Dictionary in material.raw_data.impurities:
			known[impurity.id] = true
		var total := 0.0
		for id: Variant in node.impurity_mass:
			if not known.has(id) or not _number(node.impurity_mass[id]) or node.impurity_mass[id] < 0:
				return _fail("Invalid or undefined local impurity.")
			total += node.impurity_mass[id]
		if total > node.mass:
			return _fail("Local impurities exceed matter mass.")
		has_spreading = has_spreading or node.plastic_spreading_increment > 0
	if not has_spreading:
		billet.purification_step_id = billet.step_id
		return true
	var exposure: Dictionary = surface.evaluate(nodes, billet.cells)
	if exposure.is_empty():
		errors.append_array(surface.errors)
		return false
	var changes: Array[Dictionary] = []
	var pending_events: Array[Dictionary] = []
	var discarded := 0.0
	for index in nodes.size():
		var node := nodes[index]
		var spreading: float = node.plastic_spreading_increment
		if spreading <= 0.0 or exposure.exposed[index] == 0:
			continue
		var material: RefCounted = billet.materials.get_material(node.material_id)
		var process: Dictionary = material.raw_data.get("processes", {}).get("forging", {})
		if not process.is_empty() and not process.enabled:
			continue
		var impurities: Dictionary = node.impurity_mass.duplicate(true)
		var removed := 0.0
		for impurity: Dictionary in material.raw_data.impurities:
			var policy: Dictionary = impurity.get("processes", {}).get("forging", {})
			var amount: float = impurities.get(impurity.id, 0.0)
			if not policy.get("enabled", false) or amount == 0:
				continue
			# The process graph receives only the strain eligible for this process.
			var context := {"temperature": node.temperature, "plastic_strain": node.plastic_strain,
				"plastic_strain_increment": spreading, "plastic_spreading_increment": spreading,
				"total_plastic_strain_increment": node.plastic_strain_increment}
			var fraction: Variant = material.sample("impurities.%s.forging.removal_fraction" % impurity.id, context)
			if not _number(fraction) or fraction < 0.0 or fraction > 1.0:
				return _fail("Forging removal fraction must be finite and within [0, 1].")
			var loss: float = amount * fraction
			if loss == 0:
				continue
			impurities[impurity.id] = amount - loss
			removed += loss
			if not ledger.has(node.material_id):
				ledger[node.material_id] = {}
			ledger[node.material_id][impurity.id] = ledger[node.material_id].get(impurity.id, 0.0) + loss
			pending_events.append({"node": index, "material_id": node.material_id,
				"impurity_id": impurity.id, "mass_kg": loss,
				"position": node.position, "velocity": node.velocity, "temperature": node.temperature})
		if removed > 0:
			if not is_finite(node.mass - removed) or node.mass - removed <= 0:
				return _fail("Purification would exhaust a granule; zero-mass topology is not supported.")
			changes.append({"node": index, "mass": node.mass - removed, "impurities": impurities})
			discarded += removed
	if not is_finite(billet.discarded_mass + discarded):
		return _fail("Discarded mass overflow; state retained.")
	for change: Dictionary in changes:
		nodes[change.node].mass = change.mass
		# Preserve retained impurity dictionary views used by the native adapter.
		nodes[change.node].impurity_mass.assign(change.impurities)
	billet.discarded_mass += discarded
	billet.discarded_impurity_mass = ledger
	billet.purification_step_id = billet.step_id
	events = pending_events
	removed_mass = discarded
	last_surface = exposure
	return true


func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


func _fail(message: String) -> bool:
	errors.append(message)
	return false

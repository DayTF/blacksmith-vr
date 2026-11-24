extends RefCounted
## Rate-based separation and explicit release. Staged masses remain part of
## their origin granules until they are skimmed or drained.

const DESTINATIONS := ["surface", "bottom"]
var errors := PackedStringArray()
var moved_mass := 0.0
var removed_mass := 0.0


func advance(billet: RefCounted, equipment: Dictionary, dt: float) -> bool:
	if not is_finite(dt) or dt <= 0.0:
		errors.clear()
		moved_mass = 0.0
		removed_mass = 0.0
		return _fail("Separation needs a positive duration.")
	return _process(billet, equipment, dt, "")


func skim(billet: RefCounted, equipment: Dictionary) -> bool:
	return _process(billet, equipment, 0.0, "surface")


func drain(billet: RefCounted, equipment: Dictionary) -> bool:
	return _process(billet, equipment, 0.0, "bottom")


func _process(billet: RefCounted, equipment: Dictionary, dt: float, removal: String) -> bool:
	errors.clear()
	moved_mass = 0.0
	removed_mass = 0.0
	var cap: Variant = equipment.get("maximum_temperature_c")
	var destinations: Variant = equipment.get("separation_destinations")
	if not _number(cap) or cap < -273.15 or not destinations is Array:
		return _fail("Refining equipment needs a temperature limit and separation destinations.")
	for destination: Variant in destinations:
		if not DESTINATIONS.has(destination):
			return _fail("Unknown equipment separation destination.")
	if not removal.is_empty() and not destinations.has(removal):
		return _fail("This equipment cannot remove impurities from " + removal + ".")
	if not _number(billet.discarded_mass) or billet.discarded_mass < 0.0:
		return _fail("Invalid discarded mass.")

	var nodes: Array[Dictionary] = billet.nodes
	var ledger: Dictionary = billet.discarded_impurity_mass.duplicate(true)
	var changes: Array[Dictionary] = []
	var staged_moved := 0.0
	var staged_removed := 0.0
	for index in nodes.size():
		var node := nodes[index]
		var material: RefCounted = billet.materials.get_material(node.get("material_id", ""))
		if material == null or not _node_valid(node):
			return _fail("Invalid local refining state.")
		var policy: Dictionary = material.raw_data.get("processes", {}).get("melting", {})
		if not policy.get("enabled", false):
			continue
		# Equipment cannot supply more heat than its cap and never changes local
		# temperature here. Thermal transport remains an independent operation.
		var context := {"temperature": minf(node.temperature, cap), "plastic_strain": node.plastic_strain}
		var melt: Variant = material.sample("melt_fraction", context)
		if not _ratio(melt):
			return _fail("Melt fraction must be in [0, 1].")
		if melt == 0.0:
			continue
		var staged: Dictionary = node.get("separated_impurities", {}).duplicate(true)
		var impurity_mass: Dictionary = node.impurity_mass.duplicate()
		var node_loss := 0.0
		var node_moved := 0.0
		for impurity: Dictionary in material.raw_data.impurities:
			var rule: Dictionary = impurity.get("processes", {}).get("melting", {})
			if not rule.get("enabled", false):
				continue
			var id: String = impurity.id
			var destination: Variant = rule.get("separates_to")
			if not DESTINATIONS.has(destination):
				return _fail("An enabled melt impurity requires a surface or bottom destination.")
			if not destinations.has(destination):
				continue
			var available: float = impurity_mass.get(id, 0.0)
			var pool: Dictionary = staged.get(id, {"mass_kg": 0.0, "destination": destination})
			if pool.destination != destination:
				return _fail("A material reload changed an active separation destination.")
			var separated: float = pool.mass_kg
			if removal.is_empty():
				if available == separated:
					continue
				var efficiency: Variant = material.sample("processes.melting.separation_efficiency", context)
				var rate: Variant = material.sample("impurities.%s.melting.separation_rate" % id, context)
				if not _ratio(efficiency) or not _number(rate) or rate < 0.0:
					return _fail("Invalid material separation efficiency or impurity rate.")
				var exposure: float = float(rate) * float(efficiency) * float(melt) * dt
				if not is_finite(exposure):
					return _fail("Separation rate exceeds representable scale.")
				var next_mass := minf(available, separated + (available - separated) * (1.0 - exp(-exposure)))
				if next_mass > separated:
					staged[id] = {"mass_kg": next_mass, "destination": destination}
					node_moved += next_mass - separated
			elif removal == destination and separated > 0.0:
				if not _credit_discard(ledger, node.material_id, id, separated):
					return _fail("Invalid discarded impurity ledger.")
				impurity_mass[id] = available - separated
				staged.erase(id)
				node_loss += separated
		if node_loss > 0.0 or node_moved > 0.0:
			if node.mass - node_loss <= 0.0:
				return _fail("Refining would exhaust a granule.")
			changes.append({"node": index, "separated": staged, "impurities": impurity_mass,
				"mass": node.mass - node_loss})
			staged_moved += node_moved
			staged_removed += node_loss
	if not is_finite(staged_moved) or not is_finite(billet.discarded_mass + staged_removed):
		return _fail("Refining mass exceeds representable scale.")
	for change in changes:
		var node := nodes[change.node]
		if change.separated.is_empty():
			node.erase("separated_impurities")
		else:
			node["separated_impurities"] = change.separated
		if not removal.is_empty():
			node.impurity_mass.assign(change.impurities)
			node.mass = change.mass
	if staged_removed > 0.0:
		billet.discarded_mass += staged_removed
		billet.discarded_impurity_mass = ledger
	moved_mass = staged_moved
	removed_mass = staged_removed
	return true


func _node_valid(node: Dictionary) -> bool:
	for key in ["mass", "temperature", "plastic_strain"]:
		if not _number(node.get(key)):
			return false
	if node.mass <= 0.0 or node.temperature < -273.15 or node.plastic_strain < 0.0:
		return false
	if not node.get("impurity_mass") is Dictionary:
		return false
	var total := 0.0
	for amount: Variant in node.impurity_mass.values():
		if not _number(amount) or amount < 0.0:
			return false
		total += float(amount)
	if total > node.mass:
		return false
	var pools: Variant = node.get("separated_impurities", {})
	if not pools is Dictionary:
		return false
	for id: Variant in pools:
		var pool: Variant = pools[id]
		if not pool is Dictionary or not _number(pool.get("mass_kg")) or not DESTINATIONS.has(pool.get("destination")):
			return false
		if pool.mass_kg < 0.0 or pool.mass_kg > node.impurity_mass.get(id, 0.0):
			return false
	return true


func _credit_discard(ledger: Dictionary, material_id: String, impurity_id: String, mass: float) -> bool:
	var entries: Variant = ledger.get(material_id, {})
	if not entries is Dictionary:
		return false
	var previous: Variant = entries.get(impurity_id, 0.0)
	if not _number(previous) or previous < 0.0 or not is_finite(previous + mass):
		return false
	entries[impurity_id] = previous + mass
	ledger[material_id] = entries
	return true


func _ratio(value: Variant) -> bool:
	return _number(value) and value >= 0.0 and value <= 1.0


func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(value)


func _fail(message: String) -> bool:
	errors.append(message)
	return false

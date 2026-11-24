extends RefCounted
## Conservative pairwise heat exchange and bounded explicit boundary exchange.
## All candidate state is private until a complete step succeeds.

var materials: RefCounted
var tuning: Dictionary
var errors := PackedStringArray()
var phase_events: Array[Dictionary] = []
var boundary_energy_j := 0.0


func _init(library: RefCounted, parameters: Dictionary) -> void:
	materials = library
	tuning = parameters.duplicate(true)


func step(nodes: Array[Dictionary], links: Array[Dictionary], exposed_areas: PackedFloat64Array,
		dt: float, boundary: Dictionary) -> bool:
	errors.clear()
	phase_events.clear()
	boundary_energy_j = 0.0
	if not _valid_parameters() or not _number(dt) or dt <= 0.0 or dt > tuning.maximum_step_s:
		return _fail("Invalid thermal timestep or tuning.")
	if exposed_areas.size() != nodes.size() or not _number(boundary.get("temperature_c")) or not boundary.get("coefficient_property") is String or not _number(boundary.get("coefficient_scale")) or boundary.coefficient_scale < 0:
		return _fail("Invalid thermal boundary or exposure array.")
	var ambient: float = boundary.temperature_c
	if boundary.has("maximum_temperature_c"):
		if not _number(boundary.maximum_temperature_c):
			return _fail("Invalid equipment temperature cap.")
		ambient = minf(ambient, boundary.maximum_temperature_c)
	if ambient < -float(tuning.kelvin_offset):
		return _fail("Thermal boundary is below absolute zero.")
	var temperatures := PackedFloat64Array()
	var strains := PackedFloat64Array()
	for index in nodes.size():
		var node := nodes[index]
		if not _number(node.get("temperature")) or node.temperature < -float(tuning.kelvin_offset) or not _number(node.get("mass")) or node.mass <= 0 or not _number(node.get("plastic_strain")) or node.plastic_strain < 0 or not node.get("position") is Vector3 or not node.position.is_finite() or not _number(exposed_areas[index]) or exposed_areas[index] < 0:
			return _fail("Invalid local thermal state.")
		if materials.get_material(node.get("material_id", "")) == null:
			return _fail("Unknown thermal material.")
		temperatures.append(node.temperature)
		strains.append(node.plastic_strain)
	for link: Dictionary in links:
		if not link.get("a") is int or not link.get("b") is int or link.a < 0 or link.b < 0 or link.a >= nodes.size() or link.b >= nodes.size() or link.a == link.b or not _number(link.get("thermal_area_m2", link.get("area"))) or link.get("thermal_area_m2", link.get("area")) < 0:
			return _fail("Invalid heat connection.")
	var remaining := dt
	var substeps := 0
	var events: Array[Dictionary] = []
	var external_energy := 0.0
	while remaining > 0.0:
		substeps += 1
		if substeps > tuning.maximum_substeps:
			return _fail("Thermal substep limit exceeded; state retained.")
		var capacities := PackedFloat64Array()
		var conductivities := PackedFloat64Array()
		var recovery := PackedFloat64Array()
		var boundary_g := PackedFloat64Array()
		var totals := PackedFloat64Array()
		var power := PackedFloat64Array()
		totals.resize(nodes.size())
		power.resize(nodes.size())
		var h := remaining
		for index in nodes.size():
			var state := {"temperature": temperatures[index], "plastic_strain": strains[index]}
			var properties := {}
			for property in ["specific_heat", "thermal_conductivity", "emissivity", "work_hardening_recovery", boundary.coefficient_property]:
				var value: Variant = materials.sample(nodes[index].material_id, property, state)
				if not _number(value) or value < 0:
					return _fail("Invalid thermal curve: " + str(property))
				properties[property] = float(value)
			var capacity: float = nodes[index].mass * properties.specific_heat
			if not is_finite(capacity) or capacity <= 0:
				return _fail("Positive finite heat capacity required.")
			capacities.append(capacity)
			conductivities.append(properties.thermal_conductivity)
			recovery.append(properties.work_hardening_recovery)
			var tk: float = temperatures[index] + tuning.kelvin_offset
			var ak: float = ambient + tuning.kelvin_offset
			# Factor T^4 - A^4 to obtain an exact, nonnegative frozen conductance.
			var radiation: float = properties.emissivity * tuning.stefan_boltzmann_w_m2k4 * (tk + ak) * (tk * tk + ak * ak)
			var g: float = exposed_areas[index] * (properties[boundary.coefficient_property] * boundary.coefficient_scale + radiation)
			if not is_finite(g):
				return _fail("Nonfinite thermal boundary conductance.")
			boundary_g.append(g)
			totals[index] = g
			power[index] = g * (ambient - temperatures[index])
		for link: Dictionary in links:
			if link.get("broken", false):
				continue
			var a: int = link.a
			var b: int = link.b
			var ka: float = conductivities[a]
			var kb: float = conductivities[b]
			# Harmonic interface conductivity: a zero-conductivity side blocks flow.
			var conductivity := 0.0 if ka == 0.0 or kb == 0.0 else 2.0 / (1.0 / ka + 1.0 / kb)
			var length: float = maxf(nodes[a].position.distance_to(nodes[b].position), tuning.minimum_length_m)
			var g: float = conductivity * link.get("thermal_area_m2", link.get("area")) / length
			if not is_finite(g):
				return _fail("Nonfinite thermal connection conductance.")
			var exchange: float = g * (temperatures[b] - temperatures[a])
			power[a] += exchange
			power[b] -= exchange
			totals[a] += g
			totals[b] += g
		for index in nodes.size():
			if totals[index] > 0:
				h = minf(h, tuning.stability_fraction * capacities[index] / totals[index])
		if not is_finite(h) or h <= 0.0 or remaining - h == remaining:
			return _fail("Thermal step cannot advance; state retained.")
		for index in nodes.size():
			var previous: float = temperatures[index]
			var next: float = previous + power[index] * h / capacities[index]
			var strain: float = strains[index] * exp(-recovery[index] * h)
			if not is_finite(next) or not is_finite(strain):
				return _fail("Nonfinite thermal result; state retained.")
			for event: Dictionary in materials.get_material(nodes[index].material_id).phase_events(previous, next):
				var local := event.duplicate(true)
				local["node"] = index
				events.append(local)
			external_energy += boundary_g[index] * (ambient - previous) * h
			temperatures[index] = next
			strains[index] = strain
		remaining -= h
	if not is_finite(external_energy):
		return _fail("Nonfinite boundary energy; state retained.")
	for index in nodes.size():
		nodes[index].temperature = temperatures[index]
		nodes[index].plastic_strain = strains[index]
	phase_events = events
	boundary_energy_j = external_energy
	return true


func _valid_parameters() -> bool:
	for key in ["maximum_step_s", "minimum_length_m", "kelvin_offset", "stability_fraction"]:
		if not _number(tuning.get(key)) or tuning[key] <= 0:
			return false
	return tuning.stability_fraction <= 1.0 and _number(tuning.get("maximum_substeps")) and tuning.maximum_substeps >= 1 and tuning.maximum_substeps == floorf(tuning.maximum_substeps) and _number(tuning.get("stefan_boltzmann_w_m2k4")) and tuning.stefan_boltzmann_w_m2k4 >= 0


func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


func _fail(message: String) -> bool:
	errors.append(message)
	return false

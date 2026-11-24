class_name MaterialDefinition
extends RefCounted
## Validated data plus compiled graphs; no scene, input or rendering dependencies.

const CurveGraph = preload("res://src/sim/material_curve.gd")

var errors := PackedStringArray()
var id := ""
var display_name := ""
var raw_data: Dictionary = {}
var _curves: Dictionary = {}
var _phases: Array[Dictionary] = []


func _init(data: Dictionary, defaults: Dictionary) -> void:
	_configure(data, defaults)


func sample(property: String, context: Dictionary) -> Variant:
	if not errors.is_empty() or not CurveGraph._number(context.get("temperature")):
		return null
	var selected := _curves
	for phase in _phases:
		if float(context.temperature) < phase.temperature:
			break
		selected = phase.curves
	var curve: CurveGraph = selected.get(property)
	return null if curve == null else curve.sample(context)


func phase_events(previous_temperature: float, temperature: float) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if not errors.is_empty() or not is_finite(previous_temperature) or not is_finite(temperature):
		return events
	var heating := temperature > previous_temperature
	for phase in _phases:
		var threshold: float = phase.temperature
		if (previous_temperature < threshold and temperature >= threshold) or (
			temperature < threshold and previous_temperature >= threshold
		):
			var event: Dictionary = phase.definition.duplicate(true)
			event["direction"] = "heating" if heating else "cooling"
			event["active"] = heating
			events.append(event)
	if not heating:
		events.reverse()
	return events


func has_property(property: String) -> bool:
	return _curves.has(property)


func export_runtime() -> Dictionary:
	var result := {"curves": {}, "phases": []}
	for property: String in _curves:
		result.curves[property] = _curves[property].export_graph()
	for phase in _phases:
		var curves: Dictionary = {}
		for property: String in phase.curves:
			curves[property] = phase.curves[property].export_graph()
		result.phases.append({"temperature": phase.temperature, "curves": curves})
	return result


func _configure(data: Dictionary, defaults: Dictionary) -> void:
	raw_data = data.duplicate(true)
	if data.get("schema_version") != 1:
		errors.append("Unsupported material schema_version (expected 1).")
	if defaults.get("schema_version") != 1:
		errors.append("Unsupported defaults schema_version (expected 1).")
	for field in ["id", "name"]:
		if not data.get(field) is String or str(data[field]).strip_edges().is_empty():
			errors.append("Material requires a nonempty %s." % field)
	if not errors.is_empty():
		return
	id = data.id
	display_name = data.name
	if not data.get("curves", {}) is Dictionary or not defaults.get("curves") is Dictionary:
		errors.append("Material/default curves must be objects.")
		return
	var graphs: Dictionary = defaults.curves.duplicate(true)
	graphs.merge(data.get("curves", {}), true)
	_add_processes(data.get("processes", {}), "processes", graphs)
	_validate_impurities(data.get("impurities"), graphs)
	_curves = _compile_graphs(graphs)
	for property: Variant in defaults.curves:
		var reference := CurveGraph.new(defaults.curves[property])
		var actual: CurveGraph = _curves.get(property)
		if actual != null and (actual.width != reference.width or actual.vector_value != reference.vector_value):
			errors.append("%s must preserve the default property's value shape." % property)
	_configure_phases(data.get("phase_transitions", []), graphs)


func _validate_impurities(impurities: Variant, graphs: Dictionary) -> void:
	if not impurities is Array:
		errors.append("Material requires an impurities array, even when empty.")
		return
	var ids: Dictionary = {}
	var total := 0.0
	for impurity: Variant in impurities:
		if not impurity is Dictionary or not impurity.get("id") is String:
			errors.append("Each impurity requires an id.")
			continue
		var impurity_id: String = impurity.id
		if impurity_id.is_empty() or ids.has(impurity_id):
			errors.append("Impurity ids must be nonempty and unique.")
		ids[impurity_id] = true
		var concentration: Variant = impurity.get("base_concentration")
		if not CurveGraph._number(concentration) or concentration < 0 or concentration > 1:
			errors.append("Impurity %s concentration must be within [0, 1]." % impurity_id)
		else:
			total += float(concentration)
		if not impurity.get("effect", {}) is Dictionary:
			errors.append("Impurity effects must be an object.")
		_add_processes(impurity.get("processes", {}), "impurities." + impurity_id, graphs)
	if total > 1.0:
		errors.append("Total starting impurity concentration exceeds 1.")


func _add_processes(processes: Variant, prefix: String, graphs: Dictionary) -> void:
	if not processes is Dictionary:
		errors.append("%s must be a process object." % prefix)
		return
	for process: Variant in processes:
		var definition: Variant = processes[process]
		if not process is String or not definition is Dictionary or not definition.get("enabled") is bool:
			errors.append("Processes require string ids and an explicit enabled boolean.")
			continue
		var curves: Variant = definition.get("curves", {})
		if not curves is Dictionary:
			errors.append("%s.%s curves must be an object." % [prefix, process])
			continue
		for property: Variant in curves:
			graphs["%s.%s.%s" % [prefix, process, property]] = curves[property]


func _compile_graphs(graphs: Dictionary) -> Dictionary:
	var compiled: Dictionary = {}
	for property: Variant in graphs:
		if not property is String or property.is_empty():
			errors.append("Property ids must be nonempty strings.")
			continue
		var curve := CurveGraph.new(graphs[property])
		for message in curve.errors:
			errors.append("%s: %s" % [property, message])
		compiled[property] = curve
	return compiled


func _configure_phases(transitions: Variant, base_graphs: Dictionary) -> void:
	if not transitions is Array:
		errors.append("phase_transitions must be an array.")
		return
	var sorted: Array[Dictionary] = []
	var ids: Dictionary = {}
	for transition: Variant in transitions:
		if not transition is Dictionary or not CurveGraph._number(transition.get("temperature")):
			errors.append("Each phase requires a finite temperature.")
			continue
		if not transition.get("id") is String or str(transition.id).is_empty() or ids.has(transition.id):
			errors.append("Phase ids must be nonempty and unique.")
			continue
		ids[transition.id] = true
		if not transition.get("modifiers") is Dictionary:
			errors.append("Phase modifiers must be an object.")
			continue
		sorted.append(transition)
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.temperature < b.temperature)
	var graphs := base_graphs.duplicate(true)
	var previous: Variant = null
	for transition in sorted:
		if previous != null and transition.temperature == previous:
			errors.append("Phase thresholds must be distinct; combine simultaneous modifiers.")
		previous = transition.temperature
		for property: Variant in transition.modifiers:
			var modifier: Variant = transition.modifiers[property]
			if not modifier is Dictionary or modifier.is_empty():
				errors.append("Phase property modifier must be a nonempty object.")
				continue
			if not graphs.has(property):
				errors.append("Phase cannot modify unknown property %s." % property)
				continue
			var graph: Variant = modifier.get("curve", graphs[property])
			for operation in ["scale", "offset"]:
				if modifier.has(operation):
					graph = {"op": "multiply" if operation == "scale" else "add", "inputs": [graph, {"constant": modifier[operation]}]}
			for key: Variant in modifier:
				if key not in ["curve", "scale", "offset"]:
					errors.append("Unknown phase modifier %s." % key)
			graphs[property] = graph
		var compiled := _compile_graphs(graphs)
		for property: Variant in compiled:
			var original: CurveGraph = _curves.get(property)
			var modified: CurveGraph = compiled[property]
			if original != null and (modified.width != original.width or modified.vector_value != original.vector_value):
				errors.append("Phase must preserve the value shape of %s." % property)
		_phases.append({"temperature": float(transition.temperature), "definition": transition.duplicate(true), "curves": compiled})

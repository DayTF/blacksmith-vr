extends RefCounted
## Material-specific response to an observed cooling interval.

const FRACTION_CURVE := "processes.quench_hardening.fraction"

var _materials: RefCounted
var _profiles: Dictionary = {}
var _points: Array[Dictionary] = []
var _results: Dictionary = {}


func _init(materials: RefCounted) -> void:
	_materials = materials


func prepare(nodes: Array[Dictionary]) -> void:
	for index in range(_points.size(), nodes.size()):
		var point := nodes[index]
		var material_id: String = point.material_id
		if not _profiles.has(material_id):
			var material: RefCounted = _materials.get_material(material_id)
			if material != null:
				_profiles[material_id] = material.quench_profile()
		var profile: Dictionary = _profiles.get(material_id, {})
		_points.append({
			"material": material_id, "profile": profile, "start_s": -1.0,
			"qualified": not profile.is_empty() and float(point.temperature) >= float(profile.heat_c),
		})


func observe(event: Dictionary, time_s: float) -> void:
	var point := _points[event.node]
	var profile: Dictionary = point.profile
	if profile.is_empty():
		return
	var marker: String = event.id
	if event.active:
		if marker == profile.heat_phase:
			point.qualified = true
			_results.erase(event.node)
		if marker == profile.start_phase or marker == profile.heat_phase:
			point.start_s = -1.0
	elif point.qualified:
		if marker == profile.start_phase:
			point.start_s = time_s
		elif marker == profile.finish_phase and point.start_s >= 0.0:
			var duration := time_s - float(point.start_s)
			if duration <= 0.0:
				return
			var rate := (float(profile.start_c) - float(profile.finish_c)) / duration
			var fraction: Variant = _materials.sample(point.material, FRACTION_CURVE,
				{"temperature": profile.finish_c, "cooling_rate_c_s": rate})
			if fraction is float and is_finite(fraction):
				_results[event.node] = {"fraction": clampf(fraction, 0.0, 1.0),
					"mean_cooling_rate_c_s": rate, "duration_s": duration}
			point.qualified = false
			point.start_s = -1.0


func outcomes() -> Dictionary:
	return _results.duplicate(true)

extends SceneTree
## Deterministic M0 process replay. Emits one JSON object per checkpoint.

const Library = preload("res://src/sim/material_library.gd")
const Billet = preload("res://src/sim/granular_billet.gd")
const Layered = preload("res://src/sim/layered_forging.gd")
const Surface = preload("res://src/sim/billet_surface.gd")
const Thermal = preload("res://src/sim/thermal_model.gd")
const Separation = preload("res://src/sim/melt_separation.gd")
const Purification = preload("res://src/sim/forging_purification.gd")

var _materials := Library.new()
var _billet: RefCounted
var _folding: RefCounted
var _surface: RefCounted
var _thermal: RefCounted
var _purification: RefCounted
var _config: Dictionary
var _errors := PackedStringArray()
var _initial_mass := 0.0


func _initialize() -> void:
	if not _materials.load_directory("res://data/materials"):
		_errors = _materials.errors
	elif _replay():
		quit()
		return
	for message in _errors:
		push_error(message)
	quit(1)


func _replay() -> bool:
	_config = _data("forging_harness")
	var parameters := _data("surface")
	_billet = Billet.new(_materials, _data("mechanics"))
	_folding = Layered.new(parameters, _data("welding"))
	_surface = Surface.new(parameters)
	_thermal = Thermal.new(_materials, _data("thermal"))
	_purification = Purification.new(parameters)

	var width: int = _config.width_points
	var length: int = _config.length_points
	var base_height: int = _config.base_height_points
	var leaf_height: int = _config.leaf_height_points
	var spacing: float = _config.spacing_m
	var pivot := Vector3((width - 1) * spacing, (base_height - 1) * spacing, 0.0)
	var leaf_origin := pivot - Vector3.UP * (leaf_height - 1) * spacing
	var base: PackedInt32Array = _folding.stack_grid(_billet, Vector3i(width, base_height, length),
		spacing, Vector3.ZERO, _config.base_material, _config.initial_temperature_c, "base")
	var leaf: PackedInt32Array = _folding.stack_grid(_billet, Vector3i(width, leaf_height, length),
		spacing, leaf_origin, _config.leaf_material, _config.initial_temperature_c, "leaf")
	if base.is_empty() or leaf.is_empty():
		return _fail("Scripted billet construction failed.", _folding.errors)
	_initial_mass = _billet.total_mass()
	var initial_nodes: Array[Dictionary] = _billet.nodes.duplicate(true)
	_checkpoint("assembled")

	var environments: Array = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/preview/environments.json")).environments
	var forge := _boundary(environments, "forge")
	if not _thermal_until(forge, _config.welding_temperature_c, true):
		return false
	_checkpoint("heated")

	var center_x := width >> 1
	var center_z := length >> 1
	var base_face := base[_index(center_x, base_height - 1, center_z, width, base_height)]
	var leaf_face := leaf[_index(width - 1 - center_x, leaf_height - 1, center_z, width, leaf_height)]
	if not _folding.fold(_billet, leaf, pivot, Vector3.BACK, PI):
		return _fail("Scripted fold failed.", _folding.errors)
	var exposure: Dictionary = _surface.evaluate(_billet.nodes, _billet.cells)
	if exposure.is_empty() or exposure.exposed[base_face] or exposure.exposed[leaf_face]:
		return _fail("Fold did not bury the interior interface patches.", _surface.errors)
	_checkpoint("folded", {"buried_pair": [base_face, leaf_face]})

	var pairs: Array[Vector2i] = []
	for z in length:
		for x in width:
			pairs.append(Vector2i(base[_index(x, base_height - 1, z, width, base_height)],
				leaf[_index(width - 1 - x, leaf_height - 1, z, width, leaf_height)]))
	var top_point := leaf[_index(width - 1 - center_x, 0, center_z, width, leaf_height)]
	if not _folding.hammer(_billet, _billet.nodes[top_point].position, Vector3.UP, _config.hammer_radius_m,
			_config.hammer_mass_kg, Vector3.DOWN * _config.hammer_speed_m_s, pairs):
		return _fail("Scripted welding strike failed.", _folding.errors)
	var welds := 0
	for event: Dictionary in _folding.weld_attempts:
		welds += int(event.link >= 0)
	if welds == 0:
		return _fail("The weld strike did not create a bond.")
	_checkpoint("welded", {"bonds_created": welds})

	forge.temperature_c = _config.working_boundary_c
	if not _thermal_until(forge, _config.working_temperature_max_c, false):
		return false
	var strikes := 0
	var purified := {}
	for hit in int(_config.maximum_working_strikes):
		var contact := _top_contact(center_x * spacing, center_z * spacing)
		if not _billet.hammer(contact, Vector3.UP, _config.hammer_radius_m, _config.hammer_mass_kg,
				Vector3.DOWN * _config.hammer_speed_m_s):
			return _fail("Scripted spreading strike missed.", _billet.errors)
		strikes += 1
		for step in int(_config.settle_steps):
			if not _billet.step(_config.step_s):
				return _fail("Mechanics failed while spreading.", _billet.errors)
			if not _purification.apply(_billet):
				return _fail("Purification failed while spreading.", _purification.errors)
			for event: Dictionary in _purification.events:
				if not _purification.last_surface.exposed[event.node] or _billet.nodes[event.node].plastic_spreading_increment <= 0.0:
					return _fail("Purification released matter outside a spreading surface.")
				purified[event.node] = true
		if not purified.is_empty():
			break
	if purified.is_empty():
		return _fail("Spreading released no impurities.")
	_checkpoint("spread", {"strikes": strikes, "purified_points": purified.size()})

	if not _thermal_until(_boundary(environments, "water"), _config.quench_temperature_max_c, false):
		return false
	for index in _billet.nodes.size():
		var node: Dictionary = _billet.nodes[index]
		var initial := initial_nodes[index]
		if node.layer_id != initial.layer_id or node.composition != initial.composition:
			return _fail("A point lost its original constituent or layer.")
	if absf(_billet.total_mass() - _initial_mass) > parameters.mass_roundoff_tolerance_kg:
		return _fail("The replay failed to conserve live plus discarded mass.")
	_checkpoint("quenched", {"layered_identity_preserved": true})
	return _replay_molten_interval()


func _replay_molten_interval() -> bool:
	# A separate charge demonstrates refining within one molten interval.
	_billet = Billet.new(_materials, _data("mechanics"))
	var equipment := _data("refining_equipment")
	var crucible: Dictionary = equipment.refining_crucible
	var temperature: float = crucible.maximum_temperature_c
	var material: String = _config.base_material
	if not _billet.build_grid(Vector3i(2, 2, 2), _config.spacing_m, Vector3.ZERO,
			material, temperature, "refining-charge"):
		return _fail("Could not prepare the preheated refining charge.", _billet.errors)
	var refining := Separation.new()
	var initial_mass: float = _billet.total_mass()
	if not refining.advance(_billet, equipment.forge, _config.refining_interval_s) or refining.moved_mass != 0.0:
		return _fail("The forge must leave this charge unseparated.", refining.errors)
	if not refining.advance(_billet, crucible, _config.refining_interval_s) or refining.moved_mass <= 0.0:
		return _fail("The refining crucible did not separate impurities.", refining.errors)
	var separated := refining.moved_mass
	if _billet.discarded_mass != 0.0 or _billet.total_mass() != initial_mass:
		return _fail("Migration changed the charge mass or discard ledger.")
	_checkpoint("melt_separated", {"separated_mass_kg": separated})
	if not refining.skim(_billet, crucible):
		return _fail("Skimming the charge failed.", refining.errors)
	var tolerance: float = _data("surface").mass_roundoff_tolerance_kg
	if absf(refining.removed_mass - separated) > tolerance or absf(_billet.total_mass() - initial_mass) > tolerance:
		return _fail("Skimming failed to account for the migrated mass.")
	_checkpoint("melt_skimmed", {"skimmed_mass_kg": refining.removed_mass})
	return true


func _thermal_until(environment: Dictionary, threshold: float, heating: bool) -> bool:
	var exposure: Dictionary = _surface.evaluate(_billet.nodes, _billet.cells)
	if exposure.is_empty():
		return _fail("Thermal exposure query failed.", _surface.errors)
	for iteration in int(_config.maximum_thermal_steps):
		if not _thermal.step(_billet.nodes, _billet.connections, exposure.areas, _config.step_s, environment):
			return _fail("Thermal replay failed.", _thermal.errors)
		var ready := true
		for node: Dictionary in _billet.nodes:
			if (heating and node.temperature < threshold) or (not heating and node.temperature > threshold):
				ready = false
				break
		if ready:
			return true
	return _fail("Thermal replay did not reach %s C in %s." % [threshold, environment.id])


func _top_contact(x: float, z: float) -> Vector3:
	var center := Vector3(x, -INF, z)
	var radius: float = _config.hammer_radius_m
	for node: Dictionary in _billet.nodes:
		var offset := Vector2(node.position.x - x, node.position.z - z)
		if offset.length_squared() <= radius * radius:
			center.y = maxf(center.y, node.position.y)
	return center


func _checkpoint(stage: String, details: Dictionary = {}) -> void:
	var points: Array[Dictionary] = []
	for node: Dictionary in _billet.nodes:
		points.append({"position_m": [node.position.x, node.position.y, node.position.z],
			"temperature_c": node.temperature, "impurity_mass_kg": node.impurity_mass,
			"layer_id": node.layer_id, "material_id": node.material_id})
	print(JSON.stringify({"stage": stage, "points": points, "discarded_mass_kg": _billet.discarded_mass,
		"discarded_impurity_mass_kg": _billet.discarded_impurity_mass, "details": details}))


func _boundary(environments: Array, id: String) -> Dictionary:
	for environment: Dictionary in environments:
		if environment.id == id:
			return environment.duplicate()
	return {}


func _index(x: int, y: int, z: int, width: int, height: int) -> int:
	return x + width * (y + height * z)


func _data(id: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/" + id + ".json"))


func _fail(message: String, errors: PackedStringArray = PackedStringArray()) -> bool:
	_errors.append(message)
	_errors.append_array(errors)
	return false

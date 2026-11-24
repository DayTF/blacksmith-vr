extends RefCounted
## Compatibility views synchronize on step. commit_state() explicitly releases
## retained dictionary views and transfers runtime ownership to the native solver.

const Reference = preload("res://src/sim/granular_billet.gd")
var _reference: RefCounted
var _core: RefCounted
var _loaded := false
var _views_exposed := false
var _pending_download := false
var _catalog_revision := -1
var _last_impulse := Vector3.ZERO
var errors := PackedStringArray()
var step_id: int:
	get: return _reference.step_id
var purification_step_id: int:
	get: return _reference.purification_step_id
	set(value): _reference.purification_step_id = value
var discarded_impurity_mass: Dictionary:
	get: return _reference.discarded_impurity_mass
	set(value): _reference.discarded_impurity_mass = value

var nodes: Array[Dictionary]:
	get:
		_sync_out()
		_views_exposed = true
		return _reference.nodes
	set(value):
		_sync_out()
		_reference.nodes = value
		_loaded = false
		_views_exposed = true
var connections: Array[Dictionary]:
	get:
		_sync_out()
		_views_exposed = true
		return _reference.connections
	set(value):
		_sync_out()
		_reference.connections = value
		_loaded = false
		_views_exposed = true
var cells: Array[Dictionary]:
	get:
		_sync_out()
		_views_exposed = true
		return _reference.cells
	set(value):
		_sync_out()
		_reference.cells = value
		_loaded = false
		_views_exposed = true
var materials: Variant:
	get: return _reference.materials
	set(value):
		_sync_out()
		_reference.materials = value
		_catalog_revision = -1
var tuning: Dictionary:
	get: return _reference.tuning
	set(value): _reference.tuning = value
var discarded_mass: float:
	get: return _reference.discarded_mass
	set(value):
		_sync_out()
		_reference.discarded_mass = value
		_loaded = false
var last_impulse: Vector3:
	get: return _last_impulse


func _init(material_library: Variant, parameters: Dictionary) -> void:
	_reference = Reference.new(material_library, parameters)
	if not ClassDB.class_exists("BlacksmithNativeCore"):
		GDExtensionManager.load_extension("res://native/blacksmith.gdextension")
	if ClassDB.class_exists("BlacksmithNativeCore"):
		_core = ClassDB.instantiate("BlacksmithNativeCore")
	else:
		errors.append("Native solver unavailable; build native/CMakeLists.txt first.")


func _prepare(force_upload: bool = false) -> bool:
	errors.clear()
	if _core == null or not _reference._parameters_valid():
		errors.append("Native solver unavailable or invalid tuning.")
		return false
	var revision: int = materials.get_revision()
	if revision != _catalog_revision:
		if not _core.set_materials(materials.export_runtime_catalog()):
			errors = _core.get_errors()
			return false
		_catalog_revision = revision
	if not _core.set_parameters(tuning):
		errors = _core.get_errors()
		return false
	if force_upload or not _loaded or _views_exposed:
		if not _core.load_state(_reference.nodes, _reference.connections, _reference.cells, _reference.discarded_mass):
			errors = _core.get_errors()
			return false
		_loaded = true
	return true


func _sync_out() -> void:
	if _pending_download and _loaded:
		var snapshot: Dictionary = _core.download()
		for field in ["nodes", "connections", "cells"]:
			if _views_exposed:
				var existing: Array = _reference.get(field)
				for index in existing.size():
					_merge_changes(existing[index], snapshot[field][index])
			else:
				var typed: Array[Dictionary] = []
				typed.assign(snapshot[field])
				_reference.set(field, typed)
		_pending_download = false


func commit_state() -> bool:
	# Synchronize the latest dictionaries, then explicitly release their authority.
	_sync_out()
	if not _prepare(true):
		return false
	_views_exposed = false
	return true


func step(dt: float) -> bool:
	if not _prepare():
		return false
	var success: bool = _core.step(dt)
	errors = _core.get_errors()
	if success:
		_reference.step_id += 1
		_pending_download = true
		if _views_exposed:
			_sync_out()
	return success


func hammer(center: Vector3, normal: Vector3, radius: float, mass: float, velocity: Vector3) -> bool:
	_last_impulse = Vector3.ZERO
	if not _prepare():
		return false
	var success: bool = _core.hammer(center, normal, radius, mass, velocity)
	errors = _core.get_errors()
	if success:
		_last_impulse = _core.get_last_impulse()
		_pending_download = true
		if _views_exposed:
			_sync_out()
	return success


func add_node(position: Vector3, mass: float, material_id: String, temperature: float,
		orientation: Basis = Basis.IDENTITY, impurity_mass: Variant = null, layer_id: String = "") -> int:
	_sync_out()
	var result: int = _reference.add_node(position, mass, material_id, temperature, orientation, impurity_mass, layer_id)
	_loaded = false
	return result


func connect_nodes(a: int, b: int, area: float, damping: float) -> int:
	_sync_out()
	var result: int = _reference.connect_nodes(a, b, area, damping)
	_loaded = false
	return result


func build_grid(dimensions: Vector3i, spacing: float, origin: Vector3,
		material_id: String, temperature: float, layer_id: String = "") -> bool:
	_sync_out()
	var success: bool = _reference.build_grid(dimensions, spacing, origin, material_id, temperature, layer_id)
	errors = _reference.errors
	if success:
		_loaded = false
	return success


func total_mass() -> float:
	return _core.get_total_mass() if _loaded and not _views_exposed else _reference.total_mass()


func positions_snapshot() -> PackedVector3Array:
	return _core.get_positions() if _loaded and not _views_exposed else _reference_positions()


func _reference_positions() -> PackedVector3Array:
	var result := PackedVector3Array()
	for node: Dictionary in _reference.nodes:
		result.append(node.position)
	return result


func kernel_elapsed_usec() -> float:
	return _core.get_elapsed_usec() if _core != null else 0.0


func sample_material(id: String, property: String, context: Dictionary) -> Variant:
	if not _prepare():
		return null
	return _core.sample_material(id, property, context)


func _merge_changes(target: Dictionary, source: Dictionary) -> void:
	for key: Variant in source:
		if target.get(key) == source[key]:
			continue
		if target.get(key) is Dictionary and source[key] is Dictionary:
			_merge_changes(target[key], source[key])
		else:
			target[key] = source[key]


func enable_profiling(enabled: bool) -> void:
	if _core != null:
		_core.enable_profiling(enabled)


func profile_snapshot() -> Dictionary:
	return _core.get_profile_usec() if _core != null else {}

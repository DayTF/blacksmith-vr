class_name MaterialLibrary
extends RefCounted
## Runtime JSON loading is transactional: invalid reloads retain the last catalog.

const Definition = preload("res://src/sim/material_definition.gd")
const CurveGraph = preload("res://src/sim/material_curve.gd")

var errors := PackedStringArray()
var _materials: Dictionary = {}


func load_directory(path: String, defaults_filename: String = "defaults.json") -> bool:
	errors.clear()
	var directory := DirAccess.open(path)
	if directory == null:
		errors.append("Cannot open material directory: %s" % path)
		return false
	var defaults: Variant = _read_json(path.path_join(defaults_filename))
	if not defaults is Dictionary or defaults.get("schema_version") != 1 or not defaults.get("curves") is Dictionary:
		errors.append("Defaults require schema_version 1 and a curves object.")
		return false
	# Validate defaults even if every loaded material overrides a bad property.
	for property: Variant in defaults.curves:
		var curve := CurveGraph.new(defaults.curves[property])
		for message in curve.errors:
			errors.append("defaults.%s: %s" % [property, message])
	var candidates: Dictionary = {}
	var filenames := directory.get_files()
	filenames.sort()
	for filename in filenames:
		if filename == defaults_filename or filename.get_extension().to_lower() != "json":
			continue
		var data: Variant = _read_json(path.path_join(filename))
		if not data is Dictionary:
			errors.append("%s: material root must be an object." % filename)
			continue
		var material := Definition.new(data, defaults)
		for message in material.errors:
			errors.append("%s: %s" % [filename, message])
		if candidates.has(material.id):
			errors.append("Duplicate material id: %s" % material.id)
		candidates[material.id] = material
	if candidates.is_empty():
		errors.append("No material JSON files found in %s." % path)
	if not errors.is_empty():
		return false
	_materials = candidates
	return true


func material_ids() -> PackedStringArray:
	var ids := PackedStringArray(_materials.keys())
	ids.sort()
	return ids


func get_material(id: String) -> Definition:
	return _materials.get(id)


func sample(id: String, property: String, context: Dictionary) -> Variant:
	var material := get_material(id)
	return null if material == null else material.sample(property, context)


func _read_json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("Cannot read JSON file: %s" % path)
		return null
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		errors.append("%s:%d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data

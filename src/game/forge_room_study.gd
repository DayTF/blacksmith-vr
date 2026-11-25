extends Node3D

const QuenchLiquid := preload("res://shaders/quench_liquid.gdshader")

const StationEffects := preload("res://src/game/forge_station_effects.gd")
const PreviewSession := preload("res://src/game/preview_session.gd")

var _effects := StationEffects.new()
var _quench: PreviewSession
var _quench_smoke := false
var _quench_temperature := 0.0
var _quench_start_temperature := 0.0
var _liquid_material: ShaderMaterial


func _ready() -> void:
	var surface := $Room.find_child("Tank liquid surface", true, false) as MeshInstance3D
	assert(surface != null, "The forge room GLB must include the tank liquid surface.")
	_liquid_material = ShaderMaterial.new()
	_liquid_material.shader = QuenchLiquid
	surface.material_override = _liquid_material
	var args := OS.get_cmdline_user_args()
	var medium := "oil" if "--room-oil" in args else "water"
	set_quench_medium(medium)
	_effects.name = "StationEffects"
	add_child(_effects)
	_quench_smoke = "--room-quench-smoke" in args
	if (_quench_smoke or "--room-quench" in args) and has_node("FrontView"):
		_start_quench_preview(medium)


func set_quench_medium(medium_id: String) -> void:
	assert(medium_id == "water" or medium_id == "oil")
	var oil := medium_id == "oil"
	_liquid_material.set_shader_parameter("liquid_color", Color("35230f") if oil else Color("154e58"))
	_liquid_material.set_shader_parameter("absorption", 22.0 if oil else 5.0)
	_liquid_material.set_shader_parameter("surface_roughness", 0.49 if oil else 0.18)
	_liquid_material.set_shader_parameter("ripple_strength", 0.025 if oil else 0.065)
	_liquid_material.set_shader_parameter("ripple_speed", 0.9 if oil else 2.0)


func _start_quench_preview(medium: String) -> void:
	_quench = PreviewSession.new()
	if not _quench.initialize():
		_quench_failed(_quench.errors)
		return
	for index in _quench.environments.environments.size():
		if _quench.environments.environments[index].id == medium:
			_quench.inspect_environment(index)
			break
	if not _quench.thermal_inspection:
		_quench_failed(PackedStringArray(["Missing thermal boundary for " + medium]))
		return
	_quench_temperature = _mean_quench_temperature()
	_quench_start_temperature = _quench_temperature


func _physics_process(delta: float) -> void:
	if _quench == null:
		return
	if not _quench.thermal.step(_quench.billet.nodes, _quench.billet.connections,
			_quench.exposed_areas, delta, _quench.boundary):
		_quench_failed(_quench.thermal.errors)
		return
	var temperature := _mean_quench_temperature()
	var intensity := clampf((_quench_temperature - temperature) / (delta * 340.0), 0.0, 1.0)
	_quench_temperature = temperature
	_effects.set_quench_intensity(intensity)
	if _quench_smoke and _quench_temperature < _quench_start_temperature:
		if not _effects.get_node("QuenchSteam").emitting:
			_quench_failed(PackedStringArray(["Steam did not respond to measured cooling."]))
			return
		print("Room quench ready: ", _quench.boundary.id)
		get_tree().quit()


func _mean_quench_temperature() -> float:
	var total := 0.0
	var mass := 0.0
	for point: Dictionary in _quench.billet.nodes:
		total += float(point.temperature) * float(point.mass)
		mass += float(point.mass)
	return total / mass


func _quench_failed(errors: PackedStringArray) -> void:
	_effects.set_quench_intensity(0.0)
	_quench = null
	push_error("Quench presentation failed: " + "; ".join(errors))
	if _quench_smoke:
		get_tree().quit(1)

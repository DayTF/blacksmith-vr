extends Node3D

const QuenchLiquid := preload("res://shaders/quench_liquid.gdshader")

const ForgeAudio := preload("res://src/game/forge_audio.gd")
const StationEffects := preload("res://src/game/forge_station_effects.gd")
const ThermalPreview := preload("res://src/game/room_thermal_preview.gd")

var _station_audio := ForgeAudio.new()
var _effects := StationEffects.new()
var _quench_smoke := false
var _quench_medium: String
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
	add_child(_station_audio)
	_station_audio.start_stations(StationEffects.HEARTH, StationEffects.BATH)
	if not has_node("FrontView"):
		return
	_quench_smoke = "--room-quench-smoke" in args
	var heat_smoke := "--room-heat-smoke" in args
	if heat_smoke or "--room-heat" in args:
		_start_thermal_preview("forge", heat_smoke, StationEffects.HEARTH + Vector3(0, -0.027, 0.19))
		_focus_station(Vector3(-0.2, 1.50, -0.62), StationEffects.HEARTH + Vector3(0, 0.22, 0))
	elif _quench_smoke or "--room-quench" in args:
		_start_thermal_preview(medium, _quench_smoke, StationEffects.BATH - Vector3(0, 0.022, 0))
		_focus_station(Vector3(0.19, 1.67, -0.19), StationEffects.BATH + Vector3(0, 0.12, 0))


func set_quench_medium(medium_id: String) -> void:
	assert(medium_id == "water" or medium_id == "oil")
	_quench_medium = medium_id
	var oil := medium_id == "oil"
	_liquid_material.set_shader_parameter("liquid_color", Color("35230f") if oil else Color("154e58"))
	_liquid_material.set_shader_parameter("absorption", 22.0 if oil else 5.0)
	_liquid_material.set_shader_parameter("surface_roughness", 0.49 if oil else 0.18)
	_liquid_material.set_shader_parameter("ripple_strength", 0.025 if oil else 0.065)
	_liquid_material.set_shader_parameter("ripple_speed", 0.9 if oil else 2.0)


func _focus_station(camera_position: Vector3, target: Vector3) -> void:
	var camera := $FrontView as Camera3D
	camera.position = camera_position
	camera.look_at(target)
	camera.fov = 43.0


func _start_thermal_preview(boundary_id: String, smoke: bool, charge_center: Vector3) -> void:
	var fixture := ThermalPreview.new()
	add_child(fixture)
	fixture.cooling_changed.connect(set_quench_intensity)
	fixture.start(boundary_id, smoke, charge_center)


func quench_medium() -> String:
	return _quench_medium


func set_quench_intensity(intensity: float) -> void:
	_effects.set_quench_intensity(intensity)
	_station_audio.set_quench_intensity(intensity)
	if not _quench_smoke or intensity <= 0.0:
		return
	if not _effects.get_node("QuenchSteam").emitting or _station_audio.get_node("QuenchHiss").volume_db <= -80.0:
		push_error("Quench feedback did not respond to measured cooling.")
		get_tree().quit(1)
		return
	print("Room quench ready: ", _quench_medium)
	get_tree().quit()

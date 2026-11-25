extends Node3D

const QuenchLiquid := preload("res://shaders/quench_liquid.gdshader")

var _liquid_material: ShaderMaterial


func _ready() -> void:
	var surface := $Room.find_child("Tank liquid surface", true, false) as MeshInstance3D
	assert(surface != null, "The forge room GLB must include the tank liquid surface.")
	_liquid_material = ShaderMaterial.new()
	_liquid_material.shader = QuenchLiquid
	surface.material_override = _liquid_material
	set_quench_medium("oil" if "--room-oil" in OS.get_cmdline_user_args() else "water")


func set_quench_medium(medium_id: String) -> void:
	assert(medium_id == "water" or medium_id == "oil")
	var oil := medium_id == "oil"
	_liquid_material.set_shader_parameter("liquid_color", Color("35230f") if oil else Color("154e58"))
	_liquid_material.set_shader_parameter("absorption", 22.0 if oil else 5.0)
	_liquid_material.set_shader_parameter("surface_roughness", 0.49 if oil else 0.18)
	_liquid_material.set_shader_parameter("ripple_strength", 0.025 if oil else 0.065)
	_liquid_material.set_shader_parameter("ripple_speed", 0.9 if oil else 2.0)

extends Node3D
## Local station presentation. Quench input is cooling measured by the caller.

const HEARTH := Vector3(-0.49, 0.93, -2.42)
const BATH := Vector3(1.39, 0.884, -1.34)

var _hearth_light: OmniLight3D
var _hearth_energy: float
var _steam: CPUParticles3D
var _splash: CPUParticles3D
var _seconds := 0.0


func _ready() -> void:
	_hearth_light = get_parent().get_node("HearthLight") as OmniLight3D
	_hearth_energy = _hearth_light.light_energy
	var fire := _plume("Flames", HEARTH, 42, 0.56, Vector2(0.12, 0.25),
		Vector2(0.46, 0.81), Vector3(0.28, 0.016, 0.13), [
			Color(3.0, 1.3, 0.24, 0.9), Color(2.2, 0.42, 0.05, 0.72),
			Color(1.1, 0.09, 0.01, 0.22), Color(0.4, 0.02, 0.01, 0.0)])
	fire.preprocess = 0.6
	fire.material_override.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	var embers := _plume("Embers", HEARTH, 24, 0.83, Vector2(0.012, 0.029),
		Vector2(0.44, 0.8), Vector3(0.27, 0.018, 0.14), [
			Color(3.0, 1.1, 0.17, 1.0), Color(1.7, 0.14, 0.02, 0.7), Color(0.6, 0.04, 0.01, 0.0)])
	embers.preprocess = 0.9
	var smoke := _plume("HearthSmoke", HEARTH + Vector3(0, 0.21, 0.16), 30, 1.45,
		Vector2(0.21, 0.42), Vector2(0.12, 0.24), Vector3(0.25, 0.045, 0.077), [
			Color(0.24, 0.18, 0.15, 0.0), Color(0.29, 0.24, 0.22, 0.24),
			Color(0.24, 0.20, 0.19, 0.13), Color(0.19, 0.17, 0.16, 0.0)])
	smoke.preprocess = 1.5
	_steam = _plume("QuenchSteam", BATH, 36, 1.32, Vector2(0.13, 0.27),
		Vector2(0.16, 0.37), Vector3(0.10, 0.005, 0.075), [
			Color(0.75, 0.79, 0.82, 0.06), Color(0.76, 0.81, 0.86, 0.32),
			Color(0.63, 0.70, 0.75, 0.15), Color(0.60, 0.66, 0.72, 0.0)])
	_steam.scale_amount_curve = _growth_curve()
	_steam.emitting = false
	_splash = _plume("QuenchSplash", BATH, 20, 0.42, Vector2(0.008, 0.018),
		Vector2(0.62, 1.24), Vector3(0.06, 0.005, 0.06), [
			Color(0.63, 0.80, 0.85, 0.75), Color(0.34, 0.54, 0.59, 0.0)])
	_splash.spread = 39.0
	_splash.gravity = Vector3(0, -4.8, 0)
	_splash.one_shot = true
	_splash.explosiveness = 0.92
	_splash.emitting = false


func _process(delta: float) -> void:
	_seconds += delta
	_hearth_light.light_energy = _hearth_energy * (
		1.0 + 0.074 * sin(_seconds * 7.2) + 0.055 * sin(_seconds * 12.1))


func set_quench_intensity(intensity: float) -> void:
	if intensity > 0.0 and not _steam.emitting:
		_splash.restart()
		_splash.emitting = true
	_steam.material_override.albedo_color.a = clampf(intensity, 0.0, 1.0)
	_steam.emitting = intensity > 0.0


func _plume(node_name: String, center: Vector3, count: int, life: float,
		size: Vector2, speed: Vector2, extents: Vector3, colors: Array[Color]) -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.name = node_name
	particles.position = center
	particles.amount = count
	particles.lifetime = life
	particles.fixed_fps = 30
	particles.direction = Vector3.UP
	particles.spread = 24.0
	particles.gravity = Vector3.ZERO
	particles.initial_velocity_min = speed.x
	particles.initial_velocity_max = speed.y
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = extents
	particles.scale_amount_min = size.x
	particles.scale_amount_max = size.y
	var ramp := Gradient.new()
	ramp.colors = PackedColorArray(colors)
	var offsets := PackedFloat32Array()
	for index in colors.size():
		offsets.append(float(index) / (colors.size() - 1))
	ramp.offsets = offsets
	particles.color_ramp = ramp
	particles.mesh = QuadMesh.new()
	particles.material_override = _particle_material()
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(particles)
	return particles


func _particle_material() -> StandardMaterial3D:
	var edge := Gradient.new()
	edge.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0)])
	edge.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CUBIC
	var texture := GradientTexture2D.new()
	texture.width = 48
	texture.height = 48
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.gradient = edge
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.billboard_keep_scale = true
	material.vertex_color_use_as_albedo = true
	return material


func _growth_curve() -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.3))
	curve.add_point(Vector2(1, 1))
	return curve

extends Node3D
## Desktop inspection only. Player forging will use tracked XR motion (#15).

const Session = preload("res://src/game/preview_session.gd")
var session := Session.new()
var _surface := MeshInstance3D.new()
var _wire := MeshInstance3D.new()
var _hammer := MeshInstance3D.new()
var _camera := Camera3D.new()
var _status := Label.new()
var _pause := Button.new()
var _presets := OptionButton.new()
var _environments := OptionButton.new()
var _faces: Array = []
var _yaw := 0.65
var _pitch := 0.55
var _distance := 0.32
var _capture_path := ""
var _smoke := false
var _before_strike := false
var _thermal_capture := false
var _quench_capture := false
var _completed := false


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--preview-capture="):
			_capture_path = argument.trim_prefix("--preview-capture=")
		_smoke = _smoke or argument == "--preview-smoke"
		_before_strike = _before_strike or argument == "--preview-before-strike"
		_thermal_capture = _thermal_capture or argument == "--preview-heat" or argument == "--preview-quench"
		_quench_capture = _quench_capture or argument == "--preview-quench"
	if _smoke or not _capture_path.is_empty():
		get_viewport().set_disable_input(true)
	if not session.initialize():
		_fail()
		return
	if "--preview-cold" in OS.get_cmdline_user_args():
		session.reset(float(session.config.temperature_presets_c[1]))
	if _thermal_capture:
		session.reset(float(session.config.temperature_presets_c[0 if _quench_capture else 1]))
		session.inspect_environment(2 if _quench_capture else 1)
	_build_stage()
	_build_ui()
	_cache_faces()
	_refresh()


func _process(delta: float) -> void:
	if session.billet == null:
		return
	if session.advance(session.config.step_s if _smoke else delta):
		_refresh()
	if not session.errors.is_empty():
		_fail()
		set_process(false)
	elif (session.finished or (_thermal_capture and session.elapsed >= session.environments.capture_duration_s) or (_before_strike and session.elapsed >= session.config.strike_interval_s - session.config.step_s * 2)) and not _completed and (_smoke or not _capture_path.is_empty()):
		_completed = true
		_finish_capture()


func _build_stage() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("111820")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("bacbdf")
	environment.environment.ambient_light_energy = 0.5
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment.glow_enabled = true
	add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -35, 0)
	light.light_color = Color("ccdfff")
	light.light_energy = 1.6
	light.shadow_enabled = true
	add_child(light)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-0.10, 0.15, 0.08)
	fill.light_color = Color("ffaa65")
	fill.light_energy = 0.12
	fill.omni_range = 0.6
	add_child(fill)
	_box(Vector3(0.14, 0.025, 0.22), Vector3(0, -0.0125, 0), Color("39434e"), 0.85)
	_box(Vector3(0.075, 0.08, 0.12), Vector3(0, -0.065, 0), Color("252e38"), 0.8)
	_box(Vector3(2, 0.01, 2), Vector3(0, -0.11, 0), Color("171e27"), 0.0)
	add_child(_surface)
	add_child(_wire)
	var metal := ShaderMaterial.new()
	metal.shader = preload("res://shaders/preview_metal.gdshader")
	_surface.material_override = metal
	var wire_material := StandardMaterial3D.new()
	wire_material.vertex_color_use_as_albedo = true
	wire_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_wire.material_override = wire_material
	_hammer.mesh = BoxMesh.new()
	_hammer.mesh.size = Vector3(session.config.hammer_radius_m * 2, 0.02, session.config.hammer_radius_m * 2)
	var hammer_material := StandardMaterial3D.new()
	hammer_material.albedo_color = Color("718497")
	hammer_material.metallic = 0.8
	_hammer.material_override = hammer_material
	add_child(_hammer)
	add_child(_camera)
	_camera.near = 0.005
	_camera.far = 10.0
	_camera.fov = 45.0
	_update_camera()


func _box(size: Vector3, location: Vector3, color: Color, metallic: float) -> void:
	var instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	instance.mesh = box
	instance.position = location
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = 0.65
	instance.material_override = material
	add_child(instance)


func _cache_faces() -> void:
	var boundary := {}
	for cell: Dictionary in session.billet.cells:
		for corners in [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4],
				[2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]:
			var face: Array = []
			for corner: int in corners:
				face.append(cell.nodes[corner])
			var key := face.duplicate()
			key.sort()
			if boundary.has(key):
				boundary.erase(key)
			else:
				boundary[key] = face
	_faces = boundary.values()


func _refresh() -> void:
	var nodes: Array = session.billet.nodes
	var triangles := SurfaceTool.new()
	triangles.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face: Array in _faces:
		for triangle in [[0, 1, 2], [0, 2, 3]]:
			var a: Vector3 = nodes[face[triangle[0]]].position
			var b: Vector3 = nodes[face[triangle[1]]].position
			var c: Vector3 = nodes[face[triangle[2]]].position
			var normal := (b - a).cross(c - a).normalized()
			for corner: int in triangle:
				var node: Dictionary = nodes[face[corner]]
				var rgb: PackedFloat64Array = session.materials.sample(node.material_id, "color", {"temperature": node.temperature})
				var emission: float = session.materials.sample(node.material_id, "emission_energy", {"temperature": node.temperature}) * session.config.emission_scale
				triangles.set_uv2(Vector2(emission, 0))
				triangles.set_normal(normal)
				triangles.set_color(Color(rgb[0], rgb[1], rgb[2]))
				triangles.add_vertex(node.position)
	_surface.mesh = triangles.commit()
	var lines := SurfaceTool.new()
	lines.begin(Mesh.PRIMITIVE_LINES)
	for link: Dictionary in session.billet.connections:
		lines.set_color(Color("ff3158") if link.broken else Color("322b22"))
		for index: int in [link.a, link.b]:
			lines.add_vertex(nodes[index].position + Vector3.UP * 0.00015)
	_wire.mesh = lines.commit()
	var phase: float = fmod(session.elapsed, session.config.strike_interval_s) / session.config.strike_interval_s
	_hammer.position = session.contact + Vector3.UP * (0.01 + session.config.hammer_lift_m * sin(phase * PI))
	if session.finished or session.thermal_inspection:
		_hammer.position = Vector3(-0.07, 0.08, -0.06)
	var summary: Dictionary = session.summary()
	_status.text = "%s\n\n%.0f °C mean · %.0f–%.0f °C range\n%d matter points  ·  %d strikes\n%d broken links (red)\nMean plastic strain: %.4f\nLast sim + heat step: %.1f ms\n\n%s" % [
		session.materials.get_material(session.config.material_id).raw_data.name,
		summary.temperature_mean, summary.temperature_min, summary.temperature_max, summary.nodes, session.strikes, summary.broken, summary.strain, session.step_ms,
		"Paused" if session.paused else ("Thermal inspection · " + session.boundary.id if session.thermal_inspection else ("Demo complete — replay or inspect" if session.finished else "Synthetic impacts · constant temperature"))]


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 24)
	canvas.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	margin.add_child(column)
	var title := Label.new()
	title.text = "BLACKSMITH / BILLET STUDY"
	title.add_theme_font_size_override("font_size", 26)
	column.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "EARLY MECHANICS PREVIEW · DESKTOP"
	subtitle.modulate = Color("a6b8ca")
	column.add_child(subtitle)
	column.add_child(_status)
	for value: float in session.config.temperature_presets_c:
		_presets.add_item("%.0f °C · %s" % [value, "hot" if value > 20 else "cold"])
	_presets.select(1 if session.temperature == session.config.temperature_presets_c[1] else 0)
	_presets.item_selected.connect(func(index: int): _restart(float(session.config.temperature_presets_c[index])))
	column.add_child(_presets)
	var replay := Button.new()
	replay.text = "Replay synthetic strikes"
	replay.pressed.connect(func(): _restart(session.temperature))
	column.add_child(replay)
	_pause.text = "Pause"
	_pause.pressed.connect(func():
		session.paused = not session.paused
		_pause.text = "Resume" if session.paused else "Pause"
		_refresh())
	column.add_child(_pause)
	_environments.add_item("Thermal inspection: choose environment")
	_environments.set_item_disabled(0, true)
	for environment: Dictionary in session.environments.environments:
		_environments.add_item(environment.name)
		if session.thermal_inspection and environment.id == session.boundary.id:
			_environments.select(_environments.item_count - 1)
	_environments.item_selected.connect(func(index: int):
		if index > 0:
			session.inspect_environment(index - 1)
			_pause.text = "Pause"
			_refresh())
	column.add_child(_environments)
	var note := Label.new()
	note.text = "Right-drag: orbit · Wheel: zoom\n\nThermal inspection stops synthetic strikes.\nChange environment to heat/cool/quench.\nReplay returns to constant-temperature hits.\nProvisional fantasy data / fixed heat areas\nNo purification, folding or VR input yet.\nRed links show failure; mesh does not split."
	note.add_theme_font_size_override("font_size", 14)
	note.modulate = Color("a6b8ca")
	column.add_child(note)


func _restart(temperature: float) -> void:
	if not session.reset(temperature):
		_fail()
		return
	_pause.text = "Pause"
	_environments.select(0)
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_yaw -= event.relative.x * 0.008
		_pitch = clampf(_pitch + event.relative.y * 0.008, 0.1, 1.4)
		_update_camera()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(0.16, _distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(0.8, _distance * 1.1)
		_update_camera()


func _update_camera() -> void:
	var target := Vector3(0, 0.01, 0)
	_camera.position = target + Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _distance
	_camera.look_at(target)
	# Leave space for the inspection panel without moving simulation geometry.
	_camera.h_offset = -0.035


func _fail() -> void:
	push_error("Preview failed: " + str(session.errors))
	if _smoke or not _capture_path.is_empty():
		get_tree().quit(1)


func _finish_capture() -> void:
	# Close a popup if a desktop click arrived while the automated capture ran.
	_presets.get_popup().hide()
	var result: Dictionary = session.summary()
	if _before_strike and (session.strikes != 0 or result.broken != 0 or result.strain != 0):
		session.errors.append("Unstruck billet must have no damage or plastic strain.")
		_fail()
		return
	if _thermal_capture:
		var correct: bool = result.temperature_mean < session.temperature if _quench_capture else result.temperature_mean > session.temperature
		if not correct or (not _quench_capture and result.temperature_max > session.boundary.maximum_temperature_c):
			session.errors.append("Thermal preview failed to respond within equipment limits.")
			_fail()
			return
	if not _thermal_capture and not _before_strike and result.strain <= 0.0 and result.broken == 0:
		session.errors.append("Demo produced neither plastic deformation nor fracture.")
		_fail()
		return
	for node: Dictionary in session.billet.nodes:
		if not node.position.is_finite():
			session.errors.append("Nonfinite preview geometry.")
			_fail()
			return
	print("Preview complete: ", result)
	if not _capture_path.is_empty():
		await RenderingServer.frame_post_draw
		var error := get_viewport().get_texture().get_image().save_png(_capture_path)
		if error != OK:
			push_error("Cannot save preview capture: " + str(error))
			get_tree().quit(1)
			return
	get_tree().quit()

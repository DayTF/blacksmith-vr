extends Node3D
## Desktop inspection only. Player forging will use tracked XR motion (#15).

const ForgeAudio := preload("res://src/game/forge_audio.gd")
const Session = preload("res://src/game/preview_session.gd")
const LayeredSession = preload("res://src/game/layered_preview_session.gd")
const RoundedSurface = preload("res://src/game/rounded_billet_surface.gd")
const Collection := preload("res://src/game/named_billet_collection.gd")
const FractureGeometry = preload("res://src/game/fracture_preview_geometry.gd")

@export var layered_replay := false
var _strike_audio: Node3D
var session: RefCounted = Session.new()
var _surface := MeshInstance3D.new()
var _wire := MeshInstance3D.new()
var _hammer := MeshInstance3D.new()
var _purification_sites := MultiMeshInstance3D.new()
var _fragments := MultiMeshInstance3D.new()
var _camera := Camera3D.new()
var _status := Label.new()
var _pause: Button
var _presets: OptionButton
var _environments: OptionButton
var _faces: Array = []
var _rounded_surface: RefCounted
var _rounding_radius := 0.0
var _show_wire := true
var _yaw := 0.65
var _pitch := 0.55
var _distance := 0.32
var _stage_floor_y := -0.11
var _capture_path := ""
var _smoke := false
var _before_strike := false
var _thermal_capture := false
var _quench_capture := false
var _verify_purification := false
var _completed := false
var _live_fragments: MultiMesh
var _collection_picker: OptionButton
var _collection_store: Collection
var _collection: Array[Collection.Entry] = []
var _collection_status: Label
var _viewing_collection := false
var _naming_smoke := false


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--preview-capture="):
			_capture_path = argument.trim_prefix("--preview-capture=")
		_naming_smoke = _naming_smoke or argument == "--preview-naming-smoke"
		_smoke = _smoke or argument == "--preview-smoke" or _naming_smoke
		_before_strike = _before_strike or argument == "--preview-before-strike"
		_thermal_capture = _thermal_capture or argument == "--preview-heat" or argument == "--preview-quench"
		_quench_capture = _quench_capture or argument == "--preview-quench"
		_verify_purification = _verify_purification or argument == "--preview-purification"
	if _smoke or not _capture_path.is_empty():
		get_viewport().set_disable_input(true)
	if layered_replay:
		session = LayeredSession.new()
	if not (session.initialize() if layered_replay else session.initialize(_requested_material())):
		_fail()
		return
	if "--preview-cold" in OS.get_cmdline_user_args():
		session.reset(float(session.config.temperature_presets_c[1]))
	if _thermal_capture:
		session.reset(float(session.config.temperature_presets_c[0 if _quench_capture else 1]))
		session.inspect_environment(2 if _quench_capture else 1)
	_build_stage()
	if not layered_replay:
		_build_strike_audio()
	_build_ui()
	_cache_faces()
	_refresh()


func _requested_material() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--preview-material="):
			return argument.trim_prefix("--preview-material=")
	return ""


func _process(delta: float) -> void:
	if session.billet == null or _viewing_collection:
		return
	var strikes_before: int = session.strikes
	if session.advance(session.config.step_s if _smoke else delta):
		if _strike_audio != null and session.strikes > strikes_before:
			_strike_audio.play_strike(session.billet, session.contact)
		_refresh()
		if _naming_smoke and session.strikes > 0:
			_finish_naming_smoke()
			return
	if not session.errors.is_empty():
		_fail()
		set_process(false)
	elif (session.finished or (_thermal_capture and session.elapsed >= session.environments.capture_duration_s) or (_before_strike and session.elapsed >= session.config.strike_interval_s - session.config.step_s * 2)) and not _completed and (_smoke or not _capture_path.is_empty()):
		_completed = true
		_finish_capture()


func _build_strike_audio() -> void:
	_strike_audio = ForgeAudio.new()
	add_child(_strike_audio)


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
	var support_height := -0.03 - _stage_floor_y
	_box(Vector3(0.075, support_height, 0.12), Vector3(0, -0.025 - support_height * 0.5, 0), Color("252e38"), 0.8)
	_box(Vector3(2, 0.01, 2), Vector3(0, _stage_floor_y, 0), Color("171e27"), 0.0)
	_build_visuals()


func _build_visuals() -> void:
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
	var marker := SphereMesh.new()
	marker.radius = session.config.purification_marker_radius_m
	marker.height = marker.radius * 2
	marker.radial_segments = 8
	marker.rings = 4
	var marker_material := StandardMaterial3D.new()
	var rgba: Array = session.config.purification_marker_color
	marker_material.albedo_color = Color(rgba[0], rgba[1], rgba[2], rgba[3])
	marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.material = marker_material
	_purification_sites.multimesh = MultiMesh.new()
	_purification_sites.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_purification_sites.multimesh.mesh = marker
	_purification_sites.multimesh.instance_count = session.billet.nodes.size()
	_purification_sites.multimesh.visible_instance_count = 0
	add_child(_purification_sites)
	var fragment_mesh := SphereMesh.new()
	fragment_mesh.radius = session.config.spacing_m * 0.12
	fragment_mesh.height = fragment_mesh.radius * 2.0
	fragment_mesh.radial_segments = 8
	fragment_mesh.rings = 4
	var fragment_material := StandardMaterial3D.new()
	fragment_material.vertex_color_use_as_albedo = true
	fragment_material.metallic = 0.55
	fragment_mesh.material = fragment_material
	var fragment_instances := MultiMesh.new()
	fragment_instances.transform_format = MultiMesh.TRANSFORM_3D
	fragment_instances.use_colors = true
	fragment_instances.mesh = fragment_mesh
	fragment_instances.instance_count = session.billet.nodes.size()
	fragment_instances.visible_instance_count = 0
	_live_fragments = fragment_instances
	_fragments.multimesh = _live_fragments
	add_child(_fragments)
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
	if _rounding_radius > 0.0:
		_rounded_surface = RoundedSurface.new(session.billet.nodes, _rounding_radius)


func _refresh(update_controls: bool = true) -> int:
	var nodes: Array = session.billet.nodes
	var links: Array[Dictionary] = session.billet.connections
	var severed := FractureGeometry.broken_pairs(links)
	var colors := PackedColorArray()
	var emissions := PackedFloat32Array()
	var temperatures := {}
	for node: Dictionary in nodes:
		var key := [node.material_id, node.temperature]
		if not temperatures.has(key):
			var state := {"temperature": node.temperature}
			var rgb: PackedFloat64Array = session.materials.sample(node.material_id, "color", state)
			var energy: float = session.materials.sample(node.material_id, "emission_energy", state)
			temperatures[key] = [Color(rgb[0], rgb[1], rgb[2]), energy]
		var sample: Array = temperatures[key]
		var color: Color = sample[0]
		if layered_replay:
			var tint := Color("94baff") if node.layer_id == "leaf" else Color("ffc473")
			color = color.lerp(tint, 0.6)
		colors.append(color)
		emissions.append(sample[1] * session.config.emission_scale)
	var triangles := SurfaceTool.new()
	triangles.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vertex_count := 0
	for face: Array in _faces:
		for triangle: Array in FractureGeometry.visible_triangles(face, severed):
			if _rounded_surface != null:
				_rounded_surface.append(triangles, triangle, nodes, colors, emissions, vertex_count)
				vertex_count += RoundedSurface.WEIGHTS.size()
				continue
			var a: Vector3 = nodes[triangle[0]].position
			var b: Vector3 = nodes[triangle[1]].position
			var c: Vector3 = nodes[triangle[2]].position
			var normal := (b - a).cross(c - a).normalized()
			for id: int in triangle:
				triangles.set_uv2(Vector2(emissions[id], 0))
				triangles.set_normal(normal)
				triangles.set_color(colors[id])
				triangles.add_vertex(nodes[id].position)
	_surface.mesh = triangles.commit()
	var lines := SurfaceTool.new()
	lines.begin(Mesh.PRIMITIVE_LINES)
	lines.set_color(Color("322b22"))
	var bonded := PackedByteArray()
	bonded.resize(nodes.size())
	for link in links:
		if link.broken:
			continue
		for index: int in [link.a, link.b]:
			bonded[index] = 1
			if _show_wire:
				lines.add_vertex(nodes[index].position + Vector3.UP * 0.00015)
	_wire.mesh = lines.commit() if _show_wire else null
	var fragment_count := 0
	if not severed.is_empty():
		for index in nodes.size():
			if bonded[index]:
				continue
			var fragment: Dictionary = nodes[index]
			_fragments.multimesh.set_instance_transform(fragment_count, Transform3D(Basis.IDENTITY, fragment.position))
			_fragments.multimesh.set_instance_color(fragment_count, colors[index])
			fragment_count += 1
	_fragments.multimesh.visible_instance_count = fragment_count
	var marker_count := 0
	for index in nodes.size():
		var marked: bool = session.weld_marker_nodes.has(index) if layered_replay else session.purified_nodes[index] != 0
		if marked:
			_purification_sites.multimesh.set_instance_transform(marker_count, Transform3D(Basis.IDENTITY, nodes[index].position))
			marker_count += 1
	_purification_sites.multimesh.visible_instance_count = marker_count
	if not update_controls:
		return severed.size()
	if layered_replay:
		_hammer.position = session.contact + Vector3.UP * session.hammer_height()
		_status.text = "%s\n\n%d contacts under the hammer\n%d bonded patches\n\nGold · Mithril base\nBlue · Embersteel leaf\nMint · Bonded patch" % [
			"Paused" if session.paused else session.stage, session.contacting_patches, session.bonded_patches]
		return severed.size()
	var phase: float = fmod(session.elapsed, session.config.strike_interval_s) / session.config.strike_interval_s
	_hammer.position = session.contact + Vector3.UP * (0.01 + session.config.hammer_lift_m * sin(phase * PI))
	if session.finished or session.thermal_inspection:
		_hammer.position = Vector3(-0.07, 0.08, -0.06)
	var summary: Dictionary = session.summary()
	_status.text = "%s\n\n%.0f °C mean · %.0f–%.0f °C range\n%d matter points  ·  %d strikes\n%d severed links\nMean plastic strain: %.4f\nImpurities: %.3f mg · slag: %.3f µg\nPurified surface points: %d\nLast sim + processes: %.1f ms\n\n%s" % [
		session.materials.get_material(session.config.material_id).raw_data.name,
		summary.temperature_mean, summary.temperature_min, summary.temperature_max, summary.nodes, session.strikes, summary.broken, summary.strain,
		summary.impurity_mass_kg * 1e6, summary.discarded_mass_kg * 1e9, summary.purified_nodes, session.step_ms,
		"Paused" if session.paused else ("Thermal inspection · " + session.boundary.id if session.thermal_inspection else ("Demo complete — replay or inspect" if session.finished else "Synthetic impacts · constant temperature"))]

	return severed.size()


func _build_ui() -> void:
	_pause = Button.new()
	_presets = OptionButton.new()
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
	title.text = "BLACKSMITH / LAYERED WELD" if layered_replay else "BLACKSMITH / BILLET STUDY"
	title.add_theme_font_size_override("font_size", 26)
	column.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "SCRIPTED FORGE WELD COMPARISON" if layered_replay else "EARLY MECHANICS PREVIEW · DESKTOP"
	subtitle.modulate = Color("a6b8ca")
	column.add_child(subtitle)
	column.add_child(_status)
	if not layered_replay:
		var material_picker := OptionButton.new()
		var ids: PackedStringArray = session.materials.material_ids()
		for material_id in ids:
			material_picker.add_item(session.materials.get_material(material_id).display_name)
		material_picker.select(ids.find(session.config.material_id))
		material_picker.item_selected.connect(func(index: int):
			session.config.material_id = ids[index]
			_restart(session.temperature)
		)
		column.add_child(material_picker)
	for value: float in session.config.temperature_presets_c:
		if layered_replay:
			_presets.add_item("Hot weld" if value > 20 else "Cold comparison")
		else:
			_presets.add_item("%.0f °C · %s" % [value, "hot" if value > 20 else "cold"])
	_presets.select(1 if session.temperature == session.config.temperature_presets_c[1] else 0)
	_presets.item_selected.connect(func(index: int): _restart(float(session.config.temperature_presets_c[index])))
	column.add_child(_presets)
	var replay := Button.new()
	replay.text = "Replay fold and strike" if layered_replay else "Replay synthetic strikes"
	replay.pressed.connect(func(): _restart(session.temperature))
	column.add_child(replay)
	_pause.text = "Pause"
	_pause.pressed.connect(func():
		session.paused = not session.paused
		_pause.text = "Resume" if session.paused else "Pause"
		if not _viewing_collection:
			_refresh())
	column.add_child(_pause)
	var switch_preview := Button.new()
	switch_preview.text = "Back to billet study" if layered_replay else "Open layered weld replay"
	switch_preview.pressed.connect(func():
		var destination := "billet_preview" if layered_replay else "layered_preview"
		get_tree().change_scene_to_file("res://scenes/%s.tscn" % destination))
	column.add_child(switch_preview)
	if "--preview-naming" in OS.get_cmdline_user_args() or _naming_smoke:
		_build_collection_controls(column)
	if layered_replay:
		var controls := Label.new()
		controls.text = "Right-drag to orbit · Wheel to zoom"
		column.add_child(controls)
		return
	_environments = OptionButton.new()
	_environments.add_item("Synthetic strikes · keep billet")
	_environments.allow_reselect = true
	for environment: Dictionary in session.environments.environments:
		_environments.add_item(environment.name)
		if session.thermal_inspection and environment.id == session.boundary.id:
			_environments.select(_environments.item_count - 1)
	_environments.item_selected.connect(func(index: int):
		if index == 0:
			session.resume_forging()
		else:
			session.inspect_environment(index - 1)
		_pause.text = "Pause"
		if not _viewing_collection:
			_refresh())
	column.add_child(_environments)
	var sites := CheckButton.new()
	sites.text = "Show impurity release sites"
	sites.button_pressed = true
	sites.toggled.connect(func(visible_sites: bool): _purification_sites.visible = visible_sites)
	column.add_child(sites)
	var note := Label.new()
	note.text = "Right-drag: orbit · Wheel: zoom\n\nMode menu keeps the billet; Replay resets.\nFantasy tuning · Scripted desktop controls.\nCyan: impurity release sites\nOpen faces show severed lattice edges."
	note.add_theme_font_size_override("font_size", 14)
	note.modulate = Color("a6b8ca")
	column.add_child(note)


func _build_collection_controls(column: VBoxContainer) -> void:
	_collection_store = Collection.new()
	if _naming_smoke:
		var token := Crypto.new().generate_random_bytes(16).hex_encode()
		_collection_store.directory = OS.get_temp_dir().path_join("blacksmith-naming-" + token)
	_collection = _collection_store.load_entries()
	var row := HBoxContainer.new()
	column.add_child(row)
	var name_field := LineEdit.new()
	name_field.placeholder_text = "Billet name"
	name_field.custom_minimum_size.x = 160.0
	row.add_child(name_field)
	var keep := Button.new()
	keep.text = "Name and keep"
	keep.pressed.connect(func(): _keep_current(name_field.text))
	name_field.text_submitted.connect(_keep_current)
	row.add_child(keep)
	_collection_picker = OptionButton.new()
	_collection_picker.add_item("Current billet")
	for item in _collection:
		_collection_picker.add_item(item.assigned_name())
	_collection_picker.item_selected.connect(_display_collection)
	column.add_child(_collection_picker)
	_collection_status = Label.new()
	_collection_status.hide()
	column.add_child(_collection_status)
	if _collection_store.skipped_entries > 0:
		_show_collection_status("%d saved entries could not be opened." % _collection_store.skipped_entries)


func _show_collection_status(message: String) -> void:
	_collection_status.text = message
	_collection_status.visible = not message.is_empty()


func _keep_current(item_name: String) -> void:
	if _viewing_collection or (_surface.mesh == null and _fragments.multimesh.visible_instance_count == 0):
		return
	_show_collection_status("")
	var item: RefCounted = session.solidify(item_name, _save_named_billet)
	if item == null:
		return
	_collection_picker.add_item(item.assigned_name())
	_collection_picker.select(_collection.size())
	_display_collection(_collection.size())


func _save_named_billet(item: RefCounted) -> bool:
	var entry := Collection.Entry.new()
	entry.terminal_bytes = var_to_bytes(item.terminal_state())
	entry.mesh = _surface.mesh
	entry.fragments = _capture_fragments()
	var result := _collection_store.save(entry)
	if result != OK:
		_show_collection_status("Could not save billet. " + error_string(result))
		return false
	_collection.append(entry)
	return true


func _capture_fragments() -> MultiMesh:
	var snapshot := MultiMesh.new()
	snapshot.transform_format = MultiMesh.TRANSFORM_3D
	snapshot.use_colors = true
	snapshot.mesh = _live_fragments.mesh
	snapshot.instance_count = _live_fragments.visible_instance_count
	for index in snapshot.instance_count:
		snapshot.set_instance_transform(index, _live_fragments.get_instance_transform(index))
		snapshot.set_instance_color(index, _live_fragments.get_instance_color(index))
	return snapshot


func _display_collection(index: int) -> void:
	_viewing_collection = index > 0
	_hammer.visible = not _viewing_collection
	if not _viewing_collection:
		_fragments.multimesh = _live_fragments
		_refresh()
		return
	var saved := _collection[index - 1]
	_surface.mesh = saved.mesh
	_fragments.multimesh = saved.fragments
	_wire.mesh = null
	_purification_sites.multimesh.visible_instance_count = 0
	_status.text = "%s · static collection item" % saved.assigned_name()


func _finish_naming_smoke() -> void:
	_keep_current("Inspection billet")
	if _collection.size() != 1:
		push_error("Naming did not store the billet.")
		get_tree().quit(1)
		return
	var saved := _collection[0]
	var before := saved.terminal_state()
	var edited_copy := saved.terminal_state()
	edited_copy.nodes[0].temperature = -99.0
	var frozen_step: int = session.billet.step_id
	session.resume_forging()
	session.inspect_environment(1)
	if session.advance(session.config.step_s) or session.billet.step_id != frozen_step:
		push_error("The named billet continued stepping.")
		get_tree().quit(1)
		return
	_restart(float(session.config.temperature_presets_c[1]))
	_collection = _collection_store.load_entries()
	var folder := DirAccess.open(_collection_store.directory)
	for filename in folder.get_files():
		folder.remove(filename)
	DirAccess.remove_absolute(_collection_store.directory)
	if _collection.size() != 1:
		push_error("The saved billet could not be reloaded.")
		get_tree().quit(1)
		return
	var restored := _collection[0]
	_collection_picker.select(1)
	_display_collection(1)
	if not _viewing_collection or restored.mesh != _surface.mesh or before != restored.terminal_state() \
			or saved.fragments.instance_count != restored.fragments.instance_count \
			or saved.fragments.buffer != restored.fragments.buffer \
			or not _same_static_mesh(saved.mesh, restored.mesh):
		push_error("Reload changed the terminal state or static geometry.")
		get_tree().quit(1)
		return
	print("Named billet ready: ", restored.assigned_name())
	if not _capture_path.is_empty():
		await RenderingServer.frame_post_draw
		var result := get_viewport().get_texture().get_image().save_png(_capture_path)
		await get_tree().create_timer(0.55).timeout
		get_tree().quit(result)
	else:
		get_tree().quit()


func _same_static_mesh(before: Mesh, after: Mesh) -> bool:
	if before == null or after == null:
		return before == after
	if before.get_surface_count() != after.get_surface_count():
		return false
	for index in before.get_surface_count():
		if before.surface_get_arrays(index) != after.surface_get_arrays(index):
			return false
	return true

func _restart(temperature: float) -> void:
	if not session.reset(temperature):
		_fail()
		return
	_pause.text = "Pause"
	if _environments != null:
		_environments.select(0)
	if _collection_picker != null:
		_collection_picker.select(0)
		_display_collection(0)
	else:
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
	if layered_replay:
		var hot: bool = session.temperature == session.config.temperature_presets_c[0]
		if session.contacting_patches == 0 or (session.bonded_patches > 0) != hot:
			session.errors.append("Layered replay failed to distinguish the hot and cold interfaces.")
			_fail()
			return
		print("Layered replay complete: %d contacting, %d bonded" % [session.contacting_patches, session.bonded_patches])
	if _before_strike and (session.strikes != 0 or result.broken != 0 or result.strain != 0):
		session.errors.append("Unstruck billet must have no damage or plastic strain.")
		_fail()
		return
	if (_before_strike or _thermal_capture) and result.discarded_mass_kg != 0.0:
		session.errors.append("Heat or an unstruck billet cannot forge away impurities.")
		_fail()
		return
	if _verify_purification and (result.discarded_mass_kg <= 0.0 or result.purified_nodes == 0):
		session.errors.append("The hot fixture must expel impurities from spreading surface matter.")
		_fail()
		return
	if _thermal_capture:
		var correct: bool = result.temperature_mean < session.temperature if _quench_capture else result.temperature_mean > session.temperature
		if not correct or (not _quench_capture and result.temperature_max > session.boundary.maximum_temperature_c):
			session.errors.append("Thermal preview failed to respond within equipment limits.")
			_fail()
			return
	if not layered_replay and not _thermal_capture and not _before_strike and result.strain <= 0.0 and result.broken == 0:
		session.errors.append("Demo produced neither plastic deformation nor fracture.")
		_fail()
		return
	for node: Dictionary in session.billet.nodes:
		if not node.position.is_finite():
			session.errors.append("Nonfinite preview geometry.")
			_fail()
			return
	print("Preview material: ", session.config.material_id)
	print("Preview complete: ", result)
	if not _capture_path.is_empty():
		await RenderingServer.frame_post_draw
		var error := get_viewport().get_texture().get_image().save_png(_capture_path)
		if error != OK:
			push_error("Cannot save preview capture: " + str(error))
			get_tree().quit(1)
			return
	get_tree().quit()

extends "res://src/game/billet_preview.gd"

const IndexRay := preload("res://src/vr/index_pickup_ray.gd")
const WorldTools = preload("res://src/vr/world_tool_grip.gd")
const Teleport = preload("res://src/vr/forge_teleport.gd")
const ThermalContacts := preload("res://src/game/forge_thermal_contacts.gd")
const Room = preload("res://scenes/forge_room_study.tscn")
const NativeBillet = preload("res://src/sim/native_granular_billet.gd")
const BilletGrab = preload("res://src/sim/billet_grab.gd")
const TrackedHammer = preload("res://src/sim/tracked_hammer.gd")
const HammerTracking = preload("res://src/vr/hammer_tracking.gd")

var _room: Node3D
var _thermal_contacts: RefCounted
var _boundaries := {}
var _tracking: XROrigin3D
var _sweep := TrackedHammer.new()
var _grab := BilletGrab.new()
var _grab_armed := false
var _grab_source := ""
var _xr: XRInterface
var _settings: Dictionary
var _face_offset: Vector3
var _tools := WorldTools.new()
var _left_tools := WorldTools.new()
var _pickup_beams: Array[MeshInstance3D] = []
var _point_targets := PackedInt32Array([-1, -1])
var _point_age := PackedFloat64Array([INF, INF])
var _aiming := false
var _teleport_target: Variant
var _landing := MeshInstance3D.new()
var _frame_report := 0.0


func _ready() -> void:
	_settings = JSON.parse_string(FileAccess.get_file_as_string("res://data/preview/tracked_hammer.json"))
	var offset: Array = _settings.grip_to_face_m
	_face_offset = Vector3(offset[0], offset[1], offset[2])
	var native: bool = ProjectSettings.get_setting("blacksmith_preview/native_solver", false)
	if native and not ClassDB.class_exists("BlacksmithNativeCore"):
		_setup_failed("The native mechanics library is unavailable in this staged preview.")
		return
	if not session.initialize(_requested_material()):
		_fail()
		set_process(false)
		return
	session.config.dimensions = _settings.dimensions
	if native:
		session.billet_backend = NativeBillet
		session.config.dimensions = _settings.native_dimensions
		session.config.spacing_m = _settings.native_spacing_m
		var d: Array = session.config.dimensions
		var spacing: float = session.config.spacing_m
		session.config.origin_m = [-0.5 * (d[0] - 1) * spacing, 0.0, -0.03 - 0.5 * (d[2] - 1) * spacing]
	if not session.reset(session.temperature):
		_fail()
		set_process(false)
		return
	session.billet.tuning.hammer_impulse_transfer = _settings.hammer_impulse_transfer
	session.billet.tuning.anvil_friction_coefficient = _settings.anvil_friction_coefficient
	session.billet.tuning.maximum_density_multiplier = _settings.maximum_density_multiplier
	_rounding_radius = _settings.render_corner_radius_m
	session.config.emission_scale = _settings.render_emission_scale
	_show_wire = "--show-billet-lattice" in OS.get_cmdline_user_args()
	_build_room()
	_thermal_contacts = ThermalContacts.new(JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/surface.json")))
	for boundary: Dictionary in session.environments.environments:
		_boundaries[boundary.id] = boundary
	_boundaries["anvil"] = session.environments.anvil_contact
	_build_strike_audio()
	_add_hammer_handle()
	_build_tools()
	_build_landing_marker()
	_cache_faces()
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_status.position = Vector2(28, 24)
	canvas.add_child(_status)
	_refresh(false)
	_update_tools(0.0, {}, {})
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--tracked-bath-capture="):
			_run_bath_smoke(argument.trim_prefix("--tracked-bath-capture="))
			return
	if DisplayServer.get_name() == "headless":
		if "--tracked-bath-smoke" in OS.get_cmdline_user_args():
			_run_bath_smoke()
		elif "--tracked-preview-smoke" in OS.get_cmdline_user_args():
			if session.strikes != 0 or _tools.held >= 0 or _tools.tools.size() != 2 or not session.billet.step(session.config.step_s):
				_setup_failed("Tracked fixture failed its initial mechanics step.")
				return
			print("Tracked preview ready: ", session.billet.nodes.size(), " points, ",
				"native" if native else "reference")
			print("Tracked material: ", session.billet.nodes[0].material_id)
			get_tree().quit()
		else:
			set_process(false)
		return
	_xr = XRServer.find_interface("OpenXR")
	if _xr == null or (not _xr.is_initialized() and not _xr.initialize()):
		_status.text = "OpenXR unavailable\nConnect the headset and start SteamVR, then relaunch."
		set_process(false)
		return
	_tracking = HammerTracking.new()
	_tracking.position = Vector3(0.0, Teleport.FLOOR, 2.5)
	add_child(_tracking)
	get_viewport().use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)


func _build_room() -> void:
	_room = Room.instantiate()
	_room.position = Vector3(0.0, Teleport.FLOOR, 0.18)
	var study_camera := _room.get_node("FrontView")
	_room.remove_child(study_camera)
	study_camera.free()
	add_child(_room)
	_build_visuals()


func _build_tools() -> void:
	var tongs := Node3D.new()
	add_child(tongs)
	var finish := StandardMaterial3D.new()
	finish.albedo_color = Color("354651")
	finish.metallic = 0.8
	for side in [-1.0, 1.0]:
		var arm := MeshInstance3D.new()
		var bar := BoxMesh.new()
		bar.size = Vector3(0.008, 0.012, 0.23)
		bar.material = finish
		arm.mesh = bar
		arm.position = Vector3(side * 0.018, 0, -0.045)
		arm.rotation.y = side * 0.08
		tongs.add_child(arm)
	_tools.tools = [
		{"name": "Hammer", "kind": "hammer", "pose": Transform3D(Basis.IDENTITY, Vector3(0.14, 0.045, 0.11)), "mesh": _hammer,
			"offset": _face_offset + Vector3.UP * 0.01, "aim_offset": _face_offset,
			"fall": 0.0, "clearance": 0.04},
		{"name": "Tongs", "kind": "tongs", "pose": Transform3D(Basis.IDENTITY, Vector3(-0.15, 0.014, 0.11)), "mesh": tongs,
			"offset": Vector3.ZERO, "aim_offset": Vector3.FORWARD * 0.045,
			"aim_radius": 0.115, "fall": 0.0, "clearance": 0.008},
	]

	_left_tools.tools = _tools.tools
	var shape := CylinderMesh.new()
	shape.height = 1.0
	shape.top_radius = 0.002
	shape.bottom_radius = 0.002
	var finish_beam := StandardMaterial3D.new()
	finish_beam.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	finish_beam.albedo_color = Color(1.0, 0.22, 0.12)
	shape.material = finish_beam
	for hand in 2:
		var beam := MeshInstance3D.new()
		beam.mesh = shape
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		beam.hide()
		add_child(beam)
		_pickup_beams.append(beam)


func _build_landing_marker() -> void:
	var disk := CylinderMesh.new()
	disk.top_radius = 0.12
	disk.bottom_radius = 0.12
	disk.height = 0.006
	var finish := StandardMaterial3D.new()
	finish.albedo_color = Color("7ee9dc")
	finish.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disk.material = finish
	_landing.mesh = disk
	_landing.hide()
	add_child(_landing)


func _update_tools(delta: float, right: Dictionary, left: Dictionary) -> void:
	_update_tool_hand(0, _tools, _left_tools.held, right, delta)
	_update_tool_hand(1, _left_tools, _tools.held, left, delta)
	for index in _tools.tools.size():
		var tool := _tools.tools[index]
		var pose: Transform3D = tool.pose
		if index == _tools.held or index == _left_tools.held:
			tool.fall = 0.0
		else:
			var above_anvil := absf(pose.origin.x) < 0.24 and absf(pose.origin.z) < 0.155
			var support: float = tool.clearance + (0.0 if above_anvil else Teleport.FLOOR)
			tool.fall += delta * 9.81
			pose.origin.y = maxf(support, pose.origin.y - tool.fall * delta)
			if pose.origin.y <= support:
				tool.fall = 0.0
			tool.pose = pose
		tool.mesh.transform = pose.translated_local(tool.offset)


func _update_tool_hand(hand: int, grip: RefCounted, unavailable: int, sample: Dictionary, delta: float) -> void:
	var beam := _pickup_beams[hand]
	beam.hide()
	_point_age[hand] += delta
	if sample.is_empty():
		_point_targets[hand] = -1
	else:
		var stage_from_world := global_transform.affine_inverse()
		sample.pose = stage_from_world * sample.pose
		var aim: Dictionary = _tracking.pickup_ray(hand == 1)
		sample.trigger = aim.get("trigger", sample.pressure if sample.source == "hand" else 0.0)
		var committing: bool = sample.trigger >= _settings.grab_press and _point_age[hand] <= 0.12 and _point_targets[hand] >= 0
		if grip.held < 0 and aim.has("ray") and not committing:
			var ray: Transform3D = stage_from_world * aim.ray
			var hit := IndexRay.nearest(ray, _tools.tools, 5.0, unavailable)
			_point_targets[hand] = hit.target
			_point_age[hand] = 0.0
			var direction := -ray.basis.z.normalized()
			var distance: float = maxf(0.002, hit.distance)
			beam.transform = Transform3D(Basis(Quaternion(Vector3.UP, direction)).scaled_local(
				Vector3(1.0, distance, 1.0)), ray.origin + direction * distance * 0.5)
			beam.show()
		if _point_age[hand] <= 0.12:
			sample.remote_target = _point_targets[hand]
	if grip.update(sample, _settings.grab_reach_m, _settings.grab_press, _settings.grab_release, unavailable):
		_sweep.reset_tracking()
		_point_targets[hand] = -1
		if grip.held >= 0:
			beam.hide()


func _held_hammer() -> int:
	for index in [_tools.held, _left_tools.held]:
		if index >= 0 and _tools.tools[index].kind == "hammer":
			return index
	return -1

func _update_teleport() -> void:
	var sample: Dictionary = _tracking.aim()
	if sample.is_empty():
		_aiming = false
		_teleport_target = null
	elif sample.stick > (0.35 if _aiming else 0.65):
		_aiming = true
		_teleport_target = Teleport.target(global_transform.affine_inverse() * sample.pose)
	elif _aiming:
		_aiming = false
		var target: Variant = Teleport.target(global_transform.affine_inverse() * sample.pose)
		if _teleport_target is Vector3 and target is Vector3 and target.distance_to(_teleport_target) <= 0.10:
			_tracking.position += Teleport.room_shift(_teleport_target, to_local(_tracking.head_position()))
			_sweep.reset_tracking()
		_teleport_target = null
	_landing.visible = _teleport_target is Vector3
	if _landing.visible:
		_landing.position = _teleport_target + Vector3.UP * 0.007


func _setup_failed(message: String) -> void:
	push_error(message)
	if DisplayServer.get_name() == "headless":
		get_tree().quit(1)
	set_process(false)


func _add_hammer_handle() -> void:
	var handle := MeshInstance3D.new()
	var shaft := CylinderMesh.new()
	var grip := -_face_offset - Vector3.UP * 0.01
	shaft.height = grip.length()
	shaft.top_radius = 0.011
	shaft.bottom_radius = 0.011
	handle.mesh = shaft
	handle.position = grip * 0.5
	handle.quaternion = Quaternion(Vector3.UP, grip.normalized())
	var grip_material := StandardMaterial3D.new()
	grip_material.albedo_color = Color("4e3124")
	grip_material.roughness = 0.85
	handle.material_override = grip_material
	_hammer.add_child(handle)


func _process(delta: float) -> void:
	if _tracking == null:
		return
	_tracking.update_hands()
	_update_teleport()
	_update_grab()
	var tool_hand: Dictionary = _tracking.tool_hand(_settings.pinch_closed_m, _settings.pinch_open_m)
	var left: Dictionary = {} if _grab.held else _tracking.off_hand(_settings.pinch_closed_m, _settings.pinch_open_m)
	_update_tools(delta, tool_hand, left)
	var strike_landed := false
	var hammer := _held_hammer()
	if hammer >= 0 and not _grab.held:
		var pose: Transform3D = _tools.tools[hammer].pose
		var tip := pose * _face_offset
		if _sweep.apply(session.billet, tip, delta, session.config.hammer_radius_m,
				session.config.hammer_mass_kg, _settings.maximum_sample_gap_s, _settings.maximum_sample_travel_m):
			session.strikes += 1
			strike_landed = true
	else:
		_sweep.reset_tracking()
	var started := Time.get_ticks_usec()
	if not _grab.held:
		if not _step_released_billet() or not session.purification.apply(session.billet):
			session.errors.append_array(session.billet.errors)
			session.errors.append_array(session.purification.errors)
			_fail()
			set_process(false)
			return
		for event: Dictionary in session.purification.events:
			session.purified_nodes[event.node] = 1
	session.step_ms = float(Time.get_ticks_usec() - started) / 1000.0
	if strike_landed:
		_strike_audio.play_strike(session.billet, _sweep.last_contact)
	var severed := _refresh(false)
	_status.text = "%s\n%d hits · %d severed links · %.2f ms sim · %d host FPS\n%s" % [
		"Point and trigger, or grip a nearby tool" if _tools.held < 0 and _left_tools.held < 0 else "Tool held",
		session.strikes, severed, session.step_ms, Engine.get_frames_per_second(),
		"Billet held · release left grip to place" if _grab.held else "Left grip near billet to pick up"]
	_frame_report += delta
	if _frame_report >= 5.0:
		_frame_report = 0.0
		print("Tracked preview: ", _status.text.replace("\n", "  "))


func _support_height(point: Vector3) -> float:
	return _room.position.y + ThermalContacts.support_height(point - _room.position)


func _step_released_billet() -> bool:
	# The preview kernel has one flat support plane. Use the highest support
	# under the billet's footprint so a piece spanning an edge stays supported.
	var support: float = Teleport.FLOOR
	for point: Dictionary in session.billet.nodes:
		support = maxf(support, _support_height(point.position))
	session.billet.tuning.anvil_height_m = support
	return session.billet.step(session.config.step_s)


func _physics_process(delta: float) -> void:
	if _tracking == null:
		return
	if not _step_thermal(delta):
		_fail()
		set_process(false)
		set_physics_process(false)


func _step_thermal(delta: float) -> bool:
	var areas: Dictionary = _thermal_contacts.areas_by_station(session.billet, _room.transform.affine_inverse())
	if areas.is_empty():
		session.errors.append_array(_thermal_contacts.errors)
		return false
	var contacts: Array[Dictionary] = []
	for station: String in areas:
		var boundary: String = _room.quench_medium() if station == "bath" else station
		contacts.append({"areas": areas[station], "boundary": _boundaries[boundary]})
	if not session.step_thermal(contacts, delta):
		return false
	var wet_area := 0.0
	var cooling := 0.0
	for index in session.peak_cooling_rate_c_s.size():
		var area: float = areas.bath[index]
		wet_area += area
		cooling += area * maxf(0.0, -session.thermal.mean_temperature_rate_c_s[index])
	_room.set_quench_intensity(clampf(cooling / (wet_area * 340.0), 0.0, 1.0) if wet_area > 0.0 else 0.0)
	return true


func _run_bath_smoke(capture_path := "") -> void:
	var nodes: Array[Dictionary] = session.billet.nodes
	var grip := Transform3D(Basis.IDENTITY, nodes[0].position)
	var bath := ThermalContacts.BATH
	var submerged := bath.get_center()
	submerged.y = bath.end.y - 0.05
	grip.origin = _room.position + submerged
	var initial := Transform3D(Basis.IDENTITY, nodes[0].position)
	if not _grab.acquire(session.billet, initial, _settings.grab_reach_m, _support_height) \
			or not _grab.move(grip, _support_height) or not _step_thermal(session.config.step_s):
		_setup_failed("Tracked bath fixture could not cool a held billet.")
		return
	var held_temperature: float = session.summary().temperature_mean
	var held_height: float = nodes[0].position.y
	_grab.release()
	if not _step_released_billet() or session.billet.nodes[0].position.y >= held_height:
		_setup_failed("Released billet did not begin falling under gravity.")
		return
	for frame in 35:
		if not _step_released_billet() or not _step_thermal(session.config.step_s):
			_setup_failed("Tracked bath fixture could not settle: " + str(session.billet.errors) + str(session.errors))
			return
	var floor := _room.position.y + bath.position.y
	var lowest := INF
	for point: Dictionary in session.billet.nodes:
		lowest = minf(lowest, point.position.y)
	if absf(lowest - floor) > 0.001 or not held_temperature < session.temperature \
			or not session.summary().temperature_mean < held_temperature or session.peak_cooling_rate_c_s[0] <= 0.0:
		_setup_failed("Released billet failed to settle and cool at the bath floor.")
		return
	print("Tracked bath ready: ", _room.quench_medium(), " · ", lowest, " m")
	if not capture_path.is_empty():
		var camera := Camera3D.new()
		camera.position = _room.position + Vector3(0.60, 1.49, -0.51)
		add_child(camera)
		camera.look_at(_room.position + bath.get_center())
		camera.fov = 40.0
		camera.make_current()
		_status.hide()
		_refresh(false)
		for frame in 18:
			await RenderingServer.frame_post_draw
		var result := get_viewport().get_texture().get_image().save_png(capture_path)
		_room.queue_free()
		for frame in 4:
			await get_tree().process_frame
		get_tree().quit(result)
		return
	get_tree().quit()


func _update_grab() -> void:
	if _left_tools.held >= 0:
		_grab_armed = false
		return
	var sample: Dictionary = _tracking.off_hand(_settings.pinch_closed_m, _settings.pinch_open_m)
	var source: String = sample.get("source", "")
	if source != _grab_source:
		_grab.release()
		_sweep.reset_tracking()
		_grab_armed = false
		_grab_source = source
	if sample.is_empty():
		return
	var pressure: float = sample.pressure
	if pressure <= _settings.grab_release:
		if _grab.held:
			_grab.release()
			_sweep.reset_tracking()
		_grab_armed = true
		return
	var local_pose: Transform3D = global_transform.affine_inverse() * sample.pose
	if _grab.held:
		if not _grab.move(local_pose, _support_height):
			_grab.release()
			_sweep.reset_tracking()
	elif _grab_armed and pressure >= _settings.grab_press:
		_grab_armed = false
		if _grab.acquire(session.billet, local_pose, _settings.grab_reach_m, _support_height):
			_sweep.reset_tracking()


func _unhandled_input(_event: InputEvent) -> void:
	pass

extends "res://src/game/billet_preview.gd"

const WorldTools = preload("res://src/vr/world_tool_grip.gd")
const Teleport = preload("res://src/vr/forge_teleport.gd")
const Room = preload("res://scenes/forge_room_study.tscn")
const NativeBillet = preload("res://src/sim/native_granular_billet.gd")
const BilletGrab = preload("res://src/sim/billet_grab.gd")
const TrackedHammer = preload("res://src/sim/tracked_hammer.gd")
const HammerTracking = preload("res://src/vr/hammer_tracking.gd")

var _tracking: XROrigin3D
var _sweep := TrackedHammer.new()
var _grab := BilletGrab.new()
var _grab_armed := false
var _grab_source := ""
var _xr: XRInterface
var _settings: Dictionary
var _face_offset: Vector3
var _tools := WorldTools.new()
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
	if not session.initialize():
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
	_update_tools(0.0, {})
	if DisplayServer.get_name() == "headless":
		if "--tracked-preview-smoke" in OS.get_cmdline_user_args():
			if session.strikes != 0 or _tools.held >= 0 or _tools.tools.size() != 2 or not session.billet.step(session.config.step_s):
				_setup_failed("Tracked fixture failed its initial mechanics step.")
				return
			print("Tracked preview ready: ", session.billet.nodes.size(), " points, ",
				"native" if native else "reference")
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
	var room: Node3D = Room.instantiate()
	room.position = Vector3(0.0, Teleport.FLOOR, 0.18)
	var study_camera := room.get_node("FrontView")
	room.remove_child(study_camera)
	study_camera.free()
	add_child(room)
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
			"offset": _face_offset + Vector3.UP * 0.01, "fall": 0.0, "clearance": 0.04},
		{"name": "Tongs", "kind": "tongs", "pose": Transform3D(Basis.IDENTITY, Vector3(-0.15, 0.014, 0.11)), "mesh": tongs,
			"offset": Vector3.ZERO, "fall": 0.0, "clearance": 0.008},
	]


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


func _update_tools(delta: float, sample: Dictionary) -> void:
	if not sample.is_empty():
		sample.pose = global_transform.affine_inverse() * sample.pose
	if _tools.update(sample, _settings.grab_reach_m, _settings.grab_press, _settings.grab_release):
		_sweep.reset_tracking()
	for index in _tools.tools.size():
		var tool := _tools.tools[index]
		var pose: Transform3D = tool.pose
		if index == _tools.held:
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
	_update_tools(delta, tool_hand)
	var strike_landed := false
	if _tools.held >= 0 and _tools.tools[_tools.held].kind == "hammer" and not _grab.held:
		var pose: Transform3D = _tools.tools[_tools.held].pose
		var tip := pose * _face_offset
		if _sweep.apply(session.billet, tip, delta, session.config.hammer_radius_m,
				session.config.hammer_mass_kg, _settings.maximum_sample_gap_s, _settings.maximum_sample_travel_m):
			session.strikes += 1
			strike_landed = true
	else:
		_sweep.reset_tracking()
	var started := Time.get_ticks_usec()
	if not _grab.held:
		if not session.billet.step(session.config.step_s) or not session.purification.apply(session.billet):
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
		_tools.tools[_tools.held].name + " held" if _tools.held >= 0 else "Right grip near a tool to pick it up",
		session.strikes, severed, session.step_ms, Engine.get_frames_per_second(),
		"Billet held · release left grip to place" if _grab.held else "Left grip near billet to pick up"]
	_frame_report += delta
	if _frame_report >= 5.0:
		_frame_report = 0.0
		print("Tracked preview: ", _status.text.replace("\n", "  "))


func _update_grab() -> void:
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
		if not _grab.move(local_pose):
			_grab.release()
			_sweep.reset_tracking()
	elif _grab_armed and pressure >= _settings.grab_press:
		_grab_armed = false
		if _grab.acquire(session.billet, local_pose, _settings.grab_reach_m):
			_sweep.reset_tracking()


func _unhandled_input(_event: InputEvent) -> void:
	pass

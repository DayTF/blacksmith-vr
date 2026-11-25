extends "res://src/game/billet_preview.gd"

const TrackedHammer = preload("res://src/sim/tracked_hammer.gd")
const HammerTracking = preload("res://src/vr/hammer_tracking.gd")

var _tracking: XROrigin3D
var _sweep := TrackedHammer.new()
var _xr: XRInterface
var _settings: Dictionary
var _face_offset: Vector3
var _source := ""
var _frame_report := 0.0


func _ready() -> void:
	_settings = JSON.parse_string(FileAccess.get_file_as_string("res://data/preview/tracked_hammer.json"))
	var offset: Array = _settings.grip_to_face_m
	_face_offset = Vector3(offset[0], offset[1], offset[2])
	if not session.initialize():
		_fail()
		set_process(false)
		return
	session.config.dimensions = _settings.dimensions
	if not session.reset(session.temperature):
		_fail()
		set_process(false)
		return
	session.billet.tuning.hammer_impulse_transfer = _settings.hammer_impulse_transfer
	session.billet.tuning.anvil_friction_coefficient = _settings.anvil_friction_coefficient
	session.billet.tuning.maximum_density_multiplier = _settings.maximum_density_multiplier
	_stage_floor_y = -_settings.anvil_height_m
	_build_stage()
	_add_hammer_handle()
	_cache_faces()
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_status.position = Vector2(28, 24)
	canvas.add_child(_status)
	_refresh()
	_hammer.hide()
	if DisplayServer.get_name() == "headless":
		if "--tracked-preview-smoke" in OS.get_cmdline_user_args():
			get_tree().quit(int(session.strikes != 0))
		else:
			set_process(false)
		return
	_xr = XRServer.find_interface("OpenXR")
	if _xr == null or (not _xr.is_initialized() and not _xr.initialize()):
		_status.text = "OpenXR unavailable\nConnect the headset and start SteamVR, then relaunch."
		set_process(false)
		return
	_tracking = HammerTracking.new()
	_tracking.position = Vector3(0.0, -_settings.anvil_height_m, _settings.anvil_reach_m)
	add_child(_tracking)
	get_viewport().use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)


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
	var capture: Variant = _tracking.grip()
	if _source != _tracking.source:
		_sweep.reset_tracking()
		_source = _tracking.source
	_hammer.visible = capture is Transform3D
	if _hammer.visible:
		var grip: Transform3D = capture
		var tip := to_local(grip * _face_offset)
		_hammer.basis = grip.basis
		_hammer.position = tip + grip.basis.y * 0.01
		if _sweep.apply(session.billet, tip, delta, session.config.hammer_radius_m,
				session.config.hammer_mass_kg, _settings.maximum_sample_gap_s, _settings.maximum_sample_travel_m):
			session.strikes += 1
	else:
		_sweep.reset_tracking()
	var started := Time.get_ticks_usec()
	if not session.billet.step(session.config.step_s) or not session.purification.apply(session.billet):
		session.errors.append_array(session.billet.errors)
		session.errors.append_array(session.purification.errors)
		_fail()
		set_process(false)
		return
	for event: Dictionary in session.purification.events:
		session.purified_nodes[event.node] = 1
	session.step_ms = float(Time.get_ticks_usec() - started) / 1000.0
	var hammer_transform := _hammer.transform
	_refresh()
	_hammer.transform = hammer_transform
	_status.text = "%s\n%d hits · %d severed links · %.2f ms sim · %d host FPS" % [
		_source if not _source.is_empty() else "Waiting for right-hand tracking",
		session.strikes, session.summary().broken, session.step_ms, Engine.get_frames_per_second()]
	_frame_report += delta
	if _frame_report >= 5.0:
		_frame_report = 0.0
		print("Tracked preview: ", _status.text.replace("\n", "  "))


func _unhandled_input(_event: InputEvent) -> void:
	pass

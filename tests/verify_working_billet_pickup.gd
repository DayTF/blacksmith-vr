extends SceneTree

class AimFixture extends XROrigin3D:
	var aim: Transform3D
	var trigger := 0.0
	func pickup_ray(left: bool) -> Dictionary:
		return {} if left else {"ray": aim, "trigger": trigger}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var fixture := load("res://scenes/tracked_hammer_preview.tscn").instantiate() as Node3D
	root.add_child(fixture)
	fixture.set_process(false)
	fixture.set_physics_process(false)
	var tracking := AimFixture.new()
	fixture.add_child(tracking)
	fixture._tracking = tracking
	var proxy: Dictionary = fixture._tools.tools[fixture._billet_tool]
	var from := Vector3(0.0, 0.21, 0.39)
	tracking.aim = Transform3D(Basis.IDENTITY, from).looking_at(proxy.pose.origin)
	fixture._update_tools(0.011, _sample(from, 0.0), {})
	if fixture._point_targets[0] != fixture._billet_tool:
		_fail("Right-hand ray did not hit the working billet.")
		return
	tracking.trigger = 1.0
	fixture._update_tools(0.011, _sample(from, 0.0), {})
	if not fixture._grab.held or fixture._tools.held != fixture._billet_tool:
		_fail("Right trigger did not retrieve the working billet.")
		return
	var fire: Vector3 = fixture._room.position + Vector3(-0.48, 1.02, -2.23)
	fixture._update_tools(0.011, _sample(fire, 0.0), {})
	var before: float = fixture.session.summary().temperature_mean
	for frame in 30:
		if not fixture._step_thermal(1.0 / 90.0):
			_fail("Thermal solver rejected held billet.")
			return
	var after: float = fixture.session.summary().temperature_mean
	if after <= before:
		_fail("Moving the working billet into the forge did not heat it.")
		return
	tracking.trigger = 0.0
	fixture._update_tools(0.011, _sample(fire, 0.0), {})
	if fixture._grab.held:
		_fail("Working billet did not release.")
		return
	var near: Vector3 = fixture.session.billet.nodes[0].position + Vector3.UP * 0.06
	fixture._update_tools(0.011, {}, _sample(near, 0.0))
	fixture._update_tools(0.011, {}, _sample(near, 1.0))
	if not fixture._grab.held or fixture._left_tools.held != fixture._billet_tool:
		_fail("Left grip did not pick up the working billet.")
		return
	print("Working billet: right trigger pickup, forge heating %.2f -> %.2f C, release, left grip pickup." % [before, after])
	quit()


func _sample(point: Vector3, pressure: float) -> Dictionary:
	return {"pose": Transform3D(Basis.IDENTITY, point), "source": "controller", "pressure": pressure}


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

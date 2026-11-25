extends SceneTree

class AimFixture extends XROrigin3D:
	var ray: Transform3D
	var trigger := 0.0
	var pointing := true

	func pickup_ray(left: bool) -> Dictionary:
		if left:
			return {}
		return {"trigger": trigger, "ray": ray} if pointing else {"trigger": trigger}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := load("res://scenes/tracked_hammer_preview.tscn").instantiate() as Node3D
	root.add_child(fixture)
	var tracking := AimFixture.new()
	fixture.add_child(tracking)
	fixture._tracking = tracking
	var stock_index := -1
	for index in fixture._tools.tools.size():
		if fixture._tools.tools[index].kind == "hot_stock":
			stock_index = index
			break
	if stock_index < 0:
		_fail("The room did not register hearth stock.")
		return
	var stock: Dictionary = fixture._tools.tools[stock_index]
	var target: Vector3 = stock.pose.origin
	var room: Node3D = fixture._room
	var blocked := room.to_global(Vector3(-1.46, 1.00, -2.23))
	var clear := room.to_global(Vector3(-0.62, 1.05, -1.65))
	var inside := room.to_global(Vector3(-0.62, 0.55, -2.45))
	tracking.ray = Transform3D(Basis.IDENTITY, blocked).looking_at(target)
	fixture._update_tools(0.01, _sample(blocked), {})
	if fixture._point_targets[0] != -1:
		_fail("The side bricks did not occlude the hearth stock.")
		return
	tracking.ray = Transform3D(Basis.IDENTITY, clear).looking_at(target)
	fixture._update_tools(0.01, _sample(clear), {})
	if fixture._point_targets[0] != stock_index:
		_fail("The stock could not be aimed at through the forge opening.")
		return
	tracking.ray = Transform3D(Basis.IDENTITY, blocked).looking_at(target)
	tracking.trigger = 1.0
	fixture._update_tools(0.01, _sample(blocked), {})
	if fixture._tools.held >= 0:
		_fail("A blocked trigger frame acquired a previously visible prop.")
		return
	tracking.ray = Transform3D(Basis.IDENTITY, clear).looking_at(target)
	tracking.trigger = 0.0
	fixture._update_tools(0.01, _sample(clear), {})
	tracking.trigger = 1.0
	fixture._update_tools(0.01, _sample(inside), {})
	if fixture._tools.held >= 0 or not (stock.pose.origin as Vector3).is_equal_approx(target):
		_fail("An obstructed arrival pose acquired or moved stock.")
		return
	tracking.trigger = 0.0
	fixture._update_tools(0.01, _sample(clear), {})
	tracking.pointing = false
	tracking.trigger = 1.0
	fixture._update_tools(0.01, _sample(clear), {})
	if fixture._tools.held != stock_index:
		_fail("A clear cached pointing ray did not survive a trigger curl.")
		return
	tracking.trigger = 0.0
	fixture._update_tools(0.01, _sample(clear), {})
	var submerged := room.to_global(Vector3(1.39, 0.80, -1.34))
	stock.pose = Transform3D(Basis.IDENTITY, submerged)
	var above := submerged + Vector3.UP * 0.5
	tracking.pointing = true
	tracking.ray = Transform3D(Basis.IDENTITY, above).looking_at(submerged, Vector3.FORWARD)
	fixture._update_tools(0.01, _sample(above), {})
	if fixture._point_targets[0] != stock_index:
		_fail("The quench liquid surface hid submerged stock from an overhead ray.")
		return
	print("Pickup visibility verified at the forge opening, side bricks, and quench surface.")
	quit()


func _sample(point: Vector3) -> Dictionary:
	return {"pose": Transform3D(Basis.IDENTITY, point), "source": "controller", "pressure": 0.0}


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

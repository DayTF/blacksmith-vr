extends RefCounted

const Hammer = preload("res://src/sim/tracked_hammer.gd")

class RecordedBillet:
	extends RefCounted
	var nodes: Array[Dictionary] = [
		{"position": Vector3(0, 0.02, 0)}, {"position": Vector3(0, 0.01, 0)}]
	var hits: Array[Dictionary] = []

	func hammer(center: Vector3, normal: Vector3, _radius: float, _mass: float, velocity: Vector3) -> bool:
		hits.append({"center": center, "normal": normal, "velocity": velocity})
		return true


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var billet := RecordedBillet.new()
	var sweep := Hammer.new()
	_sample(sweep, billet, Vector3(0, 0.05, 0))
	_sample(sweep, billet, Vector3(0, 0.015, 0))
	_sample(sweep, billet, Vector3(0, 0, 0))
	_sample(sweep, billet, Vector3(0, 0.05, 0))
	if billet.hits.size() != 1:
		failures.append("Crossing the top registers one strike; continuing through the billet and lifting do not.")
	else:
		var hit: Dictionary = billet.hits[0]
		if not hit.center.is_equal_approx(Vector3(0, 0.02, 0)) or not hit.velocity.is_equal_approx(Vector3(0, -3.5, 0)):
			failures.append("Hammer uses swept contact and tracked tip displacement per second.")
		if not sweep.last_contact.is_equal_approx(hit.center):
			failures.append("Impact feedback uses the most recent accepted swept contact.")
	sweep.reset_tracking()
	_sample(sweep, billet, Vector3(0, 0, 0))
	_sample(sweep, billet, Vector3(0.3, 0.05, 0))
	_sample(sweep, billet, Vector3(0.3, 0, 0))
	sweep.reset_tracking()
	_sample(sweep, billet, Vector3(0, 0.05, 0))
	sweep.apply(billet, Vector3.ZERO, 0.5, 0.025, 0.5, 0.1, 0.25)
	if billet.hits.size() != 1:
		failures.append("First sample, missed face, and tracking gaps do not create strikes.")
	return failures


func _sample(sweep: RefCounted, billet: RefCounted, point: Vector3) -> void:
	sweep.apply(billet, point, 0.01, 0.025, 0.5, 0.1, 0.25)

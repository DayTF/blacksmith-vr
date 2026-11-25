extends RefCounted

const Motion := preload("res://src/game/forge_solid_motion.gd")
const TONGS := AABB(Vector3(-0.03, -0.006, -0.16), Vector3(0.06, 0.012, 0.23))


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var hand := Transform3D(Basis.IDENTITY, Vector3(-0.48, 1.05, -1.65))
	var placed := Transform3D(Basis.IDENTITY, Vector3(-0.48, 1.05, -2.4))
	if not Motion.constrain(TONGS, hand, placed).is_equal_approx(placed):
		failures.append("Tongs could not enter through the forge opening.")
	var lowered := placed.translated(Vector3.DOWN * 0.8)
	var floor := Motion.constrain(TONGS, placed, lowered)
	if absf(floor.origin.y - 0.8912) > 0.001:
		failures.append("Tongs tunneled through the hearth floor.")
	var hood := Motion.constrain(TONGS, placed, placed.translated(Vector3.UP * 0.9))
	if absf(hood.origin.y - 1.4438) > 0.001:
		failures.append("Tongs tunneled through the hood.")
	var rear := Motion.constrain(TONGS, placed, placed.translated(Vector3.FORWARD * 2.0))
	if absf(rear.origin.z - (-2.6248)) > 0.001:
		failures.append("Tongs tunneled through the rear lining.")
	var side := Motion.constrain(TONGS, placed, placed.translated(Vector3.RIGHT * 2.0))
	if absf(side.origin.x - (-0.1152)) > 0.001:
		failures.append("Tongs tunneled through the side brick.")
	if not Motion.constrain(TONGS, placed, hand, true).is_equal_approx(hand):
		failures.append("Remote retrieval could not place tongs into a clear hand.")
	return failures

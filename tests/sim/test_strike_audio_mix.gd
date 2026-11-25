extends RefCounted

const ForgeAudio := preload("res://src/game/forge_audio.gd")
const PreviewSession := preload("res://src/game/preview_session.gd")


func run() -> PackedStringArray:
	var failures := PackedStringArray()
	var session := PreviewSession.new()
	if not session.initialize():
		return session.errors
	var mixes := PackedFloat64Array()
	for temperature in [20.0, 1000.0]:
		if not session.reset(temperature):
			return session.errors
		var billet := session.billet
		if not billet.hammer(Vector3(0, 0.03, 0), Vector3.UP, 0.023, 0.5, Vector3.DOWN * 0.04):
			return PackedStringArray(["The audio test strike missed its billet."])
		if not billet.step(session.config.step_s):
			return billet.errors
		mixes.append(ForgeAudio.plastic_mix(billet))
	if not (0.0 <= mixes[0] and mixes[0] < mixes[1] and mixes[1] <= 1.0):
		failures.append("The same impact shifts the audio mix toward the thunk in the hotter fixture.")
	return failures

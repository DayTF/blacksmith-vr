extends SceneTree
## Measure interval-average compression in the deterministic tracked hammer replay.

const ResistanceReplay := preload("res://tests/sim/test_tracked_hammer_resistance.gd")


func _initialize() -> void:
	var tracked: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/preview/tracked_hammer.json"))
	var research: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/research/aisi_1045_sources.json"))
	var bounds: Dictionary = research.hot_compression_reference.input_bounds
	var replay := ResistanceReplay.new()
	for speed in [0.5, 1.5]:
		var result := replay.replay(tracked, speed, true)
		if result.is_empty() or result.compression.is_empty():
			push_error("The deterministic tracked replay returned no compression samples.")
			quit(1)
			return
		var report := _report(result.compression, bounds)
		report["hammer_speed_m_s"] = speed
		print(JSON.stringify(report))
	quit()


func _report(samples: Array[Dictionary], bounds: Dictionary) -> Dictionary:
	var peak_rate := 0.0
	var peak_strain := 0.0
	var in_domain := 0
	for sample in samples:
		peak_rate = maxf(peak_rate, sample.strain_rate_per_s)
		peak_strain = maxf(peak_strain, sample.true_strain)
		var valid := true
		for axis: String in bounds:
			var range_for_axis: Array = bounds[axis]
			var value: float = sample[axis]
			valid = valid and value >= float(range_for_axis[0]) and value <= float(range_for_axis[1])
		in_domain += int(valid)
	return {"compressive_intervals": samples.size(), "maximum_true_strain": peak_strain,
		"maximum_mean_compression_rate_per_s": peak_rate, "intervals_in_1045_domain": in_domain}

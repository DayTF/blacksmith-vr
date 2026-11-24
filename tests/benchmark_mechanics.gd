extends SceneTree
const Billet = preload("res://src/sim/granular_billet.gd")
const Native = preload("res://src/sim/native_granular_billet.gd")
const Library = preload("res://src/sim/material_library.gd")
func _initialize() -> void:
	var materials = Library.new()
	if not materials.load_directory("res://data/materials"):
		push_error(str(materials.errors))
		quit(1)
		return
	var tuning: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/mechanics.json"))
	tuning.gravity_m_s2 = [0, 0, 0]
	var config: Dictionary = tuning.benchmark
	var backend := "reference"
	var profiling := false
	for argument in OS.get_cmdline_user_args():
		if argument == "--profile":
			profiling = true
		if argument.begins_with("--backend="):
			backend = argument.trim_prefix("--backend=")
	if backend not in ["reference", "native-resident", "native-compatibility"]:
		push_error("Unknown benchmark backend: " + backend)
		quit(1)
		return
	var dimensions := Vector3i(config.dimensions[0], config.dimensions[1], config.dimensions[2])
	var origin := Vector3(config.origin_m[0], config.origin_m[1], config.origin_m[2])
	var billet: RefCounted = Billet.new(materials, tuning) if backend == "reference" else Native.new(materials, tuning)
	if backend != "reference":
		billet.enable_profiling(profiling)
	if not billet.build_grid(dimensions, config.spacing_m, origin, config.material_id, config.temperature_c):
		push_error(str(billet.errors))
		quit(1)
		return
	for node: Dictionary in billet.nodes:
		node.position.y = origin.y + (node.position.y - origin.y) * config.compression_ratio
	if backend == "native-resident" and not billet.commit_state():
		push_error(str(billet.errors))
		quit(1)
		return
	for index in int(config.warmup_steps):
		if not billet.step(config.dt_s):
			push_error(str(billet.errors))
			quit(1)
			return
	var timings := PackedFloat64Array()
	var kernel_timings := PackedFloat64Array()
	var profiles: Array[Dictionary] = []
	for index in int(config.samples):
		var start := Time.get_ticks_usec()
		var success: bool = billet.step(config.dt_s)
		timings.append(float(Time.get_ticks_usec() - start) / 1000.0)
		if backend != "reference":
			kernel_timings.append(billet.kernel_elapsed_usec() / 1000.0)
			if profiling:
				profiles.append(billet.profile_snapshot())
		if not success:
			push_error(str(billet.errors))
			quit(1)
			return
	var ordered := timings.duplicate()
	ordered.sort()
	var broken := 0
	var active := 0
	var finite := true
	for link: Dictionary in billet.connections:
		broken += int(link.broken)
	for cell: Dictionary in billet.cells:
		active += int(cell.active)
	for node: Dictionary in billet.nodes:
		finite = finite and node.position.is_finite() and node.velocity.is_finite()
	print(JSON.stringify({"backend": backend, "profiling_enabled": profiling, "profiles_usec": profiles, "kernel_samples_ms": Array(kernel_timings), "nodes": billet.nodes.size(), "connections": billet.connections.size(),
		"volume_cells": billet.cells.size(), "substeps": tuning.substeps, "iterations": tuning.iterations,
		"warmup_steps": config.warmup_steps, "samples_ms": Array(timings), "median_ms": ordered[ordered.size() / 2],
		"target_ms": 1.0, "broken_links": broken, "active_cells": active, "finite_state": finite}))
	quit(0)

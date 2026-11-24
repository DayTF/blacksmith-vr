extends SceneTree
## Headless suite runner: godot --headless --script tests/run_all.gd
## Suites live in tests/sim/**/test_*.gd, extend RefCounted, and expose
## run() -> PackedStringArray containing failure messages (empty means success).


func _initialize() -> void:
	var suite_paths: Array[String] = []
	if _collect_suites("res://tests/sim", suite_paths) != OK:
		quit(1)
		return
	suite_paths.sort()
	if suite_paths.is_empty():
		print("No simulation suites yet: M0 infrastructure bootstrap only.")
		quit(0)
		return

	var failures := 0
	for path in suite_paths:
		failures += _run_suite(path)
	print("Suites: %d; failures: %d" % [suite_paths.size(), failures])
	quit(1 if failures > 0 else 0)


func _collect_suites(directory_path: String, paths: Array[String]) -> Error:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		push_error("Cannot discover test suites in %s" % directory_path)
		return ERR_CANT_OPEN
	for filename in directory.get_files():
		if filename.begins_with("test_") and filename.ends_with(".gd"):
			paths.append(directory_path.path_join(filename))
	for child in directory.get_directories():
		if not child.begins_with("."):
			var error := _collect_suites(directory_path.path_join(child), paths)
			if error != OK:
				return error
	return OK


func _run_suite(path: String) -> int:
	var script := load(path) as GDScript
	if script == null or not script.can_instantiate():
		push_error("Cannot compile test suite: %s" % path)
		return 1
	var suite: Variant = script.new()
	if not suite is RefCounted or not suite.has_method("run"):
		push_error("Suite must extend RefCounted and expose run(): %s" % path)
		return 1
	var result: Variant = suite.call("run")
	if not result is PackedStringArray:
		push_error("Suite run() must return PackedStringArray: %s" % path)
		return 1
	for message in result:
		push_error("%s: %s" % [path, message])
	if result.is_empty():
		print("PASS %s" % path)
	return result.size()

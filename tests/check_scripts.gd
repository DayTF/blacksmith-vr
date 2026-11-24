extends SceneTree
## Editor import registers scripts but does not necessarily compile every body.


func _initialize() -> void:
	var paths: Array[String] = []
	if not _discover("res://src", paths) or not _discover("res://tests", paths):
		quit(1)
		return
	paths.sort()
	var failures := 0
	for path in paths:
		var script := load(path) as GDScript
		if script == null or not script.can_instantiate():
			push_error("Cannot compile script: " + path)
			failures += 1
	print("Compiled scripts: %d; failures: %d" % [paths.size(), failures])
	quit(1 if failures > 0 else 0)


func _discover(path: String, paths: Array[String]) -> bool:
	var directory := DirAccess.open(path)
	if directory == null:
		push_error("Cannot scan script directory: " + path)
		return false
	for filename in directory.get_files():
		if filename.ends_with(".gd"):
			paths.append(path.path_join(filename))
	for child in directory.get_directories():
		if not child.begins_with(".") and not _discover(path.path_join(child), paths):
			return false
	return true

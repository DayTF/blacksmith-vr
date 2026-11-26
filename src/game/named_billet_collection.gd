extends RefCounted
## One atomic file per named desktop item.

const Entry := preload("res://src/game/named_billet_collection_entry.gd")

var directory: String
var skipped_entries := 0


func _init(path := "user://named_billets_v1") -> void:
	directory = path


func load_entries() -> Array[Entry]:
	var entries: Array[Entry] = []
	skipped_entries = 0
	if not DirAccess.dir_exists_absolute(directory):
		return entries
	var folder := DirAccess.open(directory)
	if folder == null:
		skipped_entries = 1
		return entries
	for filename in folder.get_files():
		if not filename.ends_with(".res") or filename.begins_with(".pending-"):
			continue
		var item := ResourceLoader.load(directory.path_join(filename), "",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as Entry
		if item == null or item.fragments == null or item.assigned_name().is_empty() \
				or (item.mesh == null and item.fragments.instance_count == 0):
			skipped_entries += 1
			continue
		entries.append(item)
	return entries


func save(item: Entry) -> Error:
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		return error
	var folder := DirAccess.open(directory)
	if folder == null:
		return DirAccess.get_open_error()
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	var filename := "%016d-%s.res" % [int(Time.get_unix_time_from_system() * 1000), token]
	var temporary := ".pending-" + filename
	error = ResourceSaver.save(item, directory.path_join(temporary), ResourceSaver.FLAG_COMPRESS)
	if error == OK:
		error = folder.rename(temporary, filename)
	if error != OK and folder.file_exists(temporary):
		folder.remove(temporary)
	return error

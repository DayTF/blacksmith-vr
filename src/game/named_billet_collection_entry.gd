extends Resource
## Persisted terminal billet and static render resources.

@export_storage var terminal_bytes: PackedByteArray
@export_storage var mesh: Mesh
@export_storage var fragments: MultiMesh


func terminal_state() -> Dictionary:
	var decoded: Variant = bytes_to_var(terminal_bytes)
	return decoded if decoded is Dictionary else {}


func assigned_name() -> String:
	return terminal_state().get("name", "")

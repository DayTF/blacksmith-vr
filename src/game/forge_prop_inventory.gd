extends RefCounted
## Turns the imported room's loose meshes into stage-space pickup objects.


static func register(room: Node3D, stage: Node3D) -> Array[Dictionary]:
	var model := room.get_node("Room")
	var props: Array[Dictionary] = []
	var stock: MeshInstance3D
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		var label: String = mesh.name
		if label.begins_with("Stock blank"):
			stock = mesh
			props.append(_prop(stage, "Stock blank", "stock", [mesh], mesh.global_transform))
		elif label.begins_with("Banked coal"):
			props.append(_prop(stage, "Coal", "fuel", [mesh], mesh.global_transform))
		elif label.begins_with("Forging tool grip"):
			var suffix := label.trim_prefix("Forging tool grip")
			var head := mesh.get_parent().get_node_or_null("Hanging tool head" + suffix) as MeshInstance3D
			if head == null:
				continue
			var mount := Transform3D(Basis(Vector3.RIGHT, PI * 0.5), mesh.global_position)
			mount.origin.y -= mesh.get_aabb().size.y * 0.23
			var hammer := _prop(stage, "Rack hammer", "hammer", [mesh, head], mount)
			hammer.impact_offset = hammer.mesh.to_local(head.global_position)
			props.append(hammer)
	if stock != null:
		for x in [-0.63, -0.35]:
			var blank := MeshInstance3D.new()
			blank.mesh = stock.mesh
			room.add_child(blank)
			blank.position = Vector3(x, 0.911, -2.19)
			blank.scale.z = 0.30
			var metal := StandardMaterial3D.new()
			metal.albedo_color = Color("8c4f34")
			metal.emission_enabled = true
			metal.emission = Color("fb672d")
			metal.emission_energy_multiplier = 2.5
			blank.material_override = metal
			var mount := Transform3D(Basis.IDENTITY, blank.global_position)
			props.append(_prop(stage, "Hearth stock", "hot_stock", [blank], mount))
	return props


static func _prop(stage: Node3D, label: String, kind: String, meshes: Array,
		mount: Transform3D) -> Dictionary:
	var holder := Node3D.new()
	holder.name = label
	stage.add_child(holder, true)
	holder.global_transform = mount
	var bounds := AABB()
	for index in meshes.size():
		var mesh: MeshInstance3D = meshes[index]
		mesh.reparent(holder)
		var part: AABB = mesh.transform * mesh.get_aabb()
		bounds = part if index == 0 else bounds.merge(part)
	return {"name": label, "kind": kind, "mesh": holder, "pose": holder.transform,
		"aim_bounds": bounds, "offset": Vector3.ZERO, "clearance": -bounds.position.y,
		"anchored": true, "fall": 0.0}

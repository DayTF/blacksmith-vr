extends RefCounted
## Display-only rounded reference surface mapped onto the moving lattice.

const WEIGHTS := [
	Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
	Vector3(0.5, 0.5, 0), Vector3(0, 0.5, 0.5), Vector3(0.5, 0, 0.5),
]
const TRIANGLES := [0, 3, 5, 3, 1, 4, 5, 4, 2, 3, 4, 5]

var _rest: PackedVector3Array
var _inner: AABB
var _radius: float
var _samples := {}


func _init(nodes: Array[Dictionary], radius: float) -> void:
	_rest = PackedVector3Array()
	var bounds := AABB(nodes[0].position, Vector3.ZERO)
	for node in nodes:
		_rest.append(node.position)
		bounds = bounds.expand(node.position)
	_radius = minf(radius, minf(bounds.size.x, minf(bounds.size.y, bounds.size.z)) * 0.5)
	_inner = bounds.grow(-_radius)


func _rounded_offsets(ids: Array) -> Array:
	var key := Vector3i(ids[0], ids[1], ids[2])
	if not _samples.has(key):
		var offsets := PackedVector3Array()
		var normals := PackedVector3Array()
		for weights: Vector3 in WEIGHTS:
			var reference := _rest[ids[0]] * weights.x + _rest[ids[1]] * weights.y + _rest[ids[2]] * weights.z
			var nearest := reference.clamp(_inner.position, _inner.end)
			var normal := (reference - nearest).normalized()
			offsets.append(nearest + normal * _radius - reference)
			normals.append(normal)
		_samples[key] = [offsets, normals]
	return _samples[key]


func append(mesh: SurfaceTool, ids: Array, nodes: Array, colors: PackedColorArray,
		emissions: PackedFloat32Array, first: int) -> void:
	var a: Dictionary = nodes[ids[0]]
	var b: Dictionary = nodes[ids[1]]
	var c: Dictionary = nodes[ids[2]]
	var samples := _rounded_offsets(ids)
	for index in WEIGHTS.size():
		var weights: Vector3 = WEIGHTS[index]
		var offset: Vector3 = samples[0][index]
		var normal: Vector3 = samples[1][index]
		var displaced: Vector3 = (a.position + a.orientation * offset) * weights.x \
			+ (b.position + b.orientation * offset) * weights.y + (c.position + c.orientation * offset) * weights.z
		var mapped_normal: Vector3 = (a.orientation * normal) * weights.x \
			+ (b.orientation * normal) * weights.y + (c.orientation * normal) * weights.z
		mesh.set_normal(mapped_normal.normalized())
		mesh.set_color(colors[ids[0]] * weights.x + colors[ids[1]] * weights.y + colors[ids[2]] * weights.z)
		mesh.set_uv2(Vector2(emissions[ids[0]] * weights.x + emissions[ids[1]] * weights.y + emissions[ids[2]] * weights.z, 0))
		mesh.add_vertex(displaced)
	for index: int in TRIANGLES:
		mesh.add_index(first + index)

extends RefCounted
## Camera-facing preview geometry for grid faces with severed connections.

const SPLITS := [[[0, 1, 2], [0, 2, 3]], [[0, 1, 3], [1, 2, 3]]]


static func broken_pairs(links: Array[Dictionary]) -> Dictionary:
	var pairs := {}
	for link in links:
		if link.broken:
			pairs[_pair(link.a, link.b)] = true
	return pairs


static func visible_triangles(face: Array, severed: Dictionary) -> Array:
	# Try both diagonals so a severed diagonal doesn't hide an otherwise
	# supported side. Triangles that cross any broken edge are discarded.
	var best: Array = []
	for split: Array in SPLITS:
		var supported: Array = []
		for corners: Array in split:
			var a: int = face[corners[0]]
			var b: int = face[corners[1]]
			var c: int = face[corners[2]]
			if not (severed.has(_pair(a, b)) or severed.has(_pair(b, c)) or severed.has(_pair(c, a))):
				supported.append([a, b, c])
		if supported.size() > best.size():
			best = supported
		if best.size() == 2:
			break
	return best


static func _pair(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))

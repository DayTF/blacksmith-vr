class_name MaterialCurve
extends RefCounted
## Compiled scalar/vector property graph. Invalid definitions collect diagnostics;
## missing/non-finite query inputs return null rather than inventing material state.

var errors := PackedStringArray()
var width := 1
var vector_value := false
var _kind := ""
var _axis := "temperature"
var _interpolation := "linear"
var _times := PackedFloat64Array()
var _values: Array[PackedFloat64Array] = []
var _inputs: Array[MaterialCurve] = []


func _init(definition: Variant) -> void:
	_configure(definition)


func sample(context: Dictionary) -> Variant:
	if not errors.is_empty():
		return null
	if _kind == "constant":
		return _export(_values[0])
	if _kind == "keys":
		var input: Variant = context.get(_axis)
		if not _number(input):
			return null
		return _sample_keys(float(input))
	var output := PackedFloat64Array()
	output.resize(width)
	for child_index in _inputs.size():
		var value: Variant = _inputs[child_index].sample(context)
		if value == null:
			return null
		var components := _components(value)
		for lane in width:
			var component := components[0 if components.size() == 1 else lane]
			if child_index == 0:
				output[lane] = component
			else:
				match _kind:
					"add": output[lane] += component
					"multiply": output[lane] *= component
					"min": output[lane] = minf(output[lane], component)
					"max": output[lane] = maxf(output[lane], component)
	return _export(output)


func _configure(definition: Variant) -> void:
	if not definition is Dictionary:
		errors.append("Expected a curve/graph object.")
		return
	var forms := int(definition.has("constant")) + int(definition.has("keys")) + int(definition.has("op"))
	if forms != 1:
		errors.append("Choose exactly one of constant, keys or op.")
		return
	if definition.has("constant"):
		_kind = "constant"
		var value: Variant = definition.constant
		if not _valid_value(value):
			errors.append("Constants must be finite scalars or nonempty numeric vectors.")
			return
		vector_value = value is Array or value is PackedFloat64Array
		_values.append(_components(value))
		width = _values[0].size()
	elif definition.has("keys"):
		_configure_keys(definition)
	else:
		_configure_operation(definition)


func _configure_keys(definition: Dictionary) -> void:
	_kind = "keys"
	var axis: Variant = definition.get("axis", "temperature")
	var interpolation: Variant = definition.get("interpolation", "linear")
	if not axis is String or axis.is_empty():
		errors.append("Curve axis must be a nonempty string.")
		return
	_axis = axis
	if interpolation not in ["linear", "cubic", "step"]:
		errors.append("Interpolation must be linear, cubic or step.")
		return
	_interpolation = interpolation
	var keys: Variant = definition["keys"]
	if not keys is Array or keys.is_empty():
		errors.append("Curve keys must be a nonempty array.")
		return
	for key: Variant in keys:
		if not key is Array or key.size() != 2 or not _number(key[0]) or not _valid_value(key[1]):
			errors.append("Each key must contain a finite input and scalar/vector value.")
			return
		var time := float(key[0])
		var value := _components(key[1])
		var is_vector := key[1] is Array or key[1] is PackedFloat64Array
		if _times.is_empty():
			width = value.size()
			vector_value = is_vector
		elif time <= _times[-1] or value.size() != width or is_vector != vector_value:
			errors.append("Keys must have increasing inputs and consistent value shapes.")
			return
		_times.append(time)
		_values.append(value)


func _configure_operation(definition: Dictionary) -> void:
	var operation: Variant = definition.op
	if operation not in ["add", "multiply", "min", "max"]:
		errors.append("Graph op must be add, multiply, min or max.")
		return
	_kind = operation
	var inputs: Variant = definition.get("inputs")
	if not inputs is Array or inputs.size() < 2:
		errors.append("Graph operations require at least two input graphs.")
		return
	for definition_input: Variant in inputs:
		var child: MaterialCurve = get_script().new(definition_input)
		for error in child.errors:
			errors.append("Input %d: %s" % [_inputs.size(), error])
		_inputs.append(child)
		width = maxi(width, child.width)
		vector_value = vector_value or child.vector_value
	for child in _inputs:
		if child.width != 1 and child.width != width:
			errors.append("Graph vectors must have matching widths; scalars broadcast.")


func _sample_keys(input: float) -> Variant:
	if input <= _times[0]:
		return _export(_values[0])
	if input >= _times[-1]:
		return _export(_values[-1])
	var low := 0
	var high := _times.size() - 1
	while high - low > 1:
		var middle := (low + high) / 2
		if _times[middle] <= input:
			low = middle
		else:
			high = middle
	if _interpolation == "step":
		return _export(_values[low])
	var span := _times[high] - _times[low]
	var t := (input - _times[low]) / span
	var result := PackedFloat64Array()
	result.resize(width)
	for lane in width:
		if _interpolation == "linear":
			result[lane] = lerpf(_values[low][lane], _values[high][lane], t)
		else:
			# Nonuniform Catmull-Rom, expressed in cubic Hermite form.
			var t2 := t * t
			var t3 := t2 * t
			result[lane] = (
				(2.0 * t3 - 3.0 * t2 + 1.0) * _values[low][lane]
				+ (t3 - 2.0 * t2 + t) * span * _tangent(low, lane)
				+ (-2.0 * t3 + 3.0 * t2) * _values[high][lane]
				+ (t3 - t2) * span * _tangent(high, lane)
			)
	return _export(result)


func _tangent(index: int, lane: int) -> float:
	var left := maxi(0, index - 1)
	var right := mini(_times.size() - 1, index + 1)
	if left == index or right == index:
		return (_values[right][lane] - _values[left][lane]) / (_times[right] - _times[left])
	var before := _times[index] - _times[left]
	var after := _times[right] - _times[index]
	var slope_before := (_values[index][lane] - _values[left][lane]) / before
	var slope_after := (_values[right][lane] - _values[index][lane]) / after
	return (slope_before * after + slope_after * before) / (before + after)


func _export(components: PackedFloat64Array) -> Variant:
	for value in components:
		if not is_finite(value):
			return null
	return components.duplicate() if vector_value else components[0]


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _valid_value(value: Variant) -> bool:
	if _number(value):
		return true
	if not (value is Array or value is PackedFloat64Array) or value.is_empty():
		return false
	for component: Variant in value:
		if not _number(component):
			return false
	return true


static func _components(value: Variant) -> PackedFloat64Array:
	if value is int or value is float:
		return PackedFloat64Array([float(value)])
	return PackedFloat64Array(value)

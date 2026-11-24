extends RefCounted

const CurveGraph = preload("res://src/sim/material_curve.gd")
var _failures := PackedStringArray()


func run() -> PackedStringArray:
	_failures.clear()
	var linear := CurveGraph.new({"keys": [[0, 10], [100, 30]]})
	_expect(linear.errors.is_empty(), "Valid linear curve rejected")
	_near(linear.sample({"temperature": 50}), 20, "Linear interpolation")
	_near(linear.sample({"temperature": -10}), 10, "Lower endpoint clamping")
	_near(linear.sample({"temperature": 200}), 30, "Upper endpoint clamping")
	_expect(linear.sample({}) == null, "Missing query axis must fail")
	_expect(linear.sample({"temperature": NAN}) == null, "Non-finite query must fail")
	var single := CurveGraph.new({"keys": [[10, 7]]})
	_near(single.sample({"temperature": 200}), 7, "Single-key curve")
	var step := CurveGraph.new({"interpolation": "step", "keys": [[0, 1], [100, 2], [200, 3]]})
	_near(step.sample({"temperature": 99.9}), 1, "Step holds left value")
	_near(step.sample({"temperature": 100}), 2, "Step changes at exact key")
	var cubic := CurveGraph.new({"interpolation": "cubic", "keys": [[0, 0], [1, 1], [3, 9], [4, 16]]})
	_near(cubic.sample({"temperature": 2}), 4, "Nonuniform cubic reproduces interior quadratic")
	_near(cubic.sample({"temperature": 3}), 9, "Cubic passes through keys")
	var vector := CurveGraph.new({"interpolation": "cubic", "keys": [[0, [0, 0]], [1, [1, 2]], [2, [4, 8]], [3, [9, 18]]]})
	var sample: Variant = vector.sample({"temperature": 1.5})
	_expect(sample is PackedFloat64Array and sample.size() == 2, "Vector output shape")
	if sample is PackedFloat64Array and sample.size() == 2:
		_near(sample[0], 2.25, "Cubic vector first lane")
		_near(sample[1], 4.5, "Cubic vector second lane")
	var constant := CurveGraph.new({"constant": [1, 2, 3]})
	var mutable: PackedFloat64Array = constant.sample({})
	mutable[0] = 999
	_near(constant.sample({})[0], 1, "Returned vector must not mutate compiled data")
	var composed := CurveGraph.new({"op": "multiply", "inputs": [
		{"keys": [[0, 100], [1000, 50]]},
		{"op": "add", "inputs": [{"constant": 1}, {"axis": "plastic_strain", "keys": [[0, 0], [1, 1]]}]}
	]})
	_near(composed.sample({"temperature": 500, "plastic_strain": 0.5}), 112.5, "Temperature/strain graph composition")
	_expect(composed.sample({"temperature": 500}) == null, "Graph propagates missing strain")
	var broadcast := CurveGraph.new({"op": "add", "inputs": [{"constant": [1, 2]}, {"constant": 3}]})
	_near(broadcast.sample({})[1], 5, "Scalar broadcast into vector")
	var limited := CurveGraph.new({"op": "min", "inputs": [{"constant": 1}, {"op": "max", "inputs": [{"constant": 0}, {"axis": "strain", "keys": [[0, -2], [1, 2]]}]}]})
	_near(limited.sample({"strain": 0}), 0, "Composed lower bound")
	_near(limited.sample({"strain": 1}), 1, "Composed upper bound")
	var invalid_definitions: Array = [
		null, {}, {"constant": NAN}, {"constant": []}, {"constant": [1, "bad"]},
		{"constant": 1, "keys": [[0, 1]]}, {"keys": []}, {"keys": [[1, 2], [1, 3]]},
		{"keys": [[2, 1], [1, 2]]}, {"keys": [[0, [1, 2]], [1, [3]]]},
		{"keys": [[0, 1], [1, [2]]]}, {"keys": [[INF, 1]]}, {"keys": [[0]]},
		{"axis": "", "keys": [[0, 1]]}, {"interpolation": "unknown", "keys": [[0, 1]]},
		{"op": "divide", "inputs": []}, {"op": "add", "inputs": [{"constant": 1}]},
		{"op": "add", "inputs": [{"constant": [1, 2]}, {"constant": [1, 2, 3]}]},
		{"op": "multiply", "inputs": [{"constant": 1}, {"constant": "bad"}]}
	]
	for index in invalid_definitions.size():
		var invalid := CurveGraph.new(invalid_definitions[index])
		_expect(not invalid.errors.is_empty(), "Invalid definition %d accepted" % index)
		_expect(invalid.sample({"temperature": 0}) == null, "Invalid graph %d evaluated" % index)
	var overflow := CurveGraph.new({"op": "multiply", "inputs": [{"constant": 1e300}, {"constant": 1e300}]})
	_expect(overflow.sample({}) == null, "Non-finite graph output must fail")
	return _failures


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _near(actual: Variant, expected: float, message: String) -> void:
	_expect((actual is int or actual is float) and is_equal_approx(float(actual), expected), message + " (got %s)" % str(actual))

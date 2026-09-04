class_name VoxelTimingWindow
extends RefCounted

## Bounded, allocation-free-on-record telemetry window. Sorting is delayed
## until a diagnostic snapshot is requested so the physics path stays O(1).
const DEFAULT_CAPACITY := 64

var _capacity := DEFAULT_CAPACITY
var _samples: Array[int] = []
var _next_index := 0
var _total := 0


func _init(capacity: int = DEFAULT_CAPACITY) -> void:
	_capacity = maxi(1, capacity)
	_samples.resize(_capacity)


func clear() -> void:
	_next_index = 0
	_total = 0
	for index in _samples.size():
		_samples[index] = 0


func record(value: int) -> void:
	var safe_value := maxi(0, value)
	var sample_index := _next_index % _capacity
	if _next_index >= _capacity:
		_total -= _samples[sample_index]
	_samples[sample_index] = safe_value
	_next_index += 1
	_total += safe_value


func snapshot() -> Dictionary:
	var count := mini(_next_index, _capacity)
	var sorted_samples: Array[int] = []
	sorted_samples.resize(count)
	for index in count:
		sorted_samples[index] = _samples[index]
	sorted_samples.sort()
	return {
		"capacity": _capacity,
		"sample_count": count,
		"recorded_count": _next_index,
		"average": float(_total) / float(count) if count > 0 else 0.0,
		"maximum": sorted_samples[-1] if not sorted_samples.is_empty() else 0,
		"p95": _nearest_rank(sorted_samples, 0.95),
		"p99": _nearest_rank(sorted_samples, 0.99),
	}


func _nearest_rank(sorted_samples: Array[int], percentile: float) -> int:
	if sorted_samples.is_empty():
		return 0
	var rank := ceili(percentile * float(sorted_samples.size()))
	return sorted_samples[clampi(rank - 1, 0, sorted_samples.size() - 1)]

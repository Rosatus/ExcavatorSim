class_name SimulationTruthSnapshot
extends RefCounted

var _canonical_json := ""


static func from_dictionary(value: Dictionary) -> SimulationTruthSnapshot:
	var result := SimulationTruthSnapshot.new()
	result._canonical_json = JSON.stringify(value)
	return result


func to_dictionary() -> Dictionary:
	var parsed: Variant = JSON.parse_string(_canonical_json)
	return (parsed as Dictionary).duplicate(true) if parsed is Dictionary else {}


func encoded_size_bytes() -> int:
	return _canonical_json.to_utf8_buffer().size()

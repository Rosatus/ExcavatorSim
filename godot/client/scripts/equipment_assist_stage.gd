class_name EquipmentAssistStage
extends RefCounted

## Base contract for one assist unit inside EquipmentAssistPipeline. A stage
## either reshapes the operator command vector (modulator, returns "commands")
## or only attenuates it (governor, returns "scale" < 1). writes_mask declares
## the channels the stage may write; the pipeline strips undeclared writes.
## holds_at_neutral must be true before a stage may emit non-zero motion while
## the operator input vector is zero — the pipeline neutral guard enforces it.

const MASK_SWING := 1
const MASK_BOOM := 2
const MASK_ARM := 4
const MASK_BUCKET := 8
const MASK_WORK_EQUIPMENT := MASK_BOOM | MASK_ARM | MASK_BUCKET

var stage_name := "stage"
var enabled := false
var configured := false
var writes_mask := 0
var holds_at_neutral := false


func configure(_descriptor: Dictionary, _soil_contract: Dictionary, _params: Dictionary) -> bool:
	configured = true
	return true


func set_enabled(value: bool) -> void:
	enabled = value and configured
	if not enabled:
		reset("disabled")


func reset(_reason := "reset") -> void:
	pass


func step(_ctx: RefCounted, commands: Vector4) -> Dictionary:
	return {"commands": commands, "scale": 1.0, "flags": []}


func get_status_snapshot() -> Dictionary:
	return {
		"name": stage_name,
		"enabled": enabled,
		"configured": configured,
		"writes_mask": writes_mask,
		"holds_at_neutral": holds_at_neutral,
	}

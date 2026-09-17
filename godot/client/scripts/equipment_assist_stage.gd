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
## Stages sharing a non-empty group are mutually exclusive: enabling one
## disables the others in the same group (level vs. slope guidance).
var exclusive_group := ""
## The parameter dictionary this stage was configured with — kept so
## non-control consumers (preview cadence, UI readouts) can read back rates
## and thresholds without re-loading the profile resource.
var profile_params := {}


func configure(_descriptor: Dictionary, _soil_contract: Dictionary, _params: Dictionary) -> bool:
	configured = true
	return true


## Runtime parameter injection for stages whose task is parameterized after
## configure (e.g. the slope stage's confirmed profile). Stages that accept
## no live parameters return false.
func apply_params(_params: Dictionary) -> bool:
	return false


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

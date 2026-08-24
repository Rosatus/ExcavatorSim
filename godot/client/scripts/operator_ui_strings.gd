class_name OperatorUIStrings
extends RefCounted

const TITLE := "EXCAVATOR CONTROL"
const GUIDE_TITLE := "Quick operator guide"
const GUIDE_INTRO := "Start the machine, move into the work area, then shape soil with the bucket itself. Digging and dumping happen automatically from physical bucket contact—there is no separate Dig or Deposit command."
const GUIDE_KEYBOARD := "Keyboard + mouse\nTracks: W/S left track · ↑/↓ right track\nUpper structure: Y/H swing · U/J boom · I/K arm · O/L bucket\nCamera: middle-drag orbit · mouse wheel zoom\nSession: F6 start · F7 pause · F8 reset"
const GUIDE_GAMEPAD := "Gamepad + keyboard/mouse\nUpper structure: left stick X swing · left stick Y boom\nArm: right stick Y · bucket: left/right triggers\nTracks currently use W/S and ↑/↓; camera uses middle-drag and wheel.\nSession: F6 start · F7 pause · F8 reset"
const GUIDE_RECOVERY := "Reset and model changes stop motion, clear terrain and bucket payload, and require controls to return to neutral before motion resumes."
const CONTROL_HINT_KEYBOARD := "W/S + ↑/↓ tracks   Y/H swing   U/J boom   I/K arm   O/L bucket"
const CONTROL_HINT_GAMEPAD := "Sticks: swing/boom/arm   Triggers: bucket   Keyboard: independent tracks"
const SOIL_AUTOMATIC_HINT := "Use the bucket edge and shell directly—cut, carry and dump are automatic."

const BUTTON_START := "Start  F6"
const BUTTON_PAUSE := "Pause  F7"
const BUTTON_RESET := "Reset  F8"
const BUTTON_GUIDE := "Controls"
const BUTTON_ADVANCED := "Advanced"
const BUTTON_CLOSE := "Continue"

const WARNING_FOCUS := "Window focus lost — motion is safely stopped. Click the simulator to continue."
const WARNING_PAUSED := "Machine paused — press Start when the work area is clear."
const WARNING_STOPPED := "Machine stopped — review the controls, then press Start."
const WARNING_GATEWAY := "Optional gateway is unavailable — reconnect or return to local mode."
const WARNING_NEUTRAL := "Return track and work-equipment controls to neutral to re-arm motion."
const WARNING_OVERFLOW := "Bucket is overfilled — curl back or dump to regain control."
const WARNING_NONE := "Ready"


static func model_name(model_id: String) -> String:
	return {"sy205": "SANY SY205", "sy135": "SANY SY135"}.get(model_id, model_id.to_upper())


static func lifecycle_text(value: String) -> String:
	return {"running": "RUNNING", "paused": "PAUSED", "stopped": "STOPPED"}.get(value, value.to_upper())


static func fill_text(fill_ratio: float) -> String:
	if fill_ratio <= 0.02:
		return "EMPTY"
	if fill_ratio >= 0.85:
		return "FULL"
	return "PARTIAL"


static func operation_text(value: String) -> String:
	return {
		"idle": "READY TO WORK",
		"contact": "BUCKET CONTACT",
		"scrape": "GRADING / PUSHING",
		"cut": "CUTTING SOIL",
		"load": "LOADING BUCKET",
		"carry": "CARRYING LOAD",
		"dump": "DUMPING",
		"spill": "SPILLING",
		"overflow": "BUCKET OVERFLOW",
	}.get(value, value.replace("_", " ").to_upper())


static func reset_confirmation() -> String:
	return "Reset this work session?\n\nTerrain and bucket payload will be cleared, motion will stop, and both track and work-equipment controls must return to neutral."


static func model_confirmation(model_id: String) -> String:
	return "Switch to %s?\n\nThe current terrain and bucket payload will be cleared. Motion stops and controls must return to neutral before the new machine can move." % model_name(model_id)

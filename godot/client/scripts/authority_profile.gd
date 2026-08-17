class_name AuthorityProfile
extends RefCounted

const PYTHON_KINEMATIC := "python_kinematic"
const JOLT_SHADOW := "jolt_shadow"
const JOLT_AUTHORITATIVE := "jolt_authoritative"
const VALUES := [PYTHON_KINEMATIC, JOLT_SHADOW, JOLT_AUTHORITATIVE]


static func is_valid(value: String) -> bool:
	return VALUES.has(value)


static func writes_product_pose(value: String) -> bool:
	return value == JOLT_AUTHORITATIVE


static func publishes_shadow(value: String) -> bool:
	return value == JOLT_SHADOW

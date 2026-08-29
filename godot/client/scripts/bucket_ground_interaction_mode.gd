class_name BucketGroundInteractionMode
extends RefCounted

const NORMAL := "normal"
const PASSTHROUGH := "bucket_passthrough"
const VALUES := [NORMAL, PASSTHROUGH]


static func is_valid(value: String) -> bool:
	return value in VALUES


static func is_passthrough(value: String) -> bool:
	return value == PASSTHROUGH

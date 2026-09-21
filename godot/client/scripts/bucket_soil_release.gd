extends RefCounted
## Orientation policy only. The authority retains confirmation, obstruction,
## admission, transactions and mass ownership.

const DEFAULT_DOWN_DOT := 0.5


static func threshold(interaction: Dictionary) -> float:
	return maxf(float(interaction.get("release_opening_down_dot", DEFAULT_DOWN_DOT)),
		SoilContractDescriptor.effective_dump_opening_down_dot(interaction))


static func opening_normal(pose: Dictionary) -> Vector3:
	var contract: Dictionary = pose.get("contract", {})
	if contract.has("soil_geometry"):
		var opening: Variant = (pose.get("current", {}) as Dictionary).get("opening")
		if opening is Transform3D:
			return (opening as Transform3D).basis.y.normalized()
		return Vector3.ZERO
	return pose.get("opening_normal_world", Vector3.UP) as Vector3

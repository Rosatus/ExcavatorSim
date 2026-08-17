extends RigidBody3D


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var probe := get_parent()
	probe.set_meta("direct_state_seen", true)
	probe.set_meta("direct_state_type", state.get_class())

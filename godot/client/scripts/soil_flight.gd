extends RefCounted

# Decorative particle motion only; never owns soil mass or terrain edits.
const GRAVITY := 5.5
const INITIAL_SPEED := 0.7
const MAX_FLIGHT_S := 4.0


static func duration(release: Vector3, landing: Vector3) -> float:
	var height := maxf(0.0, release.y - landing.y)
	return (sqrt(INITIAL_SPEED * INITIAL_SPEED + 2.0 * GRAVITY * height) - INITIAL_SPEED) / GRAVITY

# Design — game feel digging response

## Response model

The authority publishes a raw 0–1 engagement/load estimate and categorical
phase. A response shaper applies phase-aware hysteresis, attack/release slew,
model/material tuning, and a nonzero clamp to produce per-axis equipment speed
scales. Scaling occurs at the command/accepted-motion boundary already used for
safe articulation, not by inventing Jolt impulses or modifying presentation
transforms after acceptance.

Cutting deeper and curling loaded soil increase intensity. Separating, lifting
away, dumping, or reversing out uses a faster recovery path. `blocked` reports a
readable cue but retains an escape direction and reset path.

## Presentation contract

Snapshots carry phase, intensity, speed scale, material flow, fill ratio, and
event identity. VFX/audio/camera/HUD may smooth further for presentation, but
cannot change the authoritative response or material transfer.

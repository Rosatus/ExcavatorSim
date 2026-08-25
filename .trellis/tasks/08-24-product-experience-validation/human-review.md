# Human product review gate

Automation does not decide whether the machine pose looks mechanically natural.
Before the final evidence matrix, manually review SY205 in the production scene:

1. Start the local product with `F6` and select SY205.
2. Hold `O` to the positive endpoint. It should curl inward but stop before the
   bucket folds unnaturally into the arm; the provisional endpoint is `+30 deg`.
3. Hold `L` to the negative endpoint. It should open materially farther than the
   original range without appearing detached or inverted; the provisional
   endpoint is `-95 deg`.
4. Perform one real dig: tooth contact, inward curl, lift with visible soil, then
   outward dump. Confirm that soil leaves the bucket in the visible outward
   posture rather than while it is curled inward.

Reply with whether both endpoints and the direction of O/L feel correct. If an
endpoint is still wrong, report which key and whether it needs more or less
travel; no screenshot is required.

In the same manual run, also check the new usability closure:

5. SY205 should face the intended direction immediately after spawn/reset; Q/A
   should operate its visual left track and W/S its visual right track. On each
   side, the first key is forward and the second is reverse. With an XInput
   controller, LT/LB must drive that same visual left track forward/reverse and
   RT/RB the same visual right track forward/reverse.
6. Drive beyond the old center patch toward several visible site edges. The
   machine should follow the rendered ground instead of falling through.
7. Use `Hide panel`, then the remaining `Controls` button, and confirm the
   top-left HUD can be hidden and restored easily.
8. Select `Cab / First Person` (key `5`) on SY205 and SY135. Confirm the eye point
   is inside the driving cab, faces through the windshield, follows upper-body
   slew, and makes only the upper-body shell transparent. Boom, arm, bucket,
   tracks, and soil must stay normally visible. Return to Chase and confirm the
   machine shell becomes opaque again.
9. Toggle `Test Grid` in the top-left panel. The site ground should become an
   untextured black/white grid with no grass, rocks, barriers, stakes, or other
   terrain dressing; the excavator, soil deformation, and driving support must
   continue. Toggle it off and confirm the normal site presentation returns.
10. On the XInput controller, check the ISO work-equipment pattern: left stick
    left/right swings, left stick forward/back moves the arm out/in; right stick
    forward/back lowers/raises the boom, and right stick left/right curls/dumps
    the bucket. Confirm all four SY205 XInput axes now move opposite the prior
    build, while SY135 changed only left-stick swing. Release all controls after
    reset/model switch to re-arm.

These are the only new subjective checks; no screenshot is required. If a cab
position is wrong, report model plus “left/right/up/down/forward/back” adjustment.

# SY155W CAN output — RootPilot RT baseline

## Current goal and authorization
User follow-up explicitly replaces155W baseline with:
- C:/code/GuideSystem/services/can/models/SY135C_RT/dbc/can3.sy135c_RT.dbc
- C:/code/GuideSystem/services/can/models/SY135C_RT/dbc/can4.sy135c_RT.dbc
Previous unsigned18FF3F00 implementation is superseded. Preserve135/80U,
Godot v3/model3,135 physical zero/calibration, and defaultGB12 geometry.
Sender-only scope; no receiver edits, commit/push or full client export.

## Delivered
Reference DBCs copied byte-for-byte under resources/dbc/sy135c_rt_reference,
provenance hashes recorded. Generator preserves every baseline message/signal,
adds only boom2 attitude18F40000 (next after bodyF0/boomF1/armF2/bucketF3).
RT layout: signedLE roll/pitch, unsignedyaw,0.01deg,zero offset,valid zero.
Parser inverse uses Roll=reportedRoll,Pitch=-reportedPitch,Yaw=reportedYaw.
Body calibration and serial-chain/four-bar math remain135 convention.

GNSS09F80230 gives true-north computed equipment heading in radians and speed;
09F80530 gives51BE position bytes in8 classic-CAN frames, sequence1..8,
first01/33, last4FF padding. Virtual64-byte DBC never goes directly to CAN.
can4 retainsDHC ch2. Old slew/A000..A900 frames are absent; native travel remains.
No invented angular velocity/acceleration/RTCM measurements.
SocketCAN queues/coalesces complete transfer groups and drops tail on congestion;
PC001 atomically admits all8 fragments or drops all8. Existing single-frame
semantics preserved. StartedSocketCAN groups can exceed softbudget by at most7.

## Verification (2026-10-12)
- Full Python gateway suite:223 tests OK,2platform skips, actual155W+80U captures
  enabled. TEMP/sy155w_rt_suite.log. Independent raw RT decoder checks243 joint/
  body combinations and7 realGodot155W checkpoints below0.04deg.
- New6 RootPilot tests:baseline message parity,zero-valid signedIMU,rawBE GNSS
  geodetic/date/time,heading includingwrap,classic fragments,SocketCAN coalescing/
  congestion recovery/purge,PC001 whole-group enqueue/drop. Pass.
- Frozen final Windows package build+Web/resources/three-model calibration restart
  smoke passes;7 model-switch/pose tests pass including135->80->155->135,
  EOF/freshhandshake,RT console/IDs,8 ordered GNSS fragments,old135payload parity.
- Godot can_gateway_e2e_test exit0/PASS after transport changes. Existing voxel
  teardown diagnostics remain. TEMP/sy155w_rt_e2e.log.
- SourceGodot/CTN1 unchanged this follow-up, prior actual capture evidence reused.
- ScopedRuff/provenance/diff checks pass. NoLinux build; recursive packaging retained.
- Readonly peer verified receiver equations/framing and transport groups; no new
  concrete defect found.

## Completion and limits
Completed sender change. Artifact:dist/can_gateway_sy155w/gateway.exe with adjacent
config/dbc. Not a fullGodot export and does not replace running processes.
GuideSystem's currentSY135C_RT ignores18F40000 and guidance passesNaN for additional
arm sensor:receiver support is required for full155W visualization. No receiver
GUI acceptance claimed. Bucket still refers to neutralXTR13/GB12 tip ray; separate
attachment motion/tool geometry outside5IMU protocol. No commits; unrelated prior
map/controller/config migration edits preserved.

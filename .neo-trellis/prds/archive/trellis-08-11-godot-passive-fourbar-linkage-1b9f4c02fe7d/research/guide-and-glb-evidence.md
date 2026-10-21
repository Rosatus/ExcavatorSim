# Guide and GLB evidence

- The user-supplied guide is the source of truth for passive linkage semantics:
  A=`PIVOT_LINKAGE_A_COMMON`, B=`PIVOT_LINKAGE_B_ARM`,
  C=`PIVOT_LINKAGE_C_BUCKET`, D=`PIVOT_BUCKET_JOINT`; side links are controlled
  by `CTRL_LINKAGE_SIDE_LINKS`.
- The guide requires an arm-local Y-Z plane solver, AB/AC circle intersection,
  branch continuity, B X rotation for the primary rocker and side-controller
  position/rotation for the secondary links. A and C are not directly moved.
- The exact GLB contains these nodes beneath the expected five-pivot chain;
  manifest currently lists them only as visual auxiliary names and no solver
  exists in Godot.
- The GLB SHA-256 is
  `cf95534b31bcc156980afefef0a9f273e5c6f727547b3db1e9062ca5619b495a` and must
  remain unchanged.
- Python remains authoritative for five frame globals. The solver consumes
  already converted Godot transforms and owns no protocol, terrain or tooth
  state.

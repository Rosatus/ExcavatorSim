# ExcavatorSim Notices

ExcavatorSim's migrated backend is derived in part from KinematicSim at commit
`782cceb76afb635b3f9854cf48dbba1ba946f7fb`. Imported assets, adapted source,
adapted tests, and the generated Pinocchio frame fixture are tracked in
`assets/provenance.json`. KinematicSim is licensed under GNU Affero General
Public License version 3 only; its retained license is stored at
`assets/licenses/KinematicSim-AGPL-3.0.txt`.

The source BabylonSim checkout's historical Babylon.js license evidence is retained for provenance,
but Babylon.js is not a runtime dependency of this target bootstrap.

- `assets/licenses/Babylon.js-9.18.0-LICENSE.md`
- `assets/licenses/Babylon.js-9.18.0-NOTICE.md`

The recognizable excavator visual skin under `assets/visual/original/` is converted from the
user-approved `sil-foxglove-main/excavators/original` snapshot. The supplied snapshot has no Git,
license, NOTICE, or author metadata. The authorization basis and limits of the available attribution
facts are recorded in `assets/visual/original/SOURCE-RIGHTS.md`; raw source/output hashes and the
conversion relationship are recorded beside the assets. No unknown upstream authorship or public
license is asserted.

RRD exchange uses the exact locked `rerun-sdk` 0.35.0 Python package. Its version, package source,
integrity hash, and declared license are included in `assets/licenses/third-party-dependencies.json`.
Rerun's experimental RRD reader is contained behind the migrated `godot-pinocchio/rrd-v1` adapter and is
not sourced from an adjacent checkout.

`assets/licenses/third-party-dependencies.json` inventories the locked Pixi/conda packages and
records the lockfile hash. `backend/scripts/collect_notices.py` regenerates this evidence;
`--check` verifies
it without modifying files.

The included excavator motion model and calibration remain provisional. The visual skin is an
appearance asset, not production machine CAD, and does not include collision geometry, mass,
inertia, terrain/contact behavior, hydraulics, or dynamics.

The Godot client vendors Terrain3D 1.0.2 under
`godot/client/addons/terrain_3d/`. Terrain3D is Copyright © 2023-2026 Cory
Petkovsek, Roope Palmroos, and Contributors and is provided under the MIT
License retained at `godot/client/addons/terrain_3d/LICENSE.txt`. The current
temporary Godot visual baseline intentionally reuses Terrain3D's bundled demo
assets, material configuration, scanned rocks, and grass particles. Demo texture
sources are ambientCG assets supplied under CC0 1.0 Universal as recorded in
`godot/client/demo/assets/textures/asset_licenses.txt`. ExcavatorSim still owns
the logical height/control maps; demo terrain heights are not authoritative.

ExcavatorSim is licensed under `AGPL-3.0-only`. Technical provenance review is
complete, but external distribution still requires owner/legal approval of the
source-offer process, UI notice, and machine calibration rights. Visual asset rights were confirmed
by the project user on 2026-07-29 and are recorded separately as described above.

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
License retained at `godot/client/addons/terrain_3d/LICENSE.txt`. The product
uses a project-owned procedural soil shader override and creates no Terrain3D
demo rocks, grass particles, trees, foliage, or infinite background. Two
provenanced Terrain3D texture slots remain initialized for native compatibility
but are not sampled by the override; their ambientCG CC0 sources are recorded
in `godot/client/demo/assets/textures/asset_licenses.txt`. ExcavatorSim owns the
logical height/control maps; demo terrain heights are never authoritative.

The Godot client also vendors Sky3D 2.1 under
`godot/client/addons/sky_3d/`. Sky3D is Copyright © 2023-2026 Cory Petkovsek
and Contributors and © 2021 J. Cuéllar, and is provided under the MIT License
retained at `godot/client/addons/sky_3d/LICENSE.txt`. Its Milky Way and modified
star-field textures use
[“The Milky Way panorama”](https://www.eso.org/public/images/eso0932a/) by
ESO/S. Brunier under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), in original and
modified forms;
the moon map is Copyright © 2019 GPoSM under MIT. Detailed source and license
links are retained beside those assets and summarized in
`godot/client/addons/sky_3d/EXCAVATORSIM-PROVENANCE.md`. Sky3D is a fixed-time,
presentation-only environment and is not simulation or replay authority.

ExcavatorSim is licensed under `AGPL-3.0-only`. Technical provenance review is
complete, but external distribution still requires owner/legal approval of the
source-offer process, UI notice, and machine calibration rights. Visual asset rights were confirmed
by the project user on 2026-07-29 and are recorded separately as described above.

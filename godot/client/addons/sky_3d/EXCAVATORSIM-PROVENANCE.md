# Sky3D provenance

- Upstream: https://github.com/TokisanGames/Sky3D
- Local package version: 2.1 (`plugin.cfg`)
- Addon license: MIT (`LICENSE.txt`)
- Integration role: fixed-day Godot sky, atmosphere, fog, clouds, and lighting
- Logical authority: none; Sky3D is presentation-only

The package was supplied locally by the project user. ExcavatorSim uses the
addon implementation and its required runtime assets directly, but does not
instantiate an upstream demo scene or enable system-clock/day-cycle authority.

Third-party texture obligations retained in the package:

- `assets/thirdparty/textures/milkyway/Milkyway.jpg` and the modified
  `StarField.jpg`: “The Milky Way panorama” by ESO/S. Brunier, CC BY 4.0.
- `assets/thirdparty/textures/moon/MoonMap.png`: GPoSM 2019, MIT.

The production scene fixes Sky3D at 10:30 and routes all quality changes through
the project-owned `VisualEnvironment`/`VisualQualityController` seam. The
simulation viewport does not carry a permanent credit overlay; the complete
ESO/S. Brunier title, source, modification note, and CC BY 4.0 license remain in
the adjacent `LICENSE.md`, `ThirdParty.md`, and root `NOTICE.md` for packaging.

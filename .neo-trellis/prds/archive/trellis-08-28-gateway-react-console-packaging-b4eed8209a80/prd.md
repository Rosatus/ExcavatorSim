# Gateway React console and distribution integration

## Goal

Deliver the operator-facing React/Tailwind/shadcn console and package the Web
bundle plus approved reference DBCs into both Windows and Linux Gateway
distributions without a Node.js dependency on target machines.

## Requirements

- Create a React + TypeScript + Vite project using Tailwind CSS and source-owned
  shadcn/ui components; build relative static assets served by the Gateway.
- Show status, runtime mode, platform transport, handshake/can0 readiness,
  scheduler state, load estimate, notices, and bounded aggregated logs.
- In standalone mode show only platform-valid transport controls plus DBC source
  and message tables, signal editing, enablement, integer 1–100 Hz controls,
  payload/validation feedback, reload, and explicit start/stop.
- In managed mode render status/log/download functions only. Do not merely
  disable hidden mutation controls; integration tests must also observe API
  rejection.
- Present DBC source/hash/parse errors, generated defaults, ID conflicts,
  ignored persisted values, and load thresholds clearly.
- Reconnect the event stream from the last sequence and surface overflow/gaps
  rather than silently implying complete logs.
- Add the two project-owner-approved reference DBCs to bundled resources and to
  executable-adjacent `dbc/` folders in both distributions, recording raw
  hashes/provenance.
- Update Windows and Linux packaging to build/include Web resources and Python
  dependencies. The target distribution must run without Node.js.
- Preserve the existing Linux helper/install assets and Windows executable
  layout unless the documented new resource/dbc directories require additions.

## Acceptance Criteria

- [ ] A production build loads at the loopback root and supports static fallback
  without broken relative assets.
- [ ] Managed and standalone/platform views expose exactly their allowed
  controls; stale revision and stable error responses are recoverable in UI.
- [ ] Signal/rate validation, conflict handling, generated defaults, start/stop,
  reload/disarm, transport progress, and load warnings have component coverage.
- [ ] Event reconnect/gap/drop behavior and current/all-log downloads work.
- [ ] Windows and Linux packages contain usable Web assets and visible adjacent
  copies of both DBC files; exact bundled/adjacent copies render once.
- [ ] The packaged console works on a machine with no Node.js installed.
- [ ] Godot launches the packaged Gateway in managed mode and the console shows
  status/logs without mutation controls.

## Out of Scope

- Remote access/authentication, DBC schema editing, CAN receive monitoring, and
  a general-purpose transport selector.

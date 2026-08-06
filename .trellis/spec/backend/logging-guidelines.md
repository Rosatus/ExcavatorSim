# Backend Logging Guidelines

The service currently uses concise stdout diagnostics rather than a structured logging framework. Operational messages should state the action, authority identity, and stable error code where applicable.

Log lifecycle transitions, rejected commands, terrain worker faults, stale snapshot/epoch conflicts, and safe port cleanup decisions. Keep messages useful for a local desktop developer and avoid dumping full JSON payloads, raw GLB bytes, or client secrets.

Port cleanup must explain whether a verified same-checkout listener was stopped or an unrelated listener blocked startup. See `backend/src/babylon_sim/production.py` and `backend/tests/backend/test_production.py`.


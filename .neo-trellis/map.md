# Project map

## Knowledge scopes

Start with the module entry for the code you are working on, then read its
applicable contracts. [routes.json](routes.json) is the machine authority for
the code scopes below. Verify implementation facts against current code.

| Knowledge | Code paths | Scope |
|---|---|---|
| [Backend](modules/backend/index.md) | backend/, protocol/, assets/ | Backend implementation; shared protocol and asset constraints also apply outside backend ownership |
| [Godot client](modules/godot-client/index.md) | godot/client/, docs/godot-integration.md | Client implementation and integration contracts |

Paths outside these routes are not yet mapped; inspect their relevant entry
points and extend the map and routes together when their scope is established.

## Requirements and historical evidence

- [Active PRDs](prds/active/): load only the PRD identified by the current task.
- [Archived PRDs](prds/archive/): completed or retired requirement records.
- [Workspace history](history/workspace/) and [task evidence](history/tasks/):
  consult when historical context is needed; they do not authorize task resumption.
- [Historical thinking guides](history/guides/index.md): optional reference,
  not current project contracts and not a code scope to route automatically.

Current contracts remain binding. Historical task plans do not automatically
become contracts. Import provenance is retained under migration/ and is only
needed for migration audits or cleanup, using .neo-trellis/skills/migrate.md.

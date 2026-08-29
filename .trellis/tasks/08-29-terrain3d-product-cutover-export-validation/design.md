# Design — Product cutover and release evidence

Cut over through the existing backend setting rather than deleting fallback
code. Product startup requests native; adapter success activates native; any
bounded failure selects the synchronized fallback. Advanced diagnostics expose
configured versus active state and exact recovery reason.

Use a single scripted product scenario in editor and exported executable. Store
structured state evidence plus representative rendered captures. Automated
checks establish non-black/nonblank state and contract parity; human review owns
subjective material/composition acceptance.

Rollback changes only the configured default back to `soil_shader`.

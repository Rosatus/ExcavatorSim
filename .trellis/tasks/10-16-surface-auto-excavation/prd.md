# LandXML 作业面自动切削

## Goal
从 LandXML 目标 TIN 与当前体素地表差值生成切削任务，按作业点分组、贪心选择下一点，复用辅助控制运动学执行定点切削，再移动至下一点。验收使用 SY135 / urban，出生铲斗轴线向后延伸一斗宽深沟，保持朝向并直线倒退，不回转、不填方。

## Milestones
1. 任务分割与可测量完成条件；缺测不能算完成。
2. 定点执行与命令仲裁；复用 AssistRateSolver 和现有地形切削链路。
3. 显式倒车导航、LandXML/UI 入口与 urban 示例。
4. Agent automated: focused planner/lifecycle tests and urban end-to-end physical excavation test. Human manual: urban workflow and motion/readability review pending.

## Constraints
Godot/Jolt remains the only motion writer; no direct terrain editing to simulate completion. Manual takeover, focus/menu pause, reset/model/attachment changes stop automatic commands. Only main agent edits.

## Progress
Read workflow, delegation, validation and frontend authority, LandXML, driving and joint contracts. Current navigation is forward-only: rear waypoint currently triggers a 180 degree pivot. Must implement explicit reverse navigation semantics. Existing DTM sampler reads current SDF; existing AssistRateSolver supports shared constrained joint-rate control.

## Next
Implement pure task planner and reverse navigation; integrate fixed-point executor through the production controller and validate against actual urban terrain.

## Checkpoint 2026-10-16
Implemented initial SurfaceJobExecutor, public runtime equipment_context, controller job API/arbitration, DTM buttons and 2m x bucket-width x1m axis-trench XML generation, explicit reverse WaypointDriver. Fixed independent navigation start/resume exclusion, attachment manual takeover cancellation and final lift following review.

MCP connection confirmed via authenticated local HTTP (tool discovery did not expose godot-ai): project ExcavatorSim, 4.7.2 custom_build, no_scene, stopped. No credentials persisted.

Agent automated evidence:
- Headless import completed, no new parse errors; existing map UID/shutdown warnings.
- urban-out.log: production physics, LandXML parser and planner, 2 stations x5 vertices, actual SDF cutting, 1m reverse relocation. Completed ~179 simulated seconds. This run only checked centerline completion.
- urban-coverage-out.log: after final-lift and arbitration fixes, completed at frame11147 (~186 seconds), final lifted tooth Y1.870645. 100 independent samples across 2m x0.8m interior: remaining height max -0.056859m, min -0.211872m; yaw0deg, lateral0m. Coverage gate checks only remaining cut so its pass is NOT precision acceptance: overcut up to21cm remains unresolved. Simple digging explicitly enabled by test; no direct terrain or pose edits.

Open findings / exact Next:
1. Planner only samples lane center and executor only verifies those vertices. Add full footprint sampling, triangle sliver coverage, unknown fail closed, and final area verification. Independent test currently covers interior100 samples but product completion does not.
2. Fix overcut: current control uses tooth instead of lowest exterior contact and relaxed solver changes pitch. Diagnose actual tool sweep/exterior geometry; control lowest contact against design and add lower-bound depth assertion. Do not relax test to hide21cm overcut.
3. Add arrival heading alignment for multi-lane station transfers; existing navigation changes heading but station axis stays fixed.
4. Explicit soil capacity policy: test requires simple digging. Product start currently neither requires it nor scopes it automatically. Decide within acceptance scope, expose clear UI requirement and fail before unsupported full bucket execution.
5. Add lifecycle/plan focused tests (pause/resume, world/attachment change, unknown, fill-only, greedy order, reverse). Validate cumulative modified files. Improve UI job status and cancel when selected design changes. Current operator_ui calls DTM private surface setters; replace with public API.
6. Urban final acceptance remains INCOMPLETE due precision and coverage gaps. No rendered runtime pass yet. Keep task in_progress.

## Latest checkpoint — review fixes and precision
Supersedes earlier tooth-only precision findings. Executor now queries the real native cutting brush envelope (including voxel dilation), controls its lowest point, performs a short horizontal finishing sweep, and reapproaches from clearance after lost engagement. Final lift runs full lane-width SDF verification. Added station orientation phase and drive arbitration, simple-digging prerequisite, design-change cancellation, DTM job status and public surface loading API.

Validated reentry-out.log: urban SY135 2m x1m x1m LandXML trench, 2 stations, ~183.7s simulated. Product100 samples [-0.017443,+0.054463]m; independent100 samples [-0.018205,+0.052383]m; yaw0deg/lateral0m, final lift complete. Acceptance test now checks BOTH +/-0.08m. This is headless physical simulation, not rendered UI acceptance. Earlier envelope/sweep failures preserved; reentry addresses lost cut admission.

Final review corrections implemented:
- Planner preserves initial height for every verification sample. grade_accepted allows existing fill deficit while rejecting new loss below min(design,initial)-0.08m. No filling tasks generated.
- Race enable cancels surface job; resume rejects race; fixed-tick arbitration cancels stale race job ownership.
- contract-final-out.log SURFACE_JOB_CONTRACT PASS, exit0. Includes mixed cut/fill baseline, preserved fill, new overcut/residual cut rejection, race cancellation/resume exclusion, greedy order, unknown shoulder, reverse without pivot, explicit pause/cancel.
- lifecycle-out.log NAVIGATION_LIFECYCLE PASS. git diff --check passed (existing CRLF normalization warnings only).

Remaining before full handoff: run acceptance through actual DTM UI entry (test currently builds equivalent XML directly); optional authorized rendered MCP runtime observation; document exact supported limitations and commands; inspect expensive per-tick envelope construction/private cutter API for bounded reuse. Multi-lane heading code is present but not yet physically validated. Planner explicitly rejects unsupported transverse variation/discrete slivers; it is not a general obstacle/collision planner. Do not claim full arbitrary-surface or UI acceptance. Keep task in_progress until remaining acceptance scope handled.

## Final acceptance — DTM entry completed
Actual DTM controls now drive the urban regression: open panel, emit current-axis-trench button pressed, require parsed surface, emit automatic button pressed. Removed duplicate test XML construction and verbose cutter diagnostics. Button names clarify current axis and full automatic control.
Final production-code checks: dtm-final-out.log completed at frame12207; product100 samples [-0.011833,+0.056753]m, independent100 [-0.005070,+0.054393]m, yaw0deg/lateral0m. D3D12 Forward+ run dtm-rendered-out.log completed at frame12002; product100 [-0.012324,+0.051808]m, independent100 [-0.004725,+0.055803]m, yaw0deg/lateral0m. Both satisfy +/-0.08m, 2 stations with 5 targets each, reverse transfer and final lift. Rendered run uses ordinary GPU rendering and automated button signals, not a human mouse/visual approval. Existing map material/UID and optional CAN gateway warnings remain; no SCRIPT ERROR/ERROR in final rendered stderr.
MCP editor state confirmed ExcavatorSim / Godot4.7.2 custom_build; standalone acceptance process launched through pinned executable. Contract-final and navigation lifecycle evidence remains applicable. Documentation now explains DTM operation, simple-digging requirement, reverse support and supported geometry limits. No arbitrary multi-lane physical acceptance claimed. Optional envelope API/per-tick allocation refactoring deferred to avoid unrelated churn; accepted geometry unchanged.
Requested urban functional simulation acceptance complete. Changes remain uncommitted.

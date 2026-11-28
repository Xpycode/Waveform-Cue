# Waveform Cue

Last updated: 2026-11-28

## Now

**Phase:** Implementation. <!-- Phase changed: 2026-11-28 -->

Current machine: **M4 Pro, macOS 15.8.1**. Build 18 is on local `main` and `feature/appearance-panes`. [Current handoff](sessions/evidence/appearance-panes-wave4/integration.md#release-handoff)

**Execution:** [Appearance panes plan](IMPLEMENTATION_PLAN-appearance-panes.md), 13/13 complete. Wave 4 (P4.1–P4.4) is complete and build 18 awaits acceptance. PU1 is approved. Operator acceptance (PX1), VoiceOver (PX2) and macOS 27 picture hashes (PX3) remain open.

**Earlier plan:** [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 26/26 tasks done. X1 passed; X2 partly passed (AVC-Intra exports ingest on EVS); X3 and X4 open.

## Recent

- Build 18 passed 342 tests. Its exported MXF preserved the viewer layout and left the EVS reserve bands clear.
- Each movable pane now has its own Offset. A held stepper redrew the viewer during the gesture and saved the queue once. Build 17 jobs retained their migrated picture after saving.
- The Appearance panes now control picture order, title alignment and clock sides. Atlas verified the inspector through an export and a relaunch.
- All 24 picture orders fit, and all ten sidebar drag trials passed. Wave 2 can build on the tested layout and grip controls.
- Wave 0 captured build 17’s picture and added saved-job migration. All 309 tests passed, and Atlas opened the signed Debug build with its four existing helper jobs.

# Waveform Cue

Last updated: 2026-11-28

## Now

**Phase:** Implementation. <!-- Phase changed: 2026-11-28 -->

Current machine: **M4 Pro, macOS 15.8.1**. Build 19 is the copy for operator testing. [Current handoff](sessions/2026-11-28.md#resume-after-build-19-export)

**Execution:** [Appearance panes plan](IMPLEMENTATION_PLAN-appearance-panes.md), 13/13 implementation tasks complete. Resume operator and EVS acceptance (PX1) after the show. VoiceOver (PX2) and macOS 27 picture hashes (PX3) remain open. PU1 is approved.

**Earlier plan:** [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 26/26 tasks done. X1 passed; X2 partly passed (AVC-Intra exports ingest on EVS); X3 and X4 open.

## Recent

- The operator confirmed a successful export. Build 19 passed both reported safe-zone transitions with the operator’s fonts in Atlas. [Screenshots](sessions/2026-11-28.md#build-19-and-operator-export)
- The custom Bottom reserve now moves the close-up 10 px at the measured boundary. The prior build moved it 165 px. [Preview and export measurements](sessions/evidence/safe-zone-jump/README.md)
- Build 18 passed 342 tests. Its exported MXF preserved the viewer layout and left the EVS reserve bands clear.
- Each movable pane now has its own Offset. A held stepper redrew the viewer during the gesture and saved the queue once. Build 17 jobs retained their migrated picture after saving.
- The Appearance panes now control picture order, title alignment and clock sides. Atlas verified the inspector through an export and a relaunch.

# Waveform Cue

Repo/git: https://github.com/Xpycode/Waveform-Cue (`origin`, public, default branch `main`)

- State: [docs/PROJECT_STATE.md](docs/PROJECT_STATE.md) · Plan: [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) · Tasks: [docs/TASKS.md](docs/TASKS.md)
- Layout follows the Directions folder structure: Xcode project, sources, `CueCore` package and build scripts in `01_Project/`; Directions docs (state, plan, tasks, decisions, sessions, specs) in `docs/`; builds in `04_Exports/` (gitignored).
- House packages come from `../../zPackages` relative to `01_Project/` (that is, `1-macOS/zPackages`), not `~/ProgrammingProjects/zPackages`.
- Regenerate the project with `cd 01_Project && xcodegen generate`.
- Tests run headlessly with `swift test --package-path 01_Project/Packages/CueCore`; `xcodebuild test` would launch the app on the desktop.

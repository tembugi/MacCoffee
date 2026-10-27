# MacCoffee

A native macOS menu bar app (Swift: AppKit with a SwiftUI panel) that keeps the Mac awake, public at https://github.com/tembugi/MacCoffee.

- Build `./build.sh` (`--install` copies to /Applications and relaunches; it refuses while the lid is closed). Tests `Tests/run.sh` simulate the lid, sleep setting, keyboard light and brightness; `.claude/push-tests.sh` runs both.
- Exceptions to the house rules: Swift, not TypeScript (a native Mac app); app text in English (owner, 2026-10-27: a public app). No web, data or deploy rules apply: it collects nothing and runs only on the user's Mac.
- Private macOS frameworks are OK where macOS has no public API (owner, 2026-10-27): keyboard light (CoreBrightness), screen brightness (DisplayServices).
- The README says what the app does, never how (owner).
- The menu bar icon must stay featherlight: frames drawn once, animated by Core Animation, nothing per frame in the app.
- Version in `Info.plist`, shown in the menu; a `CHANGELOG.md` line per release.

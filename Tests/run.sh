#!/bin/bash
# Runs the app's logic with the lid, the sleep setting, the keyboard light and the screen brightness
# simulated, so nothing on this Mac changes. Power assertions are real, but only last while it runs.
set -euo pipefail
cd "$(dirname "$0")/.."

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

sed -e 's/^@main$//' \
    -e 's#"/usr/bin/sudo"#"/usr/bin/false"#' \
    -e 's#NSAppleScript(source: adminAppleScript(value: value))?.executeAndReturnError(&error)#_ = value#' \
    -e 's#    static var isClosed: Bool {#    static var isClosed: Bool { if let fakeLidClosed { return fakeLidClosed }#' \
    -e 's#    static var isDisabled: Bool {#    static var isDisabled: Bool { if let fakeSleepDisabled { return fakeSleepDisabled }#' \
    -e 's#^        run("/usr/bin/pmset", "-g")#        return run("/usr/bin/pmset", "-g")#' \
    -e 's#run("/usr/bin/pmset", "displaysleepnow")#displaySleepNowCalls += 1#' \
    -e 's#KeyboardLight.turnOffForClosedLid()#()#' \
    -e 's#KeyboardLight.keepOn(#_ = (#' \
    -e 's#private static let get = dlsym(framework, "DisplayServicesGetBrightness").*#private static let get: GetFn? = { _, p in p.pointee = fakeBrightness; return 0 }#' \
    -e 's#private static let set = dlsym(framework, "DisplayServicesSetBrightness").*#private static let set: SetFn? = { _, v in fakeBrightness = v; brightnessSets.append(v); return 0 }#' \
    -e 's#private func updateLidState#func updateLidState#' \
    Sources/MacCoffee.swift > "$out/App.swift"

# Never test against the real Mac: stop if any simulation above no longer matches the app's code.
for real in '"/usr/bin/sudo"' 'executeAndReturnError' '"displaysleepnow"' 'KeyboardLight.turnOffForClosedLid()' \
            'KeyboardLight.keepOn(' 'dlsym(framework, "DisplayServicesSetBrightness")' 'private func updateLidState'; do
    if grep -qF "$real" "$out/App.swift"; then
        echo "Tests/run.sh: the simulation no longer covers $real in Sources/MacCoffee.swift" >&2
        exit 1
    fi
done
for fake in 'fakeLidClosed {' 'fakeSleepDisabled {' 'return run("/usr/bin/pmset", "-g")'; do
    grep -qF "$fake" "$out/App.swift" || { echo "Tests/run.sh: couldn't simulate $fake" >&2; exit 1; }
done

xcrun swiftc -parse-as-library -swift-version 5 -suppress-warnings -target "$(uname -m)-apple-macos14.0" \
    "$out/App.swift" Tests/LidTests.swift -o "$out/tests"
"$out/tests"

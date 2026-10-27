import Foundation

// What Tests/run.sh simulates in place of the real Mac.
nonisolated(unsafe) var fakeLidClosed: Bool? = false
nonisolated(unsafe) var fakeSleepDisabled: Bool? = false
nonisolated(unsafe) var fakeBrightness: Float = 0.47
nonisolated(unsafe) var brightnessSets: [Float] = []
nonisolated(unsafe) var displaySleepNowCalls = 0

nonisolated(unsafe) var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "pass" : "FAIL", name, ok ? "" : detail())
    if !ok { failures += 1 }
}

/// The power assertions this test process holds right now, by name.
func held() -> [String] {
    let pmset = Process()
    pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    pmset.arguments = ["-g", "assertions"]
    let pipe = Pipe()
    pmset.standardOutput = pipe
    try! pmset.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return output.split(separator: "\n")
        .filter { $0.contains("pid \(getpid())(") }
        .compactMap { $0.components(separatedBy: "named: \"MacCoffee: ").last.map { String($0.prefix { $0 != "\"" }) } }
        .sorted()
}

@main
struct LidTests {
    static func main() {
        MainActor.assumeIsolated {
            let model = AwakeModel.shared
            fakeSleepDisabled = true
            model.refresh()
            check("Stay Awake is on", model.lidClosedMode)

            fakeLidClosed = true
            model.updateLidState()
            check("Keep Screen On off: closing the lid turns the screen off", displaySleepNowCalls == 1)
            check("Keep Screen On off: nothing keeps the screen on", held().isEmpty, "\(held())")
            check("Keep Screen On off: brightness is left alone", brightnessSets.isEmpty, "\(brightnessSets)")
            fakeLidClosed = false
            model.updateLidState()

            model.keepScreenOnWhenClosed = true
            check("Keep Screen On on, lid open: nothing held yet", held().isEmpty, "\(held())")
            fakeLidClosed = true
            model.updateLidState()
            check("Keep Screen On on: closing the lid keeps the screen on",
                  held() == ["Keep Display On", "Prevent Screen Lock"], "\(held())")
            check("Keep Screen On on: the screen dims to minimum", brightnessSets == [ScreenBrightness.minimum], "\(brightnessSets)")
            check("Keep Screen On on: the screen isn't turned off", displaySleepNowCalls == 1)
            fakeLidClosed = false
            model.updateLidState()
            check("opening the lid restores the brightness", brightnessSets.last == 0.47, "\(brightnessSets)")
            check("opening the lid releases the screen", held().isEmpty, "\(held())")

            fakeLidClosed = true
            model.updateLidState()
            fakeSleepDisabled = false
            model.refresh()
            check("turning Stay Awake off with the lid shut releases the screen", held().isEmpty, "\(held())")
            model.prepareForQuit()
            check("quitting while dimmed restores the brightness", brightnessSets.last == 0.47, "\(brightnessSets)")
            fakeLidClosed = false
            model.updateLidState()

            model.turnEverythingOff(askForPassword: false)
            check("Turn All Off turns Keep Screen On off", !model.keepScreenOnWhenClosed)
            model.turnEverythingOn()
            check("Turn All On turns Keep Screen On on", model.keepScreenOnWhenClosed)
            model.turnEverythingOff(askForPassword: false)

            print(failures == 0 ? "All tests passed" : "\(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

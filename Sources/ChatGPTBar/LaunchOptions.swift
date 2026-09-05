import Foundation

/// Developer/QA launch flags:
/// `--settings [tab]`           open the settings window on launch
///                             (tab: general | shortcuts | page)
/// `--dev-report <path>`        write a JSON diagnostic report
/// `--url <url>`               page to diagnose instead of the home page
/// `--settle <seconds>`        how long to sample frame gaps (default 6)
/// `--ab`                      second pass with the long-conversation tweak flipped
/// `--force-optimization 0|1`  override the long-conversation tweak for this run
/// `--probe-composer`          type a probe string so the send button exists, then dump
/// `--exit-after-report`       quit once the report is written
struct LaunchOptions {
    var openSettings = false
    var settingsTab: SettingsTab = .general
    var reportPath: String?
    var url: URL?
    var settle: TimeInterval = 6
    var abCompare = false
    var forceOptimization: Bool?
    var probeComposer = false
    var exitAfterReport = false

    static func parse(_ arguments: [String] = CommandLine.arguments) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            func next() -> String? {
                guard index + 1 < arguments.count else { return nil }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--settings":
                options.openSettings = true
                if index + 1 < arguments.count, let tab = SettingsTab(rawValue: arguments[index + 1]) {
                    options.settingsTab = tab
                    index += 1
                }
            case "--dev-report":
                options.reportPath = next()
            case "--url":
                options.url = next().flatMap(URL.init(string:))
            case "--settle":
                options.settle = next().flatMap(Double.init) ?? options.settle
            case "--ab":
                options.abCompare = true
            case "--force-optimization":
                options.forceOptimization = next().map { $0 == "1" || $0.lowercased() == "true" }
            case "--probe-composer":
                options.probeComposer = true
            case "--exit-after-report":
                options.exitAfterReport = true
            default:
                break
            }
            index += 1
        }
        return options
    }
}

enum DevReportWriter {
    static func write(_ report: [String: Any], to path: String) -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url)
            return "dev-report written: \(url.path)"
        } catch {
            return "dev-report failed: \(error.localizedDescription)"
        }
    }
}

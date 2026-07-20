import AppIntents
import SwiftUI
import WidgetKit

// M7b (U10): the Control Center / Lock Screen scan button — the shed-door
// use case. This extension is deliberately dependency-free (no GRDB, no app
// code): it's a button whose only job is opening the M7a scan route; the
// app's tested deep-link path (DL73) does the rest.

@main
struct ClutterCatcherControlsBundle: WidgetBundle {
    var body: some Widget {
        ScanControl()
    }
}

struct ScanControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.rixun.cluttercatcher.scan-control") {
            ControlWidgetButton(action: OpenScannerControlIntent()) {
                Label("Scan a Bin", systemImage: "qrcode.viewfinder")
            }
        }
        .displayName("Scan a Bin")
        .description("Opens the ClutterCatcher scanner.")
    }
}

/// The launch intent. `cluttercatcher://scan` selects the Scan tab exactly
/// as a tap would; the literal here must match the app's `QRPayload.scheme`
/// + `DeepLink.scanHost` (not imported — the extension stays code-free of
/// the app by design, and the URL is a frozen contract since M7a).
struct OpenScannerControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Scanner"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "cluttercatcher://scan")!))
    }
}

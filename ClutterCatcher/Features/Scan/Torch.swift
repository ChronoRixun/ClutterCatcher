import AVFoundation

/// U1: the torch button's logic, kept apart from the hardware call so the
/// visibility and reset rules stay testable where no torch exists — the
/// simulator has neither camera nor torch, so actual torch behavior rides
/// the on-device VERIFY.
struct TorchModel: Equatable {
    /// Whether this device has a torch at all; the button exists only then.
    let isAvailable: Bool
    private(set) var isOn = false

    var buttonVisible: Bool { isAvailable }

    mutating func toggle() {
        guard isAvailable else { return }
        isOn.toggle()
    }

    /// DL11 discipline: whenever the scanner stops — tab switch, result card
    /// up, scene backgrounded, teardown — the torch goes out with it.
    mutating func scannerStopped() {
        isOn = false
    }
}

/// The isolated hardware seam. `DataScannerViewController` owns its capture
/// session and exposes no torch control; the standard coexistence technique
/// is locking the default video device and setting `torchMode` while the
/// scanner's session runs (U1 — outcome logged as a DL).
enum Torch {
    static var deviceHasTorch: Bool {
        AVCaptureDevice.default(for: .video)?.hasTorch == true
    }

    static func apply(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            Log.app.error("Torch configuration failed: \(String(describing: error))")
        }
    }
}

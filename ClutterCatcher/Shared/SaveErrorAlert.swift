import SwiftUI

/// A failed write must never look like a successful one: editors keep their
/// sheet open and surface this alert instead of silently logging.
extension View {
    func saveErrorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Couldn't Save",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

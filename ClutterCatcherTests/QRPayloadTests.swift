import Foundation
import Testing
@testable import ClutterCatcher

@Suite struct QRPayloadTests {
    private let uuid = UUID(uuidString: "24402771-2003-49A1-B676-A16C284102B3")!

    @Test func containerPayloadRoundTrips() {
        let payload = QRPayload.container(uuid)
        #expect(payload.absoluteString == "cluttercatcher://c/24402771-2003-49A1-B676-A16C284102B3")
        #expect(QRPayload.parse(scanned: payload.absoluteString) == payload)
        #expect(QRPayload.parse(url: payload.url) == payload)
    }

    @Test func roomPayloadRoundTrips() {
        let payload = QRPayload.room(uuid)
        #expect(payload.absoluteString == "cluttercatcher://r/24402771-2003-49A1-B676-A16C284102B3")
        #expect(QRPayload.parse(scanned: payload.absoluteString) == payload)
    }

    @Test func bareUUIDParsesAsContainer() {
        #expect(QRPayload.parse(scanned: uuid.uuidString) == .container(uuid))
    }

    @Test func lowercaseAndWhitespaceAreTolerated() {
        #expect(QRPayload.parse(scanned: "  24402771-2003-49a1-b676-a16c284102b3\n") == .container(uuid))
        #expect(QRPayload.parse(scanned: "cluttercatcher://c/24402771-2003-49a1-b676-a16c284102b3") == .container(uuid))
    }

    @Test func garbageIsRejected() {
        #expect(QRPayload.parse(scanned: "hello world") == nil)
        #expect(QRPayload.parse(scanned: "") == nil)
        #expect(QRPayload.parse(scanned: "https://c/24402771-2003-49A1-B676-A16C284102B3") == nil)
        #expect(QRPayload.parse(scanned: "cluttercatcher://x/24402771-2003-49A1-B676-A16C284102B3") == nil)
        #expect(QRPayload.parse(scanned: "cluttercatcher://c/not-a-uuid") == nil)
        #expect(QRPayload.parse(scanned: "cluttercatcher://c/") == nil)
    }

    @Test func extraPathComponentsAreRejected() {
        #expect(QRPayload.parse(scanned: "cluttercatcher://c/24402771-2003-49A1-B676-A16C284102B3/extra") == nil)
    }
}

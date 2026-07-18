import Foundation
import Testing
@testable import ClutterCatcher

@Suite struct DeepLinkTests {
    private let uuid = UUID(uuidString: "24402771-2003-49A1-B676-A16C284102B3")!

    @Test func containerLinkRoutesToContainer() throws {
        let url = try #require(URL(string: "cluttercatcher://c/24402771-2003-49A1-B676-A16C284102B3"))
        #expect(Route(deepLink: url) == .container(id: uuid.uuidString))
    }

    @Test func roomLinkRoutesToRoom() throws {
        let url = try #require(URL(string: "cluttercatcher://r/24402771-2003-49A1-B676-A16C284102B3"))
        #expect(Route(deepLink: url) == .room(id: uuid.uuidString))
    }

    @Test func lowercaseLinkNormalizesToUppercaseID() throws {
        let url = try #require(URL(string: "cluttercatcher://c/24402771-2003-49a1-b676-a16c284102b3"))
        // DB primary keys are uppercase UUID strings; routing must normalize.
        #expect(Route(deepLink: url) == .container(id: "24402771-2003-49A1-B676-A16C284102B3"))
    }

    @Test func foreignURLsAreIgnored() throws {
        let https = try #require(URL(string: "https://example.com/c/24402771-2003-49A1-B676-A16C284102B3"))
        #expect(Route(deepLink: https) == nil)
        let badHost = try #require(URL(string: "cluttercatcher://settings"))
        #expect(Route(deepLink: badHost) == nil)
        let badUUID = try #require(URL(string: "cluttercatcher://c/xyz"))
        #expect(Route(deepLink: badUUID) == nil)
    }
}

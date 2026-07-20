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

    // MARK: cluttercatcher://scan (M7a — U10's prerequisite)

    @Test func scanLinkParsesAsTheScanDeepLink() throws {
        let url = try #require(URL(string: "cluttercatcher://scan"))
        #expect(DeepLink(url: url) == .scan)
    }

    @Test func scanLinkIsCaseInsensitive() throws {
        let url = try #require(URL(string: "CLUTTERCATCHER://Scan"))
        #expect(DeepLink(url: url) == .scan)
    }

    @Test func scanLinkRejectsExtraPathComponents() throws {
        let url = try #require(URL(string: "cluttercatcher://scan/now"))
        #expect(DeepLink(url: url) == nil)
    }

    @Test func catalogLinksParseAsCatalogDeepLinks() throws {
        let container = try #require(URL(string: "cluttercatcher://c/24402771-2003-49A1-B676-A16C284102B3"))
        #expect(DeepLink(url: container) == .catalog(.container(id: uuid.uuidString)))
        let room = try #require(URL(string: "cluttercatcher://r/24402771-2003-49A1-B676-A16C284102B3"))
        #expect(DeepLink(url: room) == .catalog(.room(id: uuid.uuidString)))
    }

    @Test func foreignURLsAreNotDeepLinksEither() throws {
        let https = try #require(URL(string: "https://example.com/scan"))
        #expect(DeepLink(url: https) == nil)
        let badHost = try #require(URL(string: "cluttercatcher://settings"))
        #expect(DeepLink(url: badHost) == nil)
    }

    @Test @MainActor func routerScanLinkSelectsScanTabExactlyLikeATap() throws {
        let url = try #require(URL(string: "cluttercatcher://scan"))
        let router = Router()
        router.selectedTab = .rooms
        router.catalogPath = [.room(id: "ROOM")]
        router.open(url: url)
        #expect(router.selectedTab == .scan)
        #expect(router.catalogPath == [.room(id: "ROOM")], "a tab tap never touches the catalog stack")
        #expect(router.rejectedDeepLink == nil)
    }

    @Test @MainActor func routerStillRejectsUnknownSchemeHosts() throws {
        let url = try #require(URL(string: "cluttercatcher://settings"))
        let router = Router()
        router.open(url: url)
        #expect(router.rejectedDeepLink == url)
        #expect(router.selectedTab == .rooms)
    }
}

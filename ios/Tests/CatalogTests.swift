import XCTest
@testable import Sever

@MainActor
private final class TestStorage: ProfileStorage {
    var initial = SavedState()
    var loadError: Error?
    var saveError: Error?
    var saved: SavedState?
    func load() throws -> SavedState { if let loadError { throw loadError }; return initial }
    func save(_ state: SavedState) throws { if let saveError { throw saveError }; saved = state }
}

@MainActor
private final class TestCatalog: CatalogLoading {
    var result: CatalogResult?
    var error: Error?
    func load(progress: (String) -> Void) async throws -> CatalogResult {
        progress("Загружаем тестовый каталог")
        if let error { throw error }
        return result!
    }
}

final class CatalogTests: XCTestCase {
    private func seed(_ name: String = "Test") -> ProfileSeed {
        let host = name == "Second" ? "203.0.113.6" : "203.0.113.5"
        return ProfileSeed(name: name, engine: .openvpn, configuration: "client\nproto tcp\nremote \(host) 443\n<ca>TEST</ca>\n", host: host, port: 443, country: "JP", source: "vpngate", nodes: 1)
    }
    private func bootstrap(_ name: String = "Initial") -> BundledCatalog {
        BundledCatalog(fetchedAt: Date().timeIntervalSince1970, profiles: [seed(name)])
    }

    @MainActor
    func testActualAppBundleContainsBootstrapCatalog() throws {
        let snapshot = try XCTUnwrap(BundledCatalog.load())
        XCTAssertFalse(snapshot.profiles.isEmpty)
        XCTAssertLessThanOrEqual(snapshot.profiles.count, 30)
        XCTAssertTrue(snapshot.profiles.allSatisfy { $0.engine == .openvpn && !$0.configuration.isEmpty })
    }

    @MainActor
    func testNativeHTTPAndJavaScriptCoreReadLivePublicCatalog() async throws {
        let service = CatalogService(core: try ConfigurationCore())
        let result = try await service.load { _ in }
        XCTAssertFalse(result.profiles.isEmpty)
        XCTAssertLessThanOrEqual(result.profiles.count, 30)
    }

    @MainActor
    func testFirstLaunchHasServersEvenWhenNetworkAndStorageFail() async throws {
        let storage = TestStorage()
        storage.loadError = SeverError.message("Keychain: Код -34018")
        let source = TestCatalog(); source.error = URLError(.timedOut)
        let store = AppStore(storage: storage, bootstrap: bootstrap(), catalog: source)
        XCTAssertEqual(store.profiles.count, 1)
        await store.updateFreeServers()
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertNotNil(store.selected)
        XCTAssertTrue(store.catalogError?.contains("-1001") == true)
        XCTAssertNotNil(store.storageWarning)
        XCTAssertNil(storage.saved)
        XCTAssertFalse(store.busy)
    }

    @MainActor
    func testDownloadedServersRemainVisibleWhenSavingFails() async throws {
        let storage = TestStorage(); storage.saveError = SeverError.message("Keychain: Код -34018")
        let source = TestCatalog()
        source.result = CatalogResult(profiles: [seed("Downloaded"), seed("Second")], fetchedAt: Date(), sourceName: "Тест")
        let store = AppStore(storage: storage, bootstrap: bootstrap(), catalog: source)
        await store.updateFreeServers()
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertNil(store.catalogError)
        XCTAssertTrue(store.storageWarning?.contains("-34018") == true)
        XCTAssertTrue(store.catalogStatus.contains("2"))
    }

    @MainActor
    func testRefreshPreservesPersonalProfiles() async throws {
        let storage = TestStorage()
        let personal = ServerProfile(id: "personal", name: "Personal", engine: .xray, configuration: "synthetic-private-fixture", host: "", port: 0, country: "", source: "import", nodes: 1, latency: nil)
        storage.initial.profiles = [personal]
        let source = TestCatalog()
        source.result = CatalogResult(profiles: [seed()], fetchedAt: Date(), sourceName: "Тест")
        let store = AppStore(storage: storage, bootstrap: bootstrap(), catalog: source)
        await store.updateFreeServers()
        XCTAssertEqual(store.profiles.first(where: { $0.id == "personal" }), personal)
        XCTAssertEqual(storage.saved?.profiles.count, 2)
    }

    @MainActor
    func testReserveSourceIsUsedAfterPrimaryTimeout() async throws {
        let core = try ConfigurationCore()
        let openvpn = "client\nproto tcp\nremote 203.0.113.5 443\n<ca>TEST</ca>\n"
        let encoded = Data(openvpn.utf8).base64EncodedString()
        let csv = "*vpn_servers\n#HostName,IP,Score,CountryLong,CountryShort,OpenVPN_ConfigData_Base64\ntest,203.0.113.5,1,Japan,JP,\(encoded)\n*\n"
        var hosts: [String] = []
        let service = CatalogService(core: core) { url in
            hosts.append(url.host!)
            if hosts.count == 1 { throw URLError(.timedOut) }
            return Data(csv.utf8)
        }
        let result = try await service.load { _ in }
        XCTAssertEqual(hosts, ["www.vpngate.net", "download.vpngate.jp"])
        XCTAssertEqual(result.profiles.count, 1)
        XCTAssertEqual(result.sourceName, "Резервный каталог")
    }

    func testErrorDescriptionNeverEchoesSubscriptionURL() {
        let secret = "https://private.invalid/subscription/SECRET"
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: secret, NSLocalizedDescriptionKey: secret])
        let message = UserFacingErrors.text(error)
        XCTAssertFalse(message.contains("SECRET"))
        XCTAssertTrue(message.contains("-1001"))
    }
}

import XCTest
import OpenVPNAdapter
@testable import Sever

final class TunnelPluginTests: XCTestCase {
    private func info(id: String, engine: String? = nil, executable: String = "SeverOpenVPNTunnel") -> [String: Any] {
        var value: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": executable,
                                   "NSExtension": ["NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"]]
        if let engine { value["SeverTunnelEngine"] = engine }
        return value
    }

    func testUsesActualExtensionIdentifierAfterResigning() throws {
        let plugin = try XCTUnwrap(TunnelPlugin(info: info(id: "signed.account.random.plugin42", engine: "openvpn")))
        XCTAssertEqual(try TunnelPlugins.identifier(for: .openvpn, in: [plugin]), "signed.account.random.plugin42")
    }

    func testOldBundleWithoutMarkerCanBeRecognizedByExecutable() throws {
        let plugin = try XCTUnwrap(TunnelPlugin(info: info(id: "rewritten.extension.name")))
        XCTAssertEqual(plugin.engine, .openvpn)
        XCTAssertEqual(plugin.identifier, "rewritten.extension.name")
    }

    func testInstalledAppContainsBothActualTunnelPlugins() throws {
        let plugins = try TunnelPlugins.installed()
        XCTAssertEqual(plugins.count, 2)
        XCTAssertFalse(try TunnelPlugins.identifier(for: .openvpn, in: plugins).isEmpty)
        XCTAssertFalse(try TunnelPlugins.identifier(for: .xray, in: plugins).isEmpty)
    }

    func testMissingAndAmbiguousExtensionsAreRejected() throws {
        XCTAssertThrowsError(try TunnelPlugins.identifier(for: .xray, in: []))
        let first = try XCTUnwrap(TunnelPlugin(info: info(id: "one", engine: "xray")))
        let second = try XCTUnwrap(TunnelPlugin(info: info(id: "two", engine: "xray")))
        XCTAssertThrowsError(try TunnelPlugins.identifier(for: .xray, in: [first, second]))
    }

    func testUnknownSystemErrorDoesNotExposeItsUserInfo() {
        let error = NSError(domain: "third.party", code: 7, userInfo: [NSLocalizedDescriptionKey: "password=PRIVATE"])
        XCTAssertFalse(VPNFailure.text(error).contains("PRIVATE"))
        XCTAssertTrue(VPNFailure.text(error).contains("7"))
    }

    func testBundledPublicProfilePassesNativeOpenVPNConfigurationValidation() throws {
        let snapshot = try XCTUnwrap(BundledCatalog.load())
        let profile = try XCTUnwrap(snapshot.profiles.first)
        let configuration = OpenVPNConfiguration()
        configuration.fileContent = Data(profile.configuration.utf8)
        configuration.tunPersist = true
        configuration.connectionTimeout = 25
        configuration.disableClientCert = !profile.configuration.lowercased().contains("<cert>")
        let adapter = OpenVPNAdapter()
        do { _ = try adapter.applyConfiguration(configuration) }
        catch { XCTFail("Native OpenVPN rejected the public profile; code \((error as NSError).code)") }
        // Configuration validation only: never connect, create a TUN, alter routes or transmit credentials.
    }
}

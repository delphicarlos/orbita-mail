import XCTest
@testable import OrbitaCore

final class ImportTests: XCTestCase {
    func testAccountsAreDeduplicatedWithoutGrantingAuthentication() throws {
        let raw = #"{"version":1,"accounts":[{"email":"Person@Example.com","displayName":"Person","provider":"microsoft","sourceKind":"Exchange"},{"email":"person@example.com","displayName":"Duplicate","provider":"microsoft","sourceKind":"Exchange"}]}"#
        let value = try OutlookImportManifest.parse(Data(raw.utf8))
        XCTAssertEqual(value.accounts.count, 1)
        XCTAssertEqual(value.accounts[0].email, "person@example.com")
        XCTAssertEqual(value.accounts[0].provider, .microsoft)
    }
    func testCredentialsAreNotCopiedFromAnImportFile() throws {
        let raw = #"{"accounts":[{"email":"person@example.com","displayName":"Person","provider":"google","sourceKind":"IMAP","password":"DO-NOT-PERSIST","accessToken":"DO-NOT-PERSIST"}],"refresh_token":"DO-NOT-PERSIST"}"#
        let manifest = try OutlookImportManifest.parse(Data(raw.utf8))
        let saved = String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!
        XCTAssertFalse(saved.contains("DO-NOT-PERSIST")); XCTAssertFalse(saved.contains("password")); XCTAssertFalse(saved.contains("accessToken"))
    }
    func testProviderDetectionDoesNotGuessGoogleFromCustomDomain() {
        XCTAssertEqual(ImportedAccount.outlook(kind: "IMAP", email: "p@custom.example", name: "P", server: "imap.gmail.com").provider, .google)
        XCTAssertEqual(ImportedAccount.outlook(kind: "Exchange", email: "p@custom.example", name: "P", server: "").provider, .microsoft)
        XCTAssertEqual(ImportedAccount.outlook(kind: "IMAP", email: "p@custom.example", name: "P", server: "imap.custom.example").provider, .imap)
    }
    func testInvalidVersionEmptyImportAndOversizedFilesAreRejected() {
        for value in [#"{"version":2,"accounts":[]}"#, #"{"installed":{"client_id":"not-an-account-export"}}"#, #"{"accounts":[]}"#] {
            XCTAssertThrowsError(try OutlookImportManifest.parse(Data(value.utf8)))
        }
        XCTAssertThrowsError(try OutlookImportManifest.parse(Data(count: 2_000_001)))
    }
    func testPresetIDsAreStableAndModelsKeepTheirAccountAssociation() throws {
        let preset = WritingPreset(name: "Follow-up", text: "Olá!", subject: "Retorno", accountEmail: "p@example.com", kind: .template)
        let signature = WritingPreset(name: "Follow-up", text: "Olá!", accountEmail: "p@example.com", kind: .signature)
        let value = try OutlookImportManifest(accounts: [], presets: [preset, preset, signature]).validated()
        XCTAssertEqual(value.presets.count, 2)
        XCTAssertNotEqual(preset.id, signature.id)
        XCTAssertEqual(value.presets[0].accountEmail, "p@example.com")
        XCTAssertEqual(try JSONDecoder().decode(WritingPreset.self, from: JSONEncoder().encode(preset)).id, preset.id)
    }
    func testImportedIdentityMustMatchTheAuthorizedProviderProfile() throws {
        XCTAssertNoThrow(try OAuth.validateIdentity(expectedEmail: "P@EXAMPLE.COM", actualEmail: "p@example.com"))
        XCTAssertThrowsError(try OAuth.validateIdentity(expectedEmail: "p@example.com", actualEmail: "other@example.com"))
        XCTAssertNoThrow(try OAuth.validateIdentity(expectedEmail: nil, actualEmail: "other@example.com"))
    }
    func testOAuthHintKeepsSelectedImportedEmail() throws {
        let url = try OAuth.authorizationURL(provider: .google, clientID: "client", redirect: "http://127.0.0.1:123/oauth/callback", state: "state", verifier: "verifier", loginHint: "p+work@example.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "login_hint" }?.value, "p+work@example.com")
    }
}

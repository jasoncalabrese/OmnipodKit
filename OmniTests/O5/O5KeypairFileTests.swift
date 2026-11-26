//
//  O5KeypairFileTests.swift
//  OmniTests
//
//  Export and import of `.o5keypair` files. Uses a freshly generated key and a
//  stand-in certificate (just the P-256 public key block that
//  O5CertificateStore.extractP256PublicKey looks for), never a real certificate.
//

import XCTest
import CryptoKit
@testable import OmnipodKit

final class O5KeypairFileTests: XCTestCase {

    /// The DER block that precedes a P-256 public key in a certificate.
    private let p256KeyBlockHeader = Data([
        0x30, 0x59, 0x30, 0x13,
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
        0x03, 0x42, 0x00, 0x04,
    ])

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func standInCertificate(for publicKey: Data) -> Data {
        Data([0x30, 0x82, 0x01, 0x00, 0xa0, 0x03, 0x02, 0x01, 0x02])
            + p256KeyBlockHeader + publicKey + Data(repeating: 0x05, count: 16)
    }

    private func makeRegistration(
        controllerId: UInt32 = 0x002A_1B2C,
        publicKeyOverride: Data? = nil,
        certificateKey: Data? = nil,
        privateKeyHexOverride: String? = nil
    ) -> O5RegistrationData {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        return O5RegistrationData(
            controllerId: controllerId,
            privateKeyHex: privateKeyHexOverride ?? hex(key.rawRepresentation),
            publicKeyHex: hex(publicKeyOverride ?? publicKey),
            intermediateCABase64: Data(repeating: 0x30, count: 32).base64EncodedString(),
            tlsCertificateBase64: standInCertificate(for: certificateKey ?? publicKey).base64EncodedString()
        )
    }

    private func assertImportFails(_ data: Data, with expected: O5KeypairFileError,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try O5RegistrationData.fromKeypairFile(data), file: file, line: line) { error in
            XCTAssertEqual(error as? O5KeypairFileError, expected, file: file, line: line)
        }
    }

    // MARK: - Export → import

    func testExportedFileImportsUnchanged() throws {
        let original = makeRegistration()
        let imported = try O5RegistrationData.fromKeypairFile(try original.keypairFileData())

        XCTAssertEqual(imported.controllerId, original.controllerId)
        XCTAssertEqual(imported.privateKeyHex, original.privateKeyHex)
        XCTAssertEqual(imported.publicKeyHex, original.publicKeyHex)
        XCTAssertEqual(imported.intermediateCABase64, original.intermediateCABase64)
        XCTAssertEqual(imported.tlsCertificateBase64, original.tlsCertificateBase64)
    }

    /// Exactly the five toJSON fields, so AAPS's importer reads the file too.
    func testExportedFileHasOnlyTheFiveFields() throws {
        let data = try makeRegistration().keypairFileData()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["controllerId", "privateKey", "publicKey", "intermediateCA", "tlsCertificate"])
    }

    func testFilenameCarriesControllerIdInHex() {
        XCTAssertEqual(makeRegistration(controllerId: 0x002A_1B2C).keypairFilename, "Omnipod5-002A1B2C.o5keypair")
    }

    // MARK: - Import rejects bad files

    func testRejectsNonJSON() {
        assertImportFails(Data("not json".utf8), with: .malformed)
    }

    func testRejectsMissingField() throws {
        var json = makeRegistration().toJSON()
        json.removeValue(forKey: "tlsCertificate")
        assertImportFails(try JSONSerialization.data(withJSONObject: json), with: .malformed)
    }

    func testRejectsInvalidPrivateKey() throws {
        let data = try makeRegistration(privateKeyHexOverride: "zz").keypairFileData()
        assertImportFails(data, with: .invalidPrivateKey)
    }

    func testRejectsPublicKeyThatIsNotThePrivateKeys() throws {
        let other = P256.Signing.PrivateKey().publicKey.rawRepresentation
        let data = try makeRegistration(publicKeyOverride: other, certificateKey: other).keypairFileData()
        assertImportFails(data, with: .keyMismatch)
    }

    func testRejectsCertificateForAnotherKey() throws {
        let other = P256.Signing.PrivateKey().publicKey.rawRepresentation
        let data = try makeRegistration(certificateKey: other).keypairFileData()
        assertImportFails(data, with: .certificateKeyMismatch)
    }

    func testRejectsUnreadableCertificate() throws {
        var json = makeRegistration().toJSON()
        json["tlsCertificate"] = "%%% not base64 %%%"
        assertImportFails(try JSONSerialization.data(withJSONObject: json), with: .invalidCertificate)
    }
}

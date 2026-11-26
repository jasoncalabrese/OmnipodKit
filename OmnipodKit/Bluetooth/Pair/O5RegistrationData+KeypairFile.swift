//
//  O5RegistrationData+KeypairFile.swift
//  OmnipodKit
//
//  Reading, checking and writing `.o5keypair` files: the JSON shape of
//  `O5RegistrationData.toJSON()`, which AAPS also reads and writes.
//
//  A keypair file holds the controller's private key. Export exists so a user can
//  keep their own copy and move their Omnipod 5 identity to a new phone without
//  downloading again: the keychain entry is this-device-only and never migrates.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import CryptoKit

enum O5KeypairFileError: LocalizedError, Equatable {
    /// Not JSON, or missing one of the five fields.
    case malformed
    /// The private key isn't a valid P-256 key.
    case invalidPrivateKey
    /// The public key isn't the private key's.
    case keyMismatch
    /// A certificate is missing, isn't base64, or has no P-256 key in it.
    case invalidCertificate
    /// The controller certificate is for a different key.
    case certificateKeyMismatch

    var errorDescription: String? {
        switch self {
        case .malformed:
            return LocalizedString("The selected file is not a valid o5keypair file.", comment: "Error when o5keypair file import fails")
        case .invalidPrivateKey:
            return LocalizedString("The file's private key is not valid.", comment: "o5keypair import error: bad private key")
        case .keyMismatch:
            return LocalizedString("The file's public key does not match its private key.", comment: "o5keypair import error: public key mismatch")
        case .invalidCertificate:
            return LocalizedString("The file's certificates could not be read.", comment: "o5keypair import error: unreadable certificate")
        case .certificateKeyMismatch:
            return LocalizedString("The file's certificate is for a different key.", comment: "o5keypair import error: certificate key mismatch")
        }
    }
}

extension O5RegistrationData {

    /// Checks that the private key, public key and controller certificate belong
    /// together, so a bad file is rejected at import instead of failing at the next
    /// pairing. Doesn't check who issued the certificates; the pod does that.
    func validate() throws {
        guard privateKey.count == 32,
              let signingKey = try? P256.Signing.PrivateKey(rawRepresentation: privateKey)
        else {
            throw O5KeypairFileError.invalidPrivateKey
        }
        guard signingKey.publicKey.rawRepresentation == publicKey else {
            throw O5KeypairFileError.keyMismatch
        }
        guard intermediateCA?.isEmpty == false,
              let certificate = tlsCertificate,
              let certificateKey = O5CertificateStore.extractP256PublicKey(fromDERCert: certificate)
        else {
            throw O5KeypairFileError.invalidCertificate
        }
        guard certificateKey == publicKey else {
            throw O5KeypairFileError.certificateKeyMismatch
        }
    }

    /// Parses and checks the contents of a `.o5keypair` file.
    static func fromKeypairFile(_ data: Data) throws -> O5RegistrationData {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let registration = fromJSON(json)
        else {
            throw O5KeypairFileError.malformed
        }
        try registration.validate()
        return registration
    }

    /// The contents of a `.o5keypair` file for this registration: exactly the five
    /// `toJSON()` fields, so OmnipodKit's and AAPS's importers both read it.
    func keypairFileData() throws -> Data {
        try JSONSerialization.data(withJSONObject: toJSON(), options: [.prettyPrinted, .sortedKeys])
    }

    var keypairFilename: String {
        String(format: "Omnipod5-%08X.o5keypair", controllerId)
    }
}

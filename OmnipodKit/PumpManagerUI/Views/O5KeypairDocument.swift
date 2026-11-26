//
//  O5KeypairDocument.swift
//  OmnipodKit
//
//  The file handed to SwiftUI's file exporter when exporting an Omnipod 5
//  certificate. Holds the bytes only while the export sheet is up.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.o5keypair`, a JSON file. Not declared in the host app's Info.plist, so this
    /// is a dynamic type; importers also accept plain `.json`.
    static let o5keypair = UTType(filenameExtension: "o5keypair", conformingTo: .json) ?? .json
}

struct O5KeypairDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.o5keypair, .json] }
    static var writableContentTypes: [UTType] { [.o5keypair] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

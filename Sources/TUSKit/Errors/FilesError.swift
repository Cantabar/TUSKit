//
//  File.swift
//  
//
//  Created by Tom Greco on 7/24/23.
//

import Foundation

enum FilesError: Error {
    case metaDataFileNotFound(uuid: String)
    case uuidDirectoryNotFound(uuid: String)
    case invalidProvider
}

extension FilesError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .metaDataFileNotFound(uuid):
            return NSLocalizedString("Metadata.plist file could not be found \(uuid)", comment: "RELATED_FILE_NOT_FOUND")
        case let .uuidDirectoryNotFound(uuid):
            return NSLocalizedString("UUID directory for file was not found \(uuid)", comment: "UUID_DIRECTORY_NOT_FOUND")
        case let .invalidProvider:
            return NSLocalizedString("Received invalid TusMetaProvider", comment: "INVALID_TUS_META_PROVIDER")
        default:
            return NSLocalizedString("File error", comment: "FILE_ERROR")
        }
    }
}

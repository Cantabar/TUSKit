import Foundation

/// The errors that are passed from TUSClient
public enum TUSClientError: Error {
    case couldNotCopyFile(underlyingError: Error)
    case couldNotStoreFile(underlyingError: Error)
    case fileSizeUnknown
    case couldNotLoadData(underlyingError: Error)
    case couldNotLoadMetadata
    case couldNotStoreFileMetadata(underlyingError: Error)
    case couldNotCreateFileOnServer(responseCode: Int)
    case couldNotUploadFile
    case couldNotGetFileStatus
    case fileSizeMismatchWithServer
    case couldNotDeleteFile(underlyingError: Error)
    case uploadIsAlreadyFinished
    case couldNotRetryUpload
    case couldnotRemoveFinishedUploads(underlyingError: Error)
    case receivedUnexpectedOffset
    case missingRemoteDestination
    case missingUploadManifestId
}

extension TUSClientError {
    public var errorDescription: String? {
        switch self {
        case let .couldNotCreateFileOnServer(responseCode):
            return NSLocalizedString("Creation task failed with response code \(responseCode)", comment: "RELATED_FILE_NOT_FOUND")
        case let .missingUploadManifestId:
            return NSLocalizedString("Upload manifest ID not found in metadata", comment: "METADATA_UPLOAD_MANIFEST_ID_MISSING")
        default:
            return NSLocalizedString("File error", comment: "FILE_ERROR")
        }
    }
}

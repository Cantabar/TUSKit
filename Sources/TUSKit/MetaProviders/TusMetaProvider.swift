//
//  File.swift
//  
//
//  Created by Tom Greco on 7/24/23.
//

import Foundation

enum TusMetaProviderType {
    case FileProvider
    case MMKVProvider
}

protocol TusMetaProvider {
    func addFileToUploadManifest(_ uploadManifestId: String, _ uuid: UUID)
    
    func encodeAndStore(_ metaData: UploadMetadata) throws -> Void
    
    func encodeAndStoreUploadQueue(_ queueToEncode: UploadQueue) throws -> Void
    
    func getFilesToUploadCount() -> Int
    
    func loadAllMetadata(_ filterOnUuids: [String]?) throws -> [UploadMetadata]
    
    func loadUploadQueue() throws -> UploadQueue
    
    /// Optional method to migrate data from other providers to this one
    func migrateData() throws -> Void
    
    func removeFile(_ metaData: UploadMetadata) throws -> Void
    
    func removeFileFromManifest(_ metaData: UploadMetadata) throws -> Void
}
/**
 When adding a new provider add it here and give it a migrateData function that can migrate other providers to it
 */
final class TusMetaProviderFactory {
    public static func Create(_ providerType: TusMetaProviderType, storageDirectory: URL) -> TusMetaProvider? {
        do {
            switch(providerType) {
            case .FileProvider:
                return FileProvider(storageDirectory: storageDirectory)
            case .MMKVProvider:
                return MMKVProvider(storageDirectory: storageDirectory)
            default:
                return nil
            }
        }
    }
}

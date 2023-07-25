//
//  FileProvider.swift
//  
//
//  Created by Tom Greco on 7/24/23.
//

import Foundation

/// This type handles the storage for `Files`
/// Underwater it uses `FileManager.default`.
final class FileProvider {
    
    let storageDirectory: URL
    
    private let metadataFileName = "metadata.plist"
    
    private let uploadQueueFileName = "upload_queue.plist"
    
    /// Pass a directory to store the local cache in
    init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
    }
}

extension FileProvider: TusMetaProvider {
    func addFileToUploadManifest(_ uploadManifestId: String, _ uuid: UUID) {
        do {
            let uploadManifestQueue = try self.loadUploadQueue()
            uploadManifestQueue.enqueue(uploadManifestId: uploadManifestId, uuid: uuid)
            try self.encodeAndStoreUploadQueue(uploadManifestQueue)
        } catch let error {
            print(error)
        }
    }
    
    @discardableResult
    func encodeAndStore(_ metaData: UploadMetadata) throws -> Void {
        guard FileManager.default.fileExists(atPath: metaData.fileDir.path) else {
            // Could not find the directory that's related to this metadata.
            throw FilesError.uuidDirectoryNotFound(uuid: metaData.id.uuidString)
        }
        
        let targetLocation = metaData.fileDir.appendingPathComponent(metadataFileName)
        
        let encoder = PropertyListEncoder()
        let encodedData = try encoder.encode(metaData)
        try encodedData.write(to: targetLocation, options: .atomic)
    }
    
    func encodeAndStoreUploadQueue(_ queueToEncode: UploadQueue) throws {
        let uploadQueuePath =  storageDirectory.appendingPathComponent(uploadQueueFileName)
       
        let encoder = PropertyListEncoder()
        let encodedData = try encoder.encode(queueToEncode)
        try encodedData.write(to: uploadQueuePath, options: .atomic)
    }
    
    func getFilesToUploadCount() -> Int {
        do {
            let directoryContents = try FileUtils.ContentsOfDirectory(directory: storageDirectory)
            return directoryContents.count
        }
        catch {
            return 0
        }
    }
    
    func loadAllMetadata(_ filterOnUuids: [String]?) throws -> [UploadMetadata] {
        let uuidDirs = try FileUtils.ContentsOfDirectory(directory: storageDirectory).filter({  uuidDir in
            if (uuidDir.lastPathComponent == uploadQueueFileName) {
                return false
            }
            if filterOnUuids == nil {
                return true
            }
            return filterOnUuids!.contains(where: { uuid in
                return uuid == uuidDir.lastPathComponent
            })
        })
        
        // if you want to filter the directory contents you can do like this:
        let decoder = PropertyListDecoder()
        
        let metaData: [UploadMetadata] = try uuidDirs.compactMap { uuidDir in
            let uuidDirContents = try FileUtils.ContentsOfDirectory(directory: uuidDir)
            let metaDataUrls = uuidDirContents.filter{ $0.pathExtension == "plist" }
            if(metaDataUrls.isEmpty) {
                try FileManager.default.removeItem(at: uuidDir)
                throw FilesError.metaDataFileNotFound(uuid: uuidDir.lastPathComponent)
            }
            let metaDataUrl = metaDataUrls[0]
            if let data = try? Data(contentsOf: metaDataUrl) {
                let metaData = try? decoder.decode(UploadMetadata.self, from: data)
                
                // The documentsDirectory can change between restarts (at least during testing). So we update the filePath to match the existing plist again. To avoid getting an out of sync situation where the filePath still points to a dir in a different directory than the plist.
                // (The plist and file to upload should always be in the same dir together).
                metaData?.fileDir = metaDataUrl.deletingLastPathComponent()
                
                return metaData
            }
            
            // Improvement: Handle error when it can't be decoded?
            return nil
        }
        
        return metaData
    }
    
    func loadUploadQueue() throws -> UploadQueue {
        let decoder = PropertyListDecoder()
        let uploadQueuePath = self.storageDirectory.appendingPathComponent(self.uploadQueueFileName)
        if let data = try? Data(contentsOf: uploadQueuePath) {
            guard let uploadQueue = try? decoder.decode(UploadQueue.self, from: data) else {
                return UploadQueue()
            }
            return uploadQueue
        }
        return UploadQueue()
    }
    
    func migrateData() throws {
        // @todo migrate data from MMKV to file system
    }
    
    /// Removes metadata and its related file from disk
    /// - Parameter metaData: The metadata description
    /// - Throws: Any error from FileManager when removing a file.
    func removeFile(_ metaData: UploadMetadata) throws {
        let fileDir = metaData.fileDir
        try FileManager.default.removeItem(at: fileDir)
    }
    
    func removeFileFromManifest(_ metaData: UploadMetadata) throws -> Void {
        let uploadManifestId = metaData.context?[UPLOAD_MANIFEST_METADATA_KEY]
        if(uploadManifestId != nil) {
            let uploadManifestQueue = try self.loadUploadQueue()
            uploadManifestQueue.remove(uploadManifestId: uploadManifestId!, uuid: metaData.id)
            try self.encodeAndStoreUploadQueue(uploadManifestQueue)
        }
    }
}

//
//  MMKVProvider.swift
//  
//
//  Created by Tom Greco on 7/24/23.
//

import Foundation
import MMKV

let UPLOAD_QUEUE_KEY = "upload_queue"

final class MMKVProvider {
    let storageDirectory: URL

    private let mmkv: MMKV

    /// Pass a directory to store the local cache in.
    /// - Parameter storageDirectory: Leave nil for the documents dir. Pass a relative path for a dir inside the documents dir. Pass an absolute path for storing files there.
    /// - Throws: File related errors when it can't make a directory at the designated path.
    init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
        self.mmkv = MMKV(mmapID: "metadata")!
    }
}

extension MMKVProvider: TusMetaProvider {
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
        let encodedData = try JSONEncoder().encode(metaData)
        mmkv.set(encodedData, forKey: "metadata:\(metaData.id.uuidString)")
    }
    
    func encodeAndStoreUploadQueue(_ queueToEncode: UploadQueue) throws {
        let encodedData = try JSONEncoder().encode(queueToEncode)
        mmkv.set(encodedData, forKey: UPLOAD_QUEUE_KEY)
    }
    
    /// Moves any files from TUS/background to TUS and inserts metadata into MMKV
    func migrateData() throws {
            
        let doesExist = FileManager.default.fileExists(atPath: FileUtils.DocumentsDirectory.appendingPathComponent("TUS/background").path, isDirectory: nil)
        
        if doesExist {
            let uuidDirs = try FileUtils.ContentsOfDirectory(directory: FileUtils.DocumentsDirectory.appendingPathComponent("TUS/background"))
            
            let decoder = PropertyListDecoder()
            
            try uuidDirs.compactMap { uuidDir in
                let uuidDirContents = try FileUtils.ContentsOfDirectory(directory: uuidDir)
                let metaDataUrls = uuidDirContents.filter{ $0.pathExtension == "plist" }
                if(metaDataUrls.isEmpty) {
                    try FileManager.default.removeItem(at: uuidDir)
                } else {
                    let metaDataUrl = metaDataUrls[0]
                    print("URL: \(metaDataUrl)")
                    if let data = try? Data(contentsOf: metaDataUrl) {
                        let metaData = try? decoder.decode(UploadMetadata.self, from: data)
                        metaData?.fileDir = metaDataUrl.deletingLastPathComponent()
                        
                        guard let metaData = metaData else {
                            return
                        }
                        
                        // Insert into MMKV
                        try self.encodeAndStore(metaData)
                        
                        // Move file to TUS/ directory
                        try FileUtils.CopyAndChunk(storageDirectory: self.storageDirectory, from: metaDataUrl, id: metaData.id, chunkSize: -1)
                        
                        // Load upload manifest from file system
                        
                        
                        // Add upload manifest to queue
                        guard let uploadManifestId = metaData.context?[UPLOAD_MANIFEST_METADATA_KEY] else {
                            return
                        }
                        self.addFileToUploadManifest(uploadManifestId, metaData.id)
                        
                        // Delete directory in TUS/background
                        try FileManager.default.removeItem(at: uuidDir)
                    }
                }
            }
        }
    }
    
    /**
     @todo this needs to query MMKV keys to determine how many files to upload exists
     */
    func getFilesToUploadCount() -> Int {
        return 0
    }
    
    func loadAllMetadata(_ filterOnUuids: [String]?) throws -> [UploadMetadata] {
        let keys: [String] = (mmkv.allKeys() as! [String]).filter({  key in
            print(key)
            if(!key.contains("metadata:")) {
                return false
            }
            let uuid = key.replacingOccurrences(of: "metadata:", with: "")
            if filterOnUuids == nil {
                return true
            }
            return filterOnUuids!.contains(where: { filterUuid in
                return filterUuid == uuid as! String
            })
        }) as! [String]
        
        var metaDatas: [UploadMetadata] = []
        
        do {
            try keys.compactMap { key in
                let uuid = key.replacingOccurrences(of: "metadata:", with: "")
                guard let metaDataData = mmkv.data(forKey: key) else {
                    throw FilesError.metaDataFileNotFound(uuid: uuid)
                }
                let str = String(data: metaDataData ?? Data(), encoding: .utf8) ?? ""
                let metaData = try JSONDecoder().decode(UploadMetadata.self, from: metaDataData)
                if(metaData != nil) {
                    let uuidDir = storageDirectory.appendingPathComponent(uuid)
                    let uuidDirContents = try FileUtils.ContentsOfDirectory(directory: uuidDir)
                    if(!uuidDirContents.isEmpty) {
                        let metaDataUrl = uuidDirContents[0]
                        
                        
                        // The documentsDirectory can change between restarts (at least during testing). So we update the filePath to match the existing plist again. To avoid getting an out of sync situation where the filePath still points to a dir in a different directory than the plist.
                        // (The plist and file to upload should always be in the same dir together).
                        metaData.fileDir = metaDataUrl.deletingLastPathComponent()
                        metaDatas.append(metaData)
                    }
                } else {
                    print("Metadata: \(key)\n\(str)")
                }
            }
        } catch DecodingError.dataCorrupted(let context) {
            print(context)
        } catch DecodingError.keyNotFound(let key, let context) {
            print("Key '\(key)' not found:", context.debugDescription)
            print("codingPath:", context.codingPath)
        } catch DecodingError.valueNotFound(let value, let context) {
            print("Value '\(value)' not found:", context.debugDescription)
            print("codingPath:", context.codingPath)
        } catch DecodingError.typeMismatch(let type, let context) {
            print("Type '\(type)' mismatch:", context.debugDescription)
            print("codingPath:", context.codingPath)
        } catch {
            print("error: ", error)
        }
        
        return metaDatas
    }
    
    func loadUploadQueue() throws -> UploadQueue {
        guard let data = mmkv.data(forKey: UPLOAD_QUEUE_KEY) else {
            return UploadQueue()
        }
        guard let uploadQueue = try? JSONDecoder().decode(UploadQueue.self, from: data) else {
            return UploadQueue()
        }
        return uploadQueue
    }
    
    /**
     @todo have RN write image direct to TUS metadata directory then
     we can leave file on disk. RN side will verify file was received by server before removing file from cache.
     */
    /// Removes metadata from MMKV and removes file from disk
    /// - Parameter metaData: The metadata description
    /// - Throws: Any error from FileManager when removing a file.
    func removeFile(_ metaData: UploadMetadata) throws {
        let fileDir = metaData.fileDir
        mmkv.removeValue(forKey: "metadata:\(metaData.id.uuidString)")
        // @todo remove this removeItem line after RN refactored to write file direct to TUSKit cache dir
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

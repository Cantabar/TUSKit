//
//  Files.swift
//  
//
//  Created by Tjeerd in ‘t Veen on 15/09/2021.
//

import Foundation

/// This type handles the storage for `TUSClient`
/// It makes sure that files (that are to be uploaded) are properly stored, together with their metaData.
/// TusMetaProvider determines what is used under the hood (FileSystem or MMKV)
@available(iOS 14.0, *)
final class Files {
    
    let storageDirectory: URL
    
    private let tusMetaProviderType = TusMetaProviderType.MMKVProvider
    private let fileQueue = DispatchQueue(label: "com.tuskit.files")
    private let uploadQueue = DispatchQueue(label: "com.tuskit.uploadqueue")
    
    private var tusMetaProvider: TusMetaProvider? = nil
            
    /// Pass a directory to store the local cache in.
    /// - Parameter storageDirectory: Leave nil for the documents dir. Pass a relative path for a dir inside the documents dir. Pass an absolute path for storing files there.
    /// - Throws: File related errors when it can't make a directory at the designated path.
    init(storageDirectory: URL?) throws {
        func removeLeadingSlash(url: URL) -> String {
            if url.absoluteString.first == "/" {
                return String(url.absoluteString.dropFirst())
            } else {
                return url.absoluteString
            }
        }
        
        func removeTrailingSlash(url: URL) -> String {
            if url.absoluteString.last == "/" {
                return String(url.absoluteString.dropLast())
            } else {
                return url.absoluteString
            }
        }
        
        guard let storageDirectory = storageDirectory else {
            self.storageDirectory = FileUtils.DocumentsDirectory.appendingPathComponent("TUS")
            return
        }
        
        // If a path is relative, e.g. blabla/mypath or /blabla/mypath. Then it's a folder for the documentsdir
        let isRelativePath = removeTrailingSlash(url: storageDirectory) == storageDirectory.relativePath || storageDirectory.absoluteString.first == "/"
        
        let dir = removeLeadingSlash(url: storageDirectory)

        if isRelativePath {
            self.storageDirectory = FileUtils.DocumentsDirectory.appendingPathComponent(dir)
        } else {
            if let url = URL(string: dir) {
                self.storageDirectory = url
            } else {
                assertionFailure("Can't recreate URL")
                self.storageDirectory = FileUtils.DocumentsDirectory.appendingPathComponent("TUS")
            }
        }
        
        self.tusMetaProvider = TusMetaProviderFactory.Create(self.tusMetaProviderType, storageDirectory: self.storageDirectory)!
        
        try self.tusMetaProvider?.migrateData()
        
        try FileUtils.MakeDirectoryIfNeeded(storageDirectory: self.storageDirectory, nil)
    }
    
    func printFileDirContents(url: URL) throws {
        let contents = try FileUtils.ContentsOfDirectory(directory: url)
        print(contents)
    }
    
    /// UploadQueue cannot exist in memory because it will need to be read from the background upload side of things which won't have access to TUSClient memory
    /// So load it from file every time you need to access it as well as write it back to disk every time you update the UploadQueue
    func loadUploadQueue() throws -> UploadQueue {
        return try self.tusMetaProvider!.loadUploadQueue()
    }
    
    /// This needs to exist here so we can use the uploadQueue.sync
    func removeUploadManifest(_ uploadManifestId: String) throws -> Bool {
        uploadQueue.sync {
            do {
                let uploadManifestQueue = try self.loadUploadQueue()
                uploadManifestQueue.remove(uploadManifestId: uploadManifestId)
                return true
            } catch {
                print(error)
                return false
            }
        }
    }
    
    func addFileToUploadManifest(_ uploadManifestId: String, uuid: UUID) {
        do {
            try uploadQueue.sync {
                self.tusMetaProvider!.addFileToUploadManifest(uploadManifestId, uuid)
            }
        } catch let error {
            print(error)
        }
    }
    
    /// Loads all metadata (decoded plist files) from the target directory.
    /// - Important:Metadata assumes to be in the same directory as the file it references.
    /// This means that once retrieved, this method updates the metadata's filePath to the directory that the metadata is in.
    /// This happens, because theoretically the documents directory can change. Meaning that metadata's filepaths are invalid.
    /// By updating the filePaths back to the metadata's filepath, we keep the metadata and its related file in sync.
    /// It's a little magic, but it helps prevent strange issues.
    /// - Parameter filterOnUuids if provided will only load those files
    /// - Throws: File related errors
    /// - Returns: An array of UploadMetadata types
    func loadAllMetadata(_ filterOnUuids: [String]?) throws -> [UploadMetadata] {
        try fileQueue.sync {
            try self.tusMetaProvider!.loadAllMetadata(filterOnUuids)
        }
    }
    
    func truncateChunk(metaData: UploadMetadata, offset: Int) throws -> Void {
        
        // File paths
        let truncatedFileName = "\(metaData.currentChunk)_truncated.\(metaData.fileExtension)"
        let currentChunkFileName = "\(metaData.currentChunk).\(metaData.fileExtension)"
        
        let truncatedChunkPath = metaData.fileDir.appendingPathComponent(truncatedFileName)
        let currentChunkPath = metaData.fileDir.appendingPathComponent(currentChunkFileName)
        
        // Truncate data
        let fileHandle = try FileHandle(forReadingFrom: currentChunkPath)
        defer {
            fileHandle.closeFile()
        }
        try fileHandle.seek(toOffset: UInt64(offset - metaData.truncatedOffset))
        guard let data = try? fileHandle.readToEnd() else {
            print("truncateChunk: Could not read file \(currentChunkPath)")
            throw TUSClientError.couldNotLoadMetadata
        }
        
        // Write to disk
        try data.write(to: truncatedChunkPath, options: .atomic)
        //print("truncateChunk: Wrote \(data.count) bytes to \(truncatedChunkPath) for \(metaData.id.uuidString)")
        
        metaData.truncatedFileName = truncatedFileName
        metaData.truncatedOffset += (offset - metaData.truncatedOffset)
        try self.encodeAndStore(metaData: metaData)
    }
    
    /// Copy a file from location to a TUS directory, get the URL from the new location
    /// - Parameter location: The location where to copy a file from
    /// - Parameter id: The unique identifier for the data. Will be used as a filename.
    /// - Throws: Any error related to file handling.
    /// - Returns:The URL of the new directory where chunked files live
    @discardableResult
    func copyAndChunk(from location: URL, id: UUID, chunkSize: Int) throws -> URL {
        try FileUtils.CopyAndChunk(storageDirectory: self.storageDirectory, from: location, id: id, chunkSize: chunkSize)
    }
    
    /// Removes metadata and its related file from disk
    /// - Parameter metaData: The metadata description
    /// - Parameter updateManifest: Defaults to true, but if false will not update manifest (useful if removing all files for a manifest)
    /// - Throws: Any error from FileManager when removing a file.
    func removeFile(_ metaData: UploadMetadata, _ updateManifest: Bool = true) throws {
        
        try fileQueue.sync {
            try self.tusMetaProvider?.removeFile(metaData)
        }
        
        if(updateManifest) {
            try uploadQueue.sync {
                try self.tusMetaProvider?.removeFileFromManifest(metaData)
            }
        }
    }
    
    /// Removes metadata and its related file from for array of files
    /// - Parameter uuids: The IDs of the files to remove, if nil will remove all
    /// - Throws: Any error from FileManager when removing a file.
    func removeFilesForUuids(_ uuids: [String]?) throws {
        let files = try loadAllMetadata(uuids)
        
        // Save upload manifest ID
        var uploadManifestId: String? = nil
        if(files.count > 0) {
            uploadManifestId = files[0].context?[UPLOAD_MANIFEST_METADATA_KEY]
        }
        
        try files.forEach { file in
            // We'll completely remove the manifest from the queue at the end so pass false as second param here to avoid doing mass updates to the same manifest
            try self.removeFile(file, false)
        }
        
        if(uploadManifestId != nil) {
            try uploadQueue.sync {
                let uploadManifestQueue = try self.loadUploadQueue()
                uploadManifestQueue.remove(uploadManifestId: uploadManifestId!)
                try self.encodeAndStoreUploadQueue(uploadManifestQueue)
            }
        }
    }
    
    /// Store the metadata of a file. Will follow a convention, based on a file's url, to determine where to store it.plist
    /// Hence no need to give it a location to store the metadata.
    /// The reason to use this method is persistence between runs. E.g. Between app launches or background threads.
    /// - Parameter metaData: The metadata of a file to store.
    /// - Throws: Any error related to file handling
    @discardableResult
    func encodeAndStore(metaData: UploadMetadata) throws -> Void {
        try fileQueue.sync {
            try self.tusMetaProvider?.encodeAndStore(metaData)
        }
    }
    
    /// Stores the upload queue priority to disk
    /// The reason to use this method is persistence between runs. E.g. Between app launches or background threads.
    /// - Parameter uploadQueue: The upload queue to store.
    /// - Throws: Any error related to file handling
    func encodeAndStoreUploadQueue(_ queueToEncode: UploadQueue) throws {
        try self.tusMetaProvider?.encodeAndStoreUploadQueue(queueToEncode)
    }
    
    /// Load metadata from store and find matching one by id
    /// - Parameter id: Id to find metadata
    /// - Returns: optional `UploadMetadata` type
    func findMetadata(id: UUID) throws -> UploadMetadata? {
        return try loadAllMetadata([id.uuidString]).first(where: { metaData in
            metaData.id == id
        })
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
    
    /// Get latest authorization token from Keychain and update it in file metadata
    func updateAuthorizationHeaders() {
        
        func readFromKeychain() -> Data? {
            let query = [
                kSecAttrService: Bundle.main.bundleIdentifier,
                kSecAttrAccount: "TOKENS",
                kSecClass: kSecClassGenericPassword,
                kSecReturnData: true
            ] as CFDictionary
            
            var result: AnyObject?
            SecItemCopyMatching(query, &result)
            
            if(result == nil) {
                return nil
            }
            
            return result as? Data
        }
        
        guard let keychainData = readFromKeychain() else { return }
        do {
            struct Tokens: Codable {
                var accessToken: String
                var refreshToken: String
            }
            let tokens: Tokens = try JSONDecoder().decode(Tokens.self, from: keychainData)
            let files = try loadAllMetadata(nil)
            try files.forEach { metaData in
                if(metaData.customHeaders?["Authorization"] != "Bearer \(tokens.accessToken)") {
                  metaData.customHeaders?["Authorization"] = "Bearer \(tokens.accessToken)"
                  try self.encodeAndStore(metaData: metaData)
                }
            }
        } catch let error {
            // @TODO log this error in RN sentry
            print("TUSFiles failed to decode item for keychain: \(error)")
        }
    }
}

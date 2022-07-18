//
//  Files.swift
//  
//
//  Created by Tjeerd in ‘t Veen on 15/09/2021.
//

import Foundation

enum FilesError: Error {
    case metaDataFileNotFound
    case uuidDirectoryNotFound
}

extension FilesError {
    public var errorDescription: String? {
        switch self {
        case .metaDataFileNotFound:
            return NSLocalizedString("Metadata.plist file could not be found", comment: "RELATED_FILE_NOT_FOUND")
        case .uuidDirectoryNotFound:
            return NSLocalizedString("UUID directory for file was not found", comment: "UUID_DIRECTORY_NOT_FOUND")
        default:
            return NSLocalizedString("File error", comment: "FILE_ERROR")
        }
    }
}

/// This type handles the storage for `TUSClient`
/// It makes sure that files (that are to be uploaded) are properly stored, together with their metaData.
/// Underwater it uses `FileManager.default`.
final class Files {
    
    let storageDirectory: URL
    
    private let queue = DispatchQueue(label: "com.tuskit.files")
    
    private let metadataFileName = "metadata.plist"
    
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
            self.storageDirectory = type(of: self).documentsDirectory.appendingPathComponent("TUS")
            return
        }
        
        // If a path is relative, e.g. blabla/mypath or /blabla/mypath. Then it's a folder for the documentsdir
        let isRelativePath = removeTrailingSlash(url: storageDirectory) == storageDirectory.relativePath || storageDirectory.absoluteString.first == "/"
        
        let dir = removeLeadingSlash(url: storageDirectory)

        if isRelativePath {
            self.storageDirectory = type(of: self).documentsDirectory.appendingPathComponent(dir)
        } else {
            if let url = URL(string: dir) {
                self.storageDirectory = url
            } else {
                assertionFailure("Can't recreate URL")
                self.storageDirectory = type(of: self).documentsDirectory.appendingPathComponent("TUS")
            }
        }
        
        try makeDirectoryIfNeeded(nil)
    }
    
    static private var documentsDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func printFileDirContents(url: URL) throws {
        let contents = try self.contentsOfDirectory(directory: url)
        print(contents)
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
        try queue.sync {

            let uuidDirs = try self.contentsOfDirectory(directory: storageDirectory).filter({  uuidDir in
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
                let uuidDirContents = try contentsOfDirectory(directory: uuidDir)
                let metaDataUrls = uuidDirContents.filter{ $0.pathExtension == "plist" }
                if(metaDataUrls.isEmpty) {
                    print(uuidDirContents)
                    throw FilesError.metaDataFileNotFound
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
    }
    
    /// Get file size from file on disk
    /// - Parameter filePath: The path to the file
    /// - Returns: The size of the file
    @discardableResult
    func getFileSize(filePath: URL) throws -> Int {
        let size = try filePath.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Data(contentsOf: filePath).count
        
        guard size > 0 else {
            throw TUSClientError.fileSizeUnknown
        }
        
        return size
    }
    
    @available(iOS 13.4, *)
    @discardableResult
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
        print("truncateChunk: Wrote \(offset) bytes to \(truncatedChunkPath) for \(metaData.id.uuidString)")
        
        metaData.truncatedFileName = truncatedFileName
        metaData.truncatedOffset += (offset - metaData.truncatedOffset)
        try self.encodeAndStore(metaData: metaData)
    }
    
    /// Copy a file from location to a TUS directory, get the URL from the new location
    /// - Parameter location: The location where to copy a file from
    /// - Parameter id: The unique identifier for the data. Will be used as a filename.
    /// - Throws: Any error related to file handling.
    /// - Returns:The URL of the new directory where chunked files live
    @available(iOS 13.4, *)
    @discardableResult
    func copyAndChunk(from location: URL, id: UUID, chunkSize: Int) throws -> URL {
        try makeDirectoryIfNeeded(id)
        
        let fileHandle = try FileHandle(forReadingFrom: location)
        defer {
            fileHandle.closeFile()
        }
        
        // We don't use lastPathComponent (filename) because then you can't add the same file.
        // With a unique name, you can upload the same file twice if you want.
        let uuidDir = storageDirectory.appendingPathComponent(id.uuidString)
        
        let fileSize = try getFileSize(filePath: location)
        var currentSize = 0
        var chunk = 0
        var range = 0..<min(chunkSize, fileSize)
        while (range.upperBound <= fileSize && range.upperBound != range.lowerBound) {
            let fileName = "\(chunk).\(location.pathExtension)"
            let chunkPathInUuidDir = uuidDir.appendingPathComponent(fileName)
            
            try fileHandle.seek(toOffset: UInt64(range.startIndex))
            let data = fileHandle.readData(ofLength: range.count)
            print("Writing chunk \(chunk) to \(chunkPathInUuidDir.absoluteString)")
            //print("Containing data \(range.lowerBound) - \(range.upperBound)")
            //print("File handle offset: \(try fileHandle.offset())")
            try data.write(to: chunkPathInUuidDir, options: .atomic)
            range = range.upperBound..<min(range.upperBound + chunkSize, fileSize)
            chunk += 1
        }
        
        return uuidDir
    }
    
    /// Removes metadata and its related file from disk
    /// - Parameter metaData: The metadata description
    /// - Throws: Any error from FileManager when removing a file.
    func removeFile(_ metaData: UploadMetadata) throws {
        let fileDir = metaData.fileDir
        
        try queue.sync {
            try FileManager.default.removeItem(at: fileDir)
        }
    }
    
    /// Removes metadata and its related file from for array of files
    /// - Parameter uuids: The IDs of the files to remove, if nil will remove all
    /// - Throws: Any error from FileManager when removing a file.
    func removeFilesForUuids(_ uuids: [String]?) throws {
        let files = try loadAllMetadata(uuids)
        try files.forEach { file in
            try self.removeFile(file)
        }
    }
    
    /// Store the metadata of a file. Will follow a convention, based on a file's url, to determine where to store it.plist
    /// Hence no need to give it a location to store the metadata.
    /// The reason to use this method is persistence between runs. E.g. Between app launches or background threads.
    /// - Parameter metaData: The metadata of a file to store.
    /// - Throws: Any error related to file handling
    /// - Returns: The URL of the location where the metadata is stored.
    @discardableResult
    func encodeAndStore(metaData: UploadMetadata) throws -> URL {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: metaData.fileDir.path) else {
                // Could not find the directory that's related to this metadata.
                throw FilesError.uuidDirectoryNotFound
            }
            
            let targetLocation = metaData.fileDir.appendingPathComponent(metadataFileName)
            
            let encoder = PropertyListEncoder()
            let encodedData = try encoder.encode(metaData)
            try encodedData.write(to: targetLocation, options: .atomic)
            return targetLocation
        }
    }
    
    /// Load metadata from store and find matching one by id
    /// - Parameter id: Id to find metadata
    /// - Returns: optional `UploadMetadata` type
    func findMetadata(id: UUID) throws -> UploadMetadata? {
        return try loadAllMetadata([id.uuidString]).first(where: { metaData in
            metaData.id == id
        })
    }
    
    func makeDirectoryIfNeeded(_ uuid: UUID?) throws {
        let doesExist = FileManager.default.fileExists(atPath: storageDirectory.path, isDirectory: nil)
        
        if !doesExist {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        }
        
        if (uuid != nil) {
            let pathWithUuid = storageDirectory.appendingPathComponent(uuid!.uuidString)
            let doesExist = FileManager.default.fileExists(atPath: pathWithUuid.absoluteString, isDirectory: nil)
            if !doesExist {
                try FileManager.default.createDirectory(at: pathWithUuid, withIntermediateDirectories: true)
            }
        }
    }

    func getFilesToUploadCount() -> Int {
        do {
            let directoryContents = try contentsOfDirectory(directory: storageDirectory)
            return directoryContents.count
        }
        catch {
            return 0
        }
    }
    
    func contentsOfDirectory(directory: URL) throws -> [URL] {
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
}


//
//  FileUtils.swift
//  TUSKit
//
//  Created by Tom Greco on 7/24/23.
//

import Foundation
final class FileUtils {
    static var DocumentsDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    static func ContentsOfDirectory(directory: URL) throws -> [URL] {
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
    
    static func MakeDirectoryIfNeeded(storageDirectory: URL, _ uuid: UUID?) throws {
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
    
    /// Get file size from file on disk
    /// - Parameter filePath: The path to the file
    /// - Returns: The size of the file
    @discardableResult
    static func GetFileSize(filePath: URL) throws -> Int {
        let size = try filePath.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Data(contentsOf: filePath).count
        
        guard size > 0 else {
            throw TUSClientError.fileSizeUnknown
        }
        
        return size
    }
    
    static func CopyAndChunk(storageDirectory: URL, from location: URL, id: UUID, chunkSize: Int) throws -> URL {
        try FileUtils.MakeDirectoryIfNeeded(storageDirectory: storageDirectory, id)
        
        let fileHandle = try FileHandle(forReadingFrom: location)
        defer {
            fileHandle.closeFile()
        }
        
        // We don't use lastPathComponent (filename) because then you can't add the same file.
        // With a unique name, you can upload the same file twice if you want.
        let uuidDir = storageDirectory.appendingPathComponent(id.uuidString)
        
        let fileSize = try FileUtils.GetFileSize(filePath: location)
        var currentSize = 0
        var chunk = 0
        var range = 0..<min(chunkSize == -1 ? fileSize : chunkSize, fileSize)
        while (range.upperBound <= fileSize && range.upperBound != range.lowerBound) {
            let fileName = "\(chunk).\(location.pathExtension)"
            let chunkPathInUuidDir = uuidDir.appendingPathComponent(fileName)
            
            try fileHandle.seek(toOffset: UInt64(range.startIndex))
            let data = fileHandle.readData(ofLength: range.count)
            //print("Writing chunk \(chunk) to \(chunkPathInUuidDir.absoluteString)")
            //print("Containing data \(range.lowerBound) - \(range.upperBound)")
            //print("File handle offset: \(try fileHandle.offset())")
            try data.write(to: chunkPathInUuidDir, options: .atomic)
            range = range.upperBound..<min(range.upperBound + (chunkSize == -1 ? fileSize : chunkSize), fileSize)
            chunk += 1
        }
        
        return uuidDir
    }
}

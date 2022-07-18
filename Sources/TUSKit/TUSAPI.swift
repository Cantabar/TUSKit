//
//  TUSAPI.swift
//  
//
//  Created by Tjeerd in ‘t Veen on 13/09/2021.
//

import Foundation

/// The errors a TUSAPI can return
enum TUSAPIError: Error {
    case underlyingError(Error)
    case couldNotFetchStatus
    case couldNotRetrieveOffset
    case couldNotRetrieveLocation
}

/// The status of an upload.
struct Status {
    let length: Int
    let offset: Int
}

/// The Uploader's responsibility is to perform work related to uploading.
/// This includes: Making requests, handling requests, handling errors.
final class TUSAPI {
    enum HTTPMethod: String {
        case head = "HEAD"
        case post = "POST"
        case get = "GET"
        case patch = "PATCH"
        case delete = "DELETE"
    }
    
    let session: URLSession
    
    init(session: URLSession) {
        self.session = session
    }
    
    /// Uploads data
    /// - Parameters:
    ///   - metaData: Manifest for file to upload
    ///   - currentChunkFileSize: The content length header (usually chunkSize * filePartIndex unless using truncated file)
    ///   - offset: The offset into the file as a whole
    /// - Returns: resumable task
    @discardableResult
    func getUploadTask(metaData: UploadMetadata, currentChunkFileSize: Int) -> URLSessionUploadTask {
        
        let offset = metaData.currentChunk * metaData.chunkSize + metaData.truncatedOffset
        
        /// Use truncated file path if it exists, otherwise use prechunked file
        let fileName = "\(metaData.currentChunk).\(metaData.fileExtension)"
        let fileUrl =  metaData.fileDir.appendingPathComponent(metaData.truncatedFileName ?? fileName)
        
        print("Spawning upload for \(fileUrl)")
        
        let headers = [
            "Content-Type": "application/offset+octet-stream",
            "Upload-Offset": String(offset),
            "Content-Length": String(currentChunkFileSize)
        ]
        
        /// Attach all headers from customHeader property
        let headersWithCustom = headers.merging(metaData.customHeaders ?? [:]) { _, new in new }
        
        let request = makeRequest(url: metaData.remoteDestination!, method: .patch, headers: headersWithCustom)
        
        let task = session.uploadTask(with: request, fromFile: fileUrl)
        let taskDescription = TaskDescription(uuid: metaData.id.uuidString, taskType: TaskType.uploadData.rawValue)
        task.taskDescription = self.taskDescriptionToString(taskDescription)
        return task
    }
    
    
    /// Fetch the status of an upload if an upload is not finished (e.g. interrupted).
    /// By retrieving the status,  we know where to continue when we upload again.
    /// - Parameters:
    ///   - remoteDestination: A URL to retrieve the status from (received from the create call)
    ///   - headers: Request headers.
    ///   - completion: A completion giving us the `Status` of an upload.
    @discardableResult
    func getStatusTask(metaData: UploadMetadata) -> URLSessionDataTask {
        let request = makeRequest(url: metaData.remoteDestination!, method: .head, headers: metaData.customHeaders ?? [:])
        let task = session.dataTask(with: request)
        let taskDescription = TaskDescription(uuid: metaData.id.uuidString, taskType: TaskType.status.rawValue)
        task.taskDescription = self.taskDescriptionToString(taskDescription)
        return task
    }
    
    
    /// The create step of an upload. In this step, we tell the server we are about to upload data.
    /// The server returns a URL to upload to, we can use the `create` call for this.
    /// Use file metadata to enrich the information so the server knows what filetype something is.
    /// - Parameters:
    ///   - metaData: The file metadata.
    ///   - completion: Completes with a result that gives a URL to upload to.
    @discardableResult
    func getCreationTask(metaData: UploadMetadata) -> URLSessionDataTask {
        func makeCreateRequest(metaData: UploadMetadata) -> URLRequest {
            func makeUploadMetaHeader() -> [String: String] {
                var metaDataDict: [String: String] = [:]
                
                let fileName = "\(metaData.currentChunk).\(metaData.fileExtension)"
                let fileUrl = metaData.fileDir.appendingPathComponent(fileName)
                
                if !fileName.isEmpty && fileName != "/" { // A filename can be invalid, e.g. "/"
                    metaDataDict["filename"] = fileName
                }
                
                if let mimeType = metaData.mimeType, !mimeType.isEmpty {
                    metaDataDict["filetype"] = mimeType
                }
                
                let context = (metaData.context ?? [:]) as [String:String]
                metaDataDict.merge(context) { (first, _) in first }
                
                return metaDataDict
            }
           
            /// Turn dict into a comma separated base64 string
            func encode(_ dict: [String: String]) -> String? {
                guard !dict.isEmpty else { return nil }
                var str = ""
                for (key, value) in dict {
                    let appendingStr: String
                    if !str.isEmpty {
                        str += ", "
                    }
                    appendingStr = "\(key) \(value.toBase64())"
                    str = str + appendingStr
                }
                return str
            }
            
            var defaultHeaders = ["Upload-Extension": "creation",
                                  "Upload-Length": String(metaData.size)]
            
            if let encodedMetadata = encode(makeUploadMetaHeader())  {
                defaultHeaders["Upload-Metadata"] = encodedMetadata
            }
            
            /// Attach all headers from customHeader property
            let headers = defaultHeaders.merging(metaData.customHeaders ?? [:]) { _, new in new }
            
            return makeRequest(url: metaData.uploadURL, method: .post, headers: headers)
        }
        let request = makeCreateRequest(metaData: metaData)
        let task = session.dataTask(with: request)
        let taskDescription = TaskDescription(uuid: metaData.id.uuidString, taskType: TaskType.creation.rawValue)
        task.taskDescription = self.taskDescriptionToString(taskDescription)
        return task
    }
    
    private func taskDescriptionToString(_ taskDescription: TaskDescription) -> String {
        do {
            let jsonData = try JSONEncoder().encode(taskDescription)
            return String(data: jsonData, encoding: .utf8)!
        } catch let error {
            return "{\"type:\"\(taskDescription.taskType)\",\"uuid\":\"\(taskDescription.uuid)\"}"
        }
    }
    
    /// A factory to make requests with sane defaults.
    /// - Parameters:
    ///   - url: The URL of the request.
    ///   - method: The HTTP method of a request.
    ///   - headers: The headers to add to the request.
    /// - Returns: A new URLRequest to use in any TUS API call.
    private func makeRequest(url: URL, method: HTTPMethod, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = method.rawValue
        request.addValue("1.0.0", forHTTPHeaderField: "TUS-Resumable")
        for header in headers {
            request.addValue(header.value, forHTTPHeaderField: header.key)
        }
        return request
    }
}

extension Dictionary {
    
    /// Case insenstiive subscripting. Only for string keys.
    /// We downcast to string to support AnyHashable keys.
    subscript(caseInsensitive key: Key) -> Value? {
        guard let someKey = key as? String else {
            return nil
        }
        
        let lcKey = someKey.lowercased()
        for k in keys {
            if let aKey = k as? String {
                if lcKey == aKey.lowercased() {
                    return self[k]
                }
            }
        }
        return nil
    }
}

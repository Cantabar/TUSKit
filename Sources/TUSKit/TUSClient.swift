//
//  TUSClient.swift
//

import Foundation
import BackgroundTasks
import UIKit


/// Implement this delegate to receive updates from the TUSClient
@available(iOS 13.4, macOS 10.13, *)
public protocol TUSClientDelegate: AnyObject {
    /// `TUSClient` just finished an upload, returns the URL of the uploaded file.
    func didFinishUpload(id: UUID, context: [String: String]?)
    /// An upload failed. Returns an error. Could either be a TUSClientError or a networking related error.
    func uploadFailed(id: UUID, error: String, context: [String: String]?)
    
    /// Receive an error related to files. E.g. The `TUSClient` couldn't store a file or remove a file.
    func fileError(id: String, errorMessage: String)

    /// Get the progress of a specific upload by id. The id is given when adding an upload and methods of this delegate.
    func progressFor(id: UUID, context: [String: String]?, bytesUploaded: Int, totalBytes: Int, client: TUSClient)
}


/// The TUSKit client.
/// Please refer to the Readme.md on how to use this type.
@available(iOS 13.4, macOS 10.13, *)
public final class TUSClient: NSObject {
    
    // MARK: - Public Properties
    public weak var delegate: TUSClientDelegate?
    
    // MARK: - Private Properties
    
    /// How often to try an upload if it fails. A retryCount of 2 means 3 total uploads max. (1 initial upload, and on repeated failure, 2 more retries.)
    /// URLSession will auto retry 1 time for any requests that timeout (this retryCount is separate from that)
    private let retryCount = 5
    /// How long to delay the retry. This is intended to allow the server time to realize the connection has broken. Expected time in milliseconds.
    private let retryDelay = 500
    
    public var sessionIdentifier: String = ""
    private var session: URLSession? = nil
    private var files: Files? = nil
    private var serverURL: URL? = nil
    private var api: TUSAPI? = nil
    private var chunkSize: Int = 0
    
    /// Restrict maximum concurrent uploads in scheduler and background scheduler
    private var maxConcurrentUploadsWifi: Int = 0
    private var maxConcurrentUploadsNoWifi: Int = 0
    /// Given network status will determine maximum concurrent uploads
    var maxConcurrentUploads: Int {
        get {
            let status = self.networkMonitor.connType
            return status == ConnectionType.wifi ? self.maxConcurrentUploadsWifi : self.maxConcurrentUploadsNoWifi
        }
    }
    
    private (set) var uploadTasksRunning: Int = 0
    /// Keep track of uploads that occur in the background
    private var updatesToSync: [TUSClientUpdate] = []
    /// Prevent spamming startTasks method
    private var isStartingAllTasks: Bool = false
    /// Notify system when we have finished processing background events
    public var backgroundSessionCompletionHandler: (() -> Void)?
    private let networkMonitor = NetworkMonitor.shared

    
    /// Initialize a TUSClient
    /// - Parameters:
    ///   - server: The URL of the server where you want to upload to.
    ///   - sessionIdentifier: An identifier to know which TUSClient calls delegate methods, also used for URLSession configurations.
    ///   - storageDirectory: A directory to store local files for uploading and continuing uploads. Leave nil to use the documents dir. Pass a relative path (e.g. "TUS" or "/TUS" or "/Uploads/TUS") for a relative directory inside the documents directory.
    ///   You can also pass an absolute path, e.g. "file://uploads/TUS"
    ///   - chunkSize: The amount of bytes the data to upload will be chunked by. Defaults to 512 kB.
    ///   - maxConcurrentUploadsWifi: On HTTP 2 multiplexing allows for many concurrent uploads on 1 connection
    ///   - maxConcurrentUploadsNoWifi: When not on wifi will use this as throttle maximum
    /// - Throws: File related errors when it can't make a directory at the designated path.
    public init(server: URL, sessionIdentifier: String, storageDirectory: URL? = nil, chunkSize: Int = 500 * 1024, maxConcurrentUploadsWifi: Int = 100, maxConcurrentUploadsNoWifi: Int = 100, backgroundSessionCompletionHandler: (() -> Void)?) throws {
        super.init()
        
        func initSession() {
            // https://developer.apple.com/documentation/foundation/url_loading_system/downloading_files_in_the_background
            self.sessionIdentifier = sessionIdentifier
            self.maxConcurrentUploadsWifi = maxConcurrentUploadsWifi
            self.maxConcurrentUploadsNoWifi = maxConcurrentUploadsNoWifi
            self.backgroundSessionCompletionHandler = backgroundSessionCompletionHandler
            
            let urlSessionConfig = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
            // Restrict maximum parallel connections to 2
            urlSessionConfig.httpMaximumConnectionsPerHost = 2
            // 60 Second timeout (resets if data transmitted)
            urlSessionConfig.timeoutIntervalForRequest = 60
            // Wait for connection instead of failing immediately
            urlSessionConfig.waitsForConnectivity = true
            // Don't let system decide when to start the task
            urlSessionConfig.isDiscretionary = false
            // Must use delegate and not completion handlers for background URLSessionConfiguration
            session = URLSession(configuration: urlSessionConfig, delegate: self, delegateQueue: OperationQueue.main)
        }
        initSession()
        self.api = TUSAPI(session: self.session!)
        self.files = try Files(storageDirectory: storageDirectory)
        self.serverURL = server
        self.chunkSize = chunkSize
        
        // Listen to network changes
        self.networkMonitor.start()
        
        // Background uploads don't clean up or notify parent of progress
        getUpdatesToSync()
    }
    
    deinit {
        self.networkMonitor.stop()
    }

    /// Stops the ongoing sessions, keeps the cache intact so you can continue uploading at a later stage.
    /// - Important: This method is `not` destructive. It only stops the client from running. If you want to avoid uploads to run again. Then please refer to `reset()` or `clearAllCache()`.
    public func stopAndCancelAll() {
       // scheduler?.cancelAll()
    }
    
    public func cancel(id: UUID) throws {
        /*let tasksToCancel = scheduler?.allTasks.filter { ($0 as? ScheduledTask)?.id == id }
        if tasksToCancel != nil {
            scheduler?.cancelTasks(tasksToCancel!)
        }*/
    }

    /// Returns info for debugging 
    /// - scheduler's pending tasks
    /// - scheduler's running tasks
    /// - api's maximum / current concurrent running uploads
    /// - current running uploads
    /// - files to upload
    public func getInfo() -> [String:Int] {
        let filesToUpload = files?.getFilesToUploadCount()
        
        let infoResult: [String:Int] = [
            "maxConcurrentUploadsWifi": maxConcurrentUploadsWifi,
            "maxConcurrentUploadsNoWifi": maxConcurrentUploadsNoWifi,
            "currentConcurrentUploads":  uploadTasksRunning,
            "filesToUploadCount": filesToUpload ?? 0
        ]
        
        return infoResult
    }
    
    /// This will cancel all running uploads and clear the local cache.
    /// Expect errors passed to the delegate for canceled tasks.
    /// - Warning: This method is destructive and will remove any stored cache.
    /// - Throws: File related errors
    public func reset() throws {
        stopAndCancelAll()
        try clearAllCache()
    }
    
    // MARK: - Upload file
    
    /// Upload data located at a url.  This file will be copied to a TUS directory for processing..
    /// If data can not be found at a location, it will attempt to locate the data by prefixing the path with file://
    /// - Parameters:
    ///   - filePath: The path to a file on a local filesystem
    ///   - uploadURL: A custom URL to upload to. For if you don't want to use the default server url from the config. Will call the `create` on this custom url to get the definitive upload url.
    ///   - customHeaders: Any headers you want to add to an upload
    ///   - context: Add a custom context when uploading files that you will receive back in a later stage. Useful for custom metadata you want to associate with the upload. Don't put sensitive information in here! Since a context will be stored to the disk.
    /// - Returns: ANn id
    /// - Throws: TUSClientError
    @discardableResult
    public func uploadFile(filePath: URL, uploadURL: URL? = nil, customHeaders: [String: String] = [:], context: [String: String]? = nil, startNow: Bool = true) throws -> UUID {
        do {
            let id = UUID()
            
            func makeMetadata() throws -> UploadMetadata {
                guard let files = self.files else {
                    throw TUSClientError.couldNotUploadFile
                }
                
                let storedFileDir = try files.copyAndChunk(from: filePath, id: id, chunkSize: chunkSize)
                
                let size = try files.getFileSize(filePath: filePath)
                guard let url = uploadURL ?? serverURL else {
                    throw TUSClientError.couldNotUploadFile
                }
                return UploadMetadata(id: id, fileDir: storedFileDir, uploadURL: url, size: size, chunkSize: chunkSize, fileExtension: filePath.pathExtension , customHeaders: customHeaders, mimeType: filePath.mimeType.nonEmpty, context: context)
            }
            
            let metaData = try makeMetadata()
            
            
            try startTask(for: metaData)
            
            try saveMetadata(metaData: metaData)
            
            return id
        } catch let error as TUSClientError {
            throw error
        } catch let error {
            throw TUSClientError.couldNotCopyFile(underlyingError: error)
        }
    }
    
    // MARK: - Cache
    
    /// Throw away all files.
    /// - Important:This will clear the storage directory that you supplied.
    /// - Important:Don't call this while the client is active. Only between uploading sessions. You can check for the `remainingUploads` property.
    /// - Throws: TUSClientError if a file is found but couldn't be deleted. Or if files couldn't be loaded.
    public func clearAllCache() throws {
        do {
            try files?.clearCacheInStorageDirectory()
        } catch let error {
            throw TUSClientError.couldNotDeleteFile(underlyingError: error)
        }
    }
    
    /// Remove a cache related to an id
    /// - Important:Don't call this while the client is active. Only between uploading sessions.  Or you get undefined behavior.
    /// - Parameter id: The id of a (scheduled) upload that you wish to delete.
    /// - Returns: A bool whether or not the upload was found and deleted.
    /// - Throws: TUSClientError if a file is found but couldn't be deleted. Or if files couldn't be loaded.
    @discardableResult
    public func removeCacheFor(id: UUID) throws -> Bool {
        do {
            guard let metaData = try files?.findMetadata(id: id) else {
                return false
            }
            
            try files?.removeFileAndMetadata(metaData)
            return true
        } catch let error {
            throw TUSClientError.couldNotDeleteFile(underlyingError: error)
        }
    }
   
    /// Retry a failed upload. Note that `TUSClient` already has an internal retry mechanic before it reports an upload as failure.
    /// If however, you like to retry an upload at a later stage, you can use this method to trigger the upload again.
    /// - Parameter id: The id of an upload. Received when starting an upload, or via the `TUSClientDelegate`.
    /// - Returns: a tuple with the first value being true if successfully retried or false if not. If false then the reason why it failed will be the second value in the tuple.
    @discardableResult
    public func retry(id: UUID) throws -> (didRetry: Bool, reason: String) {
        do {
            // @todo URLSession getAllTasks should run to verify if task is already running
            //guard uploads[id] == nil else { return (false, "Already scheduled") }
            guard let metaData = try files?.findMetadata(id: id) else {
                return (false, "Could not find metadata")
            }
            
            metaData.errorCount = 0
            
            try startTask(for: metaData)
            return (true, "")
        } catch let error as TUSClientError {
            throw error
        } catch {
            print(error)
            return (false, error.localizedDescription)
        }
    }
    
    /// Return the id's all failed uploads. Good to check after launch or after background processing for example, to handle them at a later stage.
    /// - Returns: An id's array of erronous uploads.
    public func failedUploadIDs() throws -> [UUID] {
        try files!.loadAllMetadata(nil).compactMap { metaData in
            if metaData.errorCount > retryCount {
                return metaData.id
            } else {
                return nil
            }
        }
    }
    
    /// Background tasks don't communicate progress back to react-native-tus
    /// This method allows react-native app to sync with the metadata filesystem
    @discardableResult
    public func sync() -> [[String:Any]] {
        print("TUSClient syncing")
        do {
            if(updatesToSync.count == 0) {
                try getUpdatesToSync()
            }
            let updates = updatesToSync.map { update in
                return [
                  "id": "\(update.id)",
                  "bytesUploaded": update.bytesUploaded,
                  "size": update.size,
                  "isError": update.errorCount >= retryCount,
                  "name": update.name
                ]
            }
            updatesToSync.removeAll()
            return updates
        } catch let error {
            return []
        }
    }
    
    // MARK: - Private

    /// Builds a list of files and their current status so parent can stay in sync with TUSClient
    /// Also, checks for any uploads that are finished and remove them from the cache (Background uploads don't have clean up)
    private func getUpdatesToSync() {
        var uuid: String = ""
        do {
            try files?.loadAllMetadata(nil)
            .forEach{ metaData in
                uuid = metaData.id.uuidString
                let tusClientUpdate = TUSClientUpdate(id: metaData.id,
                                                      bytesUploaded: metaData.uploadedRange?.count ?? 0,
                                                      size: metaData.size,
                                                      errorCount: metaData.errorCount,
                                                      name: metaData.context?["name"] ?? "")
                if (metaData.isFinished) {
                    try files?.removeFileAndMetadata(metaData)
                }
                updatesToSync.append(tusClientUpdate)
            }
        } catch let error {
            delegate?.fileError(id: uuid, errorMessage: error.localizedDescription)
        }
    }
    
    /// Store UploadMetadata to disk
    /// - Parameter metaData: The `UploadMetadata` to store.
    /// - Throws: TUSClientError.couldNotStoreFileMetadata
    private func saveMetadata(metaData: UploadMetadata) throws {
        do {
            // We store metadata here, so it's saved even if this job doesn't run this session. (Only created, doesn't mean it will run)
            try files?.encodeAndStore(metaData: metaData)
        } catch let error {
            throw TUSClientError.couldNotStoreFileMetadata(underlyingError: error)
        }
    }
    
    private func loadMetadata(for id: String) throws -> UploadMetadata {
        guard let files = files else {
            throw TUSClientError.couldNotLoadMetadata
        }
        
        // Load metadata from disk
        let metaData = try files.loadAllMetadata([id]).first
        guard let metaData = metaData else {
            throw TUSClientError.couldNotLoadMetadata
        }
        
        return metaData
    }
    
    private func getChunkSize(for metadata: UploadMetadata) throws -> Int {
        let fileName = "\(metadata.currentChunk).\(metadata.fileExtension)"
        let filePath = metadata.fileDir.appendingPathComponent(fileName)
        return try files!.getFileSize(filePath: filePath)
    }
  
    // MARK: - Tasks
    /// Check which uploads aren't finished. Load them from a store and turn these into tasks.
    public func startTasks(for uuids: [UUID]?) {
        do {
            // Prevent spamming this method
            if uuids == nil {
                if isStartingAllTasks {
                    print("TUSClient.startTasks already running")
                    return
                }
                isStartingAllTasks = true
            }
          
            // Prevent running a million requests on a multiplexed HTTP/2 connection
            if uploadTasksRunning >= maxConcurrentUploads {
                if uuids == nil {
                    isStartingAllTasks = false
                }
                print("TUSClient.startTasks running maximum concurrent tasks")
                return
            }
            
            let uuidStrings = uuids?.map({ uuid in
                return uuid.uuidString
            })
            let metaDataItems = try files?.loadAllMetadata(uuidStrings).filter({ metaData in
                // Only allow uploads where errors are below an amount
                metaData.errorCount <= retryCount && !metaData.isFinished
            })
            
            if metaDataItems != nil {
                // Prevent duplicate tasks
                self.session?.getAllTasks(completionHandler: { [weak self] tasks in
                    var uuid: String = ""
                    do {
                        guard let self = self else { return }
                        func toTaskIds() -> [String] {
                            var runningTaskIds: [String] = []
                            tasks.forEach { task in
                                do {
                                    let uuid = try task.toTaskDescription()?.uuid
                                    if uuid != nil {
                                        runningTaskIds.append(uuid!)
                                    }
                                } catch let error {
                                    print(error)
                                    if uuids == nil {
                                        self.isStartingAllTasks = false
                                    }
                                    return
                                }
                            }
                            return runningTaskIds
                        }
                        let runningTaskIds = toTaskIds()
                    
                        for metaData in metaDataItems! {
                            uuid = metaData.id.uuidString
                            
                            // Prevent running a million requests on a multiplexed HTTP/2 connection
                            if self.uploadTasksRunning >= self.maxConcurrentUploads {
                                if uuids == nil {
                                    self.isStartingAllTasks = false
                                }
                                print("TUSClient.startTasks running maximum concurrent tasks")
                                return
                            }
                            
                            // Prevent running duplicates
                            let isRunning = runningTaskIds.firstIndex(where: {$0 == metaData.id.uuidString }) != nil
                            if !isRunning {
                                try self.startTask(for: metaData)
                            }
                        }
                        
                        self.isStartingAllTasks = false
                    } catch let error {
                        if uuids == nil {
                            self?.isStartingAllTasks = false
                        }
                        self?.delegate?.fileError(id: uuid, errorMessage: error.localizedDescription)
                        print(error)
                    }
                })
            }
        } catch (let error) {
            if uuids == nil {
                isStartingAllTasks = false
            }
            delegate?.fileError(id: "", errorMessage: error.localizedDescription)
        }
    }
    
    /// Status task to find out where to continue from if endpoint exists in metadata,
    /// Creation task if no upload endpoint in metadata
    /// - Parameter metaData:The metaData for file to upload.
    private func startTask(for metaData: UploadMetadata) throws {
        if(metaData == nil || metaData.isFinished) {
            return
        }
        
        // Prevent running a million requests on a multiplexed HTTP/2 connection
        if uploadTasksRunning >= maxConcurrentUploads {
            return
        }
        uploadTasksRunning += 1
        
        if let remoteDestination = metaData.remoteDestination {
            api!.getStatusTask(metaData: metaData).resume()
        } else {
            api!.getCreationTask(metaData: metaData).resume()
        }
    }
    
    private func processCreationTaskResult(for id: String, response: HTTPURLResponse) {
        print("Processing CreationTask result")
        
        do {
            guard let location = response.locationHeader() else {
                throw TUSClientError.couldNotCreateFileOnServer
            }
            
            // Load metadata from disk
            let metaData = try loadMetadata(for: id)
        
            // location is missing leading https://
            // Example: "//api.portal-beta.scanifly.com/surveyMedias/upload/files/33485c559ae35ab1bc76d91b4cebf95a"
            var remoteDestination = URL(string: location)
            if(!location.contains("http")) {
                //print("\(metaData.uploadURL.scheme!):\(location)")
                remoteDestination = URL(string: "\(metaData.uploadURL.scheme!):\(location)")
            }
            
            // Save endpoint
            metaData.remoteDestination = remoteDestination
            try saveMetadata(metaData: metaData)
            
            let currentChunkFileSize = try getChunkSize(for: metaData)
            api!.getUploadTask(metaData: metaData, currentChunkFileSize: currentChunkFileSize).resume()
            print("UploadTask started")
        } catch let error {
            processFailedTask(for: id, errorMessage: error.localizedDescription)
        }
    }
    
    private func processStatusTaskResult(for id: String, response: HTTPURLResponse) {
        print("Processing StatusTask result")
        do {
            guard let length = response.uploadLengthHeader() else {
                throw TUSAPIError.couldNotFetchStatus
            }
            
            guard let offset = response.uploadOffsetHeader() else {
                throw TUSAPIError.couldNotFetchStatus
            }
            
            
            // Load metadata from disk
            let metaData = try loadMetadata(for: id)
            
            if length != metaData.size {
                throw TUSClientError.fileSizeMismatchWithServer
            }
            
            if offset > metaData.size {
                throw TUSClientError.fileSizeMismatchWithServer
            }
            
            // Reset error counter and set last uploaded range to match server
            metaData.errorCount = 0
            metaData.uploadedRange = 0..<offset
            try saveMetadata(metaData: metaData)
            
            if offset == metaData.size {
                processFinishedFile(for: metaData)
            } else {
                let nextRange = offset..<min((offset + chunkSize), metaData.size)
                
                let currentChunkFileSize = try getChunkSize(for: metaData)
                api!.getUploadTask(metaData: metaData, currentChunkFileSize: currentChunkFileSize).resume()
                print("UploadTask started")
            }
            
        } catch let error {
            processFailedTask(for: id, errorMessage: error.localizedDescription)
        }
    }
    
    
    private func processUploadTaskResult(for id: String, response: HTTPURLResponse) {
        print("Processing UploadTask result")
        do {
            guard let offset = response.uploadOffsetHeader() else {
                print("Processing UploadTask error: \(response.statusCode)")
                
                // If 409 bad offset try status task to get new offset
                throw TUSAPIError.couldNotRetrieveOffset
            }
            // Load metadata from disk
            let metaData = try loadMetadata(for: id)
        
            let currentOffset = metaData.uploadedRange?.upperBound ?? 0
            metaData.uploadedRange = 0..<offset
            metaData.currentChunk += 1
            metaData.errorCount = 0
            
            try saveMetadata(metaData: metaData)

            if metaData.isFinished {
                processFinishedFile(for: metaData)
                return
            }
            else if offset == currentOffset {
                throw TUSClientError.receivedUnexpectedOffset
            }
            
            delegate?.progressFor(id: metaData.id, context: metaData.context, bytesUploaded: metaData.uploadedRange?.upperBound ?? 0, totalBytes: metaData.size, client: self)
            
            var nextRange: Range<Int>? = nil
            if let range = metaData.uploadedRange {
                let chunkSize = range.count
                let upperBound = min((offset + chunkSize), metaData.size)
                if(offset > upperBound) {
                    print("Received offset: \(offset)\nchunkSize: \(chunkSize)\nmetaData.size: \(metaData.size)")
                    throw TUSClientError.receivedUnexpectedOffset
                } else {
                    nextRange = offset..<min((offset + chunkSize), metaData.size)
                }
            } else {
                nextRange = nil
            }
            
            // Upload remainder of file
            let currentChunkFileSize = try getChunkSize(for: metaData)
            print("Uploading next \(currentChunkFileSize) bytes for \(metaData.id.uuidString)")
            api!.getUploadTask(metaData: metaData, currentChunkFileSize: currentChunkFileSize).resume()
        } catch let error {
            processFailedTask(for: id, errorMessage: "\(error.localizedDescription) - status code: \(response.statusCode)")
        }
    }
    
    private func processFailedTask(for id: String, errorMessage: String) {
        do {
            print("TUSClient task error: \(errorMessage)")
            
            if uploadTasksRunning > 0 {
                uploadTasksRunning -= 1
            }
            
            // Load metadata from disk
            let metaData = try loadMetadata(for: id)
            
            // Update error count
            metaData.errorCount += 1
            try saveMetadata(metaData: metaData)
            
            let canRetry = metaData.errorCount <= retryCount
            if canRetry {
                do {
                    try startTask(for: metaData)
                }
                catch let otherError {
                    startTasks(for: nil)
                    delegate?.uploadFailed(id: metaData.id, error: otherError.localizedDescription, context: metaData.context)
                }
            } else { // Exhausted all retries, reporting back as failure.
                startTasks(for: nil)
                delegate?.uploadFailed(id: metaData.id, error: errorMessage, context: metaData.context)
            }
        } catch let fileError {
            startTasks(for: nil)
            delegate?.fileError(id: id, errorMessage: fileError.localizedDescription)
        }
    }
        
    private func processFinishedFile(for metaData: UploadMetadata) {
        print("\(metaData.id.uuidString) finished")
        do {
            if uploadTasksRunning > 0 {
                uploadTasksRunning -= 1
            }
            try files?.removeFileAndMetadata(metaData)
            startTasks(for: nil)
        } catch let error {
            delegate?.fileError(id: metaData.id.uuidString, errorMessage: error.localizedDescription)
        }
        delegate?.didFinishUpload(id: metaData.id, context: metaData.context)
    }
}

// MARK: - URLSessionTaskDelegate
/// The app will instantiate TUSClient to receive the processed events
@available(iOS 13.4, *)
extension TUSClient: URLSessionTaskDelegate {
    
    public func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        print("taskIsWaitingForConnectivity")
    }
    
    /*public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        print("didSendBody")
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        print("didFinishCollecting")
    }*/

    /// Called when task finishes, if error is nil then it completed successfully
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("didComplete")
        
        do {
            guard let taskDescription = try task.toTaskDescription() else {
                return
            }
            
            if let error = error {
                processFailedTask(for: taskDescription.uuid, errorMessage: error.localizedDescription)
                return
            }
            
            switch taskDescription.taskType {
            case TaskType.creation.rawValue:
                processCreationTaskResult(for: taskDescription.uuid, response: task.response as! HTTPURLResponse)
                break
            case TaskType.status.rawValue:
                processStatusTaskResult(for: taskDescription.uuid, response: task.response as! HTTPURLResponse)
                break
            case TaskType.uploadData.rawValue:
                processUploadTaskResult(for: taskDescription.uuid, response: task.response as! HTTPURLResponse)
                break
            default:
                print("Invalid task type: \(taskDescription.taskType)")
                break
            }
        } catch let error {
            print("didCompleteWithError: \(error.localizedDescription)")
            do {
                guard let taskDescription = try task.toTaskDescription() else {
                    return
                }
                processFailedTask(for: taskDescription.uuid, errorMessage: error.localizedDescription)
            } catch let _ {
                // @todo handle horrible error here
            }
        }
    }
}

// MARK: - URLSessionDelegate
@available(iOS 13.4, *)
extension TUSClient: URLSessionDelegate {
    /// Called when all running upload tasks have finished and the app is in the background so we can invoke completion handler
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        print("urlSessionDidFinishEvents")
        DispatchQueue.main.async {
            guard let completionHandler = self.backgroundSessionCompletionHandler else {
                return
            }
            completionHandler()
        }
    }
    
    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        print("didBecomeInvalidWithError")
        print(error)
    }
}

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
    func didFinishUpload(id: UUID)
    
    /// An upload failed. Returns an error. Could either be a TUSClientError or a networking related error.
    func uploadFailed(id: UUID, error: String)
    
    /// Receive an error related to files. E.g. The `TUSClient` couldn't store a file or remove a file.
    func fileError(id: String, errorMessage: String)
    
    /// Receive confirmation that cancel operation has finished
    func cancelFinished(errorMessage: String?)

    /// Get the progress of a specific upload by id. The id is given when adding an upload and methods of this delegate.
    func progressFor(id: UUID, bytesUploaded: Int, totalBytes: Int)
}

let UPLOAD_MANIFEST_METADATA_KEY = "upload_manifest_id"


/// The TUSKit client.
/// Please refer to the Readme.md on how to use this type.
@available(iOS 13.4, macOS 10.13, *)
public final class TUSClient: NSObject {
    
    // MARK: - Public Properties
    public weak var delegate: TUSClientDelegate?
    
    // MARK: - Private Properties
    
    /// How often to try an upload if it fails. A retryCount of 2 means 3 total uploads max. (1 initial upload, and on repeated failure, 2 more retries.)
    /// URLSession will auto retry 1 time for any requests that timeout (this retryCount is separate from that)
    private let retryCount = 2
    
    /// How long to delay the retry. This is intended to allow the server time to realize the connection has broken. Expected time in milliseconds.
    private let retryDelay = 500
    
    /// When true will prevent tasks from running, useful for clearing memory
    private var isSessionInvalidated: Bool = true
    public var sessionIdentifier: String = ""
    private var session: URLSession? = nil
    private var files: Files? = nil
    private var serverURL: URL? = nil
    private var api: TUSAPI? = nil
    private var chunkSize: Int = 0
    private var timeoutSeconds: Int = 60
    
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
    
    public private (set) var isPaused: Bool = false
        
    /// When uploadFiles runs this is set to true to prevent startTasks from running
    public private (set) var isBatchProcessingFile: Bool = false
    
    /// Keep track of uploads that occur in the background
    private var updatesToSync: [TUSClientUpdate] = []
    /// Prevent spamming startTasks method
    private var isStartingAllTasks: Bool = false
    /// Notify system when we have finished processing background events
    public var backgroundSessionCompletionHandler: (() -> Void)?
    
    /// Used to determine how many concurrent tasks should run
    private let networkMonitor = NetworkMonitor.shared

    
    /// Initialize a TUSClient
    /// - Parameters:
    ///   - server: The URL of the server where you want to upload to.
    ///   - sessionIdentifier: An identifier to know which TUSClient calls delegate methods, also used for URLSession configurations.
    ///   - storageDirectory: A directory to store local files for uploading and continuing uploads. Leave nil to use the documents dir. Pass a relative path (e.g. "TUS" or "/TUS" or "/Uploads/TUS") for a relative directory inside the documents directory.
    ///   You can also pass an absolute path, e.g. "file://uploads/TUS"
    ///   - chunkSize: The amount of bytes the data to upload will be chunked by. Defaults to 512 kB. (-1 means upload entire file)
    ///   - maxConcurrentUploadsWifi: On HTTP 2 multiplexing allows for many concurrent uploads on 1 connection
    ///   - maxConcurrentUploadsNoWifi: When not on wifi will use this as throttle maximum
    /// - Throws: File related errors when it can't make a directory at the designated path.
    public init(server: URL, sessionIdentifier: String, storageDirectory: URL? = nil, chunkSize: Int = 500 * 1024, maxConcurrentUploadsWifi: Int = 100, maxConcurrentUploadsNoWifi: Int = 100, backgroundSessionCompletionHandler: (() -> Void)?) throws {
        super.init()
        
        self.sessionIdentifier = sessionIdentifier
        self.maxConcurrentUploadsWifi = maxConcurrentUploadsWifi
        self.maxConcurrentUploadsNoWifi = maxConcurrentUploadsNoWifi
        self.backgroundSessionCompletionHandler = backgroundSessionCompletionHandler
        
        self.initSession()
        self.api = TUSAPI(session: self.session!)
        self.files = try Files(storageDirectory: storageDirectory)
        self.files!.updateAuthorizationHeaders()
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

    func initSession() {
        // https://developer.apple.com/documentation/foundation/url_loading_system/downloading_files_in_the_background
        let urlSessionConfig = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        // Restrict maximum parallel connections to 2
        urlSessionConfig.httpMaximumConnectionsPerHost = 2
        // 60 Second timeout (resets if data transmitted)
        urlSessionConfig.timeoutIntervalForRequest = TimeInterval(self.timeoutSeconds)
        // If the file isn't uploaded after 7 days stop trying and let the user manually resubmit this
        urlSessionConfig.timeoutIntervalForResource = TimeInterval(60 * 60 * 24 * 7)
        // Fail immediately if no connection and let app resume it when in foreground again to be safe with upload-offsets changing
        urlSessionConfig.waitsForConnectivity = false
        // Don't let system decide when to start the task
        urlSessionConfig.isDiscretionary = false
        // Keep TCP connection alive when app moves to background
        urlSessionConfig.shouldUseExtendedBackgroundIdleMode = true
        // iOS 13 considers most cellular networks and personal hotspots expensive.
        // If there are no nonexpensive network interfaces available and the session’s allowsExpensiveNetworkAccess property is false, any task created from the session fails
        urlSessionConfig.allowsExpensiveNetworkAccess = true
        // Must use delegate and not completion handlers for background URLSessionConfiguration
        session = URLSession(configuration: urlSessionConfig, delegate: self, delegateQueue: OperationQueue.main)
        self.api = TUSAPI(session: self.session!)
        self.isSessionInvalidated = false
    }

    
    /// Will notify delegate when cancel has finished since URLSession requires completion handler
    /// to obtain reference to running tasks
    /// - Parameters:
    ///   - uuids: Upload IDs to filter on, if nil will remove all
    public func cancelByIds(uuids: [String]?) throws {
        // Remove any pending tasks
        self.session?.getAllTasks(completionHandler: { [weak self] tasks in
            tasks.forEach { task in
                do {
                    if let uuid = try task.toTaskDescription()?.uuid {
                        if(uuids == nil || uuids!.contains(uuid)) {
                            task.cancel()
                        }
                    }
                } catch {}
            }
            
            // Remove from disk
            do {
                try self?.files?.removeFilesForUuids(uuids)
                self?.delegate?.cancelFinished(errorMessage: "")
            } catch let error {
                self?.delegate?.cancelFinished(errorMessage: error.localizedDescription)
            }
        })
    }

    /// Returns get for debugging
    /// - scheduler's pending tasks
    /// - scheduler's running tasks
    /// - api's maximum / current concurrent running uploads
    /// - current running uploads
    /// - files to upload
    public func getInfo() -> [String:Any] {
      let filesToUpload = files?.getFilesToUploadCount()
      
      do {
          let uploadQueue = try files?.loadUploadQueue()
          let queueOrder = uploadQueue?.uploadManifests.map { $0.uploadManifestId }
          
          let infoResult = [
              "maxConcurrentUploadsWifi": maxConcurrentUploadsWifi,
              "maxConcurrentUploadsNoWifi": maxConcurrentUploadsNoWifi,
              "currentConcurrentUploads":  uploadTasksRunning,
              "filesToUploadCount": filesToUpload ?? 0,
              "queueOrder": queueOrder
          ] as [String : Any]
          
          /*self.session?.getAllTasks(completionHandler: { [weak self] tasks in
            print("Pending tasks count: \(tasks.count)")
            })*/
          
          return infoResult
      } catch let error {
          return [:]
      }
    }
    
    
    // MARK: - Upload actions
    
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
    public func uploadFile(uploadId: Any?, filePath: URL, uploadURL: URL? = nil, customHeaders: [String: String] = [:], context: [String: String]? = nil) throws -> UUID {
        do {
            var id: UUID
            if (uploadId != nil) {
                id = UUID(uuidString: uploadId as! String)!
            } else {
                id = UUID()
            }
            
            try autoreleasepool {
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
                
                try saveMetadata(metaData: metaData)
                
                guard let uploadManifestId = metaData.context?[UPLOAD_MANIFEST_METADATA_KEY] else {
                    throw TUSClientError.missingUploadManifestId
                }
                
                self.files!.addFileToUploadManifest(uploadManifestId, uuid: id)
                try startTask(for: metaData)
            }
            
            return id
        } catch let error as TUSClientError {
            throw error
        } catch let error {
            throw TUSClientError.couldNotCopyFile(underlyingError: error)
        }
    }
    
    @discardableResult
    public func uploadFiles(fileUploads: [[String: Any]]) -> [[String:Any]]  {
        func buildFileUrl(fileUrl: String) -> URL {
            let fileToBeUploaded: URL
            if (fileUrl.starts(with: "file:///") || fileUrl.starts(with: "/var/") || fileUrl.starts(with: "/private/var/")) {
                fileToBeUploaded = URL(string: fileUrl)!
            } else {
                let fileManager = FileManager.default
                let docUrl = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
                let appContainer = docUrl.deletingLastPathComponent()
                fileToBeUploaded = appContainer.appendingPathComponent(fileUrl)
            }
            return fileToBeUploaded
        }
        
        isBatchProcessingFile = true
        var uploads: [[String:Any]] = []
        for fileUpload in fileUploads {
            let fileUrl = fileUpload["fileUrl"] ?? ""
            let options = fileUpload["options"] as? [String: Any] ?? [:]
            let fileToBeUploaded: URL = buildFileUrl(fileUrl: fileUrl as! String)
            let endpoint: String = options["endpoint"]! as? String ?? ""
            let headers = options["headers"]! as? [String: String] ?? [:]
            let metadata = options["metadata"]! as? [String: String] ?? [:]
            
            do {
                let uploadId = try self.uploadFile(
                    uploadId: options["uploadId"] ?? nil,
                    filePath: fileToBeUploaded,
                    uploadURL: URL(string: endpoint)!,
                    customHeaders: headers,
                    context: metadata
                )
                
                let uploadResult = [
                    "status": "success",
                    "uploadId":"\(uploadId)",
                    "fileUrl": fileUrl
                ]
                uploads += [uploadResult]
            } catch {
                print("Unable to create upload: \(error)")
                let uploadResult = [
                    "status": "failure",
                    "err": error,
                    "uploadId": "",
                    "fileUrl": fileUrl
                ]
                uploads += [uploadResult]
            }
        }
        
        isBatchProcessingFile = false
        
        return uploads
    }

    public func freeMemory() {
        if(!isSessionInvalidated) {
            self.session?.finishTasksAndInvalidate()
            self.isSessionInvalidated = true
        }
    }
    
    /// Pause all new uploads but let already running finish
    public func pause() {
        self.isPaused = true
    }
    
    /// Starts tasks and also toggles pause to true, whereas startTasks will only work if not paused
    public func resume() {
        self.isPaused = false
        self.startTasks(for: nil, processFailedItemsIfEmpty: true)
    }
    
    public func updateAuthorizationHeaders() {
        try autoreleasepool {
            self.files?.updateAuthorizationHeaders()
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
    
    /// Background tasks don't communicate progress back to react-native-tus
    /// This method allows react-native app to sync with the metadata filesystem
    @discardableResult
    public func sync() -> [[String:Any]] {
        if(updatesToSync.count == 0) {
            getUpdatesToSync()
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
                    try files?.removeFile(metaData)
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
        let fileName = "\(metadata.truncatedFileName ?? "\(metadata.currentChunk).\(metadata.fileExtension)")"
        let filePath = metadata.fileDir.appendingPathComponent(fileName)
        return try files!.getFileSize(filePath: filePath)
    }
  
    // MARK: - Tasks
    /// Validates if startTasks() can run since we only want one instance of it at a time ever
    private func canRunTasks(isFiltered: Bool) -> Bool {
        // Prevent spamming this method
        if isFiltered != true {
            if isStartingAllTasks {
                return false
            }
            isStartingAllTasks = true
        }
      
        // Prevent running a million requests on a multiplexed HTTP/2 connection
        if uploadTasksRunning >= maxConcurrentUploads {
            if isFiltered != true {
                isStartingAllTasks = false
            }
            //print("TUSClient.startTasks running maximum concurrent tasks")
            /* When max tasks reached check if we have at least 300 MB left of free memory.
             If not kill the session (no more tasks will be spawned until all tasks that were running before freeMemory was called finish).
             Alleviates memory leak from large quantity batch uploads from URLSession delegate.
             You may also see this hit max memory while document picker is importing images from external media */
            let bytesAvailable = os_proc_available_memory()
            let megaBytesAvailable = (bytesAvailable  / 1024) / 1024
            if(megaBytesAvailable < 300) {
                freeMemory()
            }
            return false
        }
        return true
    }
    
    private func canRunTask(isFiltered: Bool) -> Bool {
        if self.uploadTasksRunning >= self.maxConcurrentUploads {
            if isFiltered != true {
                self.isStartingAllTasks = false
                //print("isStartingAllTasks unlocked")
            }
            //print("TUSClient.startTasks running maximum concurrent tasks")
            return false
        }
        return true
    }
    
    public func removeUploadManifest(_ uploadManifestId: String) -> Bool {
        do {
            let result = try self.files!.removeUploadManifest(uploadManifestId)
            return result
        }  catch {
            print(error)
            return false
        }
    }
    
    /// Check which uploads aren't finished. Load them from a store and turn these into tasks.
    public func startTasks(for uuids: [UUID]?, processFailedItemsIfEmpty: Bool? = false) {
        if isPaused || isBatchProcessingFile || isSessionInvalidated {
            return
        }
        
        autoreleasepool {
            do {
                if !canRunTasks(isFiltered: uuids != nil) {
                    return
                }
                
                let uuidStrings = uuids?.map({ uuid in
                    return uuid.uuidString
                })
                var failedItems: [UploadMetadata] = []
                var ignoredFromUploadManifestQueue: [UploadMetadata] = []
                var metaDataItems = try files?.loadAllMetadata(uuidStrings).filter({ metaData in
                    // Only allow uploads where errors are below an amount
                    // Commented this out because it was impossible to make work with a queue, downside is if an item continually fails it will block the whole queue
                    /*if metaData.errorCount > retryCount {
                        failedItems.append(metaData)
                        return false
                    } else {*/
                        // Check priority of upload queue based on upload manifest ID metadata
                        let uploadManifestQueue = try self.files!.loadUploadQueue()
                        let uploadManifestToPrioritize = uploadManifestQueue.first
                        if(uploadManifestToPrioritize != nil) {
                            let uploadManifestId = metaData.context?[UPLOAD_MANIFEST_METADATA_KEY]
                            if(uploadManifestId != uploadManifestToPrioritize?.uploadManifestId) {
                                ignoredFromUploadManifestQueue.append(metaData)
                                return false
                            }
                        }
                        return !metaData.isFinished
                   // }
                })
                
                // Safe guard in case the upload queue doesn't work properly to avoid dead locks
                if(metaDataItems?.count ?? 0 == 0 && ignoredFromUploadManifestQueue.count > 0) {
                    metaDataItems = ignoredFromUploadManifestQueue
                }
                
                // If list exhausted, process failed items queue
               /* if (metaDataItems?.count ?? 0 == 0) && processFailedItemsIfEmpty == true {
                    //print("TUSClient processing failed queue")
                    metaDataItems = failedItems
                }*/
                
                if metaDataItems?.count ?? 0 > 0 {
                    // Prevent duplicate tasks
                    self.session?.getAllTasks(completionHandler: { [weak self] tasks in
                        //print("Pending tasks count: \(tasks.count)")
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
                                            //print("isStartingAllTasks unlocked")
                                        }
                                        //print("isStartingAllTasks is still locked")
                                        return
                                    }
                                }
                                return runningTaskIds
                            }
                            let runningTaskIds = toTaskIds()
                            
                            for metaData in metaDataItems! {
                                uuid = metaData.id.uuidString
                                
                                // Prevent running a million requests on a multiplexed HTTP/2 connection
                                if !self.canRunTask(isFiltered: uuids != nil) {
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
                            self?.delegate?.fileError(id: uuid, errorMessage: "Start Tasks getAllTasks: \(error.localizedDescription)")
                            print(error)
                        }
                    })
                } else {
                    self.isStartingAllTasks = false
                }
            } catch (let error) {
                if uuids == nil {
                    isStartingAllTasks = false
                }
                delegate?.fileError(id: "", errorMessage: "Start Tasks: \(error.localizedDescription)")
            }
        }
    }
    
    /// Status task to find out where to continue from if endpoint exists in metadata,
    /// Creation task if no upload endpoint in metadata
    /// - Parameter metaData:The metaData for file to upload.
    private func startTask(for metaData: UploadMetadata) throws {
        if isPaused {
            return
        }
        
        if(metaData.isFinished) {
            return
        }
        
        // Prevent running a million requests on a multiplexed HTTP/2 connection
        if uploadTasksRunning >= maxConcurrentUploads {
            return
        }

         // Prevent using invalidated session
        if isSessionInvalidated {
            return
        }

        uploadTasksRunning += 1
        
        if metaData.remoteDestination != nil {
            api!.getStatusTask(metaData: metaData).resume()
        } else {
            api!.getCreationTask(metaData: metaData).resume()
        }
    }
    
    private func processCreationTaskResult(for id: String, response: HTTPURLResponse) {
        //print("Processing CreationTask result")
        
        do {
            guard let location = response.locationHeader() else {
                throw TUSClientError.couldNotCreateFileOnServer(responseCode: response.statusCode)
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
            
            if !isSessionInvalidated {
                let currentChunkFileSize = try getChunkSize(for: metaData)
                api!.getUploadTask(metaData: metaData, currentChunkFileSize: currentChunkFileSize).resume()
            } else if uploadTasksRunning > 0 {
                uploadTasksRunning -= 1
            }
        } catch let error {
            processFailedTask(for: id, errorMessage: error.localizedDescription)
        }
    }
    
    private func processStatusTaskResult(for id: String, response: HTTPURLResponse) {
        print("-----\nProcessing StatusTask result for \(id)")
        do {
            // Load metadata from disk
            let metaData = try loadMetadata(for: id)
            
            // If status code is 404, either do creation task or remove file
            if(response.statusCode == 404) {
                processFinishedFile(for: metaData)
                return
            }
            
            guard let length = response.uploadLengthHeader() else {
                throw TUSAPIError.couldNotFetchStatus
            }
            
            guard let serverExpectedOffset = response.uploadOffsetHeader() else {
                throw TUSAPIError.couldNotFetchStatus
            }
            
            if length != metaData.size {
                throw TUSClientError.fileSizeMismatchWithServer
            }
            
            if serverExpectedOffset > metaData.size {
                throw TUSClientError.fileSizeMismatchWithServer
            }
            
            // Set last uploaded range to match server
            metaData.uploadedRange = 0..<serverExpectedOffset
            try saveMetadata(metaData: metaData)
            
            if serverExpectedOffset == metaData.size {
                processFinishedFile(for: metaData)
            } else {
                var currentChunkFileSize = try getChunkSize(for: metaData)
                var clientExpectedOffset = (metaData.currentChunk * metaData.chunkSize) + metaData.truncatedOffset
                
                var endOfCurrentChunk = (metaData.currentChunk * metaData.chunkSize) + min(metaData.chunkSize, metaData.size)
                if metaData.chunkSize == -1 {
                    clientExpectedOffset = 0 + metaData.truncatedOffset
                    endOfCurrentChunk = metaData.size
                }
                
                /*print("Starting UploadTask\nID: \(id)\nCHUNK: \(metaData.currentChunk)\nSERVER EXPECTED OFFSET: \(serverExpectedOffset)\nCLIENT EXPECTED OFFSET \(clientExpectedOffset)\nCURRENT CHUNK FILESIZE: \(currentChunkFileSize)\nTOTAL FILE SIZE: \(metaData.size)\n END OF CURRENT CHUNK: \(endOfCurrentChunk)\n------")
                 try files?.printFileDirContents(url: metaData.fileDir)*/
                
                // Handle incorrect chunk (server successfully received file but client didn't process response and has stale chunk number)
                if serverExpectedOffset >= endOfCurrentChunk {
                    if metaData.chunkSize == -1 {
                        throw TUSClientError.receivedUnexpectedOffset
                    }
                    var correctChunk = 0
                    var byteCounter = 0
                    while(byteCounter < serverExpectedOffset) {
                        byteCounter += metaData.chunkSize
                        correctChunk += 1
                    }
                    //print("Updated chunk to \(correctChunk)")
                    metaData.currentChunk = correctChunk
                    try saveMetadata(metaData: metaData)
                    
                    currentChunkFileSize = try getChunkSize(for: metaData)
                    clientExpectedOffset = (metaData.chunkSize != -1 ? (metaData.currentChunk * metaData.chunkSize) : 0) + metaData.truncatedOffset
                }
                // Handle client thinking server received it but it didnt
                else if serverExpectedOffset < clientExpectedOffset {
                    var correctChunk = 0
                    var byteCounter = 0
                    while(byteCounter < serverExpectedOffset) {
                        byteCounter += (metaData.chunkSize != -1 ? metaData.chunkSize : 0)
                        correctChunk += 1
                    }
                    
                    // Need to either rechunk the file correctly or reset to original file
                    if correctChunk == metaData.currentChunk {
                        if serverExpectedOffset == (metaData.chunkSize != -1 ? (metaData.chunkSize * metaData.currentChunk) : 0) {
                            metaData.truncatedFileName = nil
                            metaData.truncatedOffset = 0
                            try saveMetadata(metaData: metaData)
                            
                            currentChunkFileSize = try getChunkSize(for: metaData)
                            clientExpectedOffset = serverExpectedOffset
                        } else {
                            // @TODO rechunk the file correctly
                        }
                    }
                }
                
                // If client and server have incorrect offsets then we may need to adjust file size
                if clientExpectedOffset < serverExpectedOffset {
                    var offsetDifference = serverExpectedOffset - clientExpectedOffset
                    if(metaData.chunkSize == -1) {
                        offsetDifference = serverExpectedOffset
                    }
                    // Create a truncated copy of the current chunked file that starts from expected offset
                    try files?.truncateChunk(metaData: metaData, offset: offsetDifference)
                    
                    delegate?.progressFor(id: metaData.id, bytesUploaded: metaData.chunkSize == -1 ? offsetDifference : (metaData.uploadedRange?.upperBound ?? 0), totalBytes: metaData.size)
                    currentChunkFileSize = try getChunkSize(for: metaData)
                }
                
                if !isSessionInvalidated {
                    api!.getUploadTask(metaData: metaData, currentChunkFileSize: currentChunkFileSize).resume()
                } else if uploadTasksRunning > 0 {
                    uploadTasksRunning -= 1
                }
            }
            
        } catch let error {
            print(error)
            processFailedTask(for: id, errorMessage: "\(error.localizedDescription) - status code: \(response.statusCode)\n-----")
        }
    }
    
    
    private func processUploadTaskResult(for id: String, response: HTTPURLResponse) {
        //print("-----\nProcessing UploadTask result for \(id)")
        do {
            // Load metadata from disk
            let metaData = try loadMetadata(for: id)
            
            guard let offset = response.uploadOffsetHeader() else {
                print("UploadTask \(id) error: \(response.statusCode)\nReceived offset: \(String(describing: response.value(forHTTPHeaderField: "upload-offset")))")
                
                // Most likely 409 bad offset, throw error so processFailedTask runs
                // and spawns a creation or status task to take care of it
                throw TUSAPIError.couldNotRetrieveOffset
            }
        
            
            let currentChunkFileSize = try getChunkSize(for: metaData)
            if(metaData.chunkSize != -1 && offset >= ((metaData.chunkSize * metaData.currentChunk) + currentChunkFileSize)) {
                metaData.currentChunk += 1
                metaData.truncatedFileName = nil
            }
            
            let currentOffset = metaData.uploadedRange?.upperBound ?? 0
            metaData.uploadedRange = 0..<offset
            metaData.errorCount = 0
            metaData.truncatedOffset = 0
            
            try saveMetadata(metaData: metaData)

            if metaData.isFinished {
                processFinishedFile(for: metaData)
                return
            }
            else if offset == currentOffset {
                print("Processing UploadTask \(id) error: \(response.statusCode)\nReceived offset: \(offset) which is equal to current offset \(currentOffset)")
                // metaData.currentChunk -= 1
                throw TUSClientError.receivedUnexpectedOffset
            }
            
            delegate?.progressFor(id: metaData.id, bytesUploaded: metaData.uploadedRange?.upperBound ?? 0, totalBytes: metaData.size)
            
            if let range = metaData.uploadedRange {
                let chunkSize = range.count
                let upperBound = min((offset + chunkSize), metaData.size)
                if(offset > upperBound) {
                    print("Received offset: \(offset)\nchunkSize: \(chunkSize)\nmetaData.size: \(metaData.size)")
                    throw TUSClientError.receivedUnexpectedOffset
                }
            }
            
            // Upload remainder of file
            let newCurrentChunkFileSize = try getChunkSize(for: metaData)
            //print("Uploading next \(newCurrentChunkFileSize) bytes for \(metaData.id.uuidString)\n-----")
            
            if !isSessionInvalidated {
              api!.getUploadTask(metaData: metaData, currentChunkFileSize: newCurrentChunkFileSize).resume()
            } else if uploadTasksRunning > 0 {
              uploadTasksRunning -= 1
            }
        } catch let error {
            processFailedTask(for: id, errorMessage: "\(error.localizedDescription) - status code: \(response.statusCode)\n-----")
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
                    delegate?.uploadFailed(id: metaData.id, error: otherError.localizedDescription)
                }
            } else { // Exhausted all retries, reporting back as failure.
                startTasks(for: nil)
                if(errorMessage.contains("couldn’t be opened because there is no such file")) {
                    try files?.printFileDirContents(url: metaData.fileDir)
                }
                delegate?.uploadFailed(id: metaData.id, error: errorMessage)
            }
        } catch let fileError {
            startTasks(for: nil)
            // Make sure we pass over original error message along with any new error messages
            // specifically so we can parse UUID out of it in react-native if the error `metaDataFileNotFound`
            delegate?.fileError(id: id, errorMessage: "\(fileError.localizedDescription) \(errorMessage)" )
        }
    }
        
    private func processFinishedFile(for metaData: UploadMetadata) {
        //print("\(metaData.id.uuidString) finished")
        do {
            // Update counter
            if uploadTasksRunning > 0 {
                uploadTasksRunning -= 1
            }
            
            try files?.removeFile(metaData)
            
            // Make sure maximum tasks are running if any exist
            startTasks(for: nil, processFailedItemsIfEmpty: true)
        } catch let error {
            delegate?.fileError(id: metaData.id.uuidString, errorMessage: error.localizedDescription)
        }
        delegate?.didFinishUpload(id: metaData.id)
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
        //print("didComplete")
        
        do {
            guard let taskDescription = try task.toTaskDescription() else {
                return
            }
            
            if task.progress.isCancelled {
                if uploadTasksRunning > 0 {
                    uploadTasksRunning -= 1
                }
                return
            }
            
            // Failed or canceled
            if let error = error {
                if (error as NSError).code == NSURLErrorCancelled {
                    if uploadTasksRunning > 0 {
                        uploadTasksRunning -= 1
                    }
                    return
                }
                processFailedTask(for: taskDescription.uuid, errorMessage: error.localizedDescription)
                return
            }

            // No response
            if task.response == nil {
                if uploadTasksRunning > 0 {
                    uploadTasksRunning -= 1
                }
                processFailedTask(for: taskDescription.uuid, errorMessage: "Failed to obtain response")
                return
            }
            
            // Success
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
            } catch _ {
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

        if isSessionInvalidated {
            self.initSession()
            self.startTasks(for: nil)
        }
    }
    
    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        print("didBecomeInvalidWithError")
        print(error ?? "no error")

        self.isSessionInvalidated = true
        self.initSession()
        self.startTasks(for: nil)
    }
}

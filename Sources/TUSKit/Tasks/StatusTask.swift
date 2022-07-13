//
//  StatusTask.swift
//  
//
//  Created by Tjeerd in ‘t Veen on 21/09/2021.
//

import Foundation

/// A `StatusTask` fetches the status of an upload. It fetches the offset from we can continue uploading, and then makes a possible uploadtask.
@available(iOS 13.4, *)
final class StatusTask {

    // TODO Should check if offset matches the correct chunk and adjust if not
    /*{ [weak self] result in
            guard let self = self else { return }
            let metaData = self.metaData
            let files = self.files
            let chunkSize = self.metaData.chunkSize
            let api = self.api
            let progressDelegate = self.progressDelegate
            
            do {
                let status = try result.get()
                let length = status.length
                let offset = status.offset
                if length != metaData.size {
                    throw TUSClientError.fileSizeMismatchWithServer
                }
                
                if offset > metaData.size {
                    throw TUSClientError.fileSizeMismatchWithServer
                }
                
                metaData.uploadedRange = 0..<offset
                
                try files.encodeAndStore(metaData: metaData)
                
                if offset == metaData.size {
                    completed(.success([]))
                } else {
                    // If the task has been canceled
                    // we don't continue to create subsequent UploadDataTasks
                    if self.didCancel {
                        return
                    }
                    
                    let nextRange = offset..<min((offset + chunkSize), metaData.size)
                    
                    let task = try UploadDataTask(api: api, metaData: metaData, files: files, range: nextRange)
                    task.progressDelegate = progressDelegate
                    completed(.success([task]))
                }
            } catch let error as TUSClientError {
                completed(.failure(error))
            } catch {
                completed(.failure(TUSClientError.couldNotGetFileStatus))
            }
            
        }*/
  
}


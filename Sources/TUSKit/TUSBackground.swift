//
//  TUSBackground.swift
//  
//
//  Created by Tjeerd in ‘t Veen on 23/09/2021.
//

import Foundation
import BackgroundTasks

#if os(iOS)

/// Perform background uploading
@available(iOS 13.4, *)
final class TUSBackground {
    
    // Same as in the Info.plist `Permitted background task scheduler identifiers`
    private static let identifier = "io.tus.uploading"
    
    // Restrict maximum running tasks
    private var maxConcurrentTasks: Int
    
    private var pendingTasks: [ScheduledTask] = []
    private var runningTasks: [ScheduledTask] = []
    private let api: TUSAPI
    private let files: Files
    private let chunkSize: Int
    
    init(api: TUSAPI, files: Files, chunkSize: Int, maxConcurrentTasks: Int) {
        self.api = api
        self.files = files
        self.chunkSize = chunkSize
        self.maxConcurrentTasks = maxConcurrentTasks
    }
    
    func registerForBackgroundTasks() {
#if targetEnvironment(simulator)
        return
#else
        BGTaskScheduler.shared.register(forTaskWithIdentifier: TUSBackground.identifier, using: nil) { [weak self] bgTask in
            guard let self = self else {
                return
            }
            guard let backgroundTask = bgTask as? BGProcessingTask else {
                return
            }
            
            guard let tusTask = self.firstRunnableTask() else {
                backgroundTask.setTaskCompleted(success: true)
                return
            }
            
            // Mark task as running
            self.movePendingTaskToRunning(task: tusTask)
            
            backgroundTask.expirationHandler = {
                print("Task expired")
                // Remove UUID so tasks can be spawned for this file
                self.removeRunningTask(task: tusTask)
                
                // Clean up so app won't get terminated and negatively impact iOS'background rating.
                tusTask.cancel()
                
                self.scheduleSingleTask()
            }
            
            print ("Running \(tusTask.taskType)")
            do {
                try tusTask.run { result in
                    print ("\(tusTask.taskType) finished")
                    
                    // Remove UUID so tasks can be spawned for this file
                    self.removeRunningTask(task: tusTask)
                    
                    var scheduled = false
                    switch result {
                    case .success(let newTasks):
                        if(newTasks.count > 0) {
                            self.scheduleSingleTask(inputTask: newTasks[0])
                            scheduled = true
                        }
                        backgroundTask.setTaskCompleted(success: true)
                    case .failure:
                        backgroundTask.setTaskCompleted(success: false)
                    }
                    
                    if(!scheduled) {
                        self.scheduleSingleTask()
                    }
                }
                
                // Schedule as many concurrent tasks as possible
                let runningTasks = self.runningTasks.count
                if runningTasks < self.maxConcurrentTasks {
                    self.scheduleSingleTask()
                }
            } catch let error {
                print("\(tusTask.taskType) failed: \(error.localizedDescription)")
                backgroundTask.setTaskCompleted(success: false)
                self.scheduleSingleTask()
            }
        }
#endif
    }
    
    func getPendingBackgroundTasks () -> Void {
        BGTaskScheduler.shared.getPendingTaskRequests { pendingTaskRequests in
            print(pendingTaskRequests)
        }
    }
    
    func scheduleBackgroundTasks() -> Bool {
        #if targetEnvironment(simulator)
        print("Background tasks aren't supported on simulator (iOS limitation). Ignoring.")
        return false
        #else
        return self.scheduleSingleTask()
        #endif
    }
    
    /// Try and schedule another task. But, might not schedule a task if none are available.
    private func scheduleSingleTask(inputTask: ScheduledTask? = nil) -> Bool {
        guard let task = (inputTask == nil ? firstScheduableTask() : inputTask) else {
            print("Skipping scheduleSingleTask")
            return false
        }
        
        let request = BGProcessingTaskRequest(identifier: TUSBackground.identifier)
        request.requiresNetworkConnectivity = true
        do {
            print("\(task.taskType) submitted")
            try BGTaskScheduler.shared.submit(request)
            
            // Keep track of pending tasks so we don't spam 1000 of the same task.
            // Task is pending until OS decides when BGTaskScheduler.shared.register
            // should pick up the task and run it, but parent will typically call this
            // method whenever app goes into background
            self.pendingTasks.append(task)
            //self.getPendingBackgroundTasks()
            return true
        } catch {
            print("Could not schedule background task \(error)")
            return false
        }
    }
    
    private func firstRunnableTask() -> ScheduledTask? {
        return firstTask(filterOnPending: true)
    }
    
    //
    private func firstScheduableTask() -> ScheduledTask? {
        return firstTask()
    }
    
    /// Return first available task
    /// - Parameter filterOnPending: If true will only return tasks that are not running and are currently in the pending list
    /// - default is false and will only filter out running tasks and pending tasks
    /// - Returns: A possible task to run
    private func firstTask(filterOnPending: Bool = false) -> ScheduledTask? {
        guard let allMetaData = try? files.loadAllMetadata() else {
            return nil
        }
        
        // Filter out running tasks
        let filteredMetaData = allMetaData.filter { metaData in
            let isRunning = self.runningTasks.firstIndex(where: {$0.id == metaData.id }) != nil
            if isRunning {
                return false
            }
            
            let isPending = self.pendingTasks.firstIndex(where: {$0.id == metaData.id }) != nil
            return filterOnPending ? isPending : !isPending
        }
        
        return filteredMetaData.firstMap { metaData in
            try? taskFor(metaData: metaData, api: api, files: files, chunkSize: chunkSize)
        }
    }
    
    private func removeRunningTask(task: ScheduledTask) -> Void {
        let taskIndex = self.runningTasks.firstIndex(where: {$0 === task})
        if (taskIndex != nil) {
            self.runningTasks.remove(at: taskIndex!)
        }
    }
    
    private func removePendingTask(task: ScheduledTask) -> Void {
        let taskIndex = self.pendingTasks.firstIndex(where: {$0 === task})
        if (taskIndex != nil) {
            self.pendingTasks.remove(at: taskIndex!)
        }
    }
    
    private func movePendingTaskToRunning(task: ScheduledTask) -> Void {
        self.removePendingTask(task: task)
        self.runningTasks.append(task)
    }
}
private extension Array {
    /// `firstMap` is like `first(where:)`, but instead of returning the first element of the array, it returns the first transformed (mapped) element .
    /// You have to pass a `transform` closure. Whatever non-nil you return, will be returned from the method.
    /// - Parameter transform: An element to transform to. If it returns a new value, that value will be returned from this method.
    /// - Returns:An option new value.
    func firstMap<TransformedElement>(where transform: (Element) throws -> TransformedElement?) rethrows -> TransformedElement? {
        for element in self {
            if let otherElement = try transform(element) {
                return otherElement
            }
        }
        return nil
    }
}
#endif

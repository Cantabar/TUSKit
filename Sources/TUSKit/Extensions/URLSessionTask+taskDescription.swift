//
//  URLSessionTask+taskDescription.swift
//  TUSKit
//
//  Created by Tom Greco on 7/13/22.
//

import Foundation

extension URLSessionTask {
    func toJsonData() -> Data? {
        guard let taskDescriptionStr = self.taskDescription else {
            return nil
        }
        return taskDescriptionStr.data(using: .utf8)
    }
    
    func toTaskDescription() throws -> TaskDescription? {
        guard let taskDescriptionData = self.toJsonData() else {
            return nil
        }
        return try JSONDecoder().decode(TaskDescription.self, from: taskDescriptionData)
    }
}

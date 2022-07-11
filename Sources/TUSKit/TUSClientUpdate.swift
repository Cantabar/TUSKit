//
//  TUSClientUpdate.swift
//  TUSKit
//
//  Created by Tom Greco on 7/8/22.
//

import Foundation

/// When react-native app is ready it will call TUSClient.sync
/// to get in-sync with current progress that may have occurred in background tasks
public struct TUSClientUpdate {
    let id: UUID
    let bytesUploaded: Int
    let size: Int
    let errorCount: Int
    let name: String
    
    public init(id: UUID, bytesUploaded: Int, size: Int, errorCount: Int, name: String) {
        self.id = id
        self.bytesUploaded = bytesUploaded
        self.size = size
        self.errorCount = errorCount
        self.name = name
    }
}

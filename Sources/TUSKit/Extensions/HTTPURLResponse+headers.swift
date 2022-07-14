//
//  HTTPURLResponse+headers.swift
//  TUSKit
//
//  Created by Tom Greco on 7/13/22.
//

import Foundation

extension HTTPURLResponse {
    func locationHeader() -> String? {
        guard let location = self.allHeaderFields[caseInsensitive: "location"] as? String else {
            return nil
        }
        return location
    }
    
    func uploadLengthHeader() -> Int? {
        guard let lengthStr = self.allHeaderFields[caseInsensitive: "upload-length"] as? String else {
            return nil
        }
        return Int(lengthStr)
    }
    
    func uploadOffsetHeader() -> Int? {
        guard let receivedOffset = self.allHeaderFields[caseInsensitive: "upload-offset"] as? String else {
            return nil
        }
        return Int(receivedOffset)
    }
}

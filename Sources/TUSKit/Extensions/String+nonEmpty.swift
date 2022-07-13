//
//  String+nonEmpty.swift
//  TUSKit
//
//  Created by Tom Greco on 7/12/22.
//

import Foundation

extension String {
    
    /// Turn an empty string in a nil string, otherwise return self
    var nonEmpty: String? {
        if self.isEmpty {
            return nil
        } else {
            return self
        }
    }
}

//
//  DebugOptions.swift
//  TUSKit
//
//  Created by Tom Greco on 7/10/22.
//

import Foundation

/// Ignore print statements in release build
public func print(_ object: Any...) {
    //#if DEBUG
    for item in object {
        Swift.print(item)
    }
    //#endif
}

/// Ignore print statements in release build
public func print(_ object: Any) {
   // #if DEBUG
    Swift.print(object)
   // #endif
}


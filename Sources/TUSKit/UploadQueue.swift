//
//  Queue.swift
//  TUSKit
//
//  Created by Tom Greco on 6/5/23.
//

import Foundation

class UploadManifestFiles: Codable {
    var uploadManifestId: String
    var uuids: [UUID]
    
    init(uploadManifestId: String, uuids: [UUID]) {
        self.uploadManifestId = uploadManifestId
        self.uuids = uuids
    }
}

class UploadQueue: Codable {
    
    let queue = DispatchQueue(label: "com.tuskit.uploadqueue")

    enum CodingKeys: String, CodingKey {
        case uploadManifests
    }

    /// Holds array of maps where upload manifest IDs and UUIDs
    private var _uploadManifests: [UploadManifestFiles] = []
    var uploadManifests: [UploadManifestFiles] {
        get {
            queue.sync {
                _uploadManifests
            }
        } set {
            queue.async {
                self._uploadManifests = newValue
            }
        }
    }
    
    public init() {}
    
    var isEmpty: Bool {
        uploadManifests.isEmpty
    }
    
    var first: UploadManifestFiles? {
        if(isEmpty) {
            return nil
        }
        return uploadManifests.first
    }
    
    var peek: UploadManifestFiles? {
        uploadManifests.first
    }
    
    var description: String {
        if isEmpty { return "Queue is empty..." }
        return "---- Queue start ----\n"
            + uploadManifests.map({"\($0)"}).joined(separator: " -> ")
            + "\n---- Queue End ----"
    }
    
    /// Only adds elements to the queue if they don't exist in it already
    func enqueue(uploadManifestId: String, uuid: UUID) {
        let index = uploadManifests.firstIndex(where: { $0.uploadManifestId == uploadManifestId })
        guard let index = index else {
            let newUploadManifest = UploadManifestFiles(uploadManifestId: uploadManifestId, uuids: [uuid])
            uploadManifests.append(newUploadManifest)
            return
        }
        if(!uploadManifests[index].uuids.contains(uuid)) {
            uploadManifests[index].uuids.append(uuid)
        }
    }
    
    /// Removes item from queue
    func remove(uploadManifestId: String, uuid: UUID) {
        if(!isEmpty) {
            let uploadManifestIndex = uploadManifests.firstIndex(where: { $0.uploadManifestId == uploadManifestId })
            guard let uploadManifestIndex = uploadManifestIndex else {
                return
            }
            
            uploadManifests[uploadManifestIndex].uuids.removeAll(where: { $0 == uuid } )
            if(uploadManifests[uploadManifestIndex].uuids.isEmpty) {
                uploadManifests.remove(at: uploadManifestIndex)
            }
        }
    }
    
    required init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        _uploadManifests = try values.decode([UploadManifestFiles].self, forKey: .uploadManifests)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_uploadManifests, forKey: .uploadManifests)
    }
}

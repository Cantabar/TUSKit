//
//  TUSAPITests.swift
//  
//
//  Created by Tjeerd in ‘t Veen on 16/09/2021.
//

import Foundation

import XCTest
@testable import TUSKit

final class TUSAPITests: XCTestCase {
    
    var api: TUSAPI!
    var uploadURL: URL!
    
    override func setUp() {
        super.setUp()
        
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession.init(configuration: configuration)
        uploadURL = URL(string: "www.tus.io")!
        api = TUSAPI(session: session)
    }
    
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.receivedRequests = []
    }
    
    func testStatus() throws {
        let length = 3000
        let offset = 20
        let chunkSize = 3 * 1024
        MockURLProtocol.prepareResponse(for: "HEAD") { _ in
            MockURLProtocol.Response(status: 200, headers: ["Upload-Length": String(length), "Upload-Offset": String(offset)], data: nil)
        }
        
        let statusExpectation = expectation(description: "Call api.status()")
        let remoteFileURL = URL(string: "https://tus.io/myfile")!
        
        let metaData = UploadMetadata(id: UUID(),
                                      fileDir: URL(string: "file://whatever/")!,
                                      uploadURL: URL(string: "io.tus")!,
                                      size: length,
                                      chunkSize: chunkSize, fileExtension: ".png")
        metaData.remoteDestination = URL(string: "http://123")
        let task = api.getStatusTask(metaData: metaData)
        task.resume()
        XCTAssertEqual(length, task.response?.value(forKey: "length") as! Int)
        XCTAssertEqual(offset, task.response?.value(forKey: "offset") as! Int)
        statusExpectation.fulfill()
        
        waitForExpectations(timeout: 3, handler: nil)
    }
    
 
    func testUpload() throws {
        let data = Data("Hello how are you".utf8)
        MockURLProtocol.prepareResponse(for: "PATCH") { _ in
            MockURLProtocol.Response(status: 200, headers: ["Upload-Offset": String(data.count)], data: nil)
        }
        
        let offset = 2
        let length = data.count
        let range = offset..<data.count
        let uploadExpectation = expectation(description: "Call api.upload()")
        let metaData = UploadMetadata(id: UUID(),
                                      fileDir: URL(string: "file://whatever/")!,
                                      uploadURL: URL(string: "io.tus")!,
                                      size: length,
                                      chunkSize: 3 * 1024,
                                      fileExtension: ".png")
        metaData.remoteDestination = URL(string: "http://123")
        
        
        let task = api.getUploadTask(metaData: metaData, currentChunkFileSize: length)
        task.resume()
        XCTAssertEqual(task.originalRequest?.url, uploadURL)
        
        waitForExpectations(timeout: 3, handler: nil)
        
        let headerFields = try XCTUnwrap(MockURLProtocol.receivedRequests.first?.allHTTPHeaderFields)
        let expectedHeaders: [String: String] =
        [
            "TUS-Resumable": "1.0.0",
            "Content-Type": "application/offset+octet-stream",
            "Upload-Offset": String(offset),
            "Content-Length": String(length)
        ]
        
        XCTAssertEqual(headerFields, expectedHeaders)
    }
    
    func testUploadWithRelativePath() throws {
        let chunkSize = 3 * 1024
        let data = Data("Hello how are you".utf8)
        let baseURL = URL(string: "https://tus.example.org/files")!
        let relativePath = "files/24e533e02ec3bc40c387f1a0e460e216"
        let uploadURL = URL(string: relativePath, relativeTo: baseURL)!
        let expectedURL = URL(string: "https://tus.example.org/files/24e533e02ec3bc40c387f1a0e460e216")!
        MockURLProtocol.prepareResponse(for: "PATCH") { _ in
            MockURLProtocol.Response(status: 200, headers: ["Upload-Offset": String(data.count)], data: nil)
        }
        
        let offset = 2
        let length = data.count
        let uploadExpectation = expectation(description: "Call api.getUploadTask()")
        let metaData = UploadMetadata(id: UUID(),
                                      fileDir: URL(string: "file://whatever/")!,
                                      uploadURL: uploadURL,
                                      size: length,
                                      chunkSize: chunkSize,
                                      fileExtension: ".png")
        metaData.remoteDestination = URL(string: "http://123")
        let task = api.getUploadTask(metaData: metaData, currentChunkFileSize: length)
        uploadExpectation.fulfill()
        XCTAssertEqual(task.originalRequest?.url, expectedURL)
        
        waitForExpectations(timeout: 3, handler: nil)
        
        let headerFields = try XCTUnwrap(MockURLProtocol.receivedRequests.first?.allHTTPHeaderFields)
        let expectedHeaders: [String: String] =
        [
            "TUS-Resumable": "1.0.0",
            "Content-Type": "application/offset+octet-stream",
            "Upload-Offset": String(offset),
            "Content-Length": String(length)
        ]
        
        XCTAssertEqual(headerFields, expectedHeaders)
    }
    
}

import Foundation
import OSLog

final class FileLogger: ObservableObject {
    private static var instance: FileLogger? = nil
    
    let logger: Logger = {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier!,
            category: String(describing: FileLogger.self)
        )
        return logger
    }()
    
    private init() {}
    
    class func enable() {
        if(FileLogger.instance == nil) {
            FileLogger.instance = FileLogger()
        }
    }
    
    class func disable() {
        if(FileLogger.instance != nil) {
            FileLogger.instance = nil
        }
    }
    
    class func notice(_ message: String) {
        FileLogger.instance?.logger.notice("\(message)")
    }
    class func error(_ message: String) {
        FileLogger.instance?.logger.error("\(message)")
    }
    
    class func export() -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            return try store
                .getEntries()
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == Bundle.main.bundleIdentifier! }
                .map { "[\($0.date.formatted())] [\($0.category)] \($0.composedMessage)" }
        } catch {
            FileLogger.instance?.logger.warning("\(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

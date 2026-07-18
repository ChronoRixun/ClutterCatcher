import OSLog

enum Log {
    static let app = Logger(subsystem: "com.rixun.cluttercatcher", category: "app")
    static let data = Logger(subsystem: "com.rixun.cluttercatcher", category: "data")
}

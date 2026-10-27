import Foundation

public protocol FileSystem: Sendable {
    func contents(of url: URL) throws -> Data
    func size(of url: URL) throws -> Int
    func symbolicLinkDestination(of url: URL) -> String?
    func isExecutable(_ url: URL) -> Bool
    func directoryExists(_ url: URL) -> Bool
    func modificationDate(of url: URL) -> Date?
    func fileExists(_ url: URL) -> Bool
}

public struct LocalFileSystem: FileSystem {
    public init() {}

    public func contents(of url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func size(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    public func symbolicLinkDestination(of url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    public func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    public func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    public func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

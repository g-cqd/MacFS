import Foundation

/// The g-cqd analyzers lock, as aemi's `Scripts/analyzers.lock` writes it and `Scripts/analyzers.lock` copies it: one line per
/// tool, its version and the SHA-256 of its release archive for macOS arm64 and Linux x86_64 (roadmap 0010).
public struct AnalyzerLock: Sendable, Equatable {
    public struct Pin: Sendable, Equatable {
        public let tool: String
        public let version: String
        public let macOS: String
        public let linux: String

        public init(tool: String, version: String, macOS: String, linux: String) {
            self.tool = tool
            self.version = version
            self.macOS = macOS
            self.linux = linux
        }

        /// The release archive's name, without `.tar.gz`, for macOS arm64 (the only platform MacFS runs on).
        public var archive: String { "\(tool)-\(version)-macos-arm64" }

        public var url: String { "https://github.com/g-cqd/\(tool)/releases/download/v\(version)/\(archive).tar.gz" }
    }

    public struct Malformed: Error, Equatable {
        public let line: String
    }

    public let pins: [Pin]

    public init(_ text: String) throws(Malformed) {
        var pins: [Pin] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 4, Self.isDigest(fields[2]), Self.isDigest(fields[3]) else {
                throw Malformed(line: line)
            }
            pins.append(Pin(tool: fields[0], version: fields[1], macOS: fields[2], linux: fields[3]))
        }
        self.pins = pins
    }

    public init(contentsOf path: String) throws {
        try self.init(String(contentsOfFile: path, encoding: .utf8))
    }

    public subscript(tool: String) -> Pin? { pins.first { $0.tool == tool } }

    private static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }
    }
}

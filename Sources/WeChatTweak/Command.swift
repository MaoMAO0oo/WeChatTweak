//
//  Command.swift
//
//  Created by Sunny Young.
//

import Foundation
import ArgumentParser

struct Command {
    enum Error: @unchecked Sendable, LocalizedError {
        case executing(command: String, error: NSDictionary)

        var errorDescription: String? {
            switch self {
            case let .executing(command, error):
                return "executing: \(command) error: \(error)"
            }
        }
    }

    static func version(app: URL) async throws -> String? {
        try await Command.execute(executable: "/usr/bin/defaults", arguments: ["read", app.appendingPathComponent("Contents/Info.plist").path, "CFBundleVersion"])
    }

    @discardableResult
    static func patch(app: URL, config: Config) async throws -> [URL] {
        let requiresRuntime = config.targets.contains { $0.identifier == "revoke-marker" }
        var targets = config.targets
        var componentData: Data?
        if requiresRuntime {
            guard config.version == "270353" else { throw Tweak.Error.unsupportedVersion }
            let entries = try RuntimeLoader.entries(binary: app.appendingPathComponent(RuntimeLoader.binaryPath))
            targets.append(.init(identifier: "runtime-loader", binary: RuntimeLoader.binaryPath, entries: entries))
            componentData = try RuntimeLoader.runtimeData()
        }
        let groups = Dictionary(grouping: targets, by: \.binary)
        let plans = try groups.sorted(by: { $0.key < $1.key }).map { path, targets in
            try Patcher.prepare(binary: app.appendingPathComponent(path), config: Config(version: config.version, targets: targets))
        }
        var modified: [URL] = []
        if let componentData {
            let component = app.appendingPathComponent("Contents/Resources").appendingPathComponent(RuntimeLoader.libraryName)
            try componentData.write(to: component, options: .atomic)
            modified.append(component)
        }
        for plan in plans {
            try Patcher.apply(plan)
        }
        return modified + plans.map(\.binary)
    }

    static func resign(app: URL, modified: [URL]) async throws {
        for binary in modified {
            try await Command.execute(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", "--preserve-metadata=entitlements", binary.path])
        }
        try await Command.execute(executable: "/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements", app.path])
        try await Command.execute(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path])
    }

    @discardableResult
    private static func execute(executable: String, arguments: [String]) async throws -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Error.executing(command: ([executable] + arguments).joined(separator: " "), error: ["exitCode": process.terminationStatus, "output": text])
        }
        return text
    }
}

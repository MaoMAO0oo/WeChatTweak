import Foundation
import MachO
import XCTest
@testable import WeChatTweak

final class PatcherTests: XCTestCase {
    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func config(_ targets: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data("""
        {"version":"270353","targets":\(targets)}
        """.utf8))
    }

    private func thinBinary(cpu: Int32 = CPU_TYPE_ARM64) -> Data {
        var data = Data(repeating: 0, count: 512)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
        }
        put(UInt32(MH_MAGIC_64), at: 0)
        put(cpu, at: 4)
        put(UInt32(MH_DYLIB), at: 12)
        put(UInt32(1), at: 16)
        put(UInt32(72), at: 20)
        put(UInt32(LC_SEGMENT_64), at: 32)
        put(UInt32(72), at: 36)
        put(UInt64(0), at: 56)
        put(UInt64(512), at: 64)
        put(UInt64(0), at: 72)
        put(UInt64(512), at: 80)
        data.replaceSubrange(256..<264, with: [1, 2, 3, 4, 5, 6, 7, 8])
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func screenCaptureConfig() throws -> Config {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config.json")
        let profiles = try JSONDecoder().decode([Config].self, from: Data(contentsOf: file))
        let profile = try XCTUnwrap(profiles.first(where: { $0.version == "270353" }))
        let target = try XCTUnwrap(profile.targets.first(where: { $0.identifier == "screenshot-capture" }))
        return Config(version: profile.version, targets: [target])
    }

    private func screenCaptureBinary() -> Data {
        var data = thinBinary()
        // Frozen 270353 factory at VA 0x3a50138 maps to file offset 0x100.
        var address = UInt64(0x3a50038).littleEndian
        withUnsafeBytes(of: &address) { data.replaceSubrange(56..<64, with: $0) }
        data.replaceSubrange(256..<272, with: [0xff, 0x03, 0x02, 0xd1, 0xf8, 0x5f, 0x04, 0xa9,
                                              0xf6, 0x57, 0x05, 0xa9, 0xf4, 0x4f, 0x06, 0xa9])
        return data
    }

    func testScreenshotProfileReinstallsWithoutChangingOtherCodeOrLauncher() async throws {
        try await withDirectory { app in
            let core = app.appendingPathComponent(RuntimeLoader.binaryPath)
            let launcher = app.appendingPathComponent("Contents/MacOS/WeChat")
            let original = self.screenCaptureBinary()
            let originalLauncher = self.thinBinary()
            try self.write(original, to: core)
            try self.write(originalLauncher, to: launcher)
            let profile = try self.screenCaptureConfig()

            try await Command.patch(app: app, config: profile)
            let patched = try Data(contentsOf: core)
            XCTAssertNotEqual(patched.subdata(in: 256..<264), original.subdata(in: 256..<264))
            XCTAssertEqual(patched.subdata(in: 0..<256), original.subdata(in: 0..<256))
            XCTAssertEqual(patched.subdata(in: 264..<512), original.subdata(in: 264..<512))
            XCTAssertEqual(try Data(contentsOf: launcher), originalLauncher)
            try await Command.patch(app: app, config: profile)
            XCTAssertEqual(try Data(contentsOf: core), patched)
        }
    }

    func testScreenshotProfileRejectsChangedFactoryBeforeWriting() async throws {
        try await withDirectory { app in
            let core = app.appendingPathComponent(RuntimeLoader.binaryPath)
            var changed = self.screenCaptureBinary()
            changed[256] ^= 1
            try self.write(changed, to: core)
            let profile = try self.screenCaptureConfig()
            XCTAssertThrowsError(try Patcher.prepare(binary: core, config: profile))
            XCTAssertEqual(try Data(contentsOf: core), changed)
        }
    }

    func testPatchesDeclaredDylibAndLeavesLauncherUntouched() async throws {
        try await withDirectory { directory in
            let app = directory.appendingPathComponent("WeChat Test.app")
            let launcher = app.appendingPathComponent("Contents/MacOS/WeChat")
            let library = app.appendingPathComponent("Contents/Resources/wechat.dylib")
            let original = self.thinBinary()
            try self.write(original, to: launcher)
            try self.write(original, to: library)
            let config = try self.config("""
            [{"identifier":"revoke","binary":"Contents/Resources/wechat.dylib",
              "entries":[{"arch":"arm64","addr":"100","expected":"01020304","asm":"AABBCCDD"}]}]
            """)

            try await Command.patch(app: app, config: config)

            XCTAssertEqual(try Data(contentsOf: launcher), original)
            XCTAssertEqual(try Data(contentsOf: library).subdata(in: 256..<260), Data([0xaa, 0xbb, 0xcc, 0xdd]))
        }
    }

    func testOldConfigStillPatchesLauncher() async throws {
        try await withDirectory { directory in
            let binary = directory.appendingPathComponent("Contents/MacOS/WeChat")
            try self.write(self.thinBinary(), to: binary)
            let config = try self.config("""
            [{"identifier":"revoke","entries":[{"arch":"arm64","addr":"100","asm":"AABBCCDD"}]}]
            """)
            try await Command.patch(app: directory, config: config)
            XCTAssertEqual(try Data(contentsOf: binary).subdata(in: 256..<260), Data([0xaa, 0xbb, 0xcc, 0xdd]))
        }
    }

    func testWrongOriginalBytesDoNotModifyAnyTarget() async throws {
        try await withDirectory { directory in
            let binary = directory.appendingPathComponent("Contents/MacOS/WeChat")
            let original = self.thinBinary()
            try self.write(original, to: binary)
            let config = try self.config("""
            [{"identifier":"revoke","entries":[
              {"arch":"arm64","addr":"100","expected":"01020304","asm":"AABBCCDD"},
              {"arch":"arm64","addr":"104","expected":"00000000","asm":"AABBCCDD"}]}]
            """)
            do {
                try await Command.patch(app: directory, config: config)
                XCTFail("A different instruction sequence must be rejected")
            } catch {
                XCTAssertEqual(try Data(contentsOf: binary), original)
            }
        }
    }

    func testRepeatPatchIsIdempotent() async throws {
        try await withDirectory { directory in
            let binary = directory.appendingPathComponent("Contents/MacOS/WeChat")
            try self.write(self.thinBinary(), to: binary)
            let config = try self.config("""
            [{"identifier":"revoke","entries":[{"arch":"arm64","addr":"100","expected":"01020304","asm":"AABBCCDD"}]}]
            """)
            try await Command.patch(app: directory, config: config)
            let patched = try Data(contentsOf: binary)
            try await Command.patch(app: directory, config: config)
            XCTAssertEqual(try Data(contentsOf: binary), patched)
        }
    }

    func testRejectsUnmatchedArchitecture() async throws {
        try await withDirectory { directory in
            let binary = directory.appendingPathComponent("Contents/MacOS/WeChat")
            let original = self.thinBinary(cpu: CPU_TYPE_X86_64)
            try self.write(original, to: binary)
            let config = try self.config("""
            [{"identifier":"revoke","entries":[{"arch":"arm64","addr":"100","asm":"AABBCCDD"}]}]
            """)
            do {
                try await Command.patch(app: directory, config: config)
                XCTFail("An arm64 patch cannot modify an x86_64-only binary")
            } catch {
                XCTAssertEqual(try Data(contentsOf: binary), original)
            }
        }
    }

    func testRejectsAtomicFileReplacementAfterPreparation() async throws {
        try await withDirectory { directory in
            let binary = directory.appendingPathComponent("WeChat")
            let original = self.thinBinary()
            try self.write(original, to: binary)
            let config = try self.config("""
            [{"identifier":"revoke","entries":[{"arch":"arm64","addr":"100","expected":"01020304","asm":"AABBCCDD"}]}]
            """)
            let plan = try Patcher.prepare(binary: binary, config: config)
            var replacement = original
            replacement.replaceSubrange(256..<260, with: [9, 9, 9, 9])
            try replacement.write(to: binary, options: .atomic)
            do {
                try Patcher.apply(plan)
                XCTFail("A replacement binary must not receive an old write plan")
            } catch {
                XCTAssertEqual(try Data(contentsOf: binary), replacement)
            }
        }
    }

    func testRejectsInstructionChangesAfterPreparationBeforeAnyWrite() async throws {
        try await withDirectory { directory in
            let binary = directory.appendingPathComponent("WeChat")
            let original = self.thinBinary()
            try self.write(original, to: binary)
            let config = try self.config("""
            [{"identifier":"revoke","entries":[
              {"arch":"arm64","addr":"100","expected":"01020304","asm":"AABBCCDD"},
              {"arch":"arm64","addr":"104","expected":"05060708","asm":"AABBCCDD"}]}]
            """)
            let plan = try Patcher.prepare(binary: binary, config: config)
            var modified = original
            modified.replaceSubrange(260..<264, with: [9, 9, 9, 9])
            try modified.write(to: binary)
            do {
                try Patcher.apply(plan)
                XCTFail("Changed instructions must be rejected before the first write")
            } catch {
                XCTAssertEqual(try Data(contentsOf: binary), modified)
            }
        }
    }
}

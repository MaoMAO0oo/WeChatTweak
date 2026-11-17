import Foundation
import MachO
import XCTest
@testable import WeChatTweak

final class RuntimeLoaderTests: XCTestCase {
    private func binary(uuid: UUID = RuntimeLoader.profileUUID) -> Data {
        var data = Data(repeating: 0, count: 1024)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
        }
        put(UInt32(MH_MAGIC_64), at: 0)
        put(Int32(CPU_TYPE_ARM64), at: 4)
        put(UInt32(MH_DYLIB), at: 12)
        put(UInt32(2), at: 16)
        put(UInt32(176), at: 20)
        put(UInt32(LC_SEGMENT_64), at: 32)
        put(UInt32(152), at: 36)
        data.replaceSubrange(40..<46, with: Data("__TEXT".utf8))
        put(UInt64(1024), at: 64)
        put(UInt64(1024), at: 80)
        put(UInt32(1), at: 96)
        data.replaceSubrange(104..<110, with: Data("__text".utf8))
        data.replaceSubrange(120..<126, with: Data("__TEXT".utf8))
        put(UInt64(512), at: 136)
        put(UInt64(512), at: 144)
        put(UInt32(512), at: 152)
        put(UInt32(LC_UUID), at: 184)
        put(UInt32(24), at: 188)
        var rawUUID = uuid.uuid
        withUnsafeBytes(of: &rawUUID) { data.replaceSubrange(192..<208, with: $0) }
        return data
    }

    private func apply(_ file: URL) throws {
        let loader = try RuntimeLoader.entries(binary: file)
        let nop = Config.Entry(arch: .arm64, addr: 512, asm: Data(repeating: 0, count: 4), expected: Data(repeating: 0, count: 4))
        let config = Config(version: "270353", targets: [.init(identifier: "revoke-marker", entries: [nop] + loader)])
        try Patcher.patch(binary: file, config: config)
    }

    func testAddsRuntimeDependencyWithoutChangingMessageCode() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = binary()
        try original.write(to: file)
        try apply(file)
        let result = try Data(contentsOf: file)
        XCTAssertEqual(result.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }, 3)
        XCTAssertNotNil(result.range(of: Data("@loader_path/libWeChatTweakRuntime.dylib\0".utf8)))
        XCTAssertEqual(result.subdata(in: 512..<1024), original.subdata(in: 512..<1024))
    }

    func testReinstallDoesNotAppendAnotherDependency() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try binary().write(to: file)
        try apply(file)
        let installed = try Data(contentsOf: file)
        try apply(file)
        XCTAssertEqual(try Data(contentsOf: file), installed)
        XCTAssertEqual(installed.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }, 3)
    }

    func testRejectsAnotherBuildUUIDWithoutAnyWrites() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = binary(uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        try original.write(to: file)
        XCTAssertThrowsError(try RuntimeLoader.entries(binary: file))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testUniversalBinaryOnlyAddsDependencyToArm64Slice() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var intel = binary()
        var intelCPU = Int32(CPU_TYPE_X86_64).littleEndian
        withUnsafeBytes(of: &intelCPU) { intel.replaceSubrange(4..<8, with: $0) }
        var universal = Data(repeating: 0, count: 0x2400)
        func big(_ value: UInt32, at offset: Int) {
            var bytes = value.bigEndian
            withUnsafeBytes(of: &bytes) { universal.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        big(UInt32(FAT_MAGIC), at: 0)
        big(2, at: 4)
        big(UInt32(CPU_TYPE_X86_64), at: 8)
        big(0x1000, at: 16)
        big(1024, at: 20)
        big(12, at: 24)
        big(UInt32(CPU_TYPE_ARM64), at: 28)
        big(0x2000, at: 36)
        big(1024, at: 40)
        big(12, at: 44)
        universal.replaceSubrange(0x1000..<0x1400, with: intel)
        universal.replaceSubrange(0x2000..<0x2400, with: binary())
        try universal.write(to: file)
        try apply(file)
        let patched = try Data(contentsOf: file)
        XCTAssertEqual(patched.subdata(in: 0x1000..<0x1400), intel)
        XCTAssertEqual(patched.withUnsafeBytes { $0.load(fromByteOffset: 0x2010, as: UInt32.self) }, 3)
    }
}

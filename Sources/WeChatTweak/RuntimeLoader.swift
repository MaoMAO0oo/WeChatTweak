import Foundation
import MachO

struct RuntimeLoader {
    enum Error: Swift.Error {
        case invalidMachO
        case wrongProfile
        case noHeaderSpace
        case missingRuntime
        case incompatibleRuntime
    }
    static let libraryName = "libWeChatTweakRuntime.dylib"
    static let installName = "@loader_path/libWeChatTweakRuntime.dylib"
    static let profileUUID = UUID(uuidString: "8CB5F29E-FC1D-3D47-897A-272A4651E916")!
    static let binaryPath = "Contents/Resources/wechat.dylib"

    static func runtimeData() throws -> Data {
        guard let executable = Bundle.main.executableURL else { throw Error.missingRuntime }
        let library = executable.deletingLastPathComponent().appendingPathComponent(libraryName)
        guard FileManager.default.fileExists(atPath: library.path) else { throw Error.missingRuntime }
        let data = try Data(contentsOf: library)
        let marker = Data("WeChatTweakRuntime:270353:8CB5F29E-FC1D-3D47-897A-272A4651E916".utf8)
        guard data.range(of: marker) != nil else { throw Error.incompatibleRuntime }
        return data
    }

    static func entries(binary: URL) throws -> [Config.Entry] {
        let file = try FileHandle(forReadingFrom: binary)
        defer { try? file.close() }
        guard let slice = try Patcher.slices(file: file).first(where: { $0.cpu == Config.Arch.arm64.cpu }) else {
            throw Patcher.Error.noArchMatched
        }
        try file.seek(toOffset: slice.offset)
        let header = try read(file, count: 32)
        let count: UInt32 = integer(header, offset: 16)
        let size: UInt32 = integer(header, offset: 20)
        let commands = try read(file, count: Int(size))
        var cursor = 0
        var uuidOffset: Int?
        var headerLimit = UInt32.max
        var textAddress: UInt64 = 0
        var installed = false
        for _ in 0..<count {
            guard cursor + 8 <= commands.count else { throw Error.invalidMachO }
            let kind: UInt32 = integer(commands, offset: cursor)
            let length: UInt32 = integer(commands, offset: cursor + 4)
            guard length >= 8, cursor + Int(length) <= commands.count else { throw Error.invalidMachO }
            if kind == LC_UUID {
                guard length == 24 else { throw Error.invalidMachO }
                uuidOffset = cursor + 8
            } else if kind == LC_SEGMENT_64 {
                guard length >= 72 else { throw Error.invalidMachO }
                let segment = commands.subdata(in: (cursor + 8)..<(cursor + 24))
                if segment.starts(with: Data("__TEXT\0".utf8)) {
                    textAddress = integer(commands, offset: cursor + 24)
                    let sections: UInt32 = integer(commands, offset: cursor + 64)
                    for index in 0..<Int(sections) {
                        let section = cursor + 72 + index * 80
                        guard section + 80 <= cursor + Int(length) else { throw Error.invalidMachO }
                        let offset: UInt32 = integer(commands, offset: section + 48)
                        if offset > 0 { headerLimit = min(headerLimit, offset) }
                    }
                }
            } else if kind == LC_LOAD_DYLIB || kind == LC_LOAD_WEAK_DYLIB {
                let offset: UInt32 = integer(commands, offset: cursor + 8)
                guard offset < length else { throw Error.invalidMachO }
                let bytes = commands[(cursor + Int(offset))..<(cursor + Int(length))]
                let name = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                if name == installName { installed = true }
            }
            cursor += Int(length)
        }
        guard let uuidOffset, cursor == commands.count else { throw Error.invalidMachO }
        var uuid = profileUUID.uuid
        let expectedUUID = withUnsafeBytes(of: &uuid) { Data($0) }
        guard commands.subdata(in: uuidOffset..<(uuidOffset + 16)) == expectedUUID else { throw Error.wrongProfile }
        var result = [Config.Entry(arch: .arm64, addr: textAddress + UInt64(32 + uuidOffset),
                                   asm: expectedUUID, expected: expectedUUID)]
        if installed { return result }
        let name = Data((installName + "\0").utf8)
        let commandSize = (24 + name.count + 7) & ~7
        let insertion = 32 + Int(size)
        guard insertion + commandSize <= Int(headerLimit) else { throw Error.noHeaderSpace }
        var command = Data(repeating: 0, count: commandSize)
        put(UInt32(LC_LOAD_DYLIB), into: &command, offset: 0)
        put(UInt32(commandSize), into: &command, offset: 4)
        put(UInt32(24), into: &command, offset: 8)
        command.replaceSubrange(24..<(24 + name.count), with: name)
        try file.seek(toOffset: slice.offset + UInt64(insertion))
        let padding = try read(file, count: commandSize)
        guard padding.allSatisfy({ $0 == 0 }) else { throw Error.noHeaderSpace }
        result.append(Config.Entry(arch: .arm64, addr: textAddress + UInt64(insertion), asm: command, expected: padding))
        result.append(Config.Entry(arch: .arm64, addr: textAddress + 16, asm: bytes(count + 1), expected: header.subdata(in: 16..<20)))
        result.append(Config.Entry(arch: .arm64, addr: textAddress + 20, asm: bytes(size + UInt32(commandSize)), expected: header.subdata(in: 20..<24)))
        return result
    }

    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        guard let data = try file.read(upToCount: count), data.count == count else { throw Error.invalidMachO }
        return data
    }

    private static func integer<T: FixedWidthInteger>(_ data: Data, offset: Int) -> T {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian }
    }

    private static func put<T: FixedWidthInteger>(_ value: T, into data: inout Data, offset: Int) {
        data.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: bytes(value))
    }

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
}

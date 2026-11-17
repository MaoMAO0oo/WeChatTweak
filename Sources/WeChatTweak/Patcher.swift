//
//  Patcher.swift
//  WeChatTweak
//
//  Created by Sunny Young on 2025/12/4.
//

import Darwin
import MachO
import Foundation

struct Patcher {
    enum Error: Swift.Error {
        case invalidFile
        case not64BitMachO(magic: UInt32)
        case vaNotFound(arch: String, va: UInt64)
        case noArchMatched
        case unexpectedBytes(arch: String, va: UInt64, actual: Data, expected: Data)
        case binaryChanged(URL)
    }

    struct Write {
        let offset: UInt64
        let address: UInt64
        let arch: String
        let data: Data
        let original: Data
    }

    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    struct Plan {
        let binary: URL
        let identity: Identity
        let writes: [Write]
    }

    struct Slice {
        let cpu: UInt32
        let offset: UInt64
    }

    static func patch(binary: URL, config: Config) throws {
        try apply(prepare(binary: binary, config: config))
    }

    static func prepare(binary: URL, config: Config) throws -> Plan {
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw Error.invalidFile
        }

        let entries = config.targets.flatMap { $0.entries }
        guard !entries.isEmpty else { throw Error.noArchMatched }

        let fh = try FileHandle(forReadingFrom: binary)
        defer { try? fh.close() }

        let slices = try slices(file: fh)
        var writes: [Write] = []
        for slice in slices {
            for target in entries where target.arch.cpu == slice.cpu {
                writes.append(try planOneSlice(file: fh, sliceOffset: slice.offset,
                                              targetVA: target.addr, patch: target.asm,
                                              expected: target.expected, archName: target.arch.rawValue))
            }
        }
        guard !writes.isEmpty else { throw Error.noArchMatched }
        return Plan(binary: binary, identity: try identity(of: fh), writes: writes)
    }

    static func slices(file fh: FileHandle) throws -> [Slice] {
        try fh.seek(toOffset: 0)
        guard let magicData = try fh.read(upToCount: 4), magicData.count == 4 else {
            throw Error.invalidFile
        }
        let magicBE = magicData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let isSwappedFat = (magicBE == FAT_CIGAM)

        if magicBE == FAT_MAGIC || magicBE == FAT_CIGAM {
            // FAT header: magic(4) + nfat_arch(4)
            guard let nfatData = try fh.read(upToCount: 4), nfatData.count == 4 else {
                throw Error.invalidFile
            }
            let rawNfat = nfatData.withUnsafeBytes { $0.load(as: UInt32.self) }
            let nfat = isSwappedFat ? UInt32(littleEndian: rawNfat) : UInt32(bigEndian: rawNfat)

            var archEntries: [Slice] = []

            for _ in 0..<nfat {
                // fat_arch: cputype(4) cpusub(4) offset(4) size(4) align(4) big-endian
                guard let archData = try fh.read(upToCount: 20), archData.count == 20 else {
                    throw Error.invalidFile
                }
                let rawCpu = archData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                let rawOff = archData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let cputype = isSwappedFat ? UInt32(littleEndian: rawCpu) : UInt32(bigEndian: rawCpu)
                let offset  = isSwappedFat ? UInt32(littleEndian: rawOff) : UInt32(bigEndian: rawOff)
                archEntries.append(Slice(cpu: cputype, offset: UInt64(offset)))
            }
            return archEntries
        } else {
            // thin mach-o：回到开头按 mach_header_64 解析（小端）
            try fh.seek(toOffset: 0)
            guard let hdr = try fh.read(upToCount: 32), hdr.count == 32 else {
                throw Error.invalidFile
            }
            let magic = hdr.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let cputype = hdr.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }

            guard magic == MH_MAGIC_64 else {
                throw Error.not64BitMachO(magic: magic)
            }

            return [Slice(cpu: cputype, offset: 0)]
        }
    }

    static func apply(_ plan: Plan) throws {
        let file = try FileHandle(forUpdating: plan.binary)
        defer { try? file.close() }
        guard try identity(of: file) == plan.identity else {
            throw Error.binaryChanged(plan.binary)
        }
        for write in plan.writes {
            try file.seek(toOffset: write.offset)
            let actual = try file.read(upToCount: write.original.count)
            guard actual == write.original || actual == write.data else {
                throw Error.binaryChanged(plan.binary)
            }
        }
        for write in plan.writes {
            print("[\(write.arch)] patch VA=\(String(format: "0x%llx", write.address)), fileoff=\(String(format: "0x%llx", write.offset))")
            try file.seek(toOffset: write.offset)
            try file.write(contentsOf: write.data)
        }
        let current = try FileHandle(forReadingFrom: plan.binary)
        defer { try? current.close() }
        guard try identity(of: current) == plan.identity else {
            throw Error.binaryChanged(plan.binary)
        }
    }

    private static func identity(of file: FileHandle) throws -> Identity {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    private static func planOneSlice(file fh: FileHandle,
                                      sliceOffset: UInt64,
                                      targetVA: UInt64,
                                      patch: Data,
                                      expected: Data?,
                                      archName: String) throws -> Write {

        // 读 slice 内 mach_header_64
        try fh.seek(toOffset: sliceOffset)
        guard let hdr = try fh.read(upToCount: 32), hdr.count == 32 else {
            throw Error.invalidFile
        }

        let magic   = hdr.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let ncmds   = hdr.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self).littleEndian }

        guard magic == MH_MAGIC_64 else {
            throw Error.not64BitMachO(magic: magic)
        }

        var lcOffset = sliceOffset + 32

        for _ in 0..<ncmds {
            try fh.seek(toOffset: lcOffset)
            guard let lcHead = try fh.read(upToCount: 8), lcHead.count == 8 else {
                throw Error.invalidFile
            }

            let cmd     = lcHead.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let cmdsize = lcHead.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }

            if cmd == LC_SEGMENT_64 {
                guard let segData = try fh.read(upToCount: 64), segData.count == 64 else {
                    throw Error.invalidFile
                }

                let vmaddr  = segData.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self).littleEndian }
                let vmsize  = segData.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self).littleEndian }
                let fileoff = segData.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt64.self).littleEndian }
                let filesize = segData.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt64.self).littleEndian }

                if vmaddr <= targetVA && targetVA < vmaddr + vmsize {
                    let relativeOffset = targetVA - vmaddr
                    guard relativeOffset <= filesize, UInt64(patch.count) <= filesize - relativeOffset else {
                        throw Error.vaNotFound(arch: archName, va: targetVA)
                    }
                    let fileOffset = sliceOffset + fileoff + (targetVA - vmaddr)
                    try fh.seek(toOffset: fileOffset)
                    guard let actual = try fh.read(upToCount: patch.count), actual.count == patch.count else {
                        throw Error.invalidFile
                    }
                    if let expected, actual != expected && actual != patch {
                        throw Error.unexpectedBytes(arch: archName, va: targetVA, actual: actual, expected: expected)
                    }
                    return Write(offset: fileOffset, address: targetVA, arch: archName, data: patch, original: actual)
                }
            }

            lcOffset += UInt64(cmdsize)
        }

        throw Error.vaNotFound(arch: archName, va: targetVA)
    }
}

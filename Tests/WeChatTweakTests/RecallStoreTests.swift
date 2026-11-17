import Foundation
import XCTest
import WeChatTweakRuntime

final class RecallStoreTests: XCTestCase {
    func testOthersRecallsArePreservedWhileOwnRecallsRemainNative() {
        XCTAssertTrue(WTShouldPreserveRecall("“测试联系人”撤回了一条消息"))
        XCTAssertTrue(WTShouldPreserveRecall("\"Test Contact\" recalled a message"))
        XCTAssertFalse(WTShouldPreserveRecall("你撤回了一条消息"))
        XCTAssertFalse(WTShouldPreserveRecall("You recalled a message"))
        XCTAssertFalse(WTShouldPreserveRecall(""))
        XCTAssertFalse(WTShouldPreserveRecall("这是一条普通系统消息"))
    }

    func testNicknameContainingSelfRecallWordsIsStillAnOthersRecall() {
        XCTAssertTrue(WTShouldPreserveRecall("“你撤回了什么”撤回了一条消息"))
    }

    func testMarkerSurvivesReopeningAndKeepsItsAccountAndConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("markers.json").path
        let messageID: UInt64 = 18_446_744_073_709_551_614
        let first = try XCTUnwrap(WTRecallStoreCreate(path))
        XCTAssertTrue(WTRecallStoreRecord(first, "account-a", "session-a", messageID))
        WTRecallStoreDestroy(first)

        let reopened = try XCTUnwrap(WTRecallStoreCreate(path))
        defer { WTRecallStoreDestroy(reopened) }
        XCTAssertTrue(WTRecallStoreContains(reopened, "account-a", "session-a", messageID))
        XCTAssertFalse(WTRecallStoreContains(reopened, "account-b", "session-a", messageID))
        XCTAssertFalse(WTRecallStoreContains(reopened, "account-a", "session-b", messageID))
        XCTAssertFalse(WTRecallStoreContains(reopened, "account-a", "session-a", messageID - 1))
    }

    func testRepeatedRecallDoesNotCreateDuplicateRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("markers.json")
        let store = try XCTUnwrap(WTRecallStoreCreate(file.path))
        defer { WTRecallStoreDestroy(store) }
        XCTAssertTrue(WTRecallStoreRecord(store, "account", "session", 123))
        XCTAssertTrue(WTRecallStoreRecord(store, "account", "session", 123))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        let root = try XCTUnwrap(json as? [String: Any])
        let records = try XCTUnwrap(root["records"] as? [[String: String]])
        XCTAssertEqual(records.count, 1)
    }

    func testDisplayMarkerLookupUsesNetworkServerID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WTRecallStoreCreate(directory.appendingPathComponent("markers.json").path))
        defer { WTRecallStoreDestroy(store) }
        let networkServerID: UInt64 = 12_345_678_901_234_567
        XCTAssertTrue(WTRecallStoreRecord(store, "account", "session", networkServerID))

        // 270353 native conversion: Message+0xF8 -> display+0x90;
        // Message+0x100 -> display+0xA0 is a separate identifier.
        var display = Data(repeating: 0, count: 0x350)
        var server = networkServerID.littleEndian
        var separateID = UInt64(778_899).littleEndian
        withUnsafeBytes(of: &server) { display.replaceSubrange(0x90..<0x98, with: $0) }
        withUnsafeBytes(of: &separateID) { display.replaceSubrange(0xa0..<0xa8, with: $0) }
        let markerFound = display.withUnsafeBytes { bytes in
            WTRecallStoreContains(store, "account", "session", WTMessageServerIDFromDisplay(bytes.baseAddress))
        }
        XCTAssertTrue(markerFound)
    }

    func testCorruptMetadataKeepsNewMarkersInMemoryWithoutReplacingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("markers.json")
        let damaged = Data("{damaged metadata".utf8)
        try damaged.write(to: file)
        let store = try XCTUnwrap(WTRecallStoreCreate(file.path))
        defer { WTRecallStoreDestroy(store) }
        XCTAssertFalse(WTRecallStoreRecord(store, "account", "session", 123))
        XCTAssertTrue(WTRecallStoreContains(store, "account", "session", 123))
        XCTAssertFalse(WTRecallStoreIsPersistent(store, "account", "session", 123))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testFailedWriteRetainsMarkerAndReportsItAsTransient() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("markers.json")
        let store = try XCTUnwrap(WTRecallStoreCreate(file.path))
        defer { WTRecallStoreDestroy(store) }
        XCTAssertTrue(WTRecallStoreRecord(store, "account", "session", 100))
        XCTAssertTrue(WTRecallStoreIsPersistent(store, "account", "session", 100))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(WTRecallStoreRecord(store, "account", "session", 200))
        XCTAssertTrue(WTRecallStoreContains(store, "account", "session", 200))
        XCTAssertFalse(WTRecallStoreIsPersistent(store, "account", "session", 200))
    }
}

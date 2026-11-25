import XCTest
@testable import SleepMacCore

final class CommandStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("commands.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SleepMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStartsWithOnlyDefaultsInFixedOrder() {
        let store = CommandStore(fileURL: fileURL)
        XCTAssertTrue(store.customCommands.isEmpty)
        XCTAssertEqual(store.allCommands.map { $0.id }, DefaultCommands.all.map { $0.id })
        XCTAssertTrue(store.allCommands.allSatisfy { $0.isDefault })
    }

    func testAddAppendsAfterDefaultsAndTrimsInput() throws {
        let store = CommandStore(fileURL: fileURL)
        let added = try store.addCommand(name: "  Stop Docker  ", script: "\n osascript -e 'quit app \"Docker\"' \n", requiresAdmin: false)
        XCTAssertEqual(added.name, "Stop Docker")
        XCTAssertEqual(added.script, "osascript -e 'quit app \"Docker\"'")
        XCTAssertFalse(added.isDefault)
        XCTAssertEqual(store.allCommands.last?.id, added.id)
        XCTAssertEqual(store.allCommands.count, DefaultCommands.all.count + 1)
    }

    func testRejectsEmptyNameOrScript() {
        let store = CommandStore(fileURL: fileURL)
        XCTAssertThrowsError(try store.addCommand(name: "   ", script: "ls", requiresAdmin: false))
        XCTAssertThrowsError(try store.addCommand(name: "x", script: " \n ", requiresAdmin: false))
        XCTAssertTrue(store.customCommands.isEmpty)
    }

    func testDefaultCommandsCannotBeRemoved() {
        let store = CommandStore(fileURL: fileURL)
        for command in DefaultCommands.all {
            XCTAssertThrowsError(try store.removeCommand(id: command.id)) { error in
                XCTAssertEqual(error as? CommandStore.StoreError, .cannotRemoveDefault)
            }
        }
        XCTAssertEqual(store.allCommands.count, DefaultCommands.all.count)
    }

    func testRemoveCustomCommand() throws {
        let store = CommandStore(fileURL: fileURL)
        let first = try store.addCommand(name: "One", script: "true", requiresAdmin: false)
        let second = try store.addCommand(name: "Two", script: "true", requiresAdmin: true)
        try store.removeCommand(id: first.id)
        XCTAssertEqual(store.customCommands.map { $0.id }, [second.id])
        XCTAssertThrowsError(try store.removeCommand(id: first.id)) { error in
            XCTAssertEqual(error as? CommandStore.StoreError, .notFound)
        }
    }

    func testPersistsAcrossInstances() throws {
        let store = CommandStore(fileURL: fileURL)
        try store.addCommand(name: "Persisted", script: "echo hi", requiresAdmin: true)
        let reloaded = CommandStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.customCommands.count, 1)
        XCTAssertEqual(reloaded.customCommands.first?.name, "Persisted")
        XCTAssertEqual(reloaded.customCommands.first?.requiresAdmin, true)
    }

    func testFileCannotInjectDefaultOrBuiltInCommands() throws {
        let tampered = """
        [{"id":"x","name":"Sneaky","script":"echo","requiresAdmin":false,"kind":"restoreSystemSleep","isDefault":true}]
        """
        try tampered.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = CommandStore(fileURL: fileURL)
        XCTAssertEqual(store.customCommands.count, 1)
        XCTAssertFalse(store.customCommands[0].isDefault)
        XCTAssertEqual(store.customCommands[0].kind, .shell)
    }

    func testCorruptFileIsKeptAndStoreStartsEmpty() throws {
        try "not json".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = CommandStore(fileURL: fileURL)
        XCTAssertTrue(store.customCommands.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("commands.json.corrupt").path))
        // The store still works afterwards.
        XCTAssertNoThrow(try store.addCommand(name: "After", script: "true", requiresAdmin: false))
    }
}

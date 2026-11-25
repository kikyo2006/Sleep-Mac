import XCTest
@testable import SleepMacCore

private final class FakeLoginItemService: LoginItemService {
    struct Failure: LocalizedError { var errorDescription: String? { "boom" } }

    var status: LoginItemStatus
    /// Status the service reports after a successful `register()`.
    var statusAfterRegister: LoginItemStatus = .enabled
    var registerError: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: LoginItemStatus) { self.status = status }

    func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        status = .disabled
    }
}

final class LaunchAtLoginTests: XCTestCase {
    func testToggleEnablesWhenDisabled() {
        let service = FakeLoginItemService(status: .disabled)
        let login = LaunchAtLogin(service: service)
        XCTAssertFalse(login.isEnabled)
        XCTAssertEqual(login.toggle(), .enabled)
        XCTAssertTrue(login.isEnabled)
        XCTAssertEqual(service.registerCalls, 1)
    }

    func testToggleDisablesWhenEnabled() {
        let service = FakeLoginItemService(status: .enabled)
        let login = LaunchAtLogin(service: service)
        XCTAssertEqual(login.toggle(), .disabled)
        XCTAssertFalse(login.isEnabled)
        XCTAssertEqual(service.unregisterCalls, 1)
    }

    func testTogglingTwiceReturnsToTheStart() {
        let login = LaunchAtLogin(service: FakeLoginItemService(status: .disabled))
        XCTAssertEqual(login.toggle(), .enabled)
        XCTAssertEqual(login.toggle(), .disabled)
        XCTAssertEqual(login.toggle(), .enabled)
    }

    func testRegisterFailureIsReported() {
        let service = FakeLoginItemService(status: .disabled)
        service.registerError = FakeLoginItemService.Failure()
        XCTAssertEqual(LaunchAtLogin(service: service).toggle(), .failed("boom"))
        XCTAssertEqual(service.status, .disabled)
    }

    func testRegisterThatNeedsApproval() {
        let service = FakeLoginItemService(status: .disabled)
        service.statusAfterRegister = .requiresApproval
        let login = LaunchAtLogin(service: service)
        XCTAssertEqual(login.toggle(), .requiresApproval)
        XCTAssertFalse(login.isEnabled)
    }

    func testTogglingWhileAwaitingApprovalChangesNothing() {
        let service = FakeLoginItemService(status: .requiresApproval)
        XCTAssertEqual(LaunchAtLogin(service: service).toggle(), .requiresApproval)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testRegisterThatDoesNotStickIsAFailure() {
        let service = FakeLoginItemService(status: .unavailable)
        service.statusAfterRegister = .unavailable
        guard case .failed(let message) = LaunchAtLogin(service: service).toggle() else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(message.contains("Applications folder"))
    }
}

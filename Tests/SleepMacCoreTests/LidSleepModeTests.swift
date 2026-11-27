import XCTest
@testable import SleepMacCore

final class LidSleepModeTests: XCTestCase {
    func testStoredSettingsMapToOneMode() {
        XCTAssertEqual(LidSleepMode.from(lidEnabled: false, lightEnabled: false), .off)
        XCTAssertEqual(LidSleepMode.from(lidEnabled: true, lightEnabled: false), .lidSensor)
        XCTAssertEqual(LidSleepMode.from(lidEnabled: false, lightEnabled: true), .lightSensor)
    }

    func testBothOnMeansLightSensor() {
        XCTAssertEqual(LidSleepMode.from(lidEnabled: true, lightEnabled: true), .lightSensor)
    }

    func testEachModeEnablesAtMostOneGuard() {
        for mode in LidSleepMode.allCases {
            XCTAssertFalse(mode.enablesLidSensor && mode.enablesLightSensor)
            XCTAssertEqual(LidSleepMode.from(lidEnabled: mode.enablesLidSensor, lightEnabled: mode.enablesLightSensor), mode)
        }
    }

    func testTitles() {
        XCTAssertEqual(LidSleepMode.allCases.map(\.title), ["Off", "Lid Sensor", "Light Sensor"])
    }
}

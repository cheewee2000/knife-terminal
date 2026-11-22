import XCTest
import CloudKit
@testable import KnifeKit

final class ZoneDeltaTests: XCTestCase {
    private func tab(_ name: String) -> CKRecord {
        CKRecord(recordType: "Tab", recordID: CKRecord.ID(recordName: name, zoneID: CKRecordZone.ID(zoneName: "Z", ownerName: CKCurrentUserDefaultName)))
    }

    /// Record names are reused, so across the pages of one fetch a name can be deleted then
    /// saved again, or saved then deleted. Consumers add tabs, then drop deletions: the later page must win.
    func testLaterPageWins() {
        var d = ZoneDelta()
        d.absorb([tab("tab-1")], deletions: ["tab-2", "input-x-3"])
        d.absorb([tab("tab-2")], deletions: ["tab-1"])
        XCTAssertEqual(d.tabs.map(\.id), ["tab-2"])
        XCTAssertEqual(d.deletedTabRecordNames, ["tab-1"])
    }

    /// Records already in the zone are named by these ids: the hash must never move.
    func testTabIdsPerMachine() {
        XCTAssertEqual(TabIds.base(machine: "10"), 8_740_001)
        XCTAssertEqual(TabIds.base(machine: "okras-mac-mini"), 4_410_001)
        XCTAssertEqual(TabIds.machine(of: 4_410_003, among: ["10", "okras-mac-mini"]), "okras-mac-mini")
        XCTAssertNil(TabIds.machine(of: 1, among: ["10", "okras-mac-mini"]))
    }
}

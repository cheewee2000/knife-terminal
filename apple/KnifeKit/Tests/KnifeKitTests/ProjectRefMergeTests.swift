import XCTest
@testable import KnifeKit

final class ProjectRefMergeTests: XCTestCase {
    func testMergePrefersNewestAndKeepsDescription() {
        let old = ProjectRef(name: "knife", path: "/mini/knife", remote: "git@x/knife", description: "a terminal", lastTouched: Date(timeIntervalSince1970: 100))
        let new = ProjectRef(name: "knife-terminal", path: "/laptop/knife", remote: "git@x/knife", description: nil, lastTouched: Date(timeIntervalSince1970: 200))
        let legacy = ProjectRef(name: "other", path: "/x/other") // no remote: keyed by path
        let merged = ProjectRef.merge([[old, legacy], [new]])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].path, "/laptop/knife")
        XCTAssertEqual(merged[0].description, "a terminal")
        XCTAssertEqual(merged[1].name, "other")
    }
}

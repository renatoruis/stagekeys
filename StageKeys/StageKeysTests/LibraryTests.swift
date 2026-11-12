import XCTest
@testable import StageKeys

final class LibraryTests: XCTestCase {
    private func page(_ objects: [(String, Int, String)], next: String?) -> Data {
        let contents = objects.map { key, size, etag in
            "<Contents><Key>\(key)</Key><LastModified>2026-10-16T10:00:00.000Z</LastModified><ETag>&quot;\(etag)&quot;</ETag><Size>\(size)</Size><StorageClass>STANDARD</StorageClass></Contents>"
        }.joined()
        let tail = next.map { "<IsTruncated>true</IsTruncated><NextContinuationToken>\($0)</NextContinuationToken>" } ?? "<IsTruncated>false</IsTruncated>"
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>sounds</Name><KeyCount>\(objects.count)</KeyCount>\(tail)\(contents)</ListBucketResult>
        """.utf8)
    }

    func testListBucketPages() throws {
        let first = try XCTUnwrap(ListBucketParser.parse(page([
            ("Nord - Piano - GP Grand.sf2", 245_196_142, "beb0"),
            (".DS_Store", 6148, "aaaa"),
            ("old/Piano - Concert Grand.sf2", 10, "bbbb"),
        ], next: "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")))
        XCTAssertEqual(first.sounds, [RemoteSound(file: "Nord - Piano - GP Grand.sf2", size: 245_196_142, etag: "beb0")])
        XCTAssertEqual(first.next, "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")

        let second = try XCTUnwrap(ListBucketParser.parse(page([
            ("Piano - Concert Grand.sf2", 280_707_950, "27cb"),
            ("readme.txt", 12, "cccc"),
        ], next: nil)))
        XCTAssertEqual(second.sounds.map(\.file), ["Piano - Concert Grand.sf2"])
        XCTAssertNil(second.next)
    }

    func testParseName() {
        XCTAssertTrue(SF2Catalog.parseName("Piano - Concert Grand") == ("Piano", nil, "Concert Grand"))
        XCTAssertTrue(SF2Catalog.parseName("Nord - Piano - GP Grand") == ("Nord", "Piano", "GP Grand"))
        XCTAssertTrue(SF2Catalog.parseName("Loose") == ("Other", nil, "Loose"))
        XCTAssertEqual(SF2Catalog.orderedCategories(["Yamaha", "Piano", "Nord", "Collection"]), ["Nord", "Piano", "Collection", "Yamaha"])
    }

    func testNordRenames() {
        XCTAssertEqual(SF2Catalog.renamed.count, 7)
        for (old, new) in SF2Catalog.renamed {
            XCTAssertTrue(old.hasPrefix("sf2/") && new.hasPrefix("sf2/Nord - "), old)
            let stem = ((new as NSString).lastPathComponent as NSString).deletingPathExtension
            XCTAssertNotNil(SF2Catalog.parseName(stem).subcategory, new)
        }
        XCTAssertEqual(SF2Catalog.renamed["sf2/Piano - GP Grand.sf2"], "sf2/Nord - Piano - GP Grand.sf2")
    }

    func testPresetNames() {
        XCTAssertTrue(SF2Catalog.isHeading("   //EltonLirakeys"))
        XCTAssertTrue(SF2Catalog.isHeading("___________________"))
        XCTAssertTrue(SF2Catalog.isHeading("Desenvolvido Por"))
        XCTAssertFalse(SF2Catalog.isHeading("KITWorshipLirakeys"))
        XCTAssertEqual(SF2Catalog.cleanPresetName("Royal Grand 3D - No"), "Royal Grand 3D")
    }
}

import XCTest

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
        XCTAssertTrue(ResourceCatalog.parseName("Piano - Concert Grand") == ("Piano", nil, "Concert Grand"))
        XCTAssertTrue(ResourceCatalog.parseName("Nord - Piano - GP Grand") == ("Nord", "Piano", "GP Grand"))
        XCTAssertTrue(ResourceCatalog.parseName("Loose") == ("Other", nil, "Loose"))
        XCTAssertEqual(ResourceCatalog.orderedCategories(["Yamaha", "Piano", "Nord", "Collection"]), ["Nord", "Piano", "Collection", "Yamaha"])
    }

    func testNordRenames() {
        XCTAssertEqual(ResourceCatalog.renamed.count, 7)
        for (old, new) in ResourceCatalog.renamed {
            XCTAssertTrue(old.hasPrefix("sf2/") && new.hasPrefix("sf2/Nord - "), old)
            let stem = ((new as NSString).lastPathComponent as NSString).deletingPathExtension
            XCTAssertNotNil(ResourceCatalog.parseName(stem).subcategory, new)
        }
        XCTAssertEqual(ResourceCatalog.renamed["sf2/Piano - GP Grand.sf2"], "sf2/Nord - Piano - GP Grand.sf2")
    }

    func testPresetNames() {
        XCTAssertTrue(ResourceCatalog.isHeading("   //EltonLirakeys"))
        XCTAssertTrue(ResourceCatalog.isHeading("___________________"))
        XCTAssertTrue(ResourceCatalog.isHeading("Desenvolvido Por"))
        XCTAssertFalse(ResourceCatalog.isHeading("KITWorshipLirakeys"))
        XCTAssertEqual(ResourceCatalog.cleanPresetName("Royal Grand 3D - No"), "Royal Grand 3D")
    }
}

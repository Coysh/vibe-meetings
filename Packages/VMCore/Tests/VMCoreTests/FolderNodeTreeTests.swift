import XCTest
@testable import VMCore

final class FolderNodeTreeTests: XCTestCase {

    private func meeting(_ title: String) -> Meeting {
        Meeting(
            title: title, startedAt: Date(), folderRelativePath: title,
            transcriptionEngine: EngineRef(kind: "whisperkit", version: "test"),
            modelId: "base"
        )
    }

    private func folder(_ path: String, _ children: [FolderNode] = []) -> FolderNode {
        FolderNode(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent,
                   isMeeting: false, meeting: nil, children: children)
    }

    private func meetingNode(_ path: String, _ m: Meeting) -> FolderNode {
        FolderNode(url: URL(fileURLWithPath: path), name: m.title, isMeeting: true, meeting: m, children: [])
    }

    func testQueries() {
        let a = meeting("A"), b = meeting("B")
        let ma = meetingNode("/r/People/Ann/a", a)
        let mb = meetingNode("/r/Teams/b", b)
        let ann = folder("/r/People/Ann", [ma])
        let people = folder("/r/People", [ann])
        let teams = folder("/r/Teams", [mb])
        let root = folder("/r", [people, teams])

        XCTAssertEqual(root.allMeetings.map(\.title), ["A", "B"])
        XCTAssertEqual(root.allMeetingNodes.map(\.url.path), ["/r/People/Ann/a", "/r/Teams/b"])
        XCTAssertEqual(root.allFolders.map(\.name), ["r", "People", "Ann", "Teams"], "meeting folders are leaves and not listed")
        XCTAssertEqual(root.node(at: URL(fileURLWithPath: "/r/Teams"))?.name, "Teams")
        XCTAssertNil(root.node(at: URL(fileURLWithPath: "/r/Nope")))
        XCTAssertEqual(root.meetingNode(id: b.id)?.url.path, "/r/Teams/b")
        XCTAssertEqual(root.parent(of: ma)?.name, "Ann")
        XCTAssertNil(root.parent(of: root))
        XCTAssertEqual(ann.displayPath(relativeTo: URL(fileURLWithPath: "/r")), "People/Ann")
        XCTAssertEqual(root.displayPath(relativeTo: URL(fileURLWithPath: "/r")), "/")
    }
}

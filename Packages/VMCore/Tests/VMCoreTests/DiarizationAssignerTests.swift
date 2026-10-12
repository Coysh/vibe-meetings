import XCTest
@testable import VMCore

final class DiarizationAssignerTests: XCTestCase {

    private func sys(_ text: String, _ start: TimeInterval, _ end: TimeInterval, id: String = "others") -> TranscriptSegment {
        TranscriptSegment(speakerId: id, channel: .system, start: start, end: end, text: text)
    }

    private func mic(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speakerId: "you", channel: .mic, start: start, end: end, text: text)
    }

    private func turn(_ s: TimeInterval, _ e: TimeInterval, _ c: String) -> DiarizationAssigner.Turn {
        .init(start: s, end: e, cluster: c)
    }

    /// Alice (A) then Bob (B), each with plenty of speech.
    private var twoSpeakerTurns: [DiarizationAssigner.Turn] {
        [turn(0, 10, "A"), turn(10, 20, "B"), turn(20, 30, "A"), turn(30, 40, "B")]
    }

    private var twoSpeakerSegments: [TranscriptSegment] {
        [sys("alice one", 0, 9), sys("bob one", 11, 19), mic("me", 19, 20), sys("alice two", 21, 29), sys("bob two", 31, 39)]
    }

    func testOneRemoteSpeakerIsANoOp() {
        let segs = [sys("hello", 0, 5), sys("again", 6, 12)]
        let r = DiarizationAssigner.assign(turns: [turn(0, 30, "A"), turn(40, 41, "B")], segments: segs)
        XCTAssertFalse(r.changed, "a 1:1 (one real speaker plus a 1 s blip) must not be split")
        XCTAssertEqual(r.segments, segs)
        XCTAssertTrue(r.speakers.isEmpty)
    }

    func testTwoSpeakersAreSplitInOrderOfFirstAppearance() {
        let r = DiarizationAssigner.assign(turns: twoSpeakerTurns, segments: twoSpeakerSegments)
        XCTAssertTrue(r.changed)
        let labels = r.segments.filter { $0.channel == .system }.map(\.speakerId)
        XCTAssertEqual(labels, ["others-1", "others-2", "others-1", "others-2"])
        XCTAssertEqual(r.speakers.map(\.displayName), ["Speaker 1", "Speaker 2"])
        XCTAssertTrue(r.speakers.allSatisfy { $0.channel == .system })
    }

    func testMicSegmentsAndIdsAndChannelsAreUntouched() {
        let input = twoSpeakerSegments
        let r = DiarizationAssigner.assign(turns: twoSpeakerTurns, segments: input)
        XCTAssertEqual(r.segments.map(\.id), input.map(\.id))
        XCTAssertEqual(r.segments.map(\.text), input.map(\.text))
        XCTAssertEqual(r.segments.map(\.channel), input.map(\.channel), "echo dedup keys on channel; it must stay .system")
        XCTAssertEqual(r.segments.first { $0.channel == .mic }?.speakerId, "you")
    }

    func testSegmentSpanningTwoTurnsGoesToDominantSpeaker() {
        // 7 s with A, 2 s with B.
        let segs = [sys("mostly alice", 3, 12), sys("bob", 31, 39)]
        let r = DiarizationAssigner.assign(turns: twoSpeakerTurns, segments: segs)
        XCTAssertEqual(r.segments[0].speakerId, "others-1")
        XCTAssertEqual(r.segments[1].speakerId, "others-2")
    }

    func testShortNoiseClusterIsIgnored() {
        var turns = twoSpeakerTurns
        turns.append(turn(50, 52, "C"))   // 2 s: a notification sound, a cough
        let segs = twoSpeakerSegments + [sys("blip", 50, 52)]
        let r = DiarizationAssigner.assign(turns: turns, segments: segs)
        XCTAssertEqual(r.speakers.count, 2)
        XCTAssertFalse(r.segments.contains { $0.speakerId == "others-3" })
    }

    func testResumeOffsetLeavesEarlierSegmentsAlone() {
        // Audio file covers transcript time 100 s onwards.
        let earlier = sys("before resume", 10, 20, id: "others")
        let segs = [earlier] + twoSpeakerSegments.map { var s = $0; s.start += 100; s.end += 100; return s }
        let r = DiarizationAssigner.assign(turns: twoSpeakerTurns, segments: segs, timelineOffset: 100)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.segments[0].speakerId, "others", "segments before the audio file must keep their label")
        XCTAssertEqual(r.segments[1].speakerId, "others-1")
    }

    func testRerunIsStableAndKeepsLabelsAcrossDifferentClusterNames() {
        let first = DiarizationAssigner.assign(turns: twoSpeakerTurns, segments: twoSpeakerSegments)
        // Same speakers, but the diarizer happens to name the clusters differently.
        let renamedTurns = twoSpeakerTurns.map { turn($0.start, $0.end, $0.cluster == "A" ? "X" : "Y") }
        let second = DiarizationAssigner.assign(turns: renamedTurns, segments: first.segments)
        XCTAssertEqual(second.segments.map(\.speakerId), first.segments.map(\.speakerId))
    }

    func testRerunKeepsAUserRenamedSpeakersName() {
        let first = DiarizationAssigner.assign(turns: twoSpeakerTurns, segments: twoSpeakerSegments)
        let existing = [Speaker.you, Speaker.others,
                        Speaker(id: "others-1", displayName: "Priya", channel: .system),
                        Speaker(id: "others-2", displayName: "Speaker 2", channel: .system)]
        let second = DiarizationAssigner.assign(turns: twoSpeakerTurns, segments: first.segments)
        let merged = DiarizationAssigner.mergeParticipants(existing: existing, assigned: second.speakers)
        XCTAssertEqual(merged.first { $0.id == "others-1" }?.displayName, "Priya")
        XCTAssertEqual(merged.first { $0.id == "you" }?.displayName, "You")
        XCTAssertEqual(merged.filter { $0.id == "others-1" }.count, 1)
    }

    func testMergeDropsStaleRemoteSpeakers() {
        let existing = [Speaker.you, Speaker.others, Speaker(id: "others-3", displayName: "Old", channel: .system)]
        let merged = DiarizationAssigner.mergeParticipants(
            existing: existing,
            assigned: [Speaker(id: "others-1", displayName: "Speaker 1", channel: .system)]
        )
        XCTAssertEqual(merged.map(\.id), ["you", "others", "others-1"])
    }

    func testUnplaceableSegmentFallsBackToOthers() {
        let segs = twoSpeakerSegments + [sys("far away", 200, 205, id: "others-2")]
        let r = DiarizationAssigner.assign(turns: twoSpeakerTurns, segments: segs)
        XCTAssertEqual(r.segments.last?.speakerId, "others", "a stale others-N must not survive when no speaker overlaps")
    }

    // MARK: - Policy and noise floor

    private func meeting(attendees: [String]?, type: MeetingType? = .group, title: String = "Team sync") -> Meeting {
        var m = Meeting(title: title, startedAt: Date(), folderRelativePath: title,
                        transcriptionEngine: EngineRef(kind: "whisperkit", version: "test"), modelId: "base")
        m.attendees = attendees
        m.meetingType = type
        return m
    }

    func testOneToOnesAreSkipped() {
        XCTAssertEqual(DiarizationAssigner.policy(for: meeting(attendees: ["Tim", "Theresa"])), .skip)
        XCTAssertEqual(DiarizationAssigner.policy(for: meeting(attendees: ["Theresa"])), .skip)
        XCTAssertEqual(DiarizationAssigner.policy(for: meeting(attendees: nil, type: .oneOnOne)), .skip)
    }

    func testGroupInviteCapsSpeakers() {
        let eight = (1...8).map { "Person \($0)" }
        XCTAssertEqual(DiarizationAssigner.policy(for: meeting(attendees: eight)), .diarize(maxSpeakers: 7))
    }

    func testUnknownOrHugeInviteIsUncapped() {
        XCTAssertEqual(DiarizationAssigner.policy(for: meeting(attendees: nil)), .diarize(maxSpeakers: nil))
        let list = (1...55).map { "P\($0)" }
        XCTAssertEqual(DiarizationAssigner.policy(for: meeting(attendees: list)), .diarize(maxSpeakers: nil))
    }

    func testSmallShareOfALongMeetingIsNoise() {
        // 20 minutes of A; B has 20 s (1.6%) — over the absolute floor but under 2%.
        let turns = [turn(0, 1200, "A"), turn(1200, 1220, "B")]
        let segs = [sys("long", 0, 1200), sys("short", 1200, 1220)]
        XCTAssertFalse(DiarizationAssigner.assign(turns: turns, segments: segs).changed)
    }
}

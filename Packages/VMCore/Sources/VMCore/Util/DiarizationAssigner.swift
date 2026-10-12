import Foundation

/// Turns anonymous speaker turns from a diarizer into transcript labels:
/// "Others" becomes "others-1" / "others-2" … ("Speaker 1", "Speaker 2" …).
///
/// Pure logic, no audio: the diarizer runs on the system-audio channel (the
/// other participants, one mixed stream) and reports who spoke when; this
/// decides which speaker each transcript segment belongs to.
public enum DiarizationAssigner {

    public struct Turn: Sendable, Equatable {
        public let start: TimeInterval
        public let end: TimeInterval
        /// Opaque cluster label from the diarizer; only equality matters.
        public let cluster: String

        public init(start: TimeInterval, end: TimeInterval, cluster: String) {
            self.start = start
            self.end = end
            self.cluster = cluster
        }
    }

    public struct Result: Sendable {
        /// All input segments, relabelled where applicable (ids, text and channel unchanged).
        public let segments: [TranscriptSegment]
        /// The remote speakers now referenced by the transcript ("others-N", "Speaker N").
        public let speakers: [Speaker]
        /// False when there is nothing to split (one remote speaker, e.g. a 1:1):
        /// `segments` is then exactly the input.
        public let changed: Bool
        /// Seconds of speech per significant cluster, keyed by the assigned speaker id.
        public let speechBySpeaker: [String: TimeInterval]
    }

    public static let remotePrefix = "others"

    /// "others" or "others-N" — the labels this assigner owns.
    public static func isRemoteSpeakerID(_ id: String) -> Bool {
        id == remotePrefix || id.hasPrefix(remotePrefix + "-")
    }

    /// - Parameters:
    ///   - turns: diarizer output, in seconds from the start of the audio file.
    ///   - segments: the transcript, in transcript time.
    ///   - timelineOffset: transcript time at which the audio file starts (non-zero
    ///     after "Resume recording", when the file holds only the new session).
    ///     Segments that begin earlier aren't covered by the audio and keep their labels.
    ///   - minClusterSpeech / minClusterShare: a cluster needs at least this much
    ///     speech, and this share of all remote speech, to count as a speaker —
    ///     anything less is noise (a cough, a notification, a voice split off
    ///     when the line quality changed). Tuned on real recordings.
    public static func assign(
        turns: [Turn],
        segments: [TranscriptSegment],
        timelineOffset: TimeInterval = 0,
        minClusterSpeech: TimeInterval = 15,
        minClusterShare: Double = 0.02
    ) -> Result {
        let unchanged = Result(segments: segments, speakers: [], changed: false, speechBySpeaker: [:])

        // 1. Shift into transcript time; keep only clusters with real speech.
        let shifted = turns.map { Turn(start: $0.start + timelineOffset, end: $0.end + timelineOffset, cluster: $0.cluster) }
        var speech: [String: TimeInterval] = [:]
        for t in shifted { speech[t.cluster, default: 0] += max(0, t.end - t.start) }
        let totalSpeech = speech.values.reduce(0, +)
        let floor = max(minClusterSpeech, minClusterShare * totalSpeech)
        let significant = Set(speech.filter { $0.value >= floor }.keys)
        guard significant.count >= 2 else { return unchanged }
        let kept = shifted.filter { significant.contains($0.cluster) }

        // 2. Each eligible segment → the cluster it overlaps most (whole segment, v1).
        var assigned: [Int: String] = [:]                  // segment index → cluster
        for (i, seg) in segments.enumerated()
        where seg.channel == .system && isRemoteSpeakerID(seg.speakerId) && seg.start >= timelineOffset - 2 {
            if let cluster = bestCluster(for: seg, turns: kept) { assigned[i] = cluster }
        }
        let usedClusters = Set(assigned.values)
        guard usedClusters.count >= 2 else { return unchanged }

        // 3. Label clusters. A re-run reuses the label a cluster's segments already
        //    had, so a speaker the user renamed keeps that name; new clusters are
        //    numbered by first appearance after the highest label in use.
        let label = labels(for: usedClusters, assigned: assigned, segments: segments)

        var out = segments
        for (i, cluster) in assigned {
            out[i].speakerId = label[cluster]!
        }
        // Eligible segments the diarizer couldn't place go back to plain "others"
        // rather than keep a stale "others-N" that may now mean someone else.
        for (i, seg) in segments.enumerated()
        where assigned[i] == nil && seg.channel == .system && seg.speakerId != remotePrefix
            && isRemoteSpeakerID(seg.speakerId) && seg.start >= timelineOffset - 2 {
            out[i].speakerId = remotePrefix
        }

        let ids = label.values.sorted { number(of: $0) < number(of: $1) }
        let speakers = ids.map { Speaker(id: $0, displayName: "Speaker \(number(of: $0))", channel: .system) }
        var speechByLabel: [String: TimeInterval] = [:]
        for (cluster, id) in label { speechByLabel[id] = speech[cluster] }
        return Result(segments: out, speakers: speakers, changed: true, speechBySpeaker: speechByLabel)
    }

    /// What to do for a meeting, decided from its calendar details.
    public enum Policy: Equatable, Sendable {
        /// One remote person: there is nothing to split ("Others" can simply be renamed).
        case skip
        /// Diarize, finding at most this many speakers (`nil` = no limit).
        case diarize(maxSpeakers: Int?)
    }

    /// 1:1s are skipped — on real recordings the diarizer would otherwise split
    /// one remote voice into several "speakers" whenever the line changed. A
    /// group's invite list caps the speaker count (it includes the user, hence
    /// −1); very large invites are distribution lists and aren't used as a cap.
    public static func policy(for meeting: Meeting) -> Policy {
        let invited = meeting.attendees?.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count ?? 0
        if meeting.resolvedType == .oneOnOne || (1...2).contains(invited) { return .skip }
        if (3...16).contains(invited) { return .diarize(maxSpeakers: invited - 1) }
        return .diarize(maxSpeakers: nil)
    }

    /// Combine the meeting's participants with freshly assigned remote speakers:
    /// everyone else is kept, stale "others-N" entries are dropped, and a speaker
    /// that keeps its id keeps the name the user gave it.
    public static func mergeParticipants(existing: [Speaker], assigned: [Speaker]) -> [Speaker] {
        var out = existing.filter { !isRemoteSpeakerID($0.id) || $0.id == remotePrefix }
        if !out.contains(where: { $0.id == remotePrefix }) { out.append(.others) }
        for speaker in assigned {
            if let previous = existing.first(where: { $0.id == speaker.id }) {
                out.append(previous)
            } else {
                out.append(speaker)
            }
        }
        return out
    }

    // MARK: - Internals

    private static func bestCluster(for seg: TranscriptSegment, turns: [Turn]) -> String? {
        var overlap: [String: TimeInterval] = [:]
        for t in turns where t.end > seg.start && t.start < seg.end {
            overlap[t.cluster, default: 0] += min(t.end, seg.end) - max(t.start, seg.start)
        }
        if let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }), best.value > 0 {
            return best.key
        }
        // No overlap (Whisper timestamps are approximate): nearest turn within 3 s.
        let mid = (seg.start + seg.end) / 2
        let nearest = turns
            .map { (cluster: $0.cluster, distance: mid < $0.start ? $0.start - mid : (mid > $0.end ? mid - $0.end : 0)) }
            .min { $0.distance < $1.distance }
        if let nearest, nearest.distance <= 3 { return nearest.cluster }
        return nil
    }

    private static func labels(
        for clusters: Set<String>,
        assigned: [Int: String],
        segments: [TranscriptSegment]
    ) -> [String: String] {
        // Votes: how many of each cluster's segments already carried each "others-N" label.
        var votes: [(cluster: String, label: String, count: Int)] = []
        for cluster in clusters {
            var counts: [String: Int] = [:]
            for (i, c) in assigned where c == cluster {
                let previous = segments[i].speakerId
                if previous != remotePrefix && isRemoteSpeakerID(previous) { counts[previous, default: 0] += 1 }
            }
            for (label, count) in counts { votes.append((cluster, label, count)) }
        }
        var result: [String: String] = [:]
        var usedLabels = Set<String>()
        for vote in votes.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label })
        where result[vote.cluster] == nil && !usedLabels.contains(vote.label) {
            result[vote.cluster] = vote.label
            usedLabels.insert(vote.label)
        }

        // Remaining clusters: numbered by first appearance in the transcript.
        let firstSeen: [String: TimeInterval] = assigned.reduce(into: [:]) { acc, pair in
            let start = segments[pair.key].start
            acc[pair.value] = min(acc[pair.value] ?? .infinity, start)
        }
        var next = (usedLabels.map(number(of:)).max() ?? 0) + 1
        for cluster in clusters.filter({ result[$0] == nil }).sorted(by: { (firstSeen[$0] ?? 0, $0) < (firstSeen[$1] ?? 0, $1) }) {
            result[cluster] = "\(remotePrefix)-\(next)"
            next += 1
        }
        return result
    }

    private static func number(of label: String) -> Int {
        Int(label.dropFirst(remotePrefix.count + 1)) ?? 0
    }
}

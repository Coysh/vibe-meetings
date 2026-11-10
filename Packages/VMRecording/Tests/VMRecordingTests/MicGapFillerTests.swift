import Testing
@testable import VMRecording

@Suite struct MicGapFillerTests {
    private let rate = MicGapFiller.sampleRate

    @Test func continuousBuffersInsertNothing() {
        var f = MicGapFiller()
        var t = 100.0
        for _ in 0..<50 {
            #expect(f.silenceToInsert(hostSeconds: t, frames: 4_096) == 0)
            t += 4_096 / rate
        }
    }

    @Test func jitterUnderFiftyMillisecondsIsIgnored() {
        var f = MicGapFiller()
        _ = f.silenceToInsert(hostSeconds: 10, frames: 4_800)        // ends at 10.1
        #expect(f.silenceToInsert(hostSeconds: 10.1 + 0.03, frames: 4_800) == 0)
    }

    @Test func threeSecondHoleIsFilledSoChannelsStayAligned() {
        var f = MicGapFiller()
        _ = f.silenceToInsert(hostSeconds: 10, frames: 48_000)       // ends at 11
        let inserted = f.silenceToInsert(hostSeconds: 14, frames: 4_096)
        #expect(abs(inserted - 3 * 48_000) <= 1)
        // After the gap, buffers are contiguous again.
        #expect(f.silenceToInsert(hostSeconds: 14 + 4_096 / rate, frames: 4_096) == 0)
    }

    @Test func stallPaddingCountsTowardTheGap() {
        var f = MicGapFiller()
        _ = f.silenceToInsert(hostSeconds: 10, frames: 48_000)       // mic ends at 11
        // System keeps arriving while the mic is silent: 5 s ahead.
        let pad = f.stallPadding(micFrames: 0, systemFrames: 5 * 48_000)
        #expect(pad == 5 * 48_000 - MicGapFiller.stallHeadroom)
        // Mic returns at t = 16 (5 s hole). Only the unpadded remainder is inserted.
        let inserted = f.silenceToInsert(hostSeconds: 16, frames: 4_096)
        #expect(abs((pad + inserted) - 5 * 48_000) <= 1)
    }

    @Test func noStallPaddingWhileMicKeepsUp() {
        var f = MicGapFiller()
        #expect(f.stallPadding(micFrames: 30_000, systemFrames: 48_000) == 0)
        #expect(f.stallPadding(micFrames: 0, systemFrames: MicGapFiller.stallThreshold) == 0)
        #expect(f.stallPadding(micFrames: 0, systemFrames: MicGapFiller.stallThreshold + 1) > 0)
    }

    @Test func missingHostTimeNeverInserts() {
        var f = MicGapFiller()
        #expect(f.silenceToInsert(hostSeconds: nil, frames: 4_096) == 0)
        #expect(f.silenceToInsert(hostSeconds: 50, frames: 4_096) == 0)
    }

    @Test func absurdGapsAreIgnored() {
        var f = MicGapFiller()
        _ = f.silenceToInsert(hostSeconds: 10, frames: 4_096)
        #expect(f.silenceToInsert(hostSeconds: 10 + 3 * 3_600, frames: 4_096) == 0)
    }
}

import Foundation
import OrbitPhysics
import Testing
@testable import Orbita

@Suite("Процедурная музыка")
struct MusicSynthTests {
    private static let rate = 48_000.0

    private func makeSynth(_ mood: MusicMood, body: BodyID = .luna, intensity: Double = 0.6) -> MusicSynth {
        let synth = MusicSynth()
        synth.control.withLock {
            $0.master = 1
            $0.sampleRate = Self.rate
            $0.profile = MusicProfile.make(mood: mood, body: body)
            $0.intensity = intensity
            $0.moodSerial = 1
        }
        return synth
    }

    private func rms(_ a: ArraySlice<Float>) -> Double {
        guard !a.isEmpty else { return 0 }
        return (a.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(a.count)).squareRoot()
    }

    @Test func everyMoodIsFiniteQuietAndAudible() {
        for mood in MusicMood.allCases {
            let synth = makeSynth(mood)
            let frames = Int(Self.rate * 5)
            let (l, r) = synth.renderOffline(frames: frames)
            let peak = (l + r).reduce(Float(0)) { max($0, abs($1)) }
            #expect(l.allSatisfy { $0.isFinite } && r.allSatisfy { $0.isFinite }, "\(mood): NaN/inf")
            #expect(peak <= 0.3, "\(mood): пик \(peak)")
            let tail = rms(l[Int(Self.rate * 2)...])
            if mood != .crash {
                #expect(tail > 1e-4, "\(mood): тишина, rms \(tail)")
            }
        }
    }

    @Test func crashDiesOut() {
        let synth = makeSynth(.crash)
        let (l, _) = synth.renderOffline(frames: Int(Self.rate * 9))
        let first = rms(l[0..<Int(Self.rate * 0.5)])
        let mid = rms(l[Int(Self.rate * 2)..<Int(Self.rate * 2.5)])
        let late = rms(l[Int(Self.rate * 7.5)...])
        #expect(first > 3e-3, "удар должен вступить сразу")
        #expect(first > mid)
        #expect(late < 1e-3)
    }

    @Test func crashCutsPreviousMoodQuickly() {
        let synth = makeSynth(.ascent, intensity: 1)
        _ = synth.renderOffline(frames: Int(Self.rate * 6))
        synth.control.withLock {
            $0.profile = MusicProfile.make(mood: .crash, body: .terra)
            $0.moodSerial = 2
        }
        let (l, _) = synth.renderOffline(frames: Int(Self.rate * 9))
        var maxStep: Float = 0
        for k in 1..<l.count { maxStep = max(maxStep, abs(l[k] - l[k - 1])) }
        #expect(maxStep <= 0.05)
        #expect(rms(l[0..<Int(Self.rate * 0.5)]) > 3e-3)
        // Через ~0.5 с остинато взлёта ушло, дальше только затухающий аккорд.
        #expect(rms(l[Int(Self.rate * 8)...]) < 1e-3)
    }

    @Test func alienBodiesAllSound() {
        for body in BodyID.allCases {
            for mood in [MusicMood.alienOrbit, .surface, .descent] {
                let synth = makeSynth(mood, body: body)
                let (l, r) = synth.renderOffline(frames: Int(Self.rate * 3))
                #expect(l.allSatisfy { $0.isFinite } && r.allSatisfy { $0.isFinite })
                #expect((l + r).reduce(Float(0)) { max($0, abs($1)) } <= 0.3)
            }
        }
    }

    @Test func crossfadeHasNoJumps() {
        let moods = MusicMood.allCases
        for (i, from) in moods.enumerated() {
            let to = moods[(i + 1) % moods.count]
            let synth = makeSynth(from)
            var (l, _) = synth.renderOffline(frames: Int(Self.rate * 3))
            synth.control.withLock {
                $0.profile = MusicProfile.make(mood: to, body: .luna)
                $0.moodSerial = 2
            }
            let (l2, _) = synth.renderOffline(frames: Int(Self.rate * 4))
            l += l2
            var maxStep: Float = 0
            for k in 1..<l.count { maxStep = max(maxStep, abs(l[k] - l[k - 1])) }
            #expect(maxStep <= 0.05, "\(from)->\(to): скачок \(maxStep)")
        }
    }

    @Test func intensityChangeIsSmooth() {
        let synth = makeSynth(.descent, intensity: 0.1)
        var (l, _) = synth.renderOffline(frames: Int(Self.rate * 2))
        synth.control.withLock { $0.intensity = 1 }
        let (l2, _) = synth.renderOffline(frames: Int(Self.rate * 2))
        l += l2
        var maxStep: Float = 0
        for k in 1..<l.count { maxStep = max(maxStep, abs(l[k] - l[k - 1])) }
        #expect(maxStep <= 0.05)
    }
}

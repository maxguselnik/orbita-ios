import AVFoundation
import Foundation
import Synchronization
import OrbitPhysics

// Генеративный синтезатор фоновой музыки. Выполняется в аудиопотоке:
// без аллокаций, без main actor; параметры приходят через `control` (Mutex).
// Профили настроений (массивы, аллокации) собираются на главном потоке в `MusicProfile.make`.

/// Дешёвый xorshift32 для выбора нот: без аллокаций.
struct XorShift32 {
    var state: UInt32

    init(seed: UInt32) { state = seed == 0 ? 0x9E37_79B9 : seed }

    mutating func next() -> UInt32 {
        var x = state
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        state = x
        return x
    }

    /// Равномерное число в [0, 1).
    mutating func unit() -> Double { Double(next() >> 8) / 16_777_216 }

    mutating func int(_ n: Int) -> Int { Int(next() % UInt32(max(n, 1))) }
}

/// Ритмический слой настроения.
enum MusicPulse: UInt8, Sendable {
    case none
    /// Мягкий низкий удар (отсчёт).
    case thump
    /// Остинато восьмыми по тонам аккорда (взлёт).
    case ostinato
    /// Сухое тиканье (снижение).
    case tick
}

/// Всё, что определяет характер настроения: лад, аккорды, темп, тембр, плотность. Простые значения, без куч.
struct MusicProfile: Sendable {
    /// Ступени лада в полутонах от тоники (до 8).
    var scale = SIMD8<Int32>(repeating: 0)
    var scaleCount = 7
    /// До 4 аккордов по 4 ноты (полутона от тоники).
    var chords = SIMD16<Int32>(repeating: 0)
    var chordCount = 1
    var chordSeconds = 10.0
    /// Каденция: аккорды по порядку, последний звучит до конца.
    var cadence = false
    /// Тоника как MIDI-нота.
    var tonic = 48.0

    var padLevel = 0.4
    var padCutoff = 1000.0
    /// Насколько напряжённость открывает фильтр (доля от базы на единицу).
    var padBright = 1.0
    var padAttack = 2.0
    var padRelease = 3.0
    var droneLevel = 0.4

    /// Колокольчики: среднее число нот в секунду (при intensity ~0.5), громкость, сдвиг (полутона), затухание (с).
    var bellRate = 0.2
    var bellLevel = 0.4
    var bellShift = 12
    var bellDecay = 3.0
    /// Вероятность короткого арпеджио после колокольчика.
    var arpChance = 0.0

    var pulse = MusicPulse.none
    var pulseRate = 1.0
    /// Прирост частоты пульса на единицу напряжённости.
    var pulseRateGain = 0.0
    var pulseLevel = 0.2

    /// Тремоло пэда (0 — выключено).
    var tremRate = 0.0
    var tremDepth = 0.0
    var tremRateGain = 0.0

    /// Доля сигнала в реверберацию.
    var send = 0.3
    /// Общая громкость слоя: база + прирост на единицу напряжённости.
    var levelBase = 0.7
    var levelGain = 0.5
    /// Если > 0 — слой затухает за столько секунд и умолкает (авария).
    var lifetime = 0.0
    /// Время входа этого слоя, секунды.
    var fadeIn = 3.0
    /// За сколько секунд уходят остальные слои, когда стартует этот.
    var fadeOutOthers = 3.0

    mutating func setScale(_ values: [Int]) {
        scaleCount = min(values.count, 8)
        for (i, v) in values.prefix(8).enumerated() { scale[i] = Int32(v) }
    }

    mutating func setChords(_ list: [[Int]]) {
        chordCount = min(list.count, 4)
        for (c, notes) in list.prefix(4).enumerated() {
            for k in 0..<4 { chords[c * 4 + k] = Int32(notes[min(k, notes.count - 1)]) }
        }
    }

    /// Ступень лада с переходом через октавы.
    func semitones(degree d: Int) -> Int {
        let n = max(scaleCount, 1)
        let octave = d >= 0 ? d / n : -((n - 1 - d) / n)
        let index = d - octave * n
        return Int(scale[index]) + 12 * octave
    }

    /// Аккорды терциями по ступеням лада (корень, +2, +4, октава).
    mutating func stackChords(roots: [Int]) {
        let n = max(scaleCount, 1)
        setChords(roots.map { r in
            [semitones(degree: r), semitones(degree: r + 2), semitones(degree: r + 4), semitones(degree: r + n)]
        })
    }

    /// Лад чужого тела: Луна — дорийский, Велла — фригийский, Арда — целотонный, Таррос — пентатоника, Сол — эолийский.
    private mutating func setBodyScale(_ body: BodyID, fallback: [Int]) {
        switch body {
        case .luna: setScale([0, 2, 3, 5, 7, 9, 10])
        case .vella: setScale([0, 1, 3, 5, 7, 8, 10])
        case .arda: setScale([0, 2, 4, 6, 8, 10])
        case .taros: setScale([0, 3, 5, 7, 10])
        case .sol: setScale([0, 2, 3, 5, 7, 8, 10])
        case .terra: setScale(fallback)
        }
    }

    /// Профиль настроения для тела: тональность и окраска зависят от тела.
    static func make(mood: MusicMood, body: BodyID) -> MusicProfile {
        var p = MusicProfile()
        let shift: Int
        switch body {
        case .sol: shift = -2
        case .vella: shift = 3
        case .terra: shift = 0
        case .luna: shift = 2
        case .arda: shift = 7
        case .taros: shift = -5
        }
        p.tonic = 48 + Double(shift)

        switch mood {
        case .spaceCenter:
            // Тёплый лидийский: светлые аккорды, редкие колокольчики и короткие арпеджио.
            p.setScale([0, 2, 4, 6, 7, 9, 11])
            p.setChords([[0, 7, 11, 16], [2, 9, 14, 18], [-5, 2, 7, 11], [4, 11, 16, 19]])
            p.chordSeconds = 9
            p.padLevel = 0.5; p.padCutoff = 1300; p.padBright = 0.8; p.droneLevel = 0.5
            p.bellRate = 0.35; p.bellLevel = 0.5; p.bellShift = 12; p.bellDecay = 3.5; p.arpChance = 0.3
            p.send = 0.35

        case .countdown:
            // Подвешенные sus-аккорды, тихий пульс раз в секунду, почти без мелодии.
            p.setScale([0, 2, 5, 7, 9])
            p.setChords([[0, 5, 7, 14], [0, 5, 7, 12]])
            p.chordSeconds = 10
            p.padLevel = 0.4; p.padCutoff = 800; p.padBright = 0.6; p.droneLevel = 0.5
            p.bellRate = 0.08; p.bellLevel = 0.35; p.bellShift = 12; p.bellDecay = 3
            p.pulse = .thump; p.pulseRate = 1.0; p.pulseRateGain = 0.4; p.pulseLevel = 0.5
            p.send = 0.3

        case .ascent:
            // Миксолидийский подъём: громче, ритмичное остинато восьмыми (120 уд/мин).
            p.setScale([0, 2, 4, 5, 7, 9, 10])
            p.setChords([[0, 7, 12, 16], [-2, 5, 10, 14], [-7, 5, 9, 12], [-2, 5, 10, 17]])
            p.chordSeconds = 4
            p.padLevel = 0.5; p.padCutoff = 1800; p.padBright = 1.2; p.droneLevel = 0.6
            p.bellRate = 0.3; p.bellLevel = 0.4; p.bellShift = 24; p.bellDecay = 2
            p.pulse = .ostinato; p.pulseRate = 4; p.pulseRateGain = 0; p.pulseLevel = 0.6
            p.send = 0.25; p.levelBase = 0.8; p.levelGain = 0.5

        case .orbit:
            // Лидийский простор: медленные широкие аккорды, редкие колокольчики и очень длинный хвост.
            p.setScale([0, 2, 4, 6, 7, 9, 11])
            p.setChords([[0, 7, 14, 16], [2, 9, 14, 21], [-5, 4, 11, 14], [4, 11, 16, 23]])
            p.chordSeconds = 14
            p.padLevel = 0.4; p.padCutoff = 1100; p.padBright = 1.0; p.padAttack = 3; p.padRelease = 4
            p.droneLevel = 0.4
            p.bellRate = 0.25; p.bellLevel = 0.5; p.bellShift = 12; p.bellDecay = 6; p.arpChance = 0.15
            p.send = 0.75

        case .voyage:
            // Эолийская пустота: низкие редкие ноты, дрон, много тишины.
            p.setScale([0, 2, 3, 5, 7, 8, 10])
            p.setChords([[-12, -5, 0, 3], [-16, -9, -4, 3], [-14, -7, -2, 3], [-12, -5, 0, 7]])
            p.chordSeconds = 18
            p.padLevel = 0.35; p.padCutoff = 500; p.padBright = 0.5; p.padAttack = 4; p.padRelease = 5
            p.droneLevel = 0.7
            p.bellRate = 0.06; p.bellLevel = 0.5; p.bellShift = 0; p.bellDecay = 6
            p.send = 0.6; p.levelBase = 0.6; p.levelGain = 0.3

        case .alienOrbit:
            p.setBodyScale(body, fallback: [0, 2, 4, 6, 7, 9, 11])
            p.stackChords(roots: [0, 5, 3, 4])
            p.chordSeconds = 12
            p.padLevel = 0.42; p.padCutoff = 1000; p.padBright = 0.9
            p.bellRate = 0.22; p.bellLevel = 0.45; p.bellShift = 12; p.bellDecay = 4; p.arpChance = 0.1
            p.send = 0.5
            if body == .taros { p.tonic -= 12; p.padCutoff = 600; p.bellShift = 24 }

        case .descent:
            // Гармонический минор: напряжение, тиканье ускоряется с напряжённостью.
            p.setScale([0, 2, 3, 5, 7, 8, 11])
            p.stackChords(roots: [0, 5, 3, 4])
            p.chordSeconds = 6
            p.padLevel = 0.35; p.padCutoff = 700; p.padBright = 1.5; p.droneLevel = 0.6
            p.bellRate = 0.1; p.bellLevel = 0.35; p.bellShift = 12; p.bellDecay = 2.5
            p.pulse = .tick; p.pulseRate = 1.5; p.pulseRateGain = 3.0; p.pulseLevel = 0.35
            p.send = 0.3; p.levelBase = 0.6; p.levelGain = 0.6

        case .reentry:
            // Низкий тремоло-дрон, тритон и кластер; с напряжённостью растут громкость, частота тремоло и яркость.
            p.setScale([0, 1, 6, 7, 10])
            p.setChords([[-12, -6, 0, 10], [-11, -5, 1, 7]])
            p.chordSeconds = 8
            p.padLevel = 0.55; p.padCutoff = 500; p.padBright = 2.0; p.padAttack = 1.5; p.droneLevel = 0.8
            p.tremRate = 4; p.tremRateGain = 1.2; p.tremDepth = 0.55
            p.send = 0.2; p.levelBase = 0.5; p.levelGain = 0.7

        case .surface:
            // Лад тела, очень редкие высокие ноты над тихим пэдом.
            p.setBodyScale(body, fallback: [0, 2, 4, 7, 9])
            p.stackChords(roots: [0, 3])
            p.chordSeconds = 20
            p.padLevel = 0.25; p.padCutoff = 700; p.padBright = 0.5; p.padAttack = 4; p.padRelease = 5
            p.droneLevel = 0.3
            p.bellRate = 0.05; p.bellLevel = 0.5; p.bellShift = 24; p.bellDecay = 8
            p.send = 0.65; p.levelBase = 0.7; p.levelGain = 0.3

        case .homecoming:
            // Мажорная каденция IV – V – I с длинным тёплым финальным аккордом.
            p.setScale([0, 2, 4, 5, 7, 9, 11])
            p.setChords([[-7, 5, 9, 12], [-5, 2, 7, 11], [-12, 7, 11, 16]])
            p.cadence = true
            p.chordSeconds = 5
            p.padLevel = 0.55; p.padCutoff = 1500; p.padBright = 0.8; p.padAttack = 1.5; p.droneLevel = 0.5
            p.bellRate = 0.35; p.bellLevel = 0.45; p.bellShift = 12; p.bellDecay = 4; p.arpChance = 0.25
            p.send = 0.45

        case .crash:
            // Один низкий минорный аккорд и затухание за ~4 с.
            p.setScale([0, 3, 7])
            p.setChords([[-24, -17, -12, -9]])
            p.chordSeconds = 100
            p.padLevel = 0.8; p.padCutoff = 400; p.padBright = 0.3; p.padAttack = 0.08; p.padRelease = 1
            p.droneLevel = 0.5
            p.bellRate = 0
            p.send = 0.4; p.lifetime = 4
            p.fadeIn = 0.05; p.fadeOutOthers = 0.5
            p.levelBase = 1; p.levelGain = 0
        }
        return p
    }
}

/// Управление синтезатором: что играть и общая громкость. Профиль собран на главном потоке.
struct MusicControl: Sendable {
    var master = 0.0
    var profile = MusicProfile()
    var intensity = 0.5
    /// Растёт при смене настроения (запуск кроссфейда). 0 — ещё ничего не играли.
    var moodSerial: UInt32 = 0
    var sampleRate = 48_000.0
}

private enum VoiceKind: UInt8 {
    case pad, drone, bell, pluck, thump, tick
}

/// Один голос пула. Огибающая: атака (линейно), затухание/удержание (экспонента), релиз (экспонента).
private struct MVoice {
    var active = false
    var kind = VoiceKind.pad
    var padBus = true
    var p1 = 0.0, p2 = 0.0, p3 = 0.0
    var i1 = 0.0, i2 = 0.0, i3 = 0.0
    var drop = 1.0
    var env = 0.0
    var stage = 0
    var atkInc = 0.0
    var decMul = 1.0
    var relMul = 0.99
    var gate = 0
    var amp = 0.0
    var panL = 0.7, panR = 0.7
}

@inline(__always) private func polyBlep(_ t: Double, _ dt: Double) -> Double {
    if t < dt {
        let x = t / dt
        return x + x - x * x - 1
    } else if t > 1 - dt {
        let x = (t - 1) / dt
        return x * x + x + x + 1
    }
    return 0
}

@inline(__always) private func sine(_ phase: Double) -> Double { sin(phase * 2 * Double.pi) }
@inline(__always) private func tri(_ phase: Double) -> Double { 4 * abs(phase - 0.5) - 1 }
private func midiToHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

/// Один «дек» музыки: свой секвенсор и пул голосов. Несколько деков дают кроссфейд без щелчков.
private final class MusicLayer {
    static let chunk = 32
    static let voiceCount = 24

    var profile = MusicProfile()
    var live = false
    var gain = 0.0
    var target = 0.0
    /// Секунды на полный подъём / спад громкости слоя.
    var fadeUpSeconds = 3.0
    var fadeDownSeconds = 3.0

    private var sr = 48_000.0
    private var age = 0
    private let voices: UnsafeMutablePointer<MVoice>
    /// Шины чанка: пэд L, пэд R, ноты L, ноты R.
    private let bus: UnsafeMutablePointer<Double>
    private var rng = XorShift32(seed: 1)

    private var chordTimer = 0
    private var chordIdx = 0
    private var chordsPlayed = 0
    private var pulseTimer = 0
    private var step = 0
    private var bellDeg = 7
    private var arpLeft = 0
    private var arpTimer = 0

    private var lpL1 = 0.0, lpL2 = 0.0, lpR1 = 0.0, lpR2 = 0.0
    private var tremPhase = 0.0

    init() {
        voices = .allocate(capacity: Self.voiceCount)
        voices.initialize(repeating: MVoice(), count: Self.voiceCount)
        bus = .allocate(capacity: 4 * Self.chunk)
        bus.initialize(repeating: 0, count: 4 * Self.chunk)
    }

    deinit {
        voices.deallocate()
        bus.deallocate()
    }

    func start(profile: MusicProfile, sampleRate: Double, seed: UInt32) {
        self.profile = profile
        sr = sampleRate
        rng = XorShift32(seed: seed)
        kill()
        live = true
        gain = 0
        target = 1
        fadeUpSeconds = max(profile.fadeIn, 0.02)
        fadeDownSeconds = 3
        age = 0
        chordTimer = 0
        chordIdx = 0
        chordsPlayed = 0
        pulseTimer = Int(0.3 * sr)
        step = 0
        bellDeg = 5 + rng.int(4)
        arpLeft = 0
        arpTimer = 0
        tremPhase = 0
    }

    func kill() {
        for i in 0..<Self.voiceCount { voices[i].active = false }
        lpL1 = 0; lpL2 = 0; lpR1 = 0; lpR2 = 0
        live = false
        gain = 0
        target = 0
    }

    // MARK: - Секвенсор

    private func sequence(_ n: Int, _ inten: Double) {
        let p = profile
        let dt = Double(n) / sr
        chordTimer -= n
        if chordTimer <= 0 {
            if p.lifetime > 0 && chordsPlayed > 0 { chordTimer = Int.max / 4 } else { triggerChord() }
        }

        if p.bellRate > 0 {
            let prob = p.bellRate * dt * (0.3 + 1.4 * inten)
            if rng.unit() < prob {
                walkBell()
                ringBell()
                if rng.unit() < p.arpChance {
                    arpLeft = 2 + rng.int(3)
                    arpTimer = Int(0.17 * sr)
                }
            }
        }
        if arpLeft > 0 {
            arpTimer -= n
            if arpTimer <= 0 {
                arpLeft -= 1
                arpTimer += Int(sr * (0.13 + 0.08 * rng.unit()))
                bellDeg = min(bellDeg + 1 + rng.int(2), 2 * max(p.scaleCount, 1) - 1)
                ringBell(softer: 0.75)
            }
        }

        if p.pulse != .none {
            pulseTimer -= n
            if pulseTimer <= 0 {
                let rate = max(p.pulseRate * (1 + p.pulseRateGain * inten), 0.2)
                pulseTimer += Int(sr / rate)
                firePulse(inten)
            }
        }
    }

    private func triggerChord() {
        let p = profile
        let count = max(p.chordCount, 1)
        var idx: Int
        var gateSeconds = p.chordSeconds * (0.88 + 0.24 * rng.unit())
        if p.cadence {
            idx = min(chordsPlayed, count - 1)
            if idx == count - 1 { gateSeconds = 120 }
        } else if chordsPlayed == 0 {
            idx = 0
        } else if rng.unit() < 0.7 {
            idx = (chordIdx + 1) % count
        } else {
            idx = rng.int(count)
        }
        chordIdx = idx
        chordsPlayed += 1
        chordTimer = Int(gateSeconds * sr)
        let gate = chordTimer
        for k in 0..<4 {
            let midi = p.tonic + Double(p.chords[idx * 4 + k])
            let side = k & 1 == 0 ? -1.0 : 1.0
            startVoice(kind: .pad, hz: midiToHz(midi), amp: p.padLevel * 0.1,
                       pan: side * (0.25 + 0.15 * Double(k)),
                       attack: p.padAttack, decay: 0, gate: gate, release: p.padRelease)
        }
        var droneMidi = p.tonic + Double(p.chords[idx * 4]) - 12
        while droneMidi < 30 { droneMidi += 12 }
        startVoice(kind: .drone, hz: midiToHz(droneMidi), amp: p.droneLevel * 0.13, pan: 0,
                   attack: p.padAttack, decay: 0, gate: gate, release: p.padRelease)
    }

    private func walkBell() {
        let n = max(profile.scaleCount, 1)
        let delta: Int
        switch rng.int(8) {
        case 0: delta = -2
        case 1, 2: delta = -1
        case 3: delta = 0
        case 4, 5: delta = 1
        case 6: delta = 2
        default: delta = rng.int(2) == 0 ? -3 : 3
        }
        bellDeg = min(max(bellDeg + delta, 0), 2 * n - 1)
    }

    private func ringBell(softer: Double = 1) {
        let p = profile
        let midi = p.tonic + Double(p.bellShift + p.semitones(degree: bellDeg))
        let amp = p.bellLevel * 0.1 * softer * (0.6 + 0.4 * rng.unit())
        startVoice(kind: .bell, hz: midiToHz(midi), amp: amp, pan: (rng.unit() - 0.5) * 1.4,
                   attack: 0.004, decay: p.bellDecay, gate: Int(p.bellDecay * 1.3 * sr), release: 0.4)
    }

    private func ostinatoDegree(_ s: Int) -> Int {
        switch s & 7 {
        case 0: 0
        case 1: 2
        case 2: 1
        case 3: 3
        case 4: 2
        case 5: 1
        case 6: 3
        default: 2
        }
    }

    private func firePulse(_ inten: Double) {
        let p = profile
        switch p.pulse {
        case .none:
            break
        case .thump:
            let hz = midiToHz(p.tonic - 12)
            startVoice(kind: .thump, hz: hz * 1.5, amp: p.pulseLevel * 0.12, pan: 0,
                       attack: 0.004, decay: 0.35, gate: Int(0.5 * sr), release: 0.15, drop: 0.99992)
        case .ostinato:
            let s = step
            step += 1
            if s & 1 == 1 && rng.unit() > 0.35 + 0.65 * inten { return }
            let note = Int(p.chords[chordIdx * 4 + ostinatoDegree(s)])
            let accent = s & 3 == 0 ? 1.0 : 0.65
            let amp = p.pulseLevel * 0.09 * accent * (0.5 + 0.5 * inten)
            startVoice(kind: .pluck, hz: midiToHz(p.tonic + Double(note) + 12), amp: amp,
                       pan: s & 1 == 0 ? -0.25 : 0.25, attack: 0.003, decay: 0.22,
                       gate: Int(0.3 * sr), release: 0.1)
        case .tick:
            let s = step
            step += 1
            let accent = s & 3 == 0
            let hz = accent ? 1500.0 : 2100.0
            let amp = p.pulseLevel * 0.06 * (accent ? 1.0 : 0.65) * (0.4 + 0.6 * inten)
            startVoice(kind: .tick, hz: hz, amp: amp, pan: s & 1 == 0 ? -0.3 : 0.3,
                       attack: 0.001, decay: 0.03, gate: Int(0.04 * sr), release: 0.01)
        }
    }

    // MARK: - Голоса

    private func startVoice(kind: VoiceKind, hz: Double, amp: Double, pan: Double,
                            attack: Double, decay: Double, gate: Int, release: Double, drop: Double = 1) {
        var slot = -1
        var quietest = Double.greatestFiniteMagnitude
        for i in 0..<Self.voiceCount {
            if !voices[i].active { slot = i; break }
            let level = voices[i].env * voices[i].amp
            if level < quietest { quietest = level; slot = i }
        }
        guard slot >= 0 else { return }
        if voices[slot].active && voices[slot].env * voices[slot].amp > 1e-4 {
            // Пул полон: самый тихий голос уходит в быстрый релиз (~5 мс), ноту пропускаем — без щелчка.
            voices[slot].stage = 2
            voices[slot].relMul = exp(-6.9078 / (0.005 * sr))
            return
        }
        var v = MVoice()
        v.active = true
        v.kind = kind
        v.padBus = kind == .pad || kind == .drone
        let f = hz / sr
        switch kind {
        case .pad:
            v.i1 = f * (1 + 0.0035 * (0.5 + rng.unit()))
            v.i2 = f * (1 - 0.0035 * (0.5 + rng.unit()))
            v.i3 = f
        case .drone:
            v.i1 = f
            v.i2 = f * 2.002
        case .bell:
            v.i1 = f
            v.i2 = f * 2.756
            v.i3 = f * 5.404
        case .pluck:
            v.i1 = f
            v.i2 = f * 2
        case .thump:
            v.i1 = f
            v.drop = drop
        case .tick:
            v.i1 = f
        }
        v.p1 = rng.unit(); v.p2 = rng.unit(); v.p3 = rng.unit()
        v.atkInc = 1 / (max(attack, 0.002) * sr)
        v.decMul = decay > 0 ? exp(-6.9078 / (decay * sr)) : 1
        v.relMul = exp(-6.9078 / (max(release, 0.01) * sr))
        v.gate = gate
        v.amp = amp
        let angle = (min(max(pan, -1), 1) + 1) * Double.pi / 4
        v.panL = cos(angle)
        v.panR = sin(angle)
        voices[slot] = v
    }

    private func renderVoice(_ index: Int, _ n: Int) {
        var v = voices[index]
        let outL = bus + (v.padBus ? 0 : 2 * Self.chunk)
        let outR = outL + Self.chunk
        for i in 0..<n {
            switch v.stage {
            case 0:
                v.env += v.atkInc
                if v.env >= 1 { v.env = 1; v.stage = 1 }
            case 1:
                v.env *= v.decMul
                v.gate -= 1
                if v.gate <= 0 { v.stage = 2 }
            default:
                v.env *= v.relMul
            }
            if v.env < 1e-4 && v.stage != 0 { v.active = false; break }

            let s: Double
            switch v.kind {
            case .pad:
                let saw1 = 2 * v.p1 - 1 - polyBlep(v.p1, v.i1)
                let saw2 = 2 * v.p2 - 1 - polyBlep(v.p2, v.i2)
                s = 0.32 * (saw1 + saw2) + 0.36 * sine(v.p3)
            case .drone:
                s = 0.8 * sine(v.p1) + 0.2 * tri(v.p2)
            case .bell:
                let e2 = v.env * v.env
                s = 0.7 * sine(v.p1) + 0.3 * e2 * sine(v.p2) + 0.12 * e2 * e2 * sine(v.p3)
            case .pluck:
                s = 0.7 * tri(v.p1) + 0.3 * v.env * sine(v.p2)
            case .thump:
                s = sine(v.p1) + 0.3 * sine(v.p2)
                v.i1 *= v.drop
                v.i2 = v.i1 * 2
            case .tick:
                s = sine(v.p1)
            }
            let x = s * v.env * v.amp
            outL[i] += x * v.panL
            outR[i] += x * v.panR

            v.p1 += v.i1; if v.p1 >= 1 { v.p1 -= 1 }
            v.p2 += v.i2; if v.p2 >= 1 { v.p2 -= 1 }
            v.p3 += v.i3; if v.p3 >= 1 { v.p3 -= 1 }
        }
        voices[index] = v
    }

    // MARK: - Рендер чанка

    /// Добавляет звук слоя в сумму и посыл на реверберацию.
    func process(_ n: Int, intensity: Double,
                 sumL: UnsafeMutablePointer<Double>, sumR: UnsafeMutablePointer<Double>,
                 send: UnsafeMutablePointer<Double>) {
        let p = profile
        age += n
        sequence(n, intensity)

        for i in 0..<(4 * Self.chunk) { bus[i] = 0 }
        for v in 0..<Self.voiceCount where voices[v].active { renderVoice(v, n) }

        let level = p.levelBase + p.levelGain * intensity
        let cutoff = min(max(p.padCutoff * (1 + p.padBright * intensity * 2.2), 80), sr * 0.4)
        let a = 1 - exp(-2 * Double.pi * cutoff / sr)
        var life = 1.0
        if p.lifetime > 0 {
            let t = Double(age) / (p.lifetime * sr)
            life = t >= 1 ? 0 : (1 - t) * (1 - t)
        }
        let tremOn = p.tremRate > 0
        let tremDepth = p.tremDepth * (0.4 + 0.6 * intensity)
        let tremInc = 2 * Double.pi * p.tremRate * (1 + p.tremRateGain * intensity) / sr

        let upStep = 1 / (fadeUpSeconds * sr)
        let downStep = 1 / (fadeDownSeconds * sr)
        let padL = bus, padR = bus + Self.chunk
        let noteL = bus + 2 * Self.chunk, noteR = bus + 3 * Self.chunk
        for i in 0..<n {
            if gain < target { gain = min(gain + upStep, target) } else if gain > target { gain = max(gain - downStep, target) }
            let g = gain * gain * (3 - 2 * gain) * level * life
            var tm = 1.0
            if tremOn {
                tm = 1 - tremDepth * (0.5 + 0.5 * sin(tremPhase))
                tremPhase += tremInc
            }
            lpL1 += a * (padL[i] * tm - lpL1)
            lpL2 += a * (lpL1 - lpL2)
            lpR1 += a * (padR[i] * tm - lpR1)
            lpR2 += a * (lpR1 - lpR2)
            let l = (lpL2 + noteL[i]) * g
            let r = (lpR2 + noteR[i]) * g
            sumL[i] += l
            sumR[i] += r
            send[i] += (l + r) * 0.5 * p.send
        }
        if (target == 0 && gain <= 0) || (p.lifetime > 0 && life <= 0) {
            kill()
        }
    }
}

/// Стерео-реверберация в духе Freeverb: 4 гребёнки + 2 всепропускающих на канал. Буферы выделены заранее.
private final class MusicReverb {
    private static let maxLen = 16_384

    private let buffers: UnsafeMutablePointer<Float>
    private let lengths: UnsafeMutablePointer<Int>
    private let index: UnsafeMutablePointer<Int>
    private let damp: UnsafeMutablePointer<Double>
    private let feedback = 0.9
    private let dampK = 0.35

    init() {
        buffers = .allocate(capacity: 12 * Self.maxLen)
        buffers.initialize(repeating: 0, count: 12 * Self.maxLen)
        lengths = .allocate(capacity: 12)
        lengths.initialize(repeating: 1, count: 12)
        index = .allocate(capacity: 12)
        index.initialize(repeating: 0, count: 12)
        damp = .allocate(capacity: 8)
        damp.initialize(repeating: 0, count: 8)
        configure(sampleRate: 48_000)
    }

    deinit {
        buffers.deallocate()
        lengths.deallocate()
        index.deallocate()
        damp.deallocate()
    }

    func configure(sampleRate: Double) {
        let k = sampleRate / 44_100
        let combBase = [2008, 2138, 2299, 2441]
        let allpassBase = [556, 441]
        for ch in 0..<2 {
            let spread = ch == 0 ? 0 : 41
            for i in 0..<4 { lengths[ch * 6 + i] = min(Int(Double(combBase[i] + spread) * k), Self.maxLen - 1) }
            for i in 0..<2 { lengths[ch * 6 + 4 + i] = min(Int(Double(allpassBase[i] + spread) * k), Self.maxLen - 1) }
        }
        reset()
    }

    func reset() {
        buffers.update(repeating: 0, count: 12 * Self.maxLen)
        for i in 0..<12 { index[i] = 0 }
        for i in 0..<8 { damp[i] = 0 }
    }

    func process(_ x: Double) -> (Double, Double) {
        let input = x * 0.02
        var out = (0.0, 0.0)
        for ch in 0..<2 {
            var sum = 0.0
            for i in 0..<4 {
                let slot = ch * 6 + i
                let buf = buffers + slot * Self.maxLen
                let y = Double(buf[index[slot]])
                damp[ch * 4 + i] = y * (1 - dampK) + damp[ch * 4 + i] * dampK
                buf[index[slot]] = Float(input + damp[ch * 4 + i] * feedback)
                index[slot] += 1
                if index[slot] >= lengths[slot] { index[slot] = 0 }
                sum += y
            }
            for i in 4..<6 {
                let slot = ch * 6 + i
                let buf = buffers + slot * Self.maxLen
                let y = Double(buf[index[slot]])
                buf[index[slot]] = Float(sum + y * 0.5)
                index[slot] += 1
                if index[slot] >= lengths[slot] { index[slot] = 0 }
                sum = y - sum
            }
            if ch == 0 { out.0 = sum } else { out.1 = sum }
        }
        return out
    }
}

/// Генеративная музыка: до трёх слоёв-«деков» с кроссфейдом, общая реверберация, мягкий лимитер.
final class MusicSynth: @unchecked Sendable {
    // @unchecked: всё, кроме `control`, трогает только рендер-поток.

    /// Пик суммы не выше этого значения (мягкое насыщение tanh).
    static let ceiling = 0.22
    /// Время кроссфейда настроений, секунды.
    static let crossfade = 3.0

    let control = Mutex(MusicControl())

    private var c = MusicControl()
    private var sampleRate = 48_000.0
    private let layers = [MusicLayer(), MusicLayer(), MusicLayer(), MusicLayer()]
    private let reverb = MusicReverb()
    private var activeIndex = -1
    private var seenSerial: UInt32 = 0
    private var sInt = 0.5
    private var sMaster = 0.0
    private var seedCounter: UInt32 = 0x1234_5678
    private let sumL: UnsafeMutablePointer<Double>
    private let sumR: UnsafeMutablePointer<Double>
    private let send: UnsafeMutablePointer<Double>

    init() {
        let n = MusicLayer.chunk
        sumL = .allocate(capacity: n)
        sumR = .allocate(capacity: n)
        send = .allocate(capacity: n)
        sumL.initialize(repeating: 0, count: n)
        sumR.initialize(repeating: 0, count: n)
        send.initialize(repeating: 0, count: n)
    }

    deinit {
        sumL.deallocate()
        sumR.deallocate()
        send.deallocate()
    }

    /// Рендер-блок для AVAudioSourceNode (стерео, раздельные каналы). Захватывает только `self`.
    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        return { [self] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard let left = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if buffers.count > 1, let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                render(frames: frames, left: left, right: right)
            } else {
                render(frames: frames, left: left, right: left)
            }
            return noErr
        }
    }

    /// Офлайн-рендер для тестов: тот же путь, что и в аудиопотоке.
    func renderOffline(frames: Int) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var done = 0
        while done < frames {
            let n = min(512, frames - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    render(frames: n, left: l.baseAddress! + done, right: r.baseAddress! + done)
                }
            }
            done += n
        }
        return (left, right)
    }

    // MARK: - Рендер

    private func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        pullControl()
        var done = 0
        while done < frames {
            let n = min(MusicLayer.chunk, frames - done)
            renderChunk(n, left + done, right + done)
            done += n
        }
    }

    private func pullControl() {
        if let fresh = control.withLockIfAvailable({ $0 }) { c = fresh }
        if c.sampleRate != sampleRate, c.sampleRate > 0 {
            sampleRate = c.sampleRate
            reverb.configure(sampleRate: sampleRate)
            for layer in layers { layer.kill() }
            activeIndex = -1
            seenSerial = 0
        }
        if c.moodSerial != seenSerial {
            seenSerial = c.moodSerial
            beginMood()
        } else if activeIndex >= 0 {
            layers[activeIndex].profile = c.profile
        }
    }

    /// Новое настроение: свободный слой (иначе самый тихий) стартует, остальные уходят в тишину.
    private func beginMood() {
        var slot = -1
        for i in layers.indices where !layers[i].live { slot = i; break }
        if slot < 0 {
            var quietest = Double.greatestFiniteMagnitude
            for i in layers.indices where layers[i].gain < quietest { quietest = layers[i].gain; slot = i }
        }
        guard slot >= 0 else { return }
        for i in layers.indices where i != slot {
            layers[i].target = 0
            layers[i].fadeDownSeconds = max(c.profile.fadeOutOthers, 0.02)
        }
        seedCounter = seedCounter &* 1_664_525 &+ 1_013_904_223 &+ c.moodSerial
        layers[slot].start(profile: c.profile, sampleRate: sampleRate, seed: seedCounter)
        activeIndex = slot
    }

    private func renderChunk(_ n: Int, _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>) {
        let rate = sampleRate
        sInt += (c.intensity - sInt) * (1 - exp(-Double(n) / (1.5 * rate)))
        for i in 0..<n { sumL[i] = 0; sumR[i] = 0; send[i] = 0 }
        for i in 0..<layers.count where layers[i].live {
            layers[i].process(n, intensity: sInt, sumL: sumL, sumR: sumR, send: send)
        }
        let masterK = 1 - exp(-1 / (0.25 * rate))
        let ceil = Self.ceiling
        for i in 0..<n {
            sMaster += (c.master - sMaster) * masterK
            let wet = reverb.process(send[i])
            let l = (sumL[i] + wet.0) * sMaster
            let r = (sumR[i] + wet.1) * sMaster
            outL[i] = Float(ceil * tanh(l / ceil))
            outR[i] = Float(ceil * tanh(r / ceil))
        }
    }
}

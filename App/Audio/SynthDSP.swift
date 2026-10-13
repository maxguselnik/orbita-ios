import AVFoundation
import Synchronization

// Процедурный синтезатор полётных звуков. Работает в рендер-потоке AVAudioEngine:
// без аллокаций, без main actor; параметры приходят через `control` (Mutex,
// рендер берёт его только через `withLockIfAvailable`, то есть никогда не ждёт).

/// Параметры, которые главный поток передаёт синтезатору. Громкости 0…1.
struct SynthControl: Sendable {
    /// Общая громкость (0 — плавное затухание перед остановкой движка).
    var master = 0.0
    /// Тяга двигателей 0…1.
    var thrust = 0.0
    /// Работает РДТТ: 0 или 1.
    var solid = 0.0
    /// Насколько «слышна» атмосфера: 1 — у земли, 0 — вакуум (звук через корпус).
    var air = 1.0
    /// Ветер по скоростному напору 0…1.
    var wind = 0.0
    /// Нагрев при входе 0…1.
    var heat = 0.0
    /// Купол парашюта раскрыт и полощется: 0…1.
    var chute = 0.0
    /// Космический эмбиент 0…1.
    var space = 0.0
    var sampleRate = 48_000.0
    /// Растёт с каждой отправкой; если долго не меняется (пауза, фон) — лупы затихают.
    var serial: UInt64 = 0
    /// Счётчики одноразовых звуков: рендер играет звук, когда счётчик изменился.
    var shots = OneShotCounters()
    /// Скорость последнего касания или удара, м/с.
    var impactSpeed = 0.0
    /// Растёт при каждом включении звука (новый полёт): рендер сбрасывает уровни, лупы и хвосты прошлого полёта.
    var resetToken: UInt32 = 0
    /// Голоса экипажа: рендер запускает пачку, когда `crewSerial` изменился.
    var crewSerial: UInt32 = 0
    var crewCount = 0
    var crew0 = CrewVoiceCue()
    var crew1 = CrewVoiceCue()
    var crew2 = CrewVoiceCue()
}

/// Вид голосового звука экипажа.
enum CrewVoiceKind: UInt8, Sendable {
    case none, strain, awe, joy, panic, crash
}

/// Один голосовой сигнал: вид, основной тон, сдвиг формант и задержка старта.
struct CrewVoiceCue: Sendable {
    var kind = CrewVoiceKind.none
    var pitch = 200.0
    var formantScale = 1.0
    var delay = 0.0
}

/// Голос экипажа: пила через две форманты гласной, огибающая и вибрато.
private struct CrewVoice {
    var active = false
    var kind = CrewVoiceKind.none
    var delay = 0.0
    var t = 0.0
    var duration = 0.5
    var base = 200.0
    var scale = 1.0
    var level = 0.5
    var vibRate = 6.0, vibDepth = 0.03
    var vibPhase = 0.0
    var phase = 0.0
    var increment = 0.0
    var src = 0.0
    var env = 0.0, envTarget = 0.0
    var breath = 0.0
    var f1 = SVF()
    var f2 = SVF()
}

/// Форма голоса по доле времени p (0…1): множитель тона, форманты, огибающая, доля «дыхания».
private struct CrewVoiceShape {
    var pitch = 1.0, f1 = 500.0, f2 = 1500.0, env = 1.0, breath = 0.0

    @inline(__always)
    private static func smooth(_ x: Double) -> Double {
        let u = min(max(x, 0), 1)
        return u * u * (3 - 2 * u)
    }

    static func make(_ kind: CrewVoiceKind, _ p: Double) -> CrewVoiceShape {
        var s = CrewVoiceShape()
        switch kind {
        case .none:
            s.env = 0
        case .strain: // натужное «ммм»: низко, дрожь, сначала нарастает
            s.pitch = 0.85 - 0.12 * p
            s.f1 = 280; s.f2 = 1000
            s.env = min(p / 0.25, 1) * (1 - 0.3 * p)
            s.breath = 0.05
        case .awe: // «ууух»: тон вверх-вниз, в конце выдох
            let b = smooth((p - 0.65) / 0.25)
            s.pitch = 0.9 + 0.4 * sin(Double.pi * min(p / 0.9, 1))
            s.f1 = 320 + 280 * b; s.f2 = 700 + 800 * b
            s.env = 1 - 0.45 * b
            s.breath = 0.85 * b
        case .joy: // «у-ра!»: два слога, тон вверх
            if p < 0.4 {
                s.pitch = 1.0 + 0.15 * (p / 0.4)
                s.f1 = 320; s.f2 = 760
                s.env = p > 0.34 ? 0.8 - 0.65 * smooth((p - 0.34) / 0.06) : 0.8
            } else {
                let q = (p - 0.4) / 0.6
                s.pitch = 1.3 + 0.35 * q
                s.f1 = 750; s.f2 = 1250
                s.env = 0.15 + 0.85 * smooth((p - 0.4) / 0.06) - 0.35 * q
            }
        case .panic: // вскрик «аа!»: высоко
            s.pitch = 1.55 + 0.5 * min(p / 0.3, 1) - 0.15 * max(p - 0.7, 0) / 0.3
            s.f1 = 850; s.f2 = 1300
            s.env = 1 - 0.3 * p
            s.breath = 0.1
        case .crash: // «ой»: тон вниз, «о» переходит в «й»
            let g = smooth((p - 0.5) / 0.3)
            s.pitch = 1.5 - 0.8 * p
            s.f1 = 500 + (330 - 500) * g; s.f2 = 900 + (2100 - 900) * g
            s.env = 1 - 0.5 * p
        }
        return s
    }
}

struct OneShotCounters: Sendable, Equatable {
    var ignition: UInt32 = 0
    var solidIgnition: UInt32 = 0
    var flameout: UInt32 = 0
    var separation: UInt32 = 0
    var chuteDeployed: UInt32 = 0
    var chuteOpened: UInt32 = 0
    var touchdown: UInt32 = 0
    var splashdown: UInt32 = 0
    var crash: UInt32 = 0
}

/// Фильтр с переменным состоянием (топология TPT): устойчив при любом изменении частоты.
private struct SVF {
    private var ic1 = 0.0
    private var ic2 = 0.0
    private var a1 = 0.0, a2 = 0.0, a3 = 0.0, k = 1.4

    mutating func set(frequency: Double, q: Double, sampleRate: Double) {
        let f = min(max(frequency, 20), sampleRate * 0.45)
        let g = tan(Double.pi * f / sampleRate)
        k = 1 / max(q, 0.05)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    /// Полоса с единичным пиком на центральной частоте.
    @inline(__always)
    mutating func band(_ x: Double) -> Double {
        let r = process(x)
        return r.bp * k
    }

    /// Возвращает (низкие, полоса, высокие).
    @inline(__always)
    mutating func process(_ x: Double) -> (lp: Double, bp: Double, hp: Double) {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1, x - k * v1 - v2)
    }

    mutating func reset() { ic1 = 0; ic2 = 0 }
}

private enum FilterMode { case low, band, high }
private enum Wave { case noise, sine, triangle, saw }

/// Одноразовый звук: шум через фильтр со свипом частоты или тон со свипом высоты.
private struct Voice {
    var active = false
    var wave = Wave.noise
    var mode = FilterMode.low
    var q = 0.7
    var f0 = 100.0, f1 = 100.0
    var volume = 0.0
    var duration = 0.1
    var delay = 0.0
    var t = 0.0
    var phase = 0.0
    var increment = 0.0
    var gain = 0.0
    var decay = 1.0
    var svf = SVF()
}

/// Рецепт одноразового звука.
private struct Shot {
    var wave: Wave
    var mode: FilterMode = .low
    var f0: Double
    var f1: Double
    var duration: Double
    var volume: Double
    var q: Double = 0.7
    var delay: Double = 0
}

final class SynthDSP: @unchecked Sendable {
    // @unchecked: всё, кроме `control`, трогает только рендер-поток.

    let control = Mutex(SynthControl())

    private static let controlInterval = 32
    private static let voiceCount = 12

    private var c = SynthControl()
    private var seenShots = OneShotCounters()
    private var lastSerial: UInt64 = 0
    private var seenReset: UInt32 = 0
    private var seenCrew: UInt32 = 0
    private var staleSamples = 0
    private var sampleRate = 48_000.0

    // Сглаженные значения.
    private var sMaster = 0.0, sThrust = 0.0, sSolid = 0.0, sAir = 1.0
    private var sWind = 0.0, sHeat = 0.0, sChute = 0.0, sSpace = 0.0
    private var smoothFast = 0.0, smoothSlow = 0.0, smoothPad = 0.0
    private var counter = 0

    // Генераторы.
    private var rng: UInt32 = 0x9E37_79B9
    private var brown = 0.0
    private var flicker = 0.0
    private var gust = 0.0
    private var rumblePhase = 0.0
    private var rumbleLP = 0.0
    private var crackleEnv = 0.0
    private var flutterPhase = 0.0
    private var padPhase = (0.0, 0.0, 0.0)
    private var padLFO = (0.0, 0.0, 0.0)

    private var engineFilter = SVF()
    private var crackleFilter = SVF()
    private var windFilter = SVF()
    private var heatFilter = SVF()
    private var voices = [Voice](repeating: Voice(), count: SynthDSP.voiceCount)
    private var crewVoices = [CrewVoice](repeating: CrewVoice(), count: 3)

    init() {
        recompute(sampleRate: 48_000)
    }

    /// Рендер-блок для AVAudioSourceNode. Создаётся вне main actor, захватывает только `self`.
    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        return { [self] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            render(frames: Int(frameCount), buffers: buffers)
            return noErr
        }
    }

    // MARK: - Рендер

    private func render(frames: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        pullControl(frames: frames)
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }

        for i in 0..<frames {
            if counter == 0 { controlTick() }
            counter = (counter + 1) % SynthDSP.controlInterval
            first[i] = Float(nextSample())
        }
        for index in 1..<max(buffers.count, 1) {
            guard let data = buffers[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            data.update(from: first, count: frames)
        }
    }

    private func pullControl(frames: Int) {
        if let fresh = control.withLockIfAvailable({ $0 }) {
            c = fresh
        }
        if c.sampleRate != sampleRate, c.sampleRate > 0 {
            recompute(sampleRate: c.sampleRate)
        }
        if c.resetToken != seenReset {
            seenReset = c.resetToken
            resetState()
        }
        if c.serial != lastSerial {
            lastSerial = c.serial
            staleSamples = 0
        } else {
            staleSamples += frames
        }
        if c.crewSerial != seenCrew {
            seenCrew = c.crewSerial
            triggerCrew()
        }
        if c.shots != seenShots {
            triggerShots(c.shots)
            seenShots = c.shots
        }
    }

    private func recompute(sampleRate rate: Double) {
        sampleRate = rate
        smoothFast = 1 - exp(-1 / (0.06 * rate))
        smoothSlow = 1 - exp(-1 / (0.25 * rate))
        smoothPad = 1 - exp(-1 / (1.5 * rate))
        engineFilter.reset(); crackleFilter.reset(); windFilter.reset(); heatFilter.reset()
        for i in voices.indices { voices[i].active = false }
        for i in crewVoices.indices { crewVoices[i].active = false }
    }

    /// Новый полёт: обнуляем непрерывные звуки, хвосты и фильтры. `sMaster` не трогаем — он сам плавно нарастёт.
    private func resetState() {
        sThrust = 0; sSolid = 0; sAir = c.air
        sWind = 0; sHeat = 0; sChute = 0; sSpace = 0
        crackleEnv = 0
        engineFilter.reset(); crackleFilter.reset(); windFilter.reset(); heatFilter.reset()
        for i in voices.indices { voices[i].active = false }
        for i in crewVoices.indices { crewVoices[i].active = false }
        seenCrew = c.crewSerial
        seenShots = c.shots
        lastSerial = c.serial
        staleSamples = 0
    }

    /// Раз в 32 сэмпла: частоты фильтров и свипы.
    private func controlTick() {
        let air = sAir
        let cutoff = (160 + 100 * air) + (sThrust * 450 + sSolid * 650) * (0.45 + 0.55 * air)
        engineFilter.set(frequency: cutoff, q: 0.7, sampleRate: sampleRate)
        crackleFilter.set(frequency: 700 + 500 * air, q: 0.8, sampleRate: sampleRate)
        let w = min(sWind + sHeat * 0.6, 1.4)
        windFilter.set(frequency: 350 + w * 1500 + gust * 300, q: 0.5, sampleRate: sampleRate)
        heatFilter.set(frequency: 1800 + sHeat * 2500, q: 0.6, sampleRate: sampleRate)

        crewTick()
        for i in voices.indices where voices[i].active {
            if voices[i].delay > 0 { continue }
            let p = min(voices[i].t / voices[i].duration, 1)
            let f = voices[i].f0 * pow(voices[i].f1 / voices[i].f0, p)
            if voices[i].wave == .noise {
                voices[i].svf.set(frequency: f, q: voices[i].q, sampleRate: sampleRate)
            } else {
                voices[i].increment = f / sampleRate
            }
        }
    }

    private func crewTick() {
        for i in crewVoices.indices where crewVoices[i].active {
            if crewVoices[i].delay > 0 { continue }
            let v = crewVoices[i]
            let shape = CrewVoiceShape.make(v.kind, min(v.t / v.duration, 1))
            let vib = 1 + v.vibDepth * sin(2 * Double.pi * v.vibPhase)
            crewVoices[i].vibPhase = (v.vibPhase + v.vibRate * Double(SynthDSP.controlInterval) / sampleRate)
                .truncatingRemainder(dividingBy: 1)
            crewVoices[i].increment = min(max(v.base * shape.pitch * vib, 40), 2000) / sampleRate
            crewVoices[i].f1.set(frequency: shape.f1 * v.scale, q: 6, sampleRate: sampleRate)
            crewVoices[i].f2.set(frequency: shape.f2 * v.scale, q: 8, sampleRate: sampleRate)
            crewVoices[i].envTarget = shape.env
            crewVoices[i].breath = shape.breath
        }
    }

    @inline(__always)
    private func white() -> Double {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Double(Int32(bitPattern: rng)) / 2_147_483_648
    }

    private func nextSample() -> Double {
        // Если главный поток перестал присылать кадры (пауза, фон) дольше 0.3 с — лупы глохнут.
        let alive = staleSamples < Int(sampleRate * 0.3)
        let loops = alive ? 1.0 : 0.0

        sMaster += (c.master - sMaster) * smoothFast
        sThrust += (c.thrust * loops - sThrust) * smoothFast
        sSolid += (c.solid * loops - sSolid) * smoothFast
        sAir += (c.air - sAir) * smoothSlow
        sWind += (c.wind * loops - sWind) * smoothSlow
        sHeat += (c.heat * loops - sHeat) * smoothSlow
        sChute += (c.chute * loops - sChute) * smoothSlow
        sSpace += (c.space * loops - sSpace) * smoothPad

        let n = white()
        brown = (brown + 0.02 * n) / 1.02
        let b = brown * 3.5
        flicker += (white() - flicker) * 0.0015
        gust += (white() - gust) * 0.00005

        var out = 0.0
        let through = 0.55 + 0.45 * sAir

        // Рокот двигателя: бурый шум через ФНЧ + низкая пила.
        if sThrust > 0.0005 || sSolid > 0.0005 {
            let roar = engineFilter.process(b).lp
            let level = (sThrust * 0.9 + sSolid * 0.2) * through
            out += roar * level * (1 + flicker * 6)

            rumblePhase += (36 + flicker * 40) / sampleRate
            if rumblePhase >= 1 { rumblePhase -= 1 }
            let saw = 2 * rumblePhase - 1
            rumbleLP += (saw - rumbleLP) * (2 * Double.pi * 90 / sampleRate)
            out += rumbleLP * (sThrust + sSolid * 0.5) * 0.22 * through
        }

        // Треск РДТТ: полосовой шум с редкими импульсами.
        if sSolid > 0.0005 || crackleEnv > 0.001 {
            if white() > 0.9985 { crackleEnv = 0.6 + 0.4 * abs(white()) }
            crackleEnv *= 0.9985
            let band = crackleFilter.process(n).bp
            out += band * (0.35 + 1.8 * crackleEnv) * sSolid * 0.3 * through
        }

        // Ветер и нагрев.
        let windLevel = min(sWind + sHeat * 0.6, 1.4)
        if windLevel > 0.0005 || sChute > 0.0005 {
            var band = windFilter.process(n).bp
            if sChute > 0.0005 {
                flutterPhase += (7 + gust * 4) / sampleRate
                if flutterPhase >= 1 { flutterPhase -= 1 }
                band *= 1 + sChute * 0.8 * sin(2 * Double.pi * flutterPhase)
            }
            out += band * (windLevel + sChute * 0.25) * 0.55 * (1 + gust * 2)
        }
        if sHeat > 0.0005 {
            out += heatFilter.process(n).hp * sHeat * 0.12 * (1 + flicker * 10)
        }

        // Эмбиент в космосе: три медленно дышащих синуса.
        if sSpace > 0.0005 {
            let rate = 1 / sampleRate
            padPhase.0 = (padPhase.0 + 110 * rate).truncatingRemainder(dividingBy: 1)
            padPhase.1 = (padPhase.1 + 164.8 * rate).truncatingRemainder(dividingBy: 1)
            padPhase.2 = (padPhase.2 + 220.5 * rate).truncatingRemainder(dividingBy: 1)
            padLFO.0 = (padLFO.0 + 0.07 * rate).truncatingRemainder(dividingBy: 1)
            padLFO.1 = (padLFO.1 + 0.10 * rate).truncatingRemainder(dividingBy: 1)
            padLFO.2 = (padLFO.2 + 0.13 * rate).truncatingRemainder(dividingBy: 1)
            let twoPi = 2 * Double.pi
            var pad = sin(twoPi * padPhase.0) * (0.33 + 0.16 * sin(twoPi * padLFO.0))
            pad += sin(twoPi * padPhase.1) * (0.33 + 0.16 * sin(twoPi * padLFO.1))
            pad += sin(twoPi * padPhase.2) * (0.33 + 0.16 * sin(twoPi * padLFO.2))
            out += pad * sSpace * 0.05
        }

        out += renderVoices()
        out += renderCrew()

        // Мягкое ограничение: без жёсткого клиппинга на суммах.
        return tanh(out * 0.8 * sMaster)
    }

    // MARK: - Одноразовые звуки

    private func renderVoices() -> Double {
        var sum = 0.0
        let dt = 1 / sampleRate
        for i in voices.indices where voices[i].active {
            if voices[i].delay > 0 {
                voices[i].delay -= dt
                continue
            }
            let x: Double
            switch voices[i].wave {
            case .noise:
                let r = voices[i].svf.process(white())
                switch voices[i].mode {
                case .low: x = r.lp
                case .band: x = r.bp
                case .high: x = r.hp
                }
            case .sine:
                x = sin(2 * Double.pi * voices[i].phase)
            case .triangle:
                x = 4 * abs(voices[i].phase - 0.5) - 1
            case .saw:
                x = 2 * voices[i].phase - 1
            }
            if voices[i].wave != .noise {
                voices[i].phase += voices[i].increment
                if voices[i].phase >= 1 { voices[i].phase -= 1 }
            }
            // Атака 4 мс — без щелчка, затем экспоненциальный спад до −60 дБ.
            let attack = min(voices[i].t / 0.004, 1)
            sum += x * voices[i].gain * attack
            voices[i].gain *= voices[i].decay
            voices[i].t += dt
            if voices[i].t >= voices[i].duration { voices[i].active = false }
        }
        return sum
    }

    // MARK: - Голоса экипажа

    private func renderCrew() -> Double {
        var sum = 0.0
        let dt = 1 / sampleRate
        for i in crewVoices.indices where crewVoices[i].active {
            if crewVoices[i].delay > 0 {
                crewVoices[i].delay -= dt
                continue
            }
            let v = crewVoices[i]
            crewVoices[i].phase += v.increment
            if crewVoices[i].phase >= 1 { crewVoices[i].phase -= 1 }
            // Пила, смягчённая однополюсным ФНЧ (меньше алиасинга), плюс шум «дыхания».
            let saw = 2 * crewVoices[i].phase - 1
            crewVoices[i].src += (saw - v.src) * 0.35
            let b = v.breath
            let x = crewVoices[i].src * (1 - b) + white() * b * 0.6
            let voiced = crewVoices[i].f1.band(x) + 0.7 * crewVoices[i].f2.band(x)

            crewVoices[i].env += (v.envTarget - v.env) * 0.02
            // Атака 12 мс и спад 40 мс — без щелчков.
            let attack = min(v.t / 0.012, 1)
            let release = min(max(v.duration - v.t, 0) / 0.04, 1)
            sum += voiced * v.level * crewVoices[i].env * attack * release
            crewVoices[i].t += dt
            if crewVoices[i].t >= v.duration { crewVoices[i].active = false }
        }
        return sum
    }

    private func triggerCrew() {
        // Без массивов: рендер-поток не аллоцирует.
        let count = min(max(c.crewCount, 0), 3)
        if count > 0, c.crew0.kind != .none { startCrewVoice(c.crew0) }
        if count > 1, c.crew1.kind != .none { startCrewVoice(c.crew1) }
        if count > 2, c.crew2.kind != .none { startCrewVoice(c.crew2) }
    }

    private func startCrewVoice(_ cue: CrewVoiceCue) {
        // Не больше трёх голосов: занимаем свободный слот, иначе вытесняем самый «старый».
        var slot = 0
        var oldest = -1.0
        for i in crewVoices.indices {
            if !crewVoices[i].active { slot = i; break }
            let age = crewVoices[i].t / crewVoices[i].duration
            if age > oldest { oldest = age; slot = i }
        }
        var v = CrewVoice()
        v.active = true
        v.kind = cue.kind
        v.delay = max(cue.delay, 0)
        v.base = cue.pitch * (1 + 0.03 * white())
        v.scale = cue.formantScale
        switch cue.kind {
        case .none: v.active = false
        case .strain: v.duration = 0.65; v.level = 0.30; v.vibRate = 7; v.vibDepth = 0.05
        case .awe: v.duration = 0.7; v.level = 0.30; v.vibRate = 5; v.vibDepth = 0.02
        case .joy: v.duration = 0.55; v.level = 0.32; v.vibRate = 6; v.vibDepth = 0.015
        case .panic: v.duration = 0.4; v.level = 0.34; v.vibRate = 11; v.vibDepth = 0.06
        case .crash: v.duration = 0.5; v.level = 0.32; v.vibRate = 5.5; v.vibDepth = 0.03
        }
        let shape = CrewVoiceShape.make(cue.kind, 0)
        v.envTarget = shape.env
        v.increment = v.base * shape.pitch / sampleRate
        v.f1.set(frequency: shape.f1 * v.scale, q: 6, sampleRate: sampleRate)
        v.f2.set(frequency: shape.f2 * v.scale, q: 8, sampleRate: sampleRate)
        crewVoices[slot] = v
    }

    private func start(_ shot: Shot, scale: Double) {
        var slot = -1
        var oldest = -1.0
        for i in voices.indices {
            if !voices[i].active { slot = i; break }
            let age = voices[i].t / voices[i].duration
            if age > oldest { oldest = age; slot = i }
        }
        guard slot >= 0 else { return }
        var v = Voice()
        v.active = true
        v.wave = shot.wave
        v.mode = shot.mode
        v.q = shot.q
        v.f0 = max(shot.f0, 20)
        v.f1 = max(shot.f1, 20)
        v.volume = shot.volume * scale
        v.duration = shot.duration
        v.delay = shot.delay
        v.gain = v.volume
        v.decay = pow(0.001, 1 / (shot.duration * sampleRate))
        v.increment = v.f0 / sampleRate
        v.svf.set(frequency: v.f0, q: v.q, sampleRate: sampleRate)
        voices[slot] = v
    }

    private func triggerShots(_ s: OneShotCounters) {
        // В вакууме удары слышны глуше — только через корпус.
        let body = 0.6 + 0.4 * sAir
        let impact = min(max(c.impactSpeed, 0), 60)

        if s.ignition != seenShots.ignition {
            start(Shot(wave: .noise, mode: .low, f0: 180, f1: 1600, duration: 0.7, volume: 0.6), scale: body)
            start(Shot(wave: .triangle, f0: 90, f1: 45, duration: 0.35, volume: 0.35), scale: body)
        }
        if s.solidIgnition != seenShots.solidIgnition {
            start(Shot(wave: .noise, mode: .low, f0: 300, f1: 2400, duration: 0.5, volume: 0.8), scale: body)
            start(Shot(wave: .noise, mode: .band, f0: 2500, f1: 600, duration: 0.25, volume: 0.4, q: 0.9), scale: body)
            start(Shot(wave: .saw, f0: 70, f1: 40, duration: 0.5, volume: 0.35), scale: body)
        }
        if s.flameout != seenShots.flameout {
            start(Shot(wave: .noise, mode: .low, f0: 900, f1: 120, duration: 0.45, volume: 0.3), scale: body)
        }
        if s.separation != seenShots.separation {
            start(Shot(wave: .noise, mode: .band, f0: 3500, f1: 300, duration: 0.3, volume: 0.7, q: 0.8), scale: body)
            start(Shot(wave: .triangle, f0: 140, f1: 50, duration: 0.25, volume: 0.5), scale: body)
            start(Shot(wave: .triangle, f0: 950, f1: 620, duration: 0.09, volume: 0.12, delay: 0.02), scale: body)
        }
        if s.chuteDeployed != seenShots.chuteDeployed {
            start(Shot(wave: .noise, mode: .band, f0: 1200, f1: 3000, duration: 0.15, volume: 0.45, q: 1.2), scale: body)
            start(Shot(wave: .sine, f0: 220, f1: 110, duration: 0.12, volume: 0.25), scale: body)
        }
        if s.chuteOpened != seenShots.chuteOpened {
            start(Shot(wave: .noise, mode: .high, f0: 2600, f1: 700, duration: 0.6, volume: 0.4), scale: body)
            start(Shot(wave: .sine, f0: 80, f1: 50, duration: 0.3, volume: 0.35), scale: body)
        }
        if s.touchdown != seenShots.touchdown {
            let k = 0.25 + min(impact / 10, 1) * 0.75
            start(Shot(wave: .sine, f0: 100, f1: 40, duration: 0.25, volume: 0.6), scale: k * body)
            start(Shot(wave: .noise, mode: .low, f0: 800, f1: 150, duration: 0.2, volume: 0.4), scale: k * body)
        }
        if s.splashdown != seenShots.splashdown {
            let k = 0.4 + min(impact / 15, 1) * 0.6
            start(Shot(wave: .noise, mode: .band, f0: 3000, f1: 400, duration: 1.2, volume: 0.6, q: 0.6), scale: k)
            start(Shot(wave: .noise, mode: .low, f0: 500, f1: 100, duration: 0.6, volume: 0.5), scale: k)
        }
        if s.crash != seenShots.crash {
            // Громкость растёт со скоростью удара: от 0.6 до полной на 30 м/с и выше.
            let k = 0.6 + min(impact / 30, 1) * 0.4
            start(Shot(wave: .noise, mode: .low, f0: 1800, f1: 60, duration: 2.4, volume: 1.3), scale: k)
            start(Shot(wave: .saw, f0: 70, f1: 25, duration: 1.8, volume: 0.8), scale: k)
            start(Shot(wave: .noise, mode: .band, f0: 4000, f1: 800, duration: 0.5, volume: 0.5, q: 0.7), scale: k)
            start(Shot(wave: .noise, mode: .low, f0: 600, f1: 80, duration: 1.2, volume: 0.6, delay: 0.18), scale: k)
        }
    }
}

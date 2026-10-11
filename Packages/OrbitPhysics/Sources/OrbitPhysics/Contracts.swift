import Foundation

// Контракты между физикой (A) и приложением (B, C, D). Описание — docs/CONTRACTS.md.
// Изменение этих типов — только через ведущего агента.

// MARK: - Ввод

public enum SASMode: String, Sendable, Hashable, Codable, CaseIterable {
    case off, hold, prograde, retrograde, normal, antiNormal, radialOut, radialIn
}

/// Непрерывный ввод игрока; UI выставляет каждый кадр.
public struct ControlInput: Sendable, Hashable, Codable {
    /// Тяга 0…1.
    public var throttle: Double
    /// Тангаж, рыскание, крен −1…1.
    public var pitch: Double
    public var yaw: Double
    public var roll: Double
    /// Поступательное RCS −1…1 по осям корабля.
    public var translation: Vec3

    public init(throttle: Double = 0, pitch: Double = 0, yaw: Double = 0, roll: Double = 0, translation: Vec3 = .zero) {
        self.throttle = throttle
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
        self.translation = translation
    }

    public static let neutral = ControlInput()
}

/// Дискретные команды (кнопки).
public enum FlightCommand: Sendable, Hashable, Codable {
    case stage
    case setSAS(SASMode)
    case setWarp(index: Int)
    case deployChute
}

// MARK: - Состояние

public enum VesselSituation: String, Sendable, Hashable, Codable {
    case prelaunch, flying, suborbital, orbiting, escaping, landed, splashed, crashed
}

public typealias VesselID = UInt32

/// Состояние корабля. Координаты — инерциальная система с центром в `body`, м и м/с.
public struct VesselState: Sendable, Hashable {
    public var id: VesselID
    public var body: BodyID
    public var position: Vec3
    public var velocity: Vec3
    /// Ориентация: поворот из осей корабля (нос = +Y) в инерциальные.
    public var attitude: Quat
    public var angularVelocity: Vec3
    /// Масса, кг.
    public var mass: Double
    public var throttle: Double
    public var situation: VesselSituation
    /// Активен ли (интегрируется численно) или «на рельсах».
    public var isActive: Bool

    public init(id: VesselID, body: BodyID, position: Vec3, velocity: Vec3,
                attitude: Quat = .identity, angularVelocity: Vec3 = .zero,
                mass: Double, throttle: Double = 0,
                situation: VesselSituation = .prelaunch, isActive: Bool = true) {
        self.id = id
        self.body = body
        self.position = position
        self.velocity = velocity
        self.attitude = attitude
        self.angularVelocity = angularVelocity
        self.mass = mass
        self.throttle = throttle
        self.situation = situation
        self.isActive = isActive
    }
}

/// Кеплеровы элементы относительно тела. Высоты — над уровнем моря, м.
public struct OrbitSummary: Sendable, Hashable {
    public var apoapsisAltitude: Double   // .infinity для гиперболы
    public var periapsisAltitude: Double
    public var timeToApoapsis: Double     // с; .nan, если нет
    public var timeToPeriapsis: Double
    public var eccentricity: Double
    /// Наклонение, рад.
    public var inclination: Double
    /// Период, с; .infinity для незамкнутой орбиты.
    public var period: Double

    public init(apoapsisAltitude: Double, periapsisAltitude: Double, timeToApoapsis: Double,
                timeToPeriapsis: Double, eccentricity: Double, inclination: Double, period: Double) {
        self.apoapsisAltitude = apoapsisAltitude
        self.periapsisAltitude = periapsisAltitude
        self.timeToApoapsis = timeToApoapsis
        self.timeToPeriapsis = timeToPeriapsis
        self.eccentricity = eccentricity
        self.inclination = inclination
        self.period = period
    }
}

/// Сводка по ступени для HUD и ангара. Индекс 0 — текущая (нижняя) ступень.
public struct StageInfo: Sendable, Hashable {
    /// Δv ступени, м/с (текущая — по текущему давлению, остальные — вакуум).
    public var deltaV: Double
    /// Тяговооружённость относительно g текущего тела.
    public var twr: Double
    /// Остаток топлива 0…1.
    public var fuelFraction: Double
    /// Время работы на полной тяге, с.
    public var burnTime: Double
    /// Есть ли РДТТ (нельзя дросселировать).
    public var hasSolid: Bool

    public init(deltaV: Double, twr: Double, fuelFraction: Double, burnTime: Double, hasSolid: Bool) {
        self.deltaV = deltaV
        self.twr = twr
        self.fuelFraction = fuelFraction
        self.burnTime = burnTime
        self.hasSolid = hasSolid
    }
}

/// Готовые для HUD величины активного корабля.
public struct FlightTelemetry: Sendable, Hashable {
    public var altitude: Double
    public var heightAboveTerrain: Double
    public var speed: Double
    public var surfaceSpeed: Double
    public var verticalSpeed: Double
    /// Скоростной напор q, Па.
    public var dynamicPressure: Double
    public var mach: Double
    public var orbit: OrbitSummary?
    public var sas: SASMode
    public var warpFactor: Double
    public var missionTime: Double
    /// Номер текущей ступени (0 — последняя).
    public var stage: Int
    /// Ступени сверху вниз по порядку срабатывания: [0] — текущая.
    public var stages: [StageInfo]
    /// Текущая суммарная тяга, Н, и максимум при полной тяге.
    public var thrust: Double
    public var maxThrust: Double
    /// Работает ли РДТТ (для звука треска).
    public var solidBurning: Bool
    /// Плотность атмосферы вокруг, кг/м³ (0 — вакуум).
    public var atmosphereDensity: Double
    /// Нагрев при входе 0…1 (плазма, звук).
    public var heating: Double
    /// Перегрузка, g.
    public var gForce: Double
    /// Тело текущей SOI.
    public var body: BodyID
    public var situation: VesselSituation

    public init(altitude: Double = 0, heightAboveTerrain: Double = 0, speed: Double = 0,
                surfaceSpeed: Double = 0, verticalSpeed: Double = 0, dynamicPressure: Double = 0,
                mach: Double = 0, orbit: OrbitSummary? = nil, sas: SASMode = .off,
                warpFactor: Double = 1, missionTime: Double = 0, stage: Int = 0,
                stages: [StageInfo] = [], thrust: Double = 0, maxThrust: Double = 0,
                solidBurning: Bool = false, atmosphereDensity: Double = 0, heating: Double = 0,
                gForce: Double = 0, body: BodyID = .terra, situation: VesselSituation = .prelaunch) {
        self.altitude = altitude
        self.heightAboveTerrain = heightAboveTerrain
        self.speed = speed
        self.surfaceSpeed = surfaceSpeed
        self.verticalSpeed = verticalSpeed
        self.dynamicPressure = dynamicPressure
        self.mach = mach
        self.orbit = orbit
        self.sas = sas
        self.warpFactor = warpFactor
        self.missionTime = missionTime
        self.stage = stage
        self.stages = stages
        self.thrust = thrust
        self.maxThrust = maxThrust
        self.solidBurning = solidBurning
        self.atmosphereDensity = atmosphereDensity
        self.heating = heating
        self.gForce = gForce
        self.body = body
        self.situation = situation
    }
}

/// Снимок мира за кадр. Рендер, HUD и звук читают только его.
public struct WorldSnapshot: Sendable {
    /// Время симуляции (универсальное), с.
    public var time: Double
    public var activeVessel: VesselID?
    public var vessels: [VesselState]
    /// Положение Луны относительно Терры, м.
    public var lunaPosition: Vec3
    /// Угол поворота Терры вокруг оси +Z, рад.
    public var terraRotation: Double
    public var telemetry: FlightTelemetry

    public init(time: Double = 0, activeVessel: VesselID? = nil, vessels: [VesselState] = [],
                lunaPosition: Vec3 = Vec3(Bodies.luna.orbitRadius, 0, 0), terraRotation: Double = 0,
                telemetry: FlightTelemetry = FlightTelemetry()) {
        self.time = time
        self.activeVessel = activeVessel
        self.vessels = vessels
        self.lunaPosition = lunaPosition
        self.terraRotation = terraRotation
        self.telemetry = telemetry
    }

    public static let empty = WorldSnapshot()
}

// MARK: - События

public enum WarpResetReason: String, Sendable, Hashable, Codable {
    case atmosphere, terrain, thrust, soiChange
}

/// Одноразовые события шага; звук, вибрация, эффекты и подсказки реагируют на них.
public enum SimEvent: Sendable, Hashable {
    case ignition(stage: Int)
    case flameout(stage: Int)
    case separation(stage: Int)
    case chuteDeployed
    /// Купол полностью раскрылся.
    case chuteOpened
    case maxQ(pascals: Double)
    case touchdown(speed: Double)
    case splashdown(speed: Double)
    case crash(speed: Double)
    case soiChanged(from: BodyID, to: BodyID)
    case warpReset(WarpResetReason)
}

// MARK: - Симуляция

/// Точка входа физики. Вызывается с главного актёра игровым циклом.
public protocol FlightSimulation: AnyObject {
    var snapshot: WorldSnapshot { get }
    func setInput(_ input: ControlInput)
    func send(_ command: FlightCommand)
    /// Продвигает мир на `realDelta` секунд реального времени (с учётом ускорения),
    /// внутри дробит на шаги ≤ 0.02 с. Возвращает события за этот вызов.
    func advance(realDelta: Double) -> [SimEvent]
}

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
    public var body: BodyID
    public var apoapsisAltitude: Double   // .infinity для гиперболы
    public var periapsisAltitude: Double
    /// с; nil, если апоцентра нет (гипербола).
    public var timeToApoapsis: Double?
    public var timeToPeriapsis: Double?
    public var eccentricity: Double
    /// Наклонение, рад.
    public var inclination: Double
    /// Период, с; .infinity для незамкнутой орбиты.
    public var period: Double

    public init(body: BodyID, apoapsisAltitude: Double, periapsisAltitude: Double, timeToApoapsis: Double?,
                timeToPeriapsis: Double?, eccentricity: Double, inclination: Double, period: Double) {
        self.body = body
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

    /// Тяговооружённость в вакууме.
    public var twrVacuum: Double

    public init(deltaV: Double, twr: Double, twrVacuum: Double, fuelFraction: Double, burnTime: Double, hasSolid: Bool) {
        self.deltaV = deltaV
        self.twr = twr
        self.twrVacuum = twrVacuum
        self.fuelFraction = fuelFraction
        self.burnTime = burnTime
        self.hasSolid = hasSolid
    }
}

/// Направления (единичные векторы) в осях корабля: нос = +Y. nil — не определено.
public struct NavballVectors: Sendable, Hashable {
    public var prograde: Vec3?
    public var normal: Vec3?
    public var radialOut: Vec3?
    public var surfacePrograde: Vec3?
    public var target: Vec3?
    public var maneuver: Vec3?

    public init(prograde: Vec3? = nil, normal: Vec3? = nil, radialOut: Vec3? = nil,
                surfacePrograde: Vec3? = nil, target: Vec3? = nil, maneuver: Vec3? = nil) {
        self.prograde = prograde
        self.normal = normal
        self.radialOut = radialOut
        self.surfacePrograde = surfacePrograde
        self.target = target
        self.maneuver = maneuver
    }
}

public enum ChuteState: String, Sendable, Hashable, Codable {
    /// none — парашюта нет.
    case none, stowed, armed, deploying, open, cut
}

/// Уровни ускорения времени. Первые `physicalCount` — физические, остальные — «на рельсах».
public enum TimeWarp {
    public static let levels: [Double] = [1, 2, 3, 4, 10, 100, 1_000, 10_000, 100_000]
    public static let physicalCount = 4
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
    /// Оставшиеся ступени по порядку срабатывания: [0] — текущая, последний — капсула.
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
    /// Статическое давление, атм (1 — уровень моря Терры).
    public var staticPressure: Double
    /// Ориентация относительно местного горизонта, рад: тангаж (+ вверх), курс (0 — север, π/2 — восток), крен.
    public var pitch: Double
    public var heading: Double
    public var roll: Double
    /// Маркеры навбола в осях корабля.
    public var navball: NavballVectors
    public var chute: ChuteState
    /// Безопасно ли раскрывать парашют сейчас (ниже 34 км и < 450 м/с).
    public var chuteSafe: Bool
    /// Индекс в `TimeWarp.levels` и почему выше нельзя (nil — можно).
    public var warpIndex: Int
    public var warpBlocked: WarpResetReason?

    public init(altitude: Double = 0, heightAboveTerrain: Double = 0, speed: Double = 0,
                surfaceSpeed: Double = 0, verticalSpeed: Double = 0, dynamicPressure: Double = 0,
                mach: Double = 0, orbit: OrbitSummary? = nil, sas: SASMode = .off,
                warpFactor: Double = 1, missionTime: Double = 0,
                stages: [StageInfo] = [], thrust: Double = 0, maxThrust: Double = 0,
                solidBurning: Bool = false, atmosphereDensity: Double = 0, heating: Double = 0,
                gForce: Double = 0, body: BodyID = .terra, situation: VesselSituation = .prelaunch,
                staticPressure: Double = 0, pitch: Double = 0, heading: Double = 0, roll: Double = 0,
                navball: NavballVectors = NavballVectors(), chute: ChuteState = .none, chuteSafe: Bool = false,
                warpIndex: Int = 0, warpBlocked: WarpResetReason? = nil) {
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
        self.stages = stages
        self.thrust = thrust
        self.maxThrust = maxThrust
        self.solidBurning = solidBurning
        self.atmosphereDensity = atmosphereDensity
        self.heating = heating
        self.gForce = gForce
        self.body = body
        self.situation = situation
        self.staticPressure = staticPressure
        self.pitch = pitch
        self.heading = heading
        self.roll = roll
        self.navball = navball
        self.chute = chute
        self.chuteSafe = chuteSafe
        self.warpIndex = warpIndex
        self.warpBlocked = warpBlocked
    }
}

/// Снимок мира за кадр. Рендер, HUD и звук читают только его.
public struct WorldSnapshot: Sendable {
    /// Время симуляции (универсальное), с.
    public var time: Double
    public var activeVessel: VesselID?
    public var vessels: [VesselState]
    /// Положение и скорость Луны относительно Терры, м и м/с.
    public var lunaPosition: Vec3
    public var lunaVelocity: Vec3
    /// Угол поворота Терры вокруг оси +Z, рад.
    public var terraRotation: Double
    public var telemetry: FlightTelemetry

    public init(time: Double = 0, activeVessel: VesselID? = nil, vessels: [VesselState] = [],
                lunaPosition: Vec3 = Vec3(Bodies.luna.orbitRadius, 0, 0), lunaVelocity: Vec3 = .zero, terraRotation: Double = 0,
                telemetry: FlightTelemetry = FlightTelemetry()) {
        self.time = time
        self.activeVessel = activeVessel
        self.vessels = vessels
        self.lunaPosition = lunaPosition
        self.lunaVelocity = lunaVelocity
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
    case ignition(stage: Int, solid: Bool)
    case flameout(stage: Int, solid: Bool)
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

import Foundation

// Контракты между физикой (A) и приложением (B, C, D). Описание — docs/CONTRACTS.md.
// Изменение этих типов — только через ведущего агента.

// MARK: - Ввод

public enum SASMode: String, Sendable, Hashable, Codable, CaseIterable {
    case off, hold, prograde, retrograde, normal, antiNormal, radialOut, radialIn
    /// По оставшемуся импульсу узла манёвра (нет узла — как `hold`).
    case maneuver
}

/// Непрерывный ввод игрока; UI выставляет каждый кадр.
///
/// Оси корабля (правая тройка): нос = +Y, спина = +Z, правый борт = +X.
/// pitch > 0 — нос к +Z (вверх), yaw > 0 — нос к +X (вправо), roll > 0 — правый борт вниз
/// (по часовой при взгляде сзади). На площадке: нос в зенит, +X — на восток, +Z — на юг,
/// поэтому гравитационный разворот на восток — yaw > 0.
public struct ControlInput: Sendable, Hashable, Codable {
    /// Тяга 0…1.
    public var throttle: Double
    /// Тангаж, рыскание, крен −1…1.
    public var pitch: Double
    public var yaw: Double
    public var roll: Double
    /// Поступательное RCS −1…1 по осям корабля (x — правый борт, y — нос/вперёд, z — спина/вверх).
    /// Действует, только когда RCS включено (`FlightCommand.setRCS`) и есть монотопливо.
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
    /// Поставить, изменить (nil — удалить) узел манёвра активного корабля.
    case setManeuver(ManeuverNode?)
    /// Ускорение «на рельсах» до узла: само сбрасывается до ×1 за `ManeuverStatus.warpLead` до начала прожига.
    case warpToManeuver
    /// Включить/выключить РСУ. Включённое РСУ даёт поступательную тягу по `ControlInput.translation`
    /// и добавляет момент к повороту (ручному и SAS), расходуя монотопливо.
    case setRCS(Bool)
}

// MARK: - Состояние

public enum VesselSituation: String, Sendable, Hashable, Codable {
    case prelaunch, flying, suborbital, orbiting, escaping, landed, splashed, crashed
}

public typealias VesselID = UInt32

/// Состояние корабля. Координаты — инерциальная система с центром в `body`, м и м/с.
/// `position` — нижняя точка стека деталей (то, что касается грунта), не центр масс.
/// `angularVelocity` — в инерциальной системе, рад/с. Оси корабля — см. `ControlInput`.
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
    /// Детали в порядке `VesselDesign.nodes` (для линейного стека — сверху вниз), индексы двигателей с факелом,
    /// состояние и раскрытие парашюта 0…1.
    public var parts: [PartID]
    /// Раскладка деталей (5.2) — те же индексы, что `parts`; начало — `position`. Пусто — рендер ставит стек.
    public var layout: [PartPlacement]
    public var firingEngines: [Int]
    public var chute: ChuteState
    public var chuteDeploy: Double
    /// Сопла РСУ в этом кадре, оси корабля −1…1: поступательная команда (`translation`)
    /// и поворотная (`rotation`: x — тангаж, y — крен, z — рыскание со знаком оси +Z).
    /// Нули — РСУ молчит (выключено, нет топлива или нет команды). Только у активного корабля.
    public var rcsTranslation: Vec3
    public var rcsRotation: Vec3
    /// Нагрев деталей 0…1 (температура / предел детали), те же индексы, что `parts`; пусто — холодные (5.2).
    public var partHeat: [Double] = []

    public init(id: VesselID, body: BodyID, position: Vec3, velocity: Vec3,
                attitude: Quat = .identity, angularVelocity: Vec3 = .zero,
                mass: Double, throttle: Double = 0,
                situation: VesselSituation = .prelaunch, isActive: Bool = true,
                parts: [PartID] = [], firingEngines: [Int] = [],
                chute: ChuteState = .none, chuteDeploy: Double = 0,
                rcsTranslation: Vec3 = .zero, rcsRotation: Vec3 = .zero, layout: [PartPlacement] = []) {
        self.layout = layout
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
        self.parts = parts
        self.firingEngines = firingEngines
        self.chute = chute
        self.chuteDeploy = chuteDeploy
        self.rcsTranslation = rcsTranslation
        self.rcsRotation = rcsRotation
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

/// Действие следующего нажатия «Ступень», вычисленное симуляцией.
public enum StageAction: Sendable, Hashable {
    case ignite, separate, armChute, none
}

/// Сводка по ступени для HUD и ангара. Индекс 0 — текущая (нижняя) ступень.
public struct StageInfo: Sendable, Hashable {
    /// Δv ступени, м/с (текущая — по текущему давлению, остальные — вакуум).
    public var deltaV: Double
    /// Тяговооружённость относительно g текущего тела.
    public var twr: Double
    /// Остаток топлива 0…1.
    public var fuelFraction: Double
    public var fuelMass: Double
    public var fuelCapacity: Double
    /// Время работы на полной тяге, с.
    public var burnTime: Double
    /// Есть ли РДТТ (нельзя дросселировать).
    public var hasSolid: Bool
    /// Жидкостные двигатели остаются регулируемыми даже вместе с РДТТ.
    public var hasLiquidEngine: Bool

    /// Тяговооружённость в вакууме.
    public var twrVacuum: Double
    /// Детали, которые срабатывают в этой ступени активации (двигатели, разделители, парашют, обтекатель) — для
    /// значков HUD и редактора ступеней; пусто — значки по флагам.
    public var parts: [PartID] = []

    public init(deltaV: Double, twr: Double, twrVacuum: Double, fuelFraction: Double, burnTime: Double, hasSolid: Bool, fuelMass: Double = 0, fuelCapacity: Double = 0, hasLiquidEngine: Bool = false) {
        self.deltaV = deltaV
        self.twr = twr
        self.twrVacuum = twrVacuum
        self.fuelMass = fuelMass
        self.fuelCapacity = fuelCapacity
        self.fuelFraction = fuelFraction
        self.burnTime = burnTime
        self.hasSolid = hasSolid
        self.hasLiquidEngine = hasLiquidEngine
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

/// Итоги полёта активного корабля с момента старта (для экрана результата). Только растёт.
public struct MissionRecord: Sendable, Hashable {
    /// Корабль покинул площадку или начальную точку.
    public var launched: Bool
    /// Максимальная высота над уровнем моря текущего тела, м; максимальная орбитальная скорость, м/с; перегрузка, g.
    public var maxAltitude: Double
    public var maxSpeed: Double
    public var maxGForce: Double
    /// Выше атмосферы Терры (70 км).
    public var reachedSpace: Bool
    /// Перицентр над атмосферой Терры (замкнутая орбита).
    public var reachedOrbit: Bool
    public var enteredLunaSOI: Bool
    /// Замкнутая орбита вокруг Луны с перицентром выше рельефа.
    public var lunaOrbit: Bool
    /// Посадка на Луну (landed без аварии).
    public var landedLuna: Bool
    /// Посадка или приводнение на Терре после выхода в космос.
    public var returnedFromSpace: Bool
    /// Планеты (Велла, Арда, Тарос), в SOI которых побывал корабль.
    public var visitedPlanets: Set<BodyID>
    /// Планеты, вокруг которых была замкнутая орбита выше атмосферы.
    public var orbitedPlanets: Set<BodyID>

    public init(launched: Bool = false, maxAltitude: Double = 0, maxSpeed: Double = 0, maxGForce: Double = 0,
                reachedSpace: Bool = false, reachedOrbit: Bool = false, enteredLunaSOI: Bool = false,
                lunaOrbit: Bool = false, landedLuna: Bool = false, returnedFromSpace: Bool = false,
                visitedPlanets: Set<BodyID> = [], orbitedPlanets: Set<BodyID> = []) {
        self.launched = launched
        self.maxAltitude = maxAltitude
        self.maxSpeed = maxSpeed
        self.maxGForce = maxGForce
        self.reachedSpace = reachedSpace
        self.reachedOrbit = reachedOrbit
        self.enteredLunaSOI = enteredLunaSOI
        self.lunaOrbit = lunaOrbit
        self.landedLuna = landedLuna
        self.returnedFromSpace = returnedFromSpace
        self.visitedPlanets = visitedPlanets
        self.orbitedPlanets = orbitedPlanets
    }
}

/// РСУ активного корабля для HUD.
/// Нагрев деталей (5.2): самая горячая деталь, абляционное покрытие теплозащитных экранов.
public struct ThermalStatus: Sendable, Hashable {
    /// Температура самой горячей детали / её предел, 0…1 (≥ 1 — деталь разрушается).
    public var hottest: Double
    public var hottestPart: PartID?
    /// Абляционное покрытие экранов, кг, и его ёмкость (0 — экранов нет).
    public var ablator: Double
    public var ablatorCapacity: Double
    /// Набегающий поток сейчас встречает теплозащитный экран.
    public var shieldFacingFlow: Bool

    public init(hottest: Double = 0, hottestPart: PartID? = nil, ablator: Double = 0, ablatorCapacity: Double = 0,
                shieldFacingFlow: Bool = false) {
        self.hottest = hottest
        self.hottestPart = hottestPart
        self.ablator = ablator
        self.ablatorCapacity = ablatorCapacity
        self.shieldFacingFlow = shieldFacingFlow
    }
}

public struct RCSStatus: Sendable, Hashable {
    /// Есть ли на корабле блоки РСУ.
    public var available: Bool
    /// Включено ли РСУ (команда `setRCS`); сохраняется, даже если блоков нет.
    public var enabled: Bool
    /// Монотопливо на всём корабле, кг: остаток и ёмкость.
    public var monoMass: Double
    public var monoCapacity: Double
    /// Сопла работают в этом кадре.
    public var firing: Bool

    public var monoFraction: Double { monoCapacity > 0 ? monoMass / monoCapacity : 0 }

    public init(available: Bool = false, enabled: Bool = false, monoMass: Double = 0,
                monoCapacity: Double = 0, firing: Bool = false) {
        self.available = available
        self.enabled = enabled
        self.monoMass = monoMass
        self.monoCapacity = monoCapacity
        self.firing = firing
    }
}

/// Состояние узла манёвра для HUD и навбола.
public struct ManeuverStatus: Sendable, Hashable {
    /// За сколько секунд до начала прожига `warpToManeuver` останавливает ускорение.
    public static let warpLead = 15.0

    public var node: ManeuverNode
    /// До момента узла, с (отрицательное — узел позади).
    public var timeToNode: Double
    /// Полный импульс узла и оставшийся (уменьшается по мере прожига), м/с.
    public var deltaV: Double
    public var remainingDeltaV: Double
    /// Время прожига оставшегося импульса на полной тяге текущей ступени, с (∞ — нет тяги).
    public var burnTime: Double
    /// Начало прожига относительно сейчас: timeToNode − burnTime/2, с.
    public var timeToBurn: Double
    /// Прожиг выполнен (остаток < 1 м/с или начал расти).
    public var isDone: Bool

    public init(node: ManeuverNode, timeToNode: Double, deltaV: Double, remainingDeltaV: Double,
                burnTime: Double, timeToBurn: Double, isDone: Bool) {
        self.node = node
        self.timeToNode = timeToNode
        self.deltaV = deltaV
        self.remainingDeltaV = remainingDeltaV
        self.burnTime = burnTime
        self.timeToBurn = timeToBurn
        self.isDone = isDone
    }
}

/// Отметка на карте: точка траектории в системе тела `body` (инерциальная, м) в момент `time`.
public struct MapMarker: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case apoapsis, periapsis
        /// Восходящий и нисходящий узлы относительно экватора Терры (он же плоскость орбиты Луны).
        case ascendingNode, descendingNode
        /// Вход в SOI тела и выход из SOI текущего тела.
        case soiEnter(BodyID), soiExit(BodyID)
        /// Падение на тело.
        case impact
        /// Точка узла манёвра.
        case maneuver
    }

    public var kind: Kind
    public var body: BodyID
    public var position: Vec3
    public var time: Double
    /// Высота над уровнем моря `body`, м.
    public var altitude: Double
    /// Индекс участка траектории и признак: отметка орбиты после манёвра.
    public var patchIndex: Int
    public var afterManeuver: Bool

    public init(kind: Kind, body: BodyID, position: Vec3, time: Double, altitude: Double,
                patchIndex: Int, afterManeuver: Bool) {
        self.kind = kind
        self.body = body
        self.position = position
        self.time = time
        self.altitude = altitude
        self.patchIndex = patchIndex
        self.afterManeuver = afterManeuver
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
    /// Оставшиеся ступени по порядку срабатывания: [0] — текущая, последний — капсула.
    public var nextStageAction: StageAction = .none
    public var stages: [StageInfo]
    /// Текущая суммарная тяга, Н, и максимум при полной тяге.
    public var thrust: Double
    public var maxThrust: Double
    /// Работает ли РДТТ (для звука треска).
    public var solidBurning: Bool
    /// Плотность атмосферы вокруг, кг/м³ (0 — вакуум).
    public var atmosphereDensity: Double
    /// Нагрев при входе 0…1 (плазма, звук).
    /// Температура воздуха, К; nil в вакууме (не температура деталей).
    public var environmentTemperature: Double? = nil
    /// Ускорение тяготения в текущей точке, м/с².
    public var localGravity: Double = 0
    public var heating: Double
    /// Тепловое состояние деталей при входе в атмосферу (5.2).
    public var thermal = ThermalStatus()
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
    /// Итоги полёта (экран результата).
    public var mission: MissionRecord
    /// Узел манёвра активного корабля (nil — нет).
    public var maneuver: ManeuverStatus?
    /// РСУ активного корабля.
    public var rcs: RCSStatus

    public init(altitude: Double = 0, heightAboveTerrain: Double = 0, speed: Double = 0,
                surfaceSpeed: Double = 0, verticalSpeed: Double = 0, dynamicPressure: Double = 0,
                mach: Double = 0, orbit: OrbitSummary? = nil, sas: SASMode = .off,
                warpFactor: Double = 1, missionTime: Double = 0,
                stages: [StageInfo] = [], thrust: Double = 0, maxThrust: Double = 0,
                solidBurning: Bool = false, atmosphereDensity: Double = 0, heating: Double = 0,
                gForce: Double = 0, body: BodyID = .terra, situation: VesselSituation = .prelaunch,
                staticPressure: Double = 0, pitch: Double = 0, heading: Double = 0, roll: Double = 0,
                navball: NavballVectors = NavballVectors(), chute: ChuteState = .none, chuteSafe: Bool = false,
                warpIndex: Int = 0, warpBlocked: WarpResetReason? = nil, mission: MissionRecord = MissionRecord(),
                maneuver: ManeuverStatus? = nil, rcs: RCSStatus = RCSStatus()) {
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
        self.mission = mission
        self.maneuver = maneuver
        self.rcs = rcs
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
    /// `warpToManeuver`: до начала прожига осталось `ManeuverStatus.warpLead` с.
    case maneuver
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
    /// Деталь разрушилась от перегрева (5.2).
    case partDestroyed(PartID)
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
    /// Прогноз траектории активного корабля (патченные коники), до `maxPatches` участков.
    func predictTrajectory(maxPatches: Int) -> Trajectory
    /// Прогноз после узла манёвра; nil — узел невозможен (например, корабль на грунте).
    func predictManeuver(_ node: ManeuverNode, maxPatches: Int) -> ManeuverPrediction?
}

/// Контрольная точка для отката (обучение). Симуляции без поддержки возвращают nil.
public protocol FlightCheckpointing: AnyObject {
    func checkpoint() -> SimCheckpoint
    func restore(_ checkpoint: SimCheckpoint)
}

extension FlightSim: FlightCheckpointing {}

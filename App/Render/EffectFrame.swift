import OrbitPhysics
import simd

// Контракт этапа 4 между SceneRenderer (ведущий) и эффектами (атмосфера, облака, эффекты корабля).
// Всё в Double, в инерциальной системе тела активного корабля, относительно камеры (камера — в нуле).
// Эффекты сами переводят в Float при записи трансформов.

/// Уровень качества эффектов: 0 — низкое, 1 — среднее, 2 — высокое. Меняется авто-качеством на лету.
typealias RenderQuality = Int

/// Кадр для неба, дымки, облаков и ореола атмосферы Терры.
struct AtmosphereFrame {
    /// Время рендера (с начала полёта, без ускорения времени) и шаг кадра, с.
    var time: Double
    var dt: Double
    /// Центр Терры относительно камеры, м (настоящий, без масштаба-импостора).
    var terraCenter: D3
    /// Поворот «связанная с Террой система → мир рендера».
    var terraRotation: simd_quatd
    /// Масштаб-импостор рельефа Терры: точка `p` (относительно камеры) рисуется в `p * terraScale`
    /// с размерами × `terraScale` (масштаб вокруг камеры сохраняет угловой размер). 1 — вблизи.
    var terraScale: Double
    /// Местная вертикаль Терры у камеры (единичный вектор).
    var up: D3
    /// Высота камеры над уровнем моря Терры, м.
    var altitude: Double
    /// Яркость дневного неба у камеры 0…1 (0 — космос или ночь).
    var skyBrightness: Double
    /// Направление на Солнце (единичный, неподвижно в инерциальной системе).
    var sun: D3
    /// Активное тело системы отсчёта; облака и дымка нужны только у Терры.
    var frameBody: BodyID
    var quality: RenderQuality
}

/// Кадр для эффектов активного корабля: дым, потоки воздуха, конденсационный конус, плазма.
struct VesselEffectFrame {
    var time: Double
    var dt: Double
    /// Активный корабль (позиция — нижняя точка стека, в системе тела).
    var vessel: VesselState
    /// Нижняя точка стека относительно камеры, м.
    var vesselRel: D3
    /// Высота стека, м, и нижняя точка каждой детали над низом стека (как в `VesselVisual`).
    var stackHeight: Double
    var partBottoms: [Double]
    /// Скорость корабля относительно воздуха (в системе тела), м/с; у Луны — инерциальная.
    var airVelocity: D3
    /// Скорость, с которой движется воздух у корабля (вращение Терры), м/с — для сноса дыма.
    var windVelocity: D3
    /// Местная вертикаль у корабля.
    var up: D3
    /// Высота корабля над грунтом, м, и точка грунта под кораблём относительно камеры.
    var heightAboveGround: Double
    var groundRel: D3
    var telemetry: FlightTelemetry
    /// Яркость дня у корабля 0…1 (для подсветки дыма).
    var daylight: Double
    var quality: RenderQuality
}

/// Авто-качество: по времени кадра опускает уровень, если кадры не успевают, и осторожно поднимает обратно.
struct QualityGovernor {
    private(set) var level: RenderQuality = 2
    private var avg = 0.0
    private var cooldown = 0.0
    private var goodTime = 0.0

    /// `dt` — фактический интервал кадра, `target` — желаемая длительность кадра (1 / частота), с.
    mutating func update(dt: Double, target: Double) -> RenderQuality {
        guard dt > 0, dt < 0.5 else { return level }
        avg = avg == 0 ? dt : avg + (dt - avg) * 0.05
        cooldown = max(0, cooldown - dt)
        guard cooldown == 0 else { return level }
        if avg > target * 1.25, level > 0 {
            level -= 1
            cooldown = 3
            goodTime = 0
        } else if avg < target * 1.05 {
            goodTime += dt
            if goodTime > 20, level < 2 {
                level += 1
                cooldown = 5
                goodTime = 0
            }
        } else {
            goodTime = 0
        }
        return level
    }
}

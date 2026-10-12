import Foundation

/// Отметки карты для траектории (поток A).
public enum MapMarkers {
    /// Ап/Пе (в пределах участка; у незамкнутых — только Пе), AN/DN относительно плоскости XY Терры,
    /// вход/выход SOI, падение — по каждому участку `trajectory`. Отметку `.maneuver` ставит вызывающий.
    public static func compute(_ trajectory: Trajectory, afterManeuver: Bool) -> [MapMarker] {
        []
    }
}

import OrbitPhysics

/// Заглушки звука и вибрации до этапа 1.
@MainActor
final class SilentAudio: FlightAudio {
    var isEnabled = true
    func update(snapshot: WorldSnapshot, events: [SimEvent]) {}
}

@MainActor
final class NoHaptics: FlightHaptics {
    var isEnabled = true
    func update(snapshot: WorldSnapshot, events: [SimEvent]) {}
}

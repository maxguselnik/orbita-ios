import OrbitPhysics
import Testing
@testable import Orbita

@Suite("Нагрев в HUD")
struct ThermalHUDTests {
    @Test func gaugeHiddenBelowThreshold() {
        #expect(ThermalDisplay.make(ThermalStatus(hottest: 0.3)) == nil)
        #expect(ThermalDisplay.make(ThermalStatus(hottest: 0.31)) != nil)
    }

    @Test func gaugeColorLevels() {
        #expect(ThermalDisplay.level(0.5) == .normal)
        #expect(ThermalDisplay.level(0.7) == .normal)
        #expect(ThermalDisplay.level(0.71) == .warning)
        #expect(ThermalDisplay.level(0.9) == .warning)
        #expect(ThermalDisplay.level(0.91) == .danger)
    }

    @Test func shieldShowsAblatorAndMisalignmentWarning() {
        let shield = ThermalStatus(hottest: 0.6, hottestPart: .heatShield, ablator: 50, ablatorCapacity: 200,
                                   shieldFacingFlow: false)
        let shown = ThermalDisplay.make(shield)
        #expect(shown?.hasShield == true)
        #expect(shown?.ablatorFraction == 0.25)
        #expect(shown?.shieldMisaligned == true)
        #expect(shown?.percentText == "60 %")

        let aligned = ThermalStatus(hottest: 0.6, ablator: 50, ablatorCapacity: 200, shieldFacingFlow: true)
        #expect(ThermalDisplay.make(aligned)?.shieldMisaligned == false)
        // Слабый нагрев — без предупреждения; без экрана — тоже.
        let weak = ThermalStatus(hottest: 0.4, ablator: 50, ablatorCapacity: 200, shieldFacingFlow: false)
        #expect(ThermalDisplay.make(weak)?.shieldMisaligned == false)
        let bare = ThermalStatus(hottest: 0.8, shieldFacingFlow: false)
        #expect(ThermalDisplay.make(bare)?.hasShield == false)
        #expect(ThermalDisplay.make(bare)?.shieldMisaligned == false)
    }

    @Test func destroyedPartMessage() {
        let text = FlightHUDModel.message(for: .partDestroyed(.heatShield))
        #expect(text?.hasPrefix("Сгорела деталь: ") == true)
    }

    @Test func reentryHintAsksForRetrogradeWithShield() {
        var advisor = FlightAdvisor()
        var t = FlightTelemetry(altitude: 60_000, surfaceSpeed: 3_000, verticalSpeed: -800,
                                situation: .suborbital, chute: .stowed, chuteSafe: false)
        t.mission.launched = true
        t.heating = 0.2
        t.thermal = ThermalStatus(hottest: 0.2, hottestPart: .podK1, ablator: 100, ablatorCapacity: 100,
                                  shieldFacingFlow: false)
        advisor.update(t, throttle: 0, events: [], now: 0)
        let first = advisor.hint
        #expect(first == .reentryShield)
        #expect(HUDHint.reentryShield.text == "Ретроград, экран к потоку")
        t.thermal.shieldFacingFlow = true
        advisor.update(t, throttle: 0, events: [], now: 1)
        #expect(advisor.hint != .reentryShield)
    }
}

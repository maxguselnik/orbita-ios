import Testing
@testable import Orbita

struct MapCameraTests {
    @Test func tiltStaysBetweenSideAndTopView() {
        var camera = MapCamera()
        camera.apply(orbit: SIMD2(0, -10), zoom: 1)
        #expect(camera.elevation == MapCamera.minElevation, "под плоскость орбиты камера не уходит")
        camera.apply(orbit: SIMD2(0, 10), zoom: 1)
        #expect(camera.elevation == MapCamera.maxElevation)
        camera.apply(orbit: SIMD2(1, 0), zoom: 1)
        #expect(camera.elevation == MapCamera.maxElevation, "вращение влево-вправо наклон не меняет")
    }

    @Test func defaultViewIsNearlyTopDown() {
        #expect(MapCamera.defaultElevation > 1 && MapCamera.defaultElevation < MapCamera.maxElevation)
        var camera = MapCamera()
        camera.apply(orbit: SIMD2(0.5, -0.8), zoom: 1)
        camera.setDefault(distance: 300, snap: true)
        #expect(camera.elevation == MapCamera.defaultElevation)
    }
}

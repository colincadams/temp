// Native barometer plugin for the Highway Grade Capacitor app.
//
// Bridges iOS CoreMotion's CMAltimeter (the phone's pressure sensor) to JS. It
// emits a "reading" event with `relativeAltitude` (meters relative to when
// monitoring started) and `pressure` (kPa). src/native.js forwards those to the
// window.HighwayGradeNative.barometer bridge that src/sources/barometerSource.js
// consumes.
//
// CMAltimeter resolves ~0.1 m of relative altitude change, so paired with
// horizontal distance it gives accurate, drift-free grade even where GPS and the
// elevation map fail — e.g. in steep canyons.
//
// Requires "Privacy - Motion Usage Description" (NSMotionUsageDescription) in
// the app's Info.plist. See NATIVE.md.

import Foundation
import Capacitor
import CoreMotion

@objc(BarometerPlugin)
public class BarometerPlugin: CAPPlugin {
    private let altimeter = CMAltimeter()
    private var isRunning = false

    @objc func isAvailable(_ call: CAPPluginCall) {
        call.resolve(["available": CMAltimeter.isRelativeAltitudeAvailable()])
    }

    @objc func start(_ call: CAPPluginCall) {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            call.reject("Barometric altimeter not available on this device")
            return
        }
        if isRunning {
            call.resolve(["available": true])
            return
        }
        isRunning = true
        altimeter.startRelativeAltitudeUpdates(to: OperationQueue.main) { [weak self] data, error in
            guard let self = self else { return }
            if let error = error {
                self.notifyListeners("error", data: ["message": error.localizedDescription])
                return
            }
            guard let data = data else { return }
            let timestampMs = Date().timeIntervalSince1970 * 1000.0
            self.notifyListeners("reading", data: [
                "relativeAltitude": data.relativeAltitude.doubleValue, // meters since start
                "pressure": data.pressure.doubleValue,                 // kPa
                "timestamp": timestampMs
            ])
        }
        call.resolve(["available": true])
    }

    @objc func stop(_ call: CAPPluginCall) {
        if isRunning {
            altimeter.stopRelativeAltitudeUpdates()
            isRunning = false
        }
        call.resolve()
    }
}

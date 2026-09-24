import Foundation
import UIKit
import Network
import CoreTelephony

/// What the phone knows about itself for the Mac to show: which radio the
/// Mac's traffic rides on and the battery. The iOS counterpart of the Android
/// app's DeviceFacts.
@MainActor
final class DeviceFacts {
    /// Fires when Wi-Fi comes or goes.
    var onChange: (() -> Void)?
    private(set) var onWiFi = false
    private let telephony = CTTelephonyNetworkInfo()
    private let pathMonitor = NWPathMonitor()

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.onWiFi = path.usesInterfaceType(.wifi)
                self?.onChange?()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.dpatel.passthrough.path"))
    }

    /// The network the Mac's traffic actually leaves on.
    func radio(cellularOnly: Bool, running: Bool, fallback: Bool) -> String? {
        if cellularOnly && running && fallback { return "Wi-Fi (cell down)" }
        if onWiFi && !cellularOnly { return "Wi-Fi" }
        return Self.radioLabel(telephony.serviceCurrentRadioAccessTechnology?.values.first)
    }

    var battery: Double? {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) : nil
    }

    static func radioLabel(_ tech: String?) -> String? {
        guard let tech else { return nil }
        if #available(iOS 14.1, *), tech == CTRadioAccessTechnologyNRNSA || tech == CTRadioAccessTechnologyNR { return "5G" }
        switch tech {
        case CTRadioAccessTechnologyLTE: return "LTE"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA: return "3G"
        case CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyGPRS: return "2G"
        default: return "Cellular"
        }
    }
}

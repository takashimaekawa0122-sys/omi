import Flutter
import NetworkExtension
import CoreLocation

/// Plugin for managing WiFi network connections to Omi device's AP.
/// Uses NEHotspotConfiguration to connect to networks programmatically.
///
/// IMPORTANT: iOS 13+ requires "Location When In Use" permission to read the
/// current Wi-Fi SSID via NEHotspotNetwork.fetchCurrent(). Without it the SSID
/// comes back as nil/empty and the monitor loop can never confirm a successful
/// join — it will retry until the 30s timeout and surface
/// "Connection timeout. Please try again." even though the phone actually
/// joined the Omi AP. We therefore request location authorization up-front.
///
/// Connection flow:
/// 1. Ensure CoreLocation "When In Use" authorization
/// 2. Remove any existing config for the SSID
/// 3. Apply new config (iOS shows "Join WiFi?" dialog)
/// 4. Start monitoring loop - check if connected to target SSID
/// 5. If not connected after 3 seconds, re-apply the config
/// 6. Repeat until connected or timeout (30 seconds)
class WifiNetworkPlugin: NSObject, CLLocationManagerDelegate {
    private let channel: FlutterMethodChannel
    private let locationManager = CLLocationManager()

    // Pending authorization callback (fires once CoreLocation confirms status)
    private var pendingAuthorizationCallback: ((Bool) -> Void)?

    // Connection state
    private var connectLoop = false
    private var connectionStartTime: Date?
    private static let connectionTimeout: TimeInterval = 30.0
    private static let retryInterval: TimeInterval = 3.0

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.omi.wifi_network", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler(handle)
        locationManager.delegate = self
    }

    // MARK: - CoreLocation authorization

    /// Ensure we have "When In Use" (or stronger) location authorization.
    /// iOS requires this before NEHotspotNetwork.fetchCurrent returns the SSID.
    private func ensureLocationAuthorization(completion: @escaping (Bool) -> Void) {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = locationManager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            completion(true)
        case .notDetermined:
            NSLog("WifiNetworkPlugin: Requesting location permission for SSID detection")
            pendingAuthorizationCallback = completion
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            NSLog("WifiNetworkPlugin: Location permission denied — SSID detection unavailable")
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let cb = pendingAuthorizationCallback else { return }
        let status = manager.authorizationStatus
        let granted = (status == .authorizedWhenInUse || status == .authorizedAlways)
        NSLog("WifiNetworkPlugin: Location authorization changed: \(status.rawValue) granted=\(granted)")
        pendingAuthorizationCallback = nil
        cb(granted)
    }

    // iOS 13 fallback
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        guard let cb = pendingAuthorizationCallback else { return }
        let granted = (status == .authorizedWhenInUse || status == .authorizedAlways)
        NSLog("WifiNetworkPlugin: (legacy) Location authorization changed: \(status.rawValue) granted=\(granted)")
        pendingAuthorizationCallback = nil
        cb(granted)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "connectToWifi":
            guard let args = call.arguments as? [String: Any],
                  let ssid = args["ssid"] as? String else {
                result(["success": false, "error": "Invalid arguments", "errorCode": 0])
                return
            }
            let password = args["password"] as? String
            connectToWifi(ssid: ssid, password: password, result: result)

        case "disconnectFromWifi":
            guard let args = call.arguments as? [String: Any],
                  let ssid = args["ssid"] as? String else {
                result(false)
                return
            }
            disconnectFromWifi(ssid: ssid, result: result)

        case "isConnectedToWifi":
            guard let args = call.arguments as? [String: Any],
                  let ssid = args["ssid"] as? String else {
                result(false)
                return
            }
            isConnectedToWifi(ssid: ssid, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Connect to a WiFi network, optionally with a password.
    /// Uses a retry loop that re-applies the config until connected or timeout.
    private func connectToWifi(ssid: String, password: String?, result: @escaping FlutterResult) {
        NSLog("WifiNetworkPlugin: Connecting to SSID: \(ssid), hasPassword: \(password != nil)")

        // iOS 13+ requires location permission for SSID readback via NEHotspotNetwork.fetchCurrent.
        // Without this the monitor loop can never detect a successful join and will always time out.
        ensureLocationAuthorization { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                NSLog("WifiNetworkPlugin: Location permission denied — will proceed but SSID verification may fail")
                // Proceed anyway: iOS may still switch networks, we just can't verify.
            }

            // Initialize connection state
            self.connectLoop = true
            self.connectionStartTime = Date()

            self.applyConfigAndMonitor(ssid: ssid, password: password, result: result)
        }
    }

    /// Apply the WiFi configuration and start monitoring for connection
    private func applyConfigAndMonitor(ssid: String, password: String?, result: @escaping FlutterResult) {
        guard connectLoop else {
            NSLog("WifiNetworkPlugin: Connection loop cancelled")
            return
        }

        // Check if we've exceeded the timeout
        if let startTime = connectionStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= WifiNetworkPlugin.connectionTimeout {
                NSLog("WifiNetworkPlugin: Connection timeout after \(elapsed) seconds")
                connectLoop = false
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
                result(["success": false, "error": "Connection timeout. Please try again.", "errorCode": -2])
                return
            }
        }

        // Create configuration
        let configuration: NEHotspotConfiguration
        if let password = password, !password.isEmpty {
            configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        } else {
            configuration = NEHotspotConfiguration(ssid: ssid)
        }

        configuration.joinOnce = false


        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            guard let self = self, self.connectLoop else { return }

            if let error = error as NSError? {
                NSLog("WifiNetworkPlugin: Apply error: \(error.domain) code=\(error.code)")

                if error.domain == NEHotspotConfigurationErrorDomain {
                    switch error.code {
                    case NEHotspotConfigurationError.alreadyAssociated.rawValue:
                        NSLog("WifiNetworkPlugin: Already connected to \(ssid)")
                        self.connectLoop = false
                        result(["success": true])
                        return

                    case NEHotspotConfigurationError.userDenied.rawValue:
                        NSLog("WifiNetworkPlugin: User denied WiFi connection")
                        self.connectLoop = false
                        result(["success": false, "error": "User denied WiFi connection", "errorCode": 2])
                        return

                    case NEHotspotConfigurationError.invalidWPAPassphrase.rawValue:
                        self.connectLoop = false
                        result(["success": false, "error": "Invalid WiFi password (must be 8-63 characters)", "errorCode": 3])
                        return

                    case NEHotspotConfigurationError.applicationIsNotInForeground.rawValue:
                        self.connectLoop = false
                        result(["success": false, "error": "App must be in foreground to connect", "errorCode": 4])
                        return

                    default:
                        NSLog("WifiNetworkPlugin: Error \(error.code), will check connection and retry if needed")
                    }
                }
            }

            self.monitorConnection(ssid: ssid, password: password, result: result)
        }
    }

    /// Monitor connection status and re-apply config if not connected
    private func monitorConnection(ssid: String, password: String?, result: @escaping FlutterResult) {
        guard connectLoop else { return }

        // If location permission is not granted, NEHotspotNetwork.fetchCurrent
        // returns a network whose SSID is always nil — the monitor loop would
        // then retry until timeout even though the phone actually joined the AP.
        // In that case, optimistically report success after apply() returned no
        // error (the downstream TCP connect will catch real failures).
        let locationStatus: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            locationStatus = locationManager.authorizationStatus
        } else {
            locationStatus = CLLocationManager.authorizationStatus()
        }
        let canReadSSID = (locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways)
        if !canReadSSID {
            NSLog("WifiNetworkPlugin: No location permission — assuming join succeeded after apply()")
            self.connectLoop = false
            result(["success": true])
            return
        }

        NEHotspotNetwork.fetchCurrent { [weak self] network in
            guard let self = self, self.connectLoop else { return }

            let currentSSID = network?.ssid

            if currentSSID == ssid {
                NSLog("WifiNetworkPlugin: Successfully connected to \(ssid)")
                self.connectLoop = false
                result(["success": true])
                return
            }

            guard let startTime = self.connectionStartTime else {
                self.connectLoop = false
                result(["success": false, "error": "Connection state error", "errorCode": 4])
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)

            if elapsed >= WifiNetworkPlugin.connectionTimeout {
                NSLog("WifiNetworkPlugin: Connection timeout after \(elapsed) seconds")
                self.connectLoop = false
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)

                let errorMsg: String
                if let current = currentSSID {
                    errorMsg = "Phone stayed on '\(current)' instead of switching to device WiFi."
                } else {
                    errorMsg = "Failed to join device WiFi network."
                }
                result(["success": false, "error": errorMsg, "errorCode": 5])
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + WifiNetworkPlugin.retryInterval) { [weak self] in
                guard let self = self, self.connectLoop else { return }

                // Re-apply the configuration
                self.applyConfigAndMonitor(ssid: ssid, password: password, result: result)
            }
        }
    }

    /// Disconnect from a WiFi network by removing its configuration.
    private func disconnectFromWifi(ssid: String, result: @escaping FlutterResult) {
        NSLog("WifiNetworkPlugin: Disconnecting from SSID: \(ssid)")
        connectLoop = false
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        result(true)
    }

    /// Check if we're currently connected to the specified SSID.
    private func isConnectedToWifi(ssid: String, result: @escaping FlutterResult) {
        NEHotspotNetwork.fetchCurrent { network in
            let isConnected = network?.ssid == ssid
            result(isConnected)
        }
    }
}

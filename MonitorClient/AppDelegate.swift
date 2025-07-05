//
//  AppDelegate.swift
//  MonitorClient
//
//  Created by Uranus on 7/5/25.
//

import SQLite3
import Cocoa
import CoreGraphics
import IOKit
import IOKit.usb
import os.log

let CHECKER_IDENTIFIER = "com.airentech.MonitorClient"

let API_ROUTE = "/webapi.php"
let TIC_ROUTE = "/eventhandler.php"
var APP_VERSION = "1.0"

var TIME_INTERVAL = 1
let TIC_INTERVAL = 30
let HISTORY_INTERVAL = 120
let KEY_INTERVAL = 60
var timer: Timer? = nil
var macAddress: String = ""
var activeRunning: Bool = false
var safariChecked: Double? = nil
var chromeChecked: Int64? = nil
var firefoxChecked: Int64? = nil
var edgeChecked: Int64? = nil
var operaChecked: Int64? = nil
var yandexChecked: Int64? = nil
var vivaldiChecked: Int64? = nil
var braveChecked: Int64? = nil
var lastBrowserTic: Double? = nil
var lastScreenshotCheck: Date = Date()
var lastHistoryCheck: Date = Date()
var lastTicCheck: Date = Date()
var lastKeyCheck: Date = Date()

// Browser bundle identifiers
private let browserBundleIDs = [
    "com.apple.Safari",
    "com.google.Chrome",
    "org.mozilla.firefox",
    "com.microsoft.edgemac",
    "com.operasoftware.Opera",
    "ru.yandex.desktop.yandex-browser",
    "com.vivaldi.Vivaldi",
    "com.brave.Browser"
]

struct BrowserHistoryLog: Codable {
    let browser: String
    let url: String
    let title: String
    let last_visit: Int64
    let date: String
}

struct KeyLog: Codable {
    let date: String
    let application: String
    let key: String
}

struct USBDeviceLog: Codable {
    let date: String
    let device_name: String
    let device_path: String
    let device_type: String
    let action: String
}

// Global callback function for CGEvent tap
func handleKeyDownCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Only handle keyDown events
    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }
    
    // Get the AppDelegate instance from the refcon
    guard let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue() as? AppDelegate else {
        return Unmanaged.passUnretained(event)
    }
    
    // Update last key capture time
    appDelegate.lastKeyCaptureTime = Date()
    
    // Safely create NSEvent from CGEvent
    guard let nsEvent = NSEvent(cgEvent: event) else {
        return Unmanaged.passUnretained(event)
    }
    
    // Get the active application
    let activeApp = NSWorkspace.shared.frontmostApplication
    let appName = activeApp?.localizedName ?? "Unknown"
    let bundleId = activeApp?.bundleIdentifier ?? "Unknown"
    
    // Get key information
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let modifiers = appDelegate.checkModifierKeys(event)
    let pressedChar = nsEvent.charactersIgnoringModifiers ?? ""
    let currentDate = appDelegate.getCurrentDateTimeString()
    
    // Get readable key name for special keys
    let keyName = appDelegate.getKeyName(keyCode: Int(keyCode), character: pressedChar)
    
    let keyInfo = "\(appName) (\(bundleId)) \(modifiers)\(keyName)"
    appDelegate.logMessage("Key captured: \(keyInfo)", level: .debug)
    appDelegate.keyLogs.append(KeyLog(date: currentDate, application: "\(appName) (\(bundleId))", key: "\(modifiers)\(keyName)"))
    
    // Log key log count for debugging
    if appDelegate.keyLogs.count % 10 == 0 {
        appDelegate.logMessage("Key log count: \(appDelegate.keyLogs.count)", level: .debug)
    }
    
    return Unmanaged.passUnretained(event)
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSUserNotificationCenterDelegate {
    
    var storage: UserDefaults!
    var eventTap: CFMachPort?
    var keyLogs: [KeyLog]!
    var usbDeviceLogs: [USBDeviceLog]!
    var usbNotificationPort: IONotificationPortRef?
    var usbAddedIterator: io_iterator_t = 0
    var usbRemovedIterator: io_iterator_t = 0

    // Add these properties at the top of the class
    private var lastEventTapCheck: Date = Date()
    private var eventTapCheckInterval: TimeInterval = 3.0 // Check every 3 seconds
    private var isReestablishingEventTap: Bool = false
    var lastKeyCaptureTime: Date = Date()
    private let maxKeyCaptureGap: TimeInterval = 10.0 // Alert if no keys for 10 seconds

    // Logging system
    let logFile = "MonitorClient.log"
    var logFileHandle: FileHandle?

    // MARK: - Logging Functions
    
    private func setupLogging() {
        // Try multiple locations for log file
        let possibleLogPaths = [
            FileManager.default.currentDirectoryPath,
            NSTemporaryDirectory(),
            NSHomeDirectory() + "/Desktop",
            "/tmp"
        ]
        
        var logURL: URL?
        var logFileCreated = false
        
        // Try to create log file in different locations
        for path in possibleLogPaths {
            let testURL = URL(fileURLWithPath: path).appendingPathComponent(logFile)
            
            do {
                // Create log file if it doesn't exist
                if !FileManager.default.fileExists(atPath: testURL.path) {
                    try "".write(to: testURL, atomically: true, encoding: .utf8)
                }
                
                // Test if we can write to the file
                try "test".write(to: testURL, atomically: true, encoding: .utf8)
                
                logURL = testURL
                logFileCreated = true
                break
            } catch {
                print("Failed to create log file at \(testURL.path): \(error)")
                continue
            }
        }
        
        // If we couldn't create a log file, use console only
        if !logFileCreated {
            print("⚠️  Could not create log file. Using console logging only.")
            logFileHandle = nil
        } else {
            // Open file handle for writing
            do {
                logFileHandle = try FileHandle(forWritingTo: logURL!)
                logFileHandle?.seekToEndOfFile()
                print("✅ Log file created at: \(logURL!.path)")
            } catch {
                print("⚠️  Could not open log file handle: \(error). Using console logging only.")
                logFileHandle = nil
            }
        }
        
        // Always log startup information
        let startupInfo = """
        === MonitorClient Started ===
        Version: \(APP_VERSION)
        Mac Address: \(macAddress)
        Server IP: \(storage.string(forKey: "server-ip") ?? "unknown")
        Log file location: \(logURL?.path ?? "console only")
        Current directory: \(FileManager.default.currentDirectoryPath)
        Home directory: \(NSHomeDirectory())
        """
        
        print(startupInfo)
        
        // Write to log file if available
        if let data = startupInfo.data(using: .utf8) {
            logFileHandle?.write(data)
            logFileHandle?.synchronizeFile()
        }
        
        // System log
        let osLog = OSLog(subsystem: "com.alice.MonitorClient", category: "monitoring")
        os_log("MonitorClient started - Version: %{public}@, Server: %{public}@", log: osLog, type: .info, APP_VERSION, storage.string(forKey: "server-ip") ?? "unknown")
    }
    
    func logMessage(_ message: String, level: LogLevel = .info) {
        let timestamp = getCurrentDateTimeString()
        let logEntry = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
        
        // Console output - always print for debugging
        print(logEntry.trimmingCharacters(in: .whitespacesAndNewlines))
        
        // File logging
        if let data = logEntry.data(using: .utf8) {
            logFileHandle?.write(data)
            logFileHandle?.synchronizeFile()
        }
        
        // System log
        let osLog = OSLog(subsystem: "com.alice.MonitorClient", category: "monitoring")
        os_log("%{public}@", log: osLog, type: level.osLogType, message)
    }
    
    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        
        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
    }
    
    private func logMonitoringEvent(_ event: String, details: String? = nil) {
        let message = details != nil ? "\(event): \(details!)" : event
        logMessage(message, level: .info)
    }
    
    private func logError(_ error: String, context: String? = nil) {
        let message = context != nil ? "[\(context!)] \(error)" : error
        logMessage(message, level: .error)
    }
    
    private func logSuccess(_ action: String, details: String? = nil) {
        let message = details != nil ? "✅ \(action): \(details!)" : "✅ \(action)"
        logMessage(message, level: .info)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
        
        // Since this is a background app (LSUIElement), ensure it doesn't quit when all windows are closed
        NSApp.setActivationPolicy(.accessory)
        
        storage = UserDefaults.init(suiteName: "alice.monitors")

        // Configure server IP if not already set
        if storage.string(forKey: "server-ip") == nil {
            storage.set("192.168.1.45:8924", forKey: "server-ip")
            logMessage("Server IP configured: 192.168.1.45:8924", level: .info)
        } else {
            logMessage("Server IP already configured: \(storage.string(forKey: "server-ip") ?? "unknown")", level: .info)
        }
        
        // Reset accessibility prompt flag on startup
        storage.removeObject(forKey: "accessibility-prompt-shown")

        APP_VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"

        keyLogs = []
        
        // Get MacAddress
        let address = getMacAddress()
        if !address.isEmpty {
            macAddress = address
            logMessage("Mac Address obtained: \(address)", level: .info)
        } else {
            logMessage("Warning: Could not get MacAddress", level: .warning)
            macAddress = ""
        }

        // Setup logging after basic initialization
        setupLogging()

        // Check if MonitorChecker is running and start it if not
        logMonitoringEvent("Checking MonitorChecker")
        checkMonitorChecker()
        
        // Start keyboard monitoring
        logMonitoringEvent("Starting keyboard monitoring")
        
        // Check if app has proper entitlements
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            logMessage("App bundle identifier: \(bundleIdentifier)", level: .debug)
        }
        
        startKeyboardMonitoring();
        
        // Setup event tap invalidation monitoring
        logMonitoringEvent("Setting up event tap monitoring")
        setupEventTapInvalidationMonitoring()
        
        // Single timer for all tasks
        timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(checkAllTasks), userInfo: nil, repeats: true)
        logSuccess("Main monitoring timer started")
        
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sessionDidBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionDidResignActive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        activeRunning = true
        
        // Add observer for application termination
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        
        usbDeviceLogs = []
        logMonitoringEvent("Setting up USB monitoring")
        setupUSBMonitoring()
        
        // Test server connectivity on startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.testServerConnectivity()
        }
        
        // Debug accessibility status on startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.debugAccessibilityStatus()
        }
        
        // Check app entitlements on startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.checkAppEntitlements()
        }
        
        // Set up notification delegate
        NSUserNotificationCenter.default.delegate = self
        
        logSuccess("MonitorClient initialization complete")
    }
    
    @objc func sessionDidBecomeActive(notification: Notification) {
        logMessage("User switched back to this session", level: .info)
        activeRunning = true
    }

    @objc func sessionDidResignActive(notification: Notification) {
        logMessage("User switched away from this session", level: .info)
        activeRunning = false
    }

    @objc func checkAllTasks() {
        let currentDate = Date()
        
        // Check accessibility permission periodically
        checkAccessibilityPermissionPeriodically()
        
        // Add event tap validation check to main timer loop
        checkAndReestablishEventTapThrottled()
                
        // Check if it's time for screenshots
        if currentDate.timeIntervalSince(lastScreenshotCheck) >= TimeInterval(TIME_INTERVAL) {
            logMonitoringEvent("Screenshot monitoring triggered", details: "Interval: \(TIME_INTERVAL)s")
            let randomDelay = Double.random(in: 0...Double(TIME_INTERVAL))
            perform(#selector(TakeScreenShotsAndPost), with: nil, afterDelay: randomDelay)
            lastScreenshotCheck = currentDate
        }
        
        // Check if it's time for tic event
        if currentDate.timeIntervalSince(lastTicCheck) >= TimeInterval(TIC_INTERVAL) {
            logMonitoringEvent("Tic event monitoring triggered", details: "Interval: \(TIC_INTERVAL)s")
            DispatchQueue.global(qos: .background).async {
                do {
                    try self.sendTicEvent()
                } catch {
                    self.logError("Error sending tic event: \(error)", context: "TicEvent")
                }
            }
            lastTicCheck = currentDate
        }

        // Check if it's time for browser history
        if currentDate.timeIntervalSince(lastHistoryCheck) >= TimeInterval(HISTORY_INTERVAL) {
                logMonitoringEvent("Browser history monitoring triggered", details: "Interval: \(HISTORY_INTERVAL)s")
                DispatchQueue.global(qos: .background).async {
                    do {
                        try self.sendBrowserHistories()
                    } catch {
                        self.logError("Error sending browser histories: \(error)", context: "BrowserHistory")
                    }
                }
                lastHistoryCheck = currentDate
        }

        // Check if it's time for key log
        if currentDate.timeIntervalSince(lastKeyCheck) >= TimeInterval(KEY_INTERVAL) {
            logMonitoringEvent("Key log monitoring triggered", details: "Interval: \(KEY_INTERVAL)s, Keys collected: \(keyLogs.count)")
            DispatchQueue.global(qos: .background).async {
                self.sendKeyLogs()
            }
            logMonitoringEvent("USB log monitoring triggered", details: "USB events collected: \(usbDeviceLogs.count)")
            DispatchQueue.global(qos: .background).async {
                do {
                    try self.sendUSBLogs()
                } catch {
                    self.logError("Error sending usb logs: \(error)", context: "USBLog")
                }
            }
            lastKeyCheck = currentDate
        }
    }

    /// Throttled event tap validation to prevent app from getting stuck
    private func checkAndReestablishEventTapThrottled() {
        let currentDate = Date()
        
        // Check 1: Regular interval check (every 3 seconds)
        let shouldCheckInterval = currentDate.timeIntervalSince(lastEventTapCheck) >= eventTapCheckInterval
        
        // Check 2: Key capture gap detection (if no keys for 10 seconds)
        let keyCaptureGap = currentDate.timeIntervalSince(lastKeyCaptureTime)
        let shouldCheckKeyGap = keyCaptureGap >= maxKeyCaptureGap
        
        // Only proceed if one of the conditions is met
        guard shouldCheckInterval || shouldCheckKeyGap else {
            return
        }
        
        // Prevent multiple simultaneous re-establishment attempts
        guard !isReestablishingEventTap else {
            return
        }
        
        // Additional check: only re-establish if we have accessibility permission
        guard isInputMonitoringEnabled() else {
            // Don't log this message repeatedly to avoid spam
            let lastSkipLog = storage.double(forKey: "last-skip-log-time")
            let currentTime = Date().timeIntervalSince1970
            if currentTime - lastSkipLog > 30 { // Only log every 30 seconds
                logMessage("Skipping event tap check - no accessibility permission", level: .debug)
                storage.set(currentTime, forKey: "last-skip-log-time")
            }
            return
        }
        
        lastEventTapCheck = currentDate
        
        // Log the reason for checking (but less frequently)
        if shouldCheckKeyGap && keyCaptureGap.truncatingRemainder(dividingBy: 30) < 1 {
            logMessage("No key capture detected for \(Int(keyCaptureGap))s, checking event tap...", level: .debug)
        }
        
        // Perform the check asynchronously to avoid blocking the main thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performEventTapValidation()
        }
    }
    
    /// Perform actual event tap validation (called on background queue)
    private func performEventTapValidation() {
        // Quick check first - if event tap is nil, we need to re-establish
        guard let tap = eventTap else {
            logMessage("Event tap is nil, re-establishing...", level: .info)
            reestablishEventTapAsync()
            return
        }
        
        // Check if tap is enabled (this is a lightweight operation)
        let isEnabled = CGEvent.tapIsEnabled(tap: tap)
        if !isEnabled {
            logMessage("Event tap became disabled, re-establishing...", level: .info)
            reestablishEventTapAsync()
            return
        }
        
        // Additional validation: check if mach port is still valid
        let portValid = CFMachPortIsValid(tap)
        if !portValid {
            logMessage("Event tap mach port is invalid, re-establishing...", level: .info)
            reestablishEventTapAsync()
            return
        }
        
        // Event tap is valid and working
        // logMessage("Event tap validation passed", level: .debug)
    }
    
    /// Re-establish event tap asynchronously with timeout
    private func reestablishEventTapAsync() {
        isReestablishingEventTap = true
        
        // Set a timeout to prevent infinite hanging
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.isReestablishingEventTap = false
            self?.logMessage("Event tap re-establishment timed out", level: .warning)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeoutWorkItem)
        
        // Perform re-establishment on main queue (required for UI operations)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            defer {
                self.isReestablishingEventTap = false
                timeoutWorkItem.cancel()
            }
            
            // Check permission before attempting to re-establish
            guard self.isInputMonitoringEnabled() else {
                self.logMessage("Cannot re-establish event tap - no accessibility permission", level: .warning)
                return
            }
            
            do {
                self.setupKeyboardMonitoring()
                self.logMessage("Event tap re-establishment completed successfully", level: .info)
            } catch {
                self.logMessage("Event tap re-establishment failed: \(error)", level: .error)
            }
        }
    }

    func buildEndpoint(_ mode: Bool) -> String? {
        if let ip = storage.string(forKey: "server-ip"), !ip.isEmpty {
            let endpoint = "http://" + ip + (mode ? API_ROUTE : TIC_ROUTE)
            logMessage("Built endpoint: \(endpoint)", level: .debug)
            return endpoint
        } else {
            logError("Server IP not configured", context: "Endpoint")
            return nil
        }
    }
    
    private func createTemporaryCopy(_ path: String, browser: String) throws -> String {
        let originalFileName = (path as NSString).lastPathComponent
        let randomString = generateRandomString(length: 8)
        let fileName = "\(browser)_\(randomString)_\(originalFileName)"
        let temporaryPath = NSTemporaryDirectory() + fileName
        
        // Check if source file exists and is accessible
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "FileError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Source file does not exist: \(path)"])
        }
        
        // Check if file is readable
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw NSError(domain: "FileError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Source file is not readable: \(path)"])
        }
        
        // Try to get file attributes to check if it's being modified
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let modificationDate = attributes[.modificationDate] as? Date {
                let timeSinceModification = Date().timeIntervalSince(modificationDate)
                // If file was modified in the last 5 seconds, it might be actively being written to
                if timeSinceModification < 5.0 {
                    debugPrint("Warning: File \(path) was recently modified (\(timeSinceModification)s ago), may be actively in use")
                }
            }
        } catch {
            debugPrint("Warning: Could not get file attributes for \(path): \(error)")
        }
        
        // Copy the database with retry mechanism
        var lastError: Error?
        let maxRetries = 3
        let retryDelay: TimeInterval = 1.0
        
        for attempt in 1...maxRetries {
            do {
                try FileManager.default.copyItem(atPath: path, toPath: temporaryPath)
                // Success - break out of retry loop
                break
            } catch {
                lastError = error
                debugPrint("Attempt \(attempt)/\(maxRetries) failed to copy \(path): \(error.localizedDescription)")
                
                if attempt < maxRetries {
                    debugPrint("Waiting \(retryDelay)s before retry...")
                    Thread.sleep(forTimeInterval: retryDelay)
                }
            }
        }
        
        // If all retries failed, throw the last error
        if let error = lastError {
            throw NSError(domain: "FileError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to copy file after \(maxRetries) attempts: \(error.localizedDescription)"])
        }
        
        return temporaryPath
    }

    private func processChromeBasedProfiles(profilesPath: String, browser: String, checkedVariable: inout Int64?, lastBrowserTic: Double) throws -> [BrowserHistoryLog] {
        let fileMan = FileManager()
        let username = NSUserName()
        var visitDate = ""
        var histURL = ""
        var browseHist: [BrowserHistoryLog] = []
        var highestTimestamp: Int64? = checkedVariable
        
        if fileMan.fileExists(atPath: profilesPath) {
            let fileEnum = fileMan.enumerator(atPath: profilesPath)
            
            while let each = fileEnum?.nextObject() as? String {
                // Check if this is a profile directory (Default, Profile 1, Profile 2, etc.)
                if each != "System Profile" && each != "Guest Profile" && !each.hasPrefix(".") {
                    let historyPath = "\(profilesPath)\(each)/History"
                    if fileMan.fileExists(atPath: historyPath) {
                        let temporaryPath:String = try createTemporaryCopy(historyPath, browser: browser)
                        
                        var db : OpaquePointer?
                        let dbURL = URL(fileURLWithPath: temporaryPath)
                        
                        // Check if file is a valid SQLite database
                        let openResult = sqlite3_open(dbURL.path, &db)
                        if openResult != SQLITE_OK {
                            let errorMessage = String(cString: sqlite3_errmsg(db))
                            debugPrint("[-] Could not open the \(browser) History file \(historyPath) for user \(username) - SQLite error: \(errorMessage)")
                            sqlite3_close(db)
                            try? FileManager.default.removeItem(atPath: temporaryPath)
                            continue
                        }
                        
                        // Verify database is not corrupted with better error handling
                        var isCorrupted = false
                        var errorMessage: UnsafeMutablePointer<Int8>?
                        let integrityResult = sqlite3_exec(db, "PRAGMA integrity_check;", nil, nil, &errorMessage)
                        
                        if integrityResult != SQLITE_OK {
                            isCorrupted = true
                            if let errorMsg = errorMessage {
                                debugPrint("[-] \(browser) History \(historyPath) integrity check failed: \(String(cString: errorMsg))")
                                sqlite3_free(errorMessage)
                            }
                        }
                        
                        if isCorrupted {
                            debugPrint("[-] \(browser) History \(historyPath) is corrupted")
                            sqlite3_close(db)
                            try? FileManager.default.removeItem(atPath: temporaryPath)
                            continue
                        }
                        
                        // Additional safety check - try to read database header
                        var headerCheck: OpaquePointer?
                        let headerResult = sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' LIMIT 1;", -1, &headerCheck, nil)
                        if headerResult != SQLITE_OK {
                            debugPrint("[-] \(browser) History \(historyPath) appears to be locked or corrupted - cannot read table structure")
                            sqlite3_finalize(headerCheck)
                            sqlite3_close(db)
                            try? FileManager.default.removeItem(atPath: temporaryPath)
                            continue
                        }
                        sqlite3_finalize(headerCheck)
                        
                        // Initialize timestamp if needed
                        if highestTimestamp == nil {
                            let currentDate = Date(timeIntervalSince1970: lastBrowserTic ?? Date().timeIntervalSince1970 - 86400) // Default to 24 hours ago
                            highestTimestamp = (Int64(currentDate.timeIntervalSince1970) + 11644473600) * 1000000
                        }
                        
                        let queryString = "select datetime(visit_time/1000000-11644473600, 'unixepoch', '+10:00') as last_visit_time, urls.url, visit_time from urls, visits where visits.url = urls.id and visit_time > \(highestTimestamp ?? 0) order by visit_time;"
                        
                        var queryStatement: OpaquePointer? = nil
                        
                        if sqlite3_prepare_v2(db, queryString, -1, &queryStatement, nil) == SQLITE_OK {
                            while sqlite3_step(queryStatement) == SQLITE_ROW {
                                let col1 = sqlite3_column_text(queryStatement, 0)
                                if col1 != nil {
                                    visitDate = String(cString: col1!)
                                }
                                
                                let col2 = sqlite3_column_text(queryStatement, 1)
                                if col2 != nil {
                                    histURL = String(cString: col2!)
                                }
                                
                                let visitTime = sqlite3_column_int64(queryStatement, 2)
                                if (highestTimestamp! < visitTime) {
                                    highestTimestamp = visitTime
                                }
                                
                                browseHist.append(BrowserHistoryLog(
                                    browser: browser,
                                    url: histURL,
                                    title: histURL, // Use URL as title for now
                                    last_visit: visitTime,
                                    date: getCurrentDateTimeString()
                                ))
                            }
                            
                            sqlite3_finalize(queryStatement)
                        } else {
                            let errorMsg = String(cString: sqlite3_errmsg(db))
                            debugPrint("[-] Failed to prepare \(browser) history query: \(errorMsg)")
                        }
                        
                        sqlite3_close(db)

                        try? FileManager.default.removeItem(atPath: temporaryPath)
                    }
                }
            }
        } else {
            debugPrint("[-] \(browser) profiles directory not found for user \(username)\r")
        }
        
        // Update the original checkedVariable with the highest timestamp found across all profiles
        checkedVariable = highestTimestamp
        
        return browseHist
    }

    func getSafariHistories() throws -> [BrowserHistoryLog]? {
        let fileMan = FileManager()
        
        var isDir = ObjCBool(true)
        let username = NSUserName()
        var visitDate = ""
        var histURL = ""
        var browseHist: [BrowserHistoryLog] = []
        
        // Safari history check
        if fileMan.fileExists(atPath: "/Users/\(username)/Library/Safari/History.db", isDirectory: &isDir) {
            let temporaryPath:String = try createTemporaryCopy("/Users/\(username)/Library/Safari/History.db", browser: "Safari")
            
            var db : OpaquePointer?
            let dbURL = URL(fileURLWithPath: temporaryPath)
            
            // Check if file is a valid SQLite database with better error handling
            let openResult = sqlite3_open(dbURL.path, &db)
            if openResult != SQLITE_OK {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                debugPrint("[-] Could not open the Safari History.db file for user \(username) - SQLite error: \(errorMessage)")
                sqlite3_close(db)
                try? FileManager.default.removeItem(atPath: temporaryPath)
                return []
            }
            
            // Verify database is not corrupted with better error handling
            var isCorrupted = false
            var errorMessage: UnsafeMutablePointer<Int8>?
            let integrityResult = sqlite3_exec(db, "PRAGMA integrity_check;", nil, nil, &errorMessage)
            
            if integrityResult != SQLITE_OK {
                isCorrupted = true
                if let errorMsg = errorMessage {
                    debugPrint("[-] Safari History.db integrity check failed: \(String(cString: errorMsg))")
                    sqlite3_free(errorMessage)
                }
            }
            
            if isCorrupted {
                debugPrint("[-] Safari History.db is corrupted")
                sqlite3_close(db)
                try? FileManager.default.removeItem(atPath: temporaryPath)
                return []
            }
            
            // Additional safety check - try to read database header
            var headerCheck: OpaquePointer?
            let headerResult = sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' LIMIT 1;", -1, &headerCheck, nil)
            if headerResult != SQLITE_OK {
                debugPrint("[-] Safari History.db appears to be locked or corrupted - cannot read table structure")
                sqlite3_finalize(headerCheck)
                sqlite3_close(db)
                try? FileManager.default.removeItem(atPath: temporaryPath)
                return []
            }
            sqlite3_finalize(headerCheck)
            
            if safariChecked == nil{
                let currentDate = Date(timeIntervalSince1970: lastBrowserTic ?? Date().timeIntervalSince1970 - 86400) // Default to 24 hours ago
                safariChecked = currentDate.timeIntervalSince1970 - 978307200
            }
            // Convert timestamp to VLAT timestring
            let queryString = "select datetime(history_visits.visit_time + 978307200, 'unixepoch', '+10:00') as last_visited, history_items.url, history_visits.visit_time from history_visits, history_items where history_visits.history_item=history_items.id and history_visits.visit_time > \(safariChecked ?? 0) order by history_visits.visit_time;"
            var queryStatement: OpaquePointer? = nil

            if sqlite3_prepare_v2(db, queryString, -1, &queryStatement, nil) == SQLITE_OK{
                while sqlite3_step(queryStatement) == SQLITE_ROW{
                    let col1 = sqlite3_column_text(queryStatement, 0)
                    if col1 != nil{
                        visitDate = String(cString: col1!)
                    }
                    let col2 = sqlite3_column_text(queryStatement, 1)
                    if col2 != nil{
                        histURL = String(cString: col2!)
                    }

                    let visitTime = sqlite3_column_double(queryStatement, 2)
                    if (safariChecked! < visitTime) {
                        safariChecked = visitTime
                    }

                    browseHist.append(BrowserHistoryLog(
                        browser: "Safari",
                        url: histURL,
                        title: histURL, // Use URL as title for now
                        last_visit: Int64(visitTime),
                        date: getCurrentDateTimeString()
                    ))
                }
                sqlite3_finalize(queryStatement)
            } else {
                let errorMsg = String(cString: sqlite3_errmsg(db))
                debugPrint("[-] Failed to prepare Safari history query: \(errorMsg)")
            }
            
            sqlite3_close(db)

            try? FileManager.default.removeItem(atPath: temporaryPath)
        }
        else {
            debugPrint("[-] Safari History.db database not found for user \(username)\r")
        }

        return browseHist
    }

    func getChromeHistories() throws -> [BrowserHistoryLog]? {
        let username = NSUserName()
        let chromeProfilesPath = "/Users/\(username)/Library/Application Support/Google/Chrome/"
        return try processChromeBasedProfiles(profilesPath: chromeProfilesPath, browser: "Chrome", checkedVariable: &chromeChecked, lastBrowserTic: lastBrowserTic ?? Date().timeIntervalSince1970 - 86400)
    }

    func getFirefoxHistories() throws -> [BrowserHistoryLog]? {
        let fileMan = FileManager()
        
        let username = NSUserName()
        var visitDate = ""
        var histURL = ""
        var browseHist: [BrowserHistoryLog] = []
        
        // Firefox history check
        if fileMan.fileExists(atPath: "/Users/\(username)/Library/Application Support/Firefox/Profiles/"){
            let fileEnum = fileMan.enumerator(atPath: "/Users/\(username)/Library/Application Support/Firefox/Profiles/")

            while let each = fileEnum?.nextObject() as? String {
                if each.hasSuffix("places.sqlite") {
                    let placesDBPath = "/Users/\(username)/Library/Application Support/Firefox/Profiles/\(each)"
                    let temporaryPath:String = try createTemporaryCopy(placesDBPath, browser: "Firefox")
                    var db : OpaquePointer?
                    let dbURL = URL(fileURLWithPath: temporaryPath)

                    // Check if file is a valid SQLite database
                    let openResult = sqlite3_open(dbURL.path, &db)
                    if openResult != SQLITE_OK {
                        let errorMessage = String(cString: sqlite3_errmsg(db))
                        debugPrint("[-] Could not open the Firefox \(temporaryPath) file for user \(username) - SQLite error: \(errorMessage)")
                        sqlite3_close(db)
                        try? FileManager.default.removeItem(atPath: temporaryPath)
                        continue
                    }
                    
                    // Verify database is not corrupted with better error handling
                    var isCorrupted = false
                    var errorMessage: UnsafeMutablePointer<Int8>?
                    let integrityResult = sqlite3_exec(db, "PRAGMA integrity_check;", nil, nil, &errorMessage)
                    
                    if integrityResult != SQLITE_OK {
                        isCorrupted = true
                        if let errorMsg = errorMessage {
                            debugPrint("[-] Firefox \(temporaryPath) integrity check failed: \(String(cString: errorMsg))")
                            sqlite3_free(errorMessage)
                        }
                    }
                    
                    if isCorrupted {
                        debugPrint("[-] Firefox \(temporaryPath) is corrupted")
                        sqlite3_close(db)
                        try? FileManager.default.removeItem(atPath: temporaryPath)
                        continue
                    }
                    
                    // Additional safety check - try to read database header
                    var headerCheck: OpaquePointer?
                    let headerResult = sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' LIMIT 1;", -1, &headerCheck, nil)
                    if headerResult != SQLITE_OK {
                        debugPrint("[-] Firefox \(temporaryPath) appears to be locked or corrupted - cannot read table structure")
                        sqlite3_finalize(headerCheck)
                        sqlite3_close(db)
                        try? FileManager.default.removeItem(atPath: temporaryPath)
                        continue
                    }
                    sqlite3_finalize(headerCheck)
                    
                    if firefoxChecked == nil{
                        let currentDate = Date(timeIntervalSince1970: lastBrowserTic ?? Date().timeIntervalSince1970 - 86400) // Default to 24 hours ago
                        firefoxChecked = Int64(currentDate.timeIntervalSince1970 * 1000000)
                    }

                    let queryString = "select datetime(visit_date/1000000, 'unixepoch', '+10:00') as time, url, visit_date FROM moz_places, moz_historyvisits where moz_places.id=moz_historyvisits.place_id and visit_date > \(firefoxChecked ?? 0) order by visit_date;"

                    var queryStatement: OpaquePointer? = nil

                    if sqlite3_prepare_v2(db, queryString, -1, &queryStatement, nil) == SQLITE_OK{
                        while sqlite3_step(queryStatement) == SQLITE_ROW{
                            let col1 = sqlite3_column_text(queryStatement, 0)
                            if col1 != nil{
                                visitDate = String(cString: col1!)
                            }

                            let col2 = sqlite3_column_text(queryStatement, 1)
                            if col2 != nil{
                                histURL = String(cString: col2!)
                            }

                            let visitTime = sqlite3_column_int64(queryStatement, 2)
                            if (firefoxChecked! < visitTime) {
                                firefoxChecked = visitTime
                            }

                            browseHist.append(BrowserHistoryLog(
                                browser: "Firefox",
                                url: histURL,
                                title: histURL, // Use URL as title for now
                                last_visit: visitTime,
                                date: getCurrentDateTimeString()
                            ))
                        }

                        sqlite3_finalize(queryStatement)
                    }
                    
                    sqlite3_close(db)

                    try? FileManager.default.removeItem(atPath: temporaryPath)
                }
            }
        }
        else {
            debugPrint("[-] Firefox places.sqlite database not found for user \(username)\r")
        }

        return browseHist
    }
    
    func getEdgeHistories() throws -> [BrowserHistoryLog]? {
        let username = NSUserName()
        let edgeProfilesPath = "/Users/\(username)/Library/Application Support/Microsoft Edge/"
        return try processChromeBasedProfiles(profilesPath: edgeProfilesPath, browser: "Edge", checkedVariable: &edgeChecked, lastBrowserTic: lastBrowserTic ?? Date().timeIntervalSince1970 - 86400)
    }
    
    func getOperaHistories() throws -> [BrowserHistoryLog]? {
        let username = NSUserName()
        let operaProfilesPath = "/Users/\(username)/Library/Application Support/com.operasoftware.Opera/"
        return try processChromeBasedProfiles(profilesPath: operaProfilesPath, browser: "Opera", checkedVariable: &operaChecked, lastBrowserTic: lastBrowserTic ?? Date().timeIntervalSince1970 - 86400)
    }
    
    func getYandexHistories() throws -> [BrowserHistoryLog]? {
        let username = NSUserName()
        let yandexProfilesPath = "/Users/\(username)/Library/Application Support/Yandex/YandexBrowser/"
        return try processChromeBasedProfiles(profilesPath: yandexProfilesPath, browser: "Yandex", checkedVariable: &yandexChecked, lastBrowserTic: lastBrowserTic ?? Date().timeIntervalSince1970 - 86400)
    }
    
    func getVivaldiHistories() throws -> [BrowserHistoryLog]? {
        let username = NSUserName()
        let vivaldiProfilesPath = "/Users/\(username)/Library/Application Support/Vivaldi/"
        return try processChromeBasedProfiles(profilesPath: vivaldiProfilesPath, browser: "Vivaldi", checkedVariable: &vivaldiChecked, lastBrowserTic: lastBrowserTic ?? Date().timeIntervalSince1970 - 86400)
    }
    
    func getBraveHistories() throws -> [BrowserHistoryLog]? {
        let username = NSUserName()
        let braveProfilesPath = "/Users/\(username)/Library/Application Support/BraveSoftware/Brave-Browser/"
        return try processChromeBasedProfiles(profilesPath: braveProfilesPath, browser: "Brave", checkedVariable: &braveChecked, lastBrowserTic: lastBrowserTic ?? Date().timeIntervalSince1970 - 86400)
    }
    
    func getBrowserHistories() throws -> [BrowserHistoryLog]? {
        var browseHist: [BrowserHistoryLog] = []
        
        // Get Safari histories
        do {
            if let safariHistories = try getSafariHistories() {
                browseHist.append(contentsOf: safariHistories)
            }
        } catch {
            debugPrint("Error getting Safari histories: \(error)")
        }

        // Get Chrome histories
        do {
            if let chromeHistories = try getChromeHistories() {
                browseHist.append(contentsOf: chromeHistories)
            }
        } catch {
            debugPrint("Error getting Chrome histories: \(error)")
        }

        // Get Firefox histories
        do {
            if let firefoxHistories = try getFirefoxHistories() {
                browseHist.append(contentsOf: firefoxHistories)
            }
        } catch {
            debugPrint("Error getting Firefox histories: \(error)")
        }

        // Get Edge histories
        do {
            if let edgeHistories = try getEdgeHistories() {
                browseHist.append(contentsOf: edgeHistories)
            }
        } catch {
            debugPrint("Error getting Edge histories: \(error)")
        }

        // Get Opera histories
        do {
            if let operaHistories = try getOperaHistories() {
                browseHist.append(contentsOf: operaHistories)
            }
        } catch {
            debugPrint("Error getting Opera histories: \(error)")
        }

        // Get Yandex histories
        do {
            if let yandexHistories = try getYandexHistories() {
                browseHist.append(contentsOf: yandexHistories)
            }
        } catch {
            debugPrint("Error getting Yandex histories: \(error)")
        }

        // Get Vivaldi histories
        do {
            if let vivaldiHistories = try getVivaldiHistories() {
                browseHist.append(contentsOf: vivaldiHistories)
            }
        } catch {
            debugPrint("Error getting Vivaldi histories: \(error)")
        }

        // Get Brave histories
        do {
            if let braveHistories = try getBraveHistories() {
                browseHist.append(contentsOf: braveHistories)
            }
        } catch {
            debugPrint("Error getting Brave histories: \(error)")
        }

        return browseHist
    }
    
    @objc func sendBrowserHistories() {
        var browserHistories: [BrowserHistoryLog] = []
        do {
            browserHistories = try getBrowserHistories() ?? []
        } catch {
            debugPrint("Error reading history: \(error)")
        }
        
        if (browserHistories.count > 0) {
            // Send data in chunks
            sendDataInChunks(data: browserHistories, eventType: "BrowserHistory", chunkSize: 1000)
        }
    }

    @objc func checkMonitorChecker() {
        let checkers = NSWorkspace.shared.runningApplications.filter({ app in
            app.bundleIdentifier != nil && app.bundleIdentifier! == CHECKER_IDENTIFIER
        })
        if checkers.count > 1 {
            checkers.last?.terminate()
        } else if checkers.isEmpty {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/Applications/MonitorChecker.app/Contents/MacOS/MonitorChecker")
            do {
                try task.run()
                debugPrint("Run process")
            } catch {
                debugPrint("Error: \(error)")
            }
        }
    }

    @objc func sendTicEvent() {
        logMonitoringEvent("Sending tic event to server")
        checkMonitorChecker()
        
        guard let urlString = buildEndpoint(false), let url = URL(string: urlString) else {
            logError("Failed to build endpoint for tic event", context: "TicEvent")
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("aliceServerIPUndefined"), object: CHECKER_IDENTIFIER, userInfo: nil, options: .deliverImmediately)
            return
        }
        
        if activeRunning == true {
            // Prepare request data
            let postData: [String: Any] = [
                "Event": "Tic",
                "Version": APP_VERSION,
                "MacAddress": macAddress
            ]
            
            logMessage("Tic event data: \(postData)", level: .debug)
            
            // Convert to JSON
            guard let jsonData = try? JSONSerialization.data(withJSONObject: postData) else {
                logError("Failed to serialize JSON data for tic event", context: "TicEvent")
                return
            }
            
            // Create request
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("MonitorClient/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30.0
            request.httpBody = jsonData
            
            logMessage("Sending tic event to: \(urlString)", level: .debug)
            logMessage("Request headers: \(request.allHTTPHeaderFields ?? [:])", level: .debug)
            logMessage("Request body size: \(jsonData.count) bytes", level: .debug)
            
            // Send request
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.logError("Tic event network error: \(error)", context: "TicEvent")
                        self?.logError("Error details: \(error.localizedDescription)", context: "TicEvent")
                        return
                    }
                    
                    if let httpResponse = response as? HTTPURLResponse {
                        self?.logMessage("Tic event HTTP response: \(httpResponse.statusCode)", level: .debug)
                        self?.logMessage("Response headers: \(httpResponse.allHeaderFields)", level: .debug)
                        
                        if httpResponse.statusCode != 200 {
                            self?.logError("Tic event HTTP error: \(httpResponse.statusCode)", context: "TicEvent")
                        }
                    }
                    
                    if let data = data, let responseString = String(data: data, encoding: .utf8) {
                        self?.logSuccess("Tic event sent successfully", details: "Response: \(responseString)")
                        self?.logMessage("Response data size: \(data.count) bytes", level: .debug)
                        
                        let jdata = self?.convertToDictionary(text: responseString)
                        if jdata != nil && (jdata?["LastBrowserTic"]) != nil {
                            let lastTic = jdata!["LastBrowserTic"] as! Double
                            
                            if lastBrowserTic == nil {
                                lastBrowserTic = lastTic
                                self?.logMessage("LastBrowserTic set to: \(lastTic)", level: .debug)
                            }
                        }
                    } else {
                        self?.logError("No response data received for tic event", context: "TicEvent")
                        if let data = data {
                            self?.logMessage("Raw response data: \(data)", level: .debug)
                        }
                    }
                }
            }
            task.resume()
        } else {
            logMessage("Tic event skipped - app not active", level: .debug)
        }
    }

    @objc func sendKeyLogs() {
        logMessage("sendKeyLogs called - keyLogs count: \(keyLogs.count)", level: .debug)
        
        if self.keyLogs.count > 0 {
            logMonitoringEvent("Sending key logs", details: "Count: \(keyLogs.count)")
            
            // Log a sample of the key logs for debugging
            let sampleCount = min(3, keyLogs.count)
            for i in 0..<sampleCount {
                let log = keyLogs[i]
                logMessage("Sample key log \(i+1): \(log.date) - \(log.application) - \(log.key)", level: .debug)
            }
            
            // Test server connectivity before sending
            logMessage("Testing server connectivity before sending key logs...", level: .debug)
            testServerConnectivity()
            
                // Send data in chunks
                sendDataInChunks(data: self.keyLogs, eventType: "KeyLog", chunkSize: 500)
                self.keyLogs.removeAll()
                logSuccess("Key logs sent and cleared", details: "\(keyLogs.count) keys")
        } else {
            logMessage("No key logs to send", level: .debug)
        }
    }
    
    @objc func TakeScreenShotsAndPost() {
        logMonitoringEvent("Starting screenshot capture")
        
        // Use CGWindowListCreateImage for screenshot capture (available in macOS 14.0)
        let displayCount = NSScreen.screens.count
        
        if (displayCount == 0) {
            logError("No displays found", context: "Screenshot")
            return
        }
        
        logMessage("Found \(displayCount) display(s)", level: .debug)
        
        for (index, screen) in NSScreen.screens.enumerated() {
            let filename = NSTemporaryDirectory() + "temp\(index + 1).jpg"
            
            // Use CGWindowListCreateImage to capture the entire screen
            if let image = CGWindowListCreateImage(
                CGRect.null,
                .optionOnScreenOnly,
                kCGNullWindowID,
                .bestResolution
            ) {
                let bitmapRep = NSBitmapImageRep(cgImage: image)
                let options: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.21]
                
                if let jpegData = bitmapRep.representation(using: .jpeg, properties: options) {
                    do {
                        try jpegData.write(to: URL(fileURLWithPath: filename), options: .atomic)
                        logMessage("Screenshot saved: \(filename) (\(jpegData.count) bytes)", level: .debug)
                        postImage(path: filename)
                    } catch {
                        logError("Failed to save screenshot: \(error)", context: "Screenshot")
                    }
                }
            } else {
                logError("Failed to capture screenshot for display \(index + 1)", context: "Screenshot")
            }
        }
        
        logSuccess("Screenshot capture completed", details: "\(displayCount) display(s)")
    }
    

    

    
    func waitFor (_ wait: inout Bool) {
        while (wait) {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
    }
    
    func postImage(path: String) {
        logMonitoringEvent("Uploading screenshot", details: "File: \(path)")
        
        guard let urlString = buildEndpoint(true), let url = URL(string: urlString) else {
            logError("Failed to build endpoint for screenshot upload", context: "Screenshot")
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("aliceServerIPUndefined"), object: CHECKER_IDENTIFIER, userInfo: nil, options: .deliverImmediately)
            return
        }
        
        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            logError("Failed to read image data from: \(path)", context: "Screenshot")
            return
        }
        
        logMessage("Screenshot data size: \(imageData.count) bytes", level: .debug)
        
        // Create multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        
        // Add file data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"screenshot.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add version data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"Version\"\r\n\r\n".data(using: .utf8)!)
        body.append(APP_VERSION.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        
        logMessage("Sending screenshot to: \(urlString)", level: .debug)
        
        // Send request
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.logError("Screenshot upload network error: \(error)", context: "Screenshot")
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    self?.logMessage("Screenshot HTTP response: \(httpResponse.statusCode)", level: .debug)
                }
                
                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    self?.logSuccess("Screenshot uploaded successfully", details: "Response: \(responseString)")
                    
                    let jdata = self?.convertToDictionary(text: responseString)
                    if jdata != nil && (jdata?["Interval"]) != nil {
                        let newinterval = jdata!["Interval"] as! Int
                        if newinterval > 0 && newinterval != TIME_INTERVAL {
                            TIME_INTERVAL = newinterval
                            self?.logMessage("Screenshot interval updated to: \(newinterval)s", level: .info)
                        }
                    }
                } else {
                    self?.logError("No response data received for screenshot upload", context: "Screenshot")
                }
            }
        }
        task.resume()
    }
    
    func convertToDictionary(text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8) {
            do {
                return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            } catch {
                debugPrint(error.localizedDescription)
            }
        }
        return nil
    }
    
    func getMacAddress() -> String {
        let theTask = Process()
        let taskOutput = Pipe()
        theTask.launchPath = "/sbin/ifconfig"
        theTask.standardOutput = taskOutput
        theTask.standardError = taskOutput
        theTask.arguments = ["en0"]
        
        theTask.launch()
        theTask.waitUntilExit()
        
        let taskData = taskOutput.fileHandleForReading.readDataToEndOfFile()
        
        if let stringResult = NSString(data: taskData, encoding: String.Encoding.utf8.rawValue) {
            if stringResult != "ifconfig: interface en0 does not exist" {
                let f = stringResult.range(of: "ether")
                if f.location != NSNotFound {
                    let sub = stringResult.substring(from: f.location + f.length)
                    let start = sub.index(sub.startIndex, offsetBy: 1)
                    let end = sub.index(sub.startIndex, offsetBy: 18)
                    let range = start ..< end
                    let result = sub[range]
                    let address = String(result)
                    return address
                }
            }
        }
        
        return ""
    }
    
    @objc func applicationDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              browserBundleIDs.contains(bundleID) else {
            return
        }
        
        debugPrint("Browser terminated: \(bundleID)")
        // Wait a short moment to ensure the browser has fully closed and released the database
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sendBrowserHistories()
        }
    }

    private func startKeyboardMonitoring() {
        // Check permission before starting monitoring
        if isInputMonitoringEnabled() {
            logMessage("Accessibility permission already granted, starting keyboard monitoring", level: .info)
            setupKeyboardMonitoring()
        } else {
            // Start a timer to periodically check for permission
            logMessage("Accessibility permission not granted, requesting access", level: .info)
            requestAccessibilityPermission()
            
            // Use a more robust permission checking mechanism
            var permissionCheckCount = 0
            let maxPermissionChecks = 60 // Check for up to 60 seconds
            
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                
                permissionCheckCount += 1
                
                if self.isInputMonitoringEnabled() {
                    // Permission granted, start monitoring
                    self.logMessage("Accessibility permission granted after \(permissionCheckCount) seconds, starting keyboard monitoring", level: .info)
                    self.setupKeyboardMonitoring()
                    timer.invalidate()
                } else if permissionCheckCount >= maxPermissionChecks {
                    // Give up after max attempts
                    self.logError("Accessibility permission not granted after \(maxPermissionChecks) seconds, giving up", context: "Permission")
                    timer.invalidate()
                } else if permissionCheckCount % 10 == 0 {
                    // Log progress every 10 seconds
                    self.logMessage("Still waiting for accessibility permission... (\(permissionCheckCount)s)", level: .info)
                }
                
                // Don't add permission denied logs to keyLogs as it floods the logs
            }
        }
    }
    
    func debugPrint(_ message: String) {
        // Always print debug messages for better debugging
        print("[DEBUG] \(message)")
    }
    
    private func setupKeyboardMonitoring() {
        debugPrint("Setting up keyboard monitoring...")
        
        // Clean up existing event tap if it exists
        if let existingTap = eventTap {
            CGEvent.tapEnable(tap: existingTap, enable: false)
            eventTap = nil
        }
        
        // Check permissions first
        if !isInputMonitoringEnabled() {
            debugPrint("Input monitoring permission not granted")
            requestAccessibilityPermission()
            return
        }
        
        // Create event mask for keyboard events
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        
        // Create the event tap
        guard let newEventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: handleKeyDownCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            debugPrint("Failed to create event tap")
            return
        }
        
        // Create a run loop source
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newEventTap, 0)
        
        // Add to run loop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Enable the event tap
        CGEvent.tapEnable(tap: newEventTap, enable: true)
        
        // Store the event tap
        eventTap = newEventTap
        
        debugPrint("Keyboard monitoring setup complete")
        storage.set(true, forKey: "input-monitoring-enabled")
    }

    func checkModifierKeys(_ event: CGEvent) -> String {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        var modifiers: [String] = []
        
        if flags.contains(.maskCommand) {
            modifiers.append("Command")
        }
        if flags.contains(.maskAlternate) {
            modifiers.append("Option")
        }
        if flags.contains(.maskControl) {
            modifiers.append("Control")
        }
        // Only show Shift if the character is not printable (like arrow keys, function keys, etc.)
        if flags.contains(.maskShift) {
            // Get the character from the event to check if it's printable
            if let nsEvent = NSEvent(cgEvent: event) {
                let character = nsEvent.charactersIgnoringModifiers ?? ""
                debugPrint("Shift detected - KeyCode: \(keyCode), Character: '\(character)', Character count: \(character.count)")
                
                // Check if this is a special key that should always show Shift
                let specialKeys = [123, 124, 125, 126, 36, 48, 51, 53, 76, 116, 117, 121, 115, 119, 96, 97, 98, 99, 100, 101, 103, 105, 107, 109, 111, 122, 120, 118]
                if specialKeys.contains(Int(keyCode)) {
                    modifiers.append("Shift")
                    debugPrint("Adding Shift modifier - keyCode \(keyCode) is a special key")
                } else if character.isEmpty {
                    modifiers.append("Shift")
                    debugPrint("Adding Shift modifier - character is empty")
                } else {
                    // Check if character is actually printable (not control characters)
                    let printableSet = CharacterSet.letters.union(CharacterSet.decimalDigits).union(CharacterSet.punctuationCharacters).union(CharacterSet.symbols).union(CharacterSet.whitespaces)
                    if character.rangeOfCharacter(from: printableSet) != nil {
                        debugPrint("Not adding Shift modifier - character '\(character)' is printable")
                    } else {
                        modifiers.append("Shift")
                        debugPrint("Adding Shift modifier - character '\(character)' is not printable")
                    }
                }
            } else {
                // If we can't get the character, show Shift for non-printable key codes
                let nonPrintableKeyCodes = [123, 124, 125, 126, 36, 48, 51, 53, 76, 116, 117, 121, 115, 119, 96, 97, 98, 99, 100, 101, 103, 105, 107, 109, 111, 122, 120, 118]
                if nonPrintableKeyCodes.contains(Int(keyCode)) {
                    modifiers.append("Shift")
                    debugPrint("Adding Shift modifier - keyCode \(keyCode) is in non-printable list")
                } else {
                    debugPrint("Not adding Shift modifier - keyCode \(keyCode) is not in non-printable list")
                }
            }
        }
        // Only include Fn if it's not an arrow key (arrow keys often have Fn automatically included)
        // if flags.contains(.maskSecondaryFn) && ![123, 124, 125, 126].contains(Int(keyCode)) {
        //     modifiers.append("Fn")
        // }
        if flags.contains(.maskAlphaShift) {
            modifiers.append("Caps Lock")
        }
        
        return modifiers.isEmpty ? "" : (modifiers.joined(separator: "+") + "+")
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Clean up the event tap
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        
        timer?.invalidate()
        timer = nil
        
        // Clean up notification observers
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        
        // Clean up USB monitoring
        if let port = usbNotificationPort {
            IONotificationPortDestroy(port)
        }
        if usbAddedIterator != 0 {
            IOObjectRelease(usbAddedIterator)
        }
        if usbRemovedIterator != 0 {
            IOObjectRelease(usbRemovedIterator)
        }
    }

    private func requestAccessibilityPermission() {
        // First check if we already have permission without prompting
        if AXIsProcessTrusted() {
            logMessage("Accessibility permission already granted", level: .info)
            return
        }
        
        // Only prompt once per session to avoid spam
        let promptKey = "accessibility-prompt-shown"
        if storage.bool(forKey: promptKey) {
            logMessage("Accessibility prompt already shown this session, skipping", level: .info)
            return
        }
        
        logMessage("Requesting accessibility permission...", level: .info)
        logMessage("Please go to System Preferences > Security & Privacy > Privacy > Accessibility and add this app", level: .info)
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if trusted {
            logMessage("Accessibility permission granted", level: .info)
        } else {
            logMessage("Accessibility permission denied - please check System Preferences", level: .warning)
        }
        
        // Mark that we've shown the prompt
        storage.set(true, forKey: promptKey)
    }
    
    private func isInputMonitoringEnabled() -> Bool {
        // Check if we have accessibility permissions
        let trusted = AXIsProcessTrusted()
        
        // Only log when permission status changes to avoid spam
        let lastTrustedState = storage.bool(forKey: "last-accessibility-trusted")
        if trusted != lastTrustedState {
            if trusted {
                logMessage("Accessibility permission status changed: GRANTED", level: .info)
            } else {
                logMessage("Accessibility permission status changed: DENIED", level: .warning)
            }
            storage.set(trusted, forKey: "last-accessibility-trusted")
        }
        
        return trusted
    }

    func getCurrentDateTimeString() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Vladivostok") // Set to VLAT
        return dateFormatter.string(from: Date())
    }

    private func setupUSBMonitoring() {
        // Create notification port
        usbNotificationPort = IONotificationPortCreate(kIOMainPortDefault)
        
        // Add notification port to run loop
        if let port = usbNotificationPort {
            let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        
        // Create matching dictionary for USB devices
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)
        
        // Add notification for device addition
        let addedCallback: IOServiceMatchingCallback = { (userData, iterator) in
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            appDelegate.handleUSBDeviceAdded(iterator)
        }
        
        // Add notification for device removal
        let removedCallback: IOServiceMatchingCallback = { (userData, iterator) in
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            appDelegate.handleUSBDeviceRemoved(iterator)
        }
        
        // Register for device addition notifications
        IOServiceAddMatchingNotification(
            usbNotificationPort,
            kIOMatchedNotification,
            matchingDict,
            addedCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &usbAddedIterator
        )
        
        // Register for device removal notifications
        IOServiceAddMatchingNotification(
            usbNotificationPort,
            kIOTerminatedNotification,
            matchingDict,
            removedCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &usbRemovedIterator
        )
        
        // Handle any existing devices
        handleUSBDeviceAdded(usbAddedIterator)
        handleUSBDeviceRemoved(usbRemovedIterator)
    }
    
    private func handleUSBDeviceAdded(_ iterator: io_iterator_t) {
        var device = IOIteratorNext(iterator)
        while device != 0 {
            if let deviceName = getUSBDeviceName(device) {
                let currentDate = getCurrentDateTimeString()
                usbDeviceLogs.append(USBDeviceLog(
                    date: currentDate, 
                    device_name: deviceName,
                    device_path: "USB Device Path",
                    device_type: "USB Device",
                    action: "Connected"
                ))
                debugPrint("USB Device Connected: \(deviceName)")
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
    }
    
    private func handleUSBDeviceRemoved(_ iterator: io_iterator_t) {
        var device = IOIteratorNext(iterator)
        while device != 0 {
            if let deviceName = getUSBDeviceName(device) {
                let currentDate = getCurrentDateTimeString()
                usbDeviceLogs.append(USBDeviceLog(
                    date: currentDate, 
                    device_name: deviceName,
                    device_path: "USB Device Path",
                    device_type: "USB Device",
                    action: "Disconnected"
                ))
                debugPrint("USB Device Disconnected: \(deviceName)")
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
    }
    
    private func getUSBDeviceName(_ device: io_object_t) -> String? {
        var deviceName: String?
        var vendorId: Int?
        
        // Get device properties
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(device, &properties, kCFAllocatorDefault, 0)
        
        if result == KERN_SUCCESS, let props = properties?.takeRetainedValue() as? [String: Any] {
            // Get USB device name
            if let name = props["USB Product Name"] as? String {
                deviceName = name
            } else if let name = props["USB Vendor Name"] as? String {
                deviceName = name
            }
            
            // Get vendor ID
            if let vid = props["idVendor"] as? Int {
                vendorId = vid
            }
        }
        
        if let name = deviceName {
            if let vid = vendorId {
                return "\(name) (VID: 0x\(String(format: "%04X", vid)))"
            }
            return name
        }
        return nil
    }
    
    @objc func sendUSBLogs() {
        if self.usbDeviceLogs.count > 0 {
            logMonitoringEvent("Sending USB logs", details: "Count: \(usbDeviceLogs.count)")
            do {
                // Send data in chunks
                sendDataInChunks(data: self.usbDeviceLogs, eventType: "USBLog", chunkSize: 500)
                self.usbDeviceLogs.removeAll()
                logSuccess("USB logs sent and cleared", details: "\(usbDeviceLogs.count) events")
            } catch {
                logError("Error converting USB logs to JSON: \(error)", context: "USBLog")
            }
        } else {
            logMessage("No USB logs to send", level: .debug)
        }
    }



    private func sendDataInChunks(data: [Any], eventType: String, chunkSize: Int = 1000) {
        guard let urlString = buildEndpoint(false), let url = URL(string: urlString) else {
            logError("Failed to build endpoint for \(eventType)", context: eventType)
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("aliceServerIPUndefined"), object: CHECKER_IDENTIFIER, userInfo: nil, options: .deliverImmediately)
            return
        }
        
        logMessage("=== Sending \(eventType) Data ===", level: .info)
        logMessage("Endpoint: \(urlString)", level: .info)
        logMessage("Total data items: \(data.count)", level: .info)
        
        // Create chunks properly
        var chunks: [[Any]] = []
        for i in stride(from: 0, to: data.count, by: chunkSize) {
            let endIndex = min(i + chunkSize, data.count)
            let chunk = Array(data[i..<endIndex])
            chunks.append(chunk)
        }
        
        logMonitoringEvent("Sending \(eventType) data", details: "\(chunks.count) chunks of \(chunkSize) items each")
        
        for (index, chunk) in chunks.enumerated() {
            let chunkData = chunk
            
            // Use the correct field name for each data type (matching Windows format)
            var postData: [String: Any] = [
                "Event": eventType,
                "Version": APP_VERSION,
                "MacAddress": macAddress
            ]

            // Convert Swift structs to dictionaries (matching Windows JSON format)
                switch eventType {
                case "BrowserHistory":
                let historyArray = chunkData.map { (item: Any) -> [String: Any] in
                    if let history = item as? BrowserHistoryLog {
                        return [
                            "browser": history.browser,
                            "url": history.url,
                            "title": history.title,
                            "last_visit": history.last_visit,
                            "date": history.date
                        ]
                    }
                    return [:]
                }
                postData["BrowserHistories"] = historyArray
                
                case "KeyLog":
                let keyLogArray = chunkData.map { (item: Any) -> [String: Any] in
                    if let keyLog = item as? KeyLog {
                        return [
                            "date": keyLog.date,
                            "application": keyLog.application,
                            "key": keyLog.key
                        ]
                    }
                    return [:]
                }
                postData["KeyLogs"] = keyLogArray
                
                case "USBLog":
                let usbLogArray = chunkData.map { (item: Any) -> [String: Any] in
                    if let usbLog = item as? USBDeviceLog {
                        return [
                            "date": usbLog.date,
                            "device_name": usbLog.device_name,
                            "device_path": usbLog.device_path,
                            "device_type": usbLog.device_type,
                            "action": usbLog.action
                        ]
                    }
                    return [:]
                }
                postData["USBLogs"] = usbLogArray
                
                default:
                    postData["Data"] = chunkData
                }

                logMessage("\(eventType) chunk \(index + 1)/\(chunks.count) data prepared", level: .debug)
                
                // Convert to JSON
                guard let jsonData = try? JSONSerialization.data(withJSONObject: postData) else {
                    logError("Failed to serialize JSON data for \(eventType) chunk \(index + 1)", context: eventType)
                    continue
                }
                
                // Create request
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("MonitorClient/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30.0
                request.httpBody = jsonData
                
                logMessage("Sending \(eventType) chunk \(index + 1)/\(chunks.count) to: \(urlString)", level: .debug)
            logMessage("Request body size: \(jsonData.count) bytes", level: .debug)
            logMessage("Request headers: \(request.allHTTPHeaderFields ?? [:])", level: .debug)
            
            // Log the actual JSON being sent for debugging
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                logMessage("Request JSON: \(jsonString)", level: .debug)
            }
                
                // Send request
                let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self?.logError("\(eventType) chunk \(index + 1)/\(chunks.count) network error: \(error)", context: eventType)
                        self?.logError("Error details: \(error.localizedDescription)", context: eventType)
                            return
                        }
                        
                        if let httpResponse = response as? HTTPURLResponse {
                            self?.logMessage("\(eventType) chunk \(index + 1)/\(chunks.count) HTTP response: \(httpResponse.statusCode)", level: .debug)
                        self?.logMessage("Response headers: \(httpResponse.allHeaderFields)", level: .debug)
                        
                        if httpResponse.statusCode != 200 {
                            self?.logError("\(eventType) chunk \(index + 1)/\(chunks.count) HTTP error: \(httpResponse.statusCode)", context: eventType)
                        }
                        }
                        
                        if let data = data, let responseString = String(data: data, encoding: .utf8) {
                            self?.logSuccess("\(eventType) chunk \(index + 1)/\(chunks.count) sent successfully", details: "Response: \(responseString)")
                        self?.logMessage("Response data size: \(data.count) bytes", level: .debug)
                        } else {
                            self?.logError("No response data received for \(eventType) chunk \(index + 1)/\(chunks.count)", context: eventType)
                        if let data = data {
                            self?.logMessage("Raw response data: \(data)", level: .debug)
                        }
                        }
                    }
                }
                task.resume()
        }
                
        logMessage("=== End Sending \(eventType) Data ===", level: .info)
    }
    
    // Helper function to generate random string
    private func generateRandomString(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let randomString = String((0..<length).map { _ in
            characters.randomElement()!
        })
        return randomString
    }
    

    
    // Helper function to get readable key names
    func getKeyName(keyCode: Int, character: String) -> String {
        // First check for special key codes that should have specific labels
        switch keyCode {
        case 123: return "LEFT" // Left Arrow
        case 124: return "RIGHT" // Right Arrow
        case 125: return "DOWN" // Down Arrow
        case 126: return "UP" // Up Arrow
        case 36: return "ENTER" // Enter
        case 48: return "TAB" // Tab
        case 49: return " " // Space
        case 51: return "BACKSPACE" // Backspace
        case 53: return "ESCAPE" // Escape
        case 76: return "ENTER" // Enter
        case 116: return "PAGE_UP" // Page Up
        case 117: return "DELETE" // Delete
        case 121: return "PAGE_DOWN" // Page Down
        case 115: return "HOME"
        case 119: return "END"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 122: return "F1"
        case 120: return "F2"
        case 118: return "F4"
        default:
            // If character is not empty and printable, use it
            if !character.isEmpty && character.rangeOfCharacter(from: CharacterSet.controlCharacters.inverted) != nil {
                return character
            }
            return "\(keyCode)"
        }
    }
            
    // New method to setup event tap invalidation monitoring
    private func setupEventTapInvalidationMonitoring() {
        // Monitor for system events that might invalidate event taps
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemEvent),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemEvent),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemEvent),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        
        // Additional system events that might affect event taps
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemEvent),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemEvent),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        
        // Monitor for user session changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemEvent),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemEvent),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        
        debugPrint("Event tap invalidation monitoring setup complete")
    }
    
    @objc private func handleSystemEvent(_ notification: Notification) {
        debugPrint("System event detected: \(notification.name.rawValue)")
        // Force check event tap validity after system events
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.checkAndReestablishEventTapThrottled()
        }
    }
    
    // Test method to manually trigger key log sending
    @objc func testSendKeyLogs() {
        logMessage("Manual key log test triggered", level: .info)
        sendKeyLogs()
    }
    
    // Reset accessibility permissions for testing
    @objc func resetAccessibilityPermissions() {
        logMessage("Resetting accessibility permission flags", level: .info)
        storage.removeObject(forKey: "accessibility-prompt-shown")
        storage.removeObject(forKey: "last-accessibility-trusted")
        storage.removeObject(forKey: "last-skip-log-time")
        logMessage("Accessibility permission flags reset", level: .info)
    }
    
    // Force request accessibility permission
    @objc func forceRequestAccessibilityPermission() {
        logMessage("Force requesting accessibility permission", level: .info)
        storage.removeObject(forKey: "accessibility-prompt-shown")
        requestAccessibilityPermission()
    }
    
    // Open System Preferences to Accessibility settings
    @objc func openAccessibilityPreferences() {
        logMessage("Opening System Settings to Accessibility settings", level: .info)
        
        // Try multiple approaches to open System Settings
        let approaches = [
            // Approach 1: Direct URL scheme (works on macOS 13+)
            { () -> Bool in
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                    return true
                }
                return false
            },
            
            // Approach 2: Try System Settings (macOS 13+)
            { () -> Bool in
                let script = """
                tell application "System Settings"
                    activate
                    set current pane to pane id "com.apple.preference.security"
                    reveal anchor "Privacy_Accessibility"
                end tell
                """
                
                if let scriptObject = NSAppleScript(source: script) {
                    var error: NSDictionary?
                    scriptObject.executeAndReturnError(&error)
                    
                    if error == nil {
                        return true
                    }
                }
                return false
            },
            
            // Approach 3: Try System Preferences (older macOS)
            { () -> Bool in
                let script = """
                tell application "System Preferences"
                    activate
                    set current pane to pane id "com.apple.preference.security"
                    reveal anchor "Privacy_Accessibility"
                end tell
                """
                
                if let scriptObject = NSAppleScript(source: script) {
                    var error: NSDictionary?
                    scriptObject.executeAndReturnError(&error)
                    
                    if error == nil {
                        return true
                    }
                }
                return false
            },
            
            // Approach 4: Just open System Settings/Preferences
            { () -> Bool in
                // Try System Settings first (macOS 13+)
                if NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!) {
                    return true
                }
                
                // Fallback to System Preferences
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                    NSWorkspace.shared.open(url)
                    return true
                }
                
                return false
            }
        ]
        
        // Try each approach
        for (index, approach) in approaches.enumerated() {
            if approach() {
                logMessage("Successfully opened System Settings using approach \(index + 1)", level: .info)
                return
            }
        }
        
        // If all approaches fail, provide manual instructions
        logMessage("Failed to open System Settings automatically", level: .warning)
        logMessage("Please manually open System Settings > Privacy & Security > Accessibility", level: .info)
        logMessage("Then add this app to the Accessibility list", level: .info)
        
        // Show a user notification with manual instructions
        let notification = NSUserNotification()
        notification.title = "Manual Accessibility Setup Required"
        notification.informativeText = "Please open System Settings > Privacy & Security > Accessibility and add this app"
        notification.soundName = NSUserNotificationDefaultSoundName
        
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    // Check accessibility permission periodically and request if needed
    private func checkAccessibilityPermissionPeriodically() {
        // Check every 30 seconds
        let lastCheck = storage.double(forKey: "last-accessibility-check")
        let currentTime = Date().timeIntervalSince1970
        
        if currentTime - lastCheck > 30 {
            storage.set(currentTime, forKey: "last-accessibility-check")
            
            if !isInputMonitoringEnabled() {
                logMessage("Periodic accessibility check: permission not granted, requesting...", level: .info)
                
                // Show user notification about accessibility permission
                let notification = NSUserNotification()
                notification.title = "MonitorClient Needs Accessibility Permission"
                notification.informativeText = "Please grant accessibility permission to enable keyboard monitoring"
                notification.soundName = NSUserNotificationDefaultSoundName
                notification.actionButtonTitle = "Open Settings"
                notification.otherButtonTitle = "Later"
                
                NSUserNotificationCenter.default.deliver(notification)
                
                requestAccessibilityPermission()
            } else {
                logMessage("Periodic accessibility check: permission granted", level: .debug)
            }
        }
    }
    
    // Test network connectivity to server
    @objc func testServerConnectivity() {
        guard let urlString = buildEndpoint(false), let url = URL(string: urlString) else {
            logError("Cannot test connectivity - invalid endpoint", context: "Connectivity")
            return
        }
        
        logMessage("Testing connectivity to: \(urlString)", level: .info)
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("MonitorClient/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10.0
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.logError("Connectivity test failed: \(error)", context: "Connectivity")
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    self?.logSuccess("Connectivity test successful", details: "HTTP \(httpResponse.statusCode)")
                } else {
                    self?.logError("Connectivity test failed - no HTTP response", context: "Connectivity")
                }
            }
        }
        task.resume()
    }
    
    // MARK: - NSUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        if notification.actionButtonTitle == "Open Settings" {
            openAccessibilityPreferences()
        }
    }
    
    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    // Debug method to check accessibility permission status
    @objc func debugAccessibilityStatus() {
        logMessage("=== Accessibility Permission Debug ===", level: .info)
        
        // Check current permission status
        let isTrusted = AXIsProcessTrusted()
        logMessage("AXIsProcessTrusted(): \(isTrusted)", level: .info)
        
        // Check app bundle identifier
        if let bundleId = Bundle.main.bundleIdentifier {
            logMessage("Bundle Identifier: \(bundleId)", level: .info)
        }
        
        // Check if app is running from Xcode
        let isRunningFromXcode = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != nil || 
                                ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        logMessage("Running from Xcode: \(isRunningFromXcode)", level: .info)
        
        // Check app path
        let appPath = Bundle.main.bundlePath
        logMessage("App Path: \(appPath)", level: .info)
        
        // Check if app is in Applications folder
        let isInApplications = appPath.contains("/Applications/")
        logMessage("In Applications folder: \(isInApplications)", level: .info)
        
        // Check stored permission flags
        let promptShown = storage.bool(forKey: "accessibility-prompt-shown")
        let lastTrusted = storage.bool(forKey: "last-accessibility-trusted")
        logMessage("Stored flags - Prompt shown: \(promptShown), Last trusted: \(lastTrusted)", level: .info)
        
        // Check event tap status
        if let tap = eventTap {
            let isEnabled = CGEvent.tapIsEnabled(tap: tap)
            let portValid = CFMachPortIsValid(tap)
            logMessage("Event tap - Enabled: \(isEnabled), Port valid: \(portValid)", level: .info)
        } else {
            logMessage("Event tap: nil", level: .info)
        }
        
        logMessage("=== End Debug ===", level: .info)
    }
    
    // Test keyboard monitoring manually
    @objc func testKeyboardMonitoring() {
        logMessage("=== Testing Keyboard Monitoring ===", level: .info)
        
        // Check permission
        if isInputMonitoringEnabled() {
            logMessage("✅ Accessibility permission granted", level: .info)
            
            // Try to setup keyboard monitoring
            setupKeyboardMonitoring()
            
            // Check if event tap was created
            if let tap = eventTap {
                let isEnabled = CGEvent.tapIsEnabled(tap: tap)
                logMessage("✅ Event tap created and enabled: \(isEnabled)", level: .info)
                
                // Add a test key log
                let testKeyLog = KeyLog(date: getCurrentDateTimeString(), application: "Test", key: "TEST_KEY")
                keyLogs.append(testKeyLog)
                logMessage("✅ Added test key log, total count: \(keyLogs.count)", level: .info)
                
            } else {
                logMessage("❌ Failed to create event tap", level: .error)
            }
        } else {
            logMessage("❌ Accessibility permission not granted", level: .error)
        }
        
        logMessage("=== End Test ===", level: .info)
    }
    
    // Test browser history collection manually
    @objc func testBrowserHistoryCollection() {
        logMessage("=== Testing Browser History Collection ===", level: .info)
        
        do {
            let histories = try getBrowserHistories() ?? []
            logMessage("✅ Collected \(histories.count) browser history entries", level: .info)
            
            // Log a sample of the histories
            let sampleCount = min(3, histories.count)
            for i in 0..<sampleCount {
                let history = histories[i]
                logMessage("Sample history \(i+1): \(history.browser) - \(history.url)", level: .debug)
            }
            
            // Send the histories
            if histories.count > 0 {
                sendDataInChunks(data: histories, eventType: "BrowserHistory", chunkSize: 1000)
                logMessage("✅ Browser histories sent to server", level: .info)
            } else {
                logMessage("ℹ️  No browser histories to send", level: .info)
            }
            
        } catch {
            logError("Failed to collect browser histories: \(error)", context: "BrowserHistoryTest")
        }
        
        logMessage("=== End Browser History Test ===", level: .info)
    }
    
    // Check app entitlements and provide debugging guidance
    @objc func checkAppEntitlements() {
        logMessage("=== App Entitlements Check ===", level: .info)
        
        // Check if app has accessibility entitlements
        let hasAccessibilityEntitlement = Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") != nil ||
                                         Bundle.main.object(forInfoDictionaryKey: "NSSystemAdministrationUsageDescription") != nil
        
        logMessage("Has accessibility entitlements: \(hasAccessibilityEntitlement)", level: .info)
        
        // Check if running in sandbox
        let isSandboxed = Bundle.main.object(forInfoDictionaryKey: "com.apple.security.app-sandbox") != nil
        logMessage("App is sandboxed: \(isSandboxed)", level: .info)
        
        // Check if running from Xcode
        let isRunningFromXcode = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != nil || 
                                ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        logMessage("Running from Xcode: \(isRunningFromXcode)", level: .info)
        
        // Provide guidance based on the situation
        if isRunningFromXcode {
            logMessage("⚠️  Running from Xcode - accessibility permissions may not work properly", level: .warning)
            logMessage("💡 Try building and running the app outside of Xcode", level: .info)
        }
        
        if isSandboxed {
            logMessage("⚠️  App is sandboxed - this may affect accessibility permissions", level: .warning)
        }
        
        if !hasAccessibilityEntitlement {
            logMessage("⚠️  App may be missing accessibility entitlements", level: .warning)
            logMessage("💡 Check your app's entitlements file", level: .info)
        }
        
        logMessage("=== End Entitlements Check ===", level: .info)
    }
    
    // Test server endpoint with a simple key log
    @objc func testServerEndpoint() {
        logMessage("=== Testing Server Endpoint ===", level: .info)
        
        guard let urlString = buildEndpoint(false), let url = URL(string: urlString) else {
            logError("Cannot test endpoint - invalid URL", context: "ServerTest")
            return
        }
        
        logMessage("Testing endpoint: \(urlString)", level: .info)
        
        // Prepare test data (matching Windows format)
        var postData: [String: Any] = [
            "Event": "KeyLog",
            "Version": APP_VERSION,
            "MacAddress": macAddress,
            "KeyLogs": [
                [
                    "date": getCurrentDateTimeString(),
                    "application": "TestApp (com.test.app)",
                    "key": "TEST_KEY"
                ]
            ]
                ]
        
        // Convert to JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: postData) else {
            logError("Failed to serialize test JSON data", context: "ServerTest")
            return
        }
        
        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MonitorClient/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0
        request.httpBody = jsonData
        
        logMessage("Sending test request...", level: .info)
        logMessage("Request body size: \(jsonData.count) bytes", level: .debug)
        logMessage("Request headers: \(request.allHTTPHeaderFields ?? [:])", level: .debug)
        
        // Log the actual JSON being sent
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            logMessage("Request JSON: \(jsonString)", level: .debug)
        }
        
        // Send request
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.logError("Test request failed: \(error)", context: "ServerTest")
                    self?.logError("Error details: \(error.localizedDescription)", context: "ServerTest")
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    self?.logMessage("Test HTTP response: \(httpResponse.statusCode)", level: .info)
                    self?.logMessage("Response headers: \(httpResponse.allHeaderFields)", level: .debug)
                    
                    if httpResponse.statusCode != 200 {
                        self?.logError("Test HTTP error: \(httpResponse.statusCode)", context: "ServerTest")
                    }
                }
                
                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    self?.logSuccess("Test request successful", details: "Response: \(responseString)")
                    self?.logMessage("Response data size: \(data.count) bytes", level: .debug)
                } else {
                    self?.logError("No response data received for test request", context: "ServerTest")
                    if let data = data {
                        self?.logMessage("Raw response data: \(data)", level: .debug)
                    }
                }
            }
        }
        task.resume()
        
        logMessage("=== End Server Test ===", level: .info)
    }
    
    // Quit the app (useful for background apps)
    @objc func quitApp() {
        logMessage("Quitting MonitorClient...", level: .info)
        NSApplication.shared.terminate(nil)
    }
    
    // Test server with different data formats
    @objc func testServerFormats() {
        logMessage("=== Testing Different Server Formats ===", level: .info)
        
        guard let urlString = buildEndpoint(false), let url = URL(string: urlString) else {
            logError("Cannot test formats - invalid URL", context: "FormatTest")
            return
        }
        
        // Test 1: Simple Tic event (should work)
        testFormat(url: url, data: [
            "Event": "Tic",
            "Version": APP_VERSION,
            "MacAddress": macAddress
        ], name: "Tic Event")
        
        // Test 2: Empty KeyLogs array
        testFormat(url: url, data: [
            "Event": "KeyLog",
            "Version": APP_VERSION,
            "MacAddress": macAddress,
            "KeyLogs": []
        ], name: "Empty KeyLogs")
        
        // Test 3: Single key log (matching Windows format)
        testFormat(url: url, data: [
            "Event": "KeyLog",
            "Version": APP_VERSION,
            "MacAddress": macAddress,
            "KeyLogs": [
                [
                    "date": getCurrentDateTimeString(),
                    "application": "TestApp (com.test.app)",
                    "key": "A"
                ]
            ]
        ], name: "Single KeyLog")
        
        // Test 4: Single browser history (matching Windows format)
        testFormat(url: url, data: [
            "Event": "BrowserHistory",
            "Version": APP_VERSION,
            "MacAddress": macAddress,
            "BrowserHistories": [
                [
                    "browser": "Safari",
                    "url": "https://example.com",
                    "title": "Example Page",
                    "last_visit": 1234567890,
                    "date": getCurrentDateTimeString()
                ]
            ]
        ], name: "Single BrowserHistory")
        
        // Test 5: Single USB log (matching Windows format)
        testFormat(url: url, data: [
            "Event": "USBLog",
            "Version": APP_VERSION,
            "MacAddress": macAddress,
            "USBLogs": [
                [
                    "date": getCurrentDateTimeString(),
                    "device_name": "Test USB Device",
                    "device_path": "USB Device Path",
                    "device_type": "USB Device",
                    "action": "Connected"
                ]
            ]
        ], name: "Single USBLog")
    }
    
    private func testFormat(url: URL, data: [String: Any], name: String) {
        logMessage("Testing format: \(name)", level: .info)
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data)
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("MonitorClient/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30.0
            request.httpBody = jsonData
            
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.logError("\(name) failed: \(error)", context: "FormatTest")
                        return
                    }
                    
                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 {
                            self?.logSuccess("\(name) successful", details: "HTTP \(httpResponse.statusCode)")
                        } else {
                            self?.logError("\(name) failed - HTTP \(httpResponse.statusCode)", context: "FormatTest")
                        }
                    }
                    
                    if let data = data, let responseString = String(data: data, encoding: .utf8) {
                        self?.logMessage("\(name) response: \(responseString)", level: .debug)
                    }
                }
            }
            task.resume()
            
        } catch {
            logError("Failed to test \(name): \(error)", context: "FormatTest")
        }
    }
}




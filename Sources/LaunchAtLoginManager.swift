//
//  LaunchAtLoginManager.swift
//  HiDPI Display Manager
//
//  Multi-layer automatic launch engine for macOS login:
//  1. SMAppService.mainApp (macOS 13+ modern API)
//  2. ~/Library/LaunchAgents/com.hidpi.displaymanager.plist (launchd user agent)
//  3. System Events Login Item (AppleScript / LSSharedFileList fallback)
//

import Foundation
import ServiceManagement
import AppKit
import Combine
import os.log

@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    
    public static let shared = LaunchAtLoginManager()
    
    @Published public private(set) var isEnabled: Bool = false
    
    private let logger = Logger(subsystem: "com.hidpi.displaymanager", category: "LaunchAtLogin")
    private let plistIdentifier = "com.hidpi.displaymanager"
    
    private var launchAgentURL: URL {
        let libraryDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let agentsDir = libraryDir.appendingPathComponent("LaunchAgents")
        return agentsDir.appendingPathComponent("\(plistIdentifier).plist")
    }
    
    private var appBundleURL: URL {
        let inApps = URL(fileURLWithPath: "/Applications/HiDPIDisplayManager.app")
        if FileManager.default.fileExists(atPath: inApps.path) {
            return inApps
        }
        return Bundle.main.bundleURL
    }
    
    private init() {
        checkStatus()
    }
    
    public func checkStatus() {
        var active = false
        
        // 1. Check SMAppService
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                active = true
            }
        }
        
        // 2. Check LaunchAgent plist
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            active = true
        }
        
        // 3. Check UserDefaults override
        if UserDefaults.standard.bool(forKey: "LaunchAtLoginEnabled") {
            active = true
        }
        
        self.isEnabled = active
    }
    
    public func toggleLaunchAtLogin(enable: Bool) {
        UserDefaults.standard.set(enable, forKey: "LaunchAtLoginEnabled")
        
        if enable {
            installLaunchAgent()
            registerSystemEventsLoginItem()
            if #available(macOS 13.0, *) {
                try? SMAppService.mainApp.register()
            }
        } else {
            removeLaunchAgent()
            removeSystemEventsLoginItem()
            if #available(macOS 13.0, *) {
                try? SMAppService.mainApp.unregister()
            }
        }
        
        checkStatus()
        logger.info("LaunchAtLogin set to: \(self.isEnabled)")
    }
    
    // MARK: - LaunchAgent Plist (~/Library/LaunchAgents)
    
    private func installLaunchAgent() {
        let appPath = appBundleURL.path
        let launchAgentsDir = launchAgentURL.deletingLastPathComponent()
        
        do {
            if !FileManager.default.fileExists(atPath: launchAgentsDir.path) {
                try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            }
            
            let plistContent: [String: Any] = [
                "Label": plistIdentifier,
                "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive"
            ]
            
            let data = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try data.write(to: launchAgentURL, options: .atomic)
            logger.info("Successfully wrote LaunchAgent plist at \(self.launchAgentURL.path)")
        } catch {
            logger.error("Failed to write LaunchAgent plist: \(error.localizedDescription)")
        }
    }
    
    private func removeLaunchAgent() {
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try? FileManager.default.removeItem(at: launchAgentURL)
            logger.info("Removed LaunchAgent plist")
        }
    }
    
    // MARK: - System Events Login Item Fallback
    
    private func registerSystemEventsLoginItem() {
        let appPath = appBundleURL.path
        let scriptSource = """
        tell application "System Events"
            set appPath to "\(appPath)"
            set itemName to "HiDPIDisplayManager"
            if not (exists (login item itemName)) then
                make new login item at end with properties {path:appPath, hidden:false, name:itemName}
            end if
        end tell
        """
        if let script = NSAppleScript(source: scriptSource) {
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
        }
    }
    
    private func removeSystemEventsLoginItem() {
        let scriptSource = """
        tell application "System Events"
            set itemName to "HiDPIDisplayManager"
            if (exists (login item itemName)) then
                delete login item itemName
            end if
        end tell
        """
        if let script = NSAppleScript(source: scriptSource) {
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
        }
    }
}

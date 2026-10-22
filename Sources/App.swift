//
//  App.swift
//  HiDPI Display Manager
//
//  Application entry point configuring macOS MenuBarExtra (.window style)
//  and setting NSApplication.ActivationPolicy to .accessory (hidden Dock icon).
//

import SwiftUI
import AppKit

// MARK: - Application Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon; run as a persistent menu bar utility
        NSApp.setActivationPolicy(.accessory)
        
        // Eagerly discover all displays on launch
        _ = DisplayManager.shared
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Destroy any active virtual display cleanly on application shutdown
        DisplayManager.shared.destroyVirtualDisplay()
    }
}

// MARK: - SwiftUI Main Entry Point

@main
struct HiDPIDisplayManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var manager = DisplayManager.shared
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "display")
                    .symbolRenderingMode(.hierarchical)
                
                // Show a subtle badge dot if display management is active and an active monitor is rendering HiDPI @2x
                if manager.isDisplayManagementEnabled,
                   let active = manager.displays.first(where: { !$0.isBuiltin })?.currentMode ?? manager.displays.first?.currentMode,
                   active.isHiDPI {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundColor(.purple)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

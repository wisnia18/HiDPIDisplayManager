//
//  DisplayManager.swift
//  HiDPI Display Manager
//
//  Central hardware engine managing monitor discovery, deep mode inspection
//  (CoreGraphics & CGS), transactional mode switching with safety rollback,
//  virtual dummy display lifecycle, and gamma-based brightness.
//

import Foundation
@preconcurrency import CoreGraphics
import AppKit
import Combine
import os.log

// MARK: - Rollback State

/// Holds previous mode state when testing a newly applied resolution.
public struct SafetyRollbackState: Identifiable {
    public var id: CGDirectDisplayID { displayID }
    public let displayID: CGDirectDisplayID
    public let displayName: String
    public let previousCGMode: CGDisplayMode?
    public let previousCGSModeIndex: Int32?
    public let targetMode: DisplayModeItem
}

// MARK: - Display Manager Implementation

@MainActor
public final class DisplayManager: ObservableObject {
    
    // MARK: - Singleton Instance
    public static let shared = DisplayManager()
    
    // MARK: - Published Properties
    
    /// List of all active hardware & virtual displays.
    @Published public private(set) var displays: [DisplayScreen] = []
    
    /// Currently pending safety rollback if a resolution test is underway.
    @Published public private(set) var activeRollback: SafetyRollbackState? = nil
    
    /// Remaining seconds in the safety rollback countdown (starts at 15).
    @Published public private(set) var rollbackCountdown: Int = 15
    
    /// True if an active virtual dummy display is running.
    @Published public private(set) var isVirtualDisplayActive: Bool = false
    
    /// The display ID of the virtual dummy display, if active.
    @Published public private(set) var virtualDisplayID: CGDirectDisplayID? = nil
    
    /// Target physical display ID currently mirroring the virtual dummy display.
    @Published public private(set) var mirroredPhysicalDisplayID: CGDirectDisplayID? = nil
    
    /// Filter state for UI: show only HiDPI (Retina) modes.
    @Published public var showHiDPIOnly: Bool = false
    
    /// Informational or error banner text for the UI.
    @Published public var statusMessage: String? = nil
    
    // MARK: - Private Storage
    
    private let logger = Logger(subsystem: "com.hidpi.displaymanager", category: "DisplayManager")
    private var rollbackTimer: AnyCancellable?
    private var virtualDisplayInstance: CGVirtualDisplay?
    private var isReconfiguring = false
    
    // MARK: - Initialization & Hardware Hook
    
    private init() {
        registerReconfigurationCallback()
        refreshDisplays()
    }
    
    deinit {
        // Unregister C callback on teardown
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }
    
    // MARK: - Hardware Event Monitoring
    
    private func registerReconfigurationCallback() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)
        if result != .success {
            logger.error("Failed to register CGDisplayRegisterReconfigurationCallback: \(result.rawValue)")
        } else {
            logger.info("Successfully registered display hardware reconfiguration callback.")
        }
    }
    
    /// Called by the C callback when macOS detects monitor hotplug, wake, sleep, or mode shift.
    fileprivate func handleDisplayHardwareChange(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        // Ignore the begin configuration notification; react when configuration completes
        if flags.contains(.beginConfigurationFlag) {
            return
        }
        
        Task { @MainActor in
            self.logger.info("Display hardware change detected (flags: \(flags.rawValue)). Refreshing display list...")
            self.refreshDisplays()
        }
    }
    
    // MARK: - Display Enumeration
    
    /// Refreshes all connected displays, builds deep mode lists, and restores cached brightness.
    public func refreshDisplays() {
        var activeDisplayCount: UInt32 = 0
        var result = CGGetActiveDisplayList(0, nil, &activeDisplayCount)
        guard result == .success, activeDisplayCount > 0 else {
            self.displays = []
            return
        }
        
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(activeDisplayCount))
        result = CGGetActiveDisplayList(activeDisplayCount, &displayIDs, &activeDisplayCount)
        guard result == .success else {
            return
        }
        
        var updatedDisplays: [DisplayScreen] = []
        
        for displayID in displayIDs {
            let name = resolveDisplayName(displayID: displayID)
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let isMain = CGDisplayIsMain(displayID) != 0
            let isVirtual = (self.virtualDisplayID == displayID)
            let vendorID = CGDisplayVendorNumber(displayID)
            let modelID = CGDisplayModelNumber(displayID)
            let serialNum = CGDisplaySerialNumber(displayID)
            
            // Check mirroring status
            let primaryForMirror = CGDisplayPrimaryDisplay(displayID)
            let isMirrored = (primaryForMirror != kCGNullDirectDisplay && primaryForMirror != displayID)
            let mirroredID: CGDirectDisplayID? = isMirrored ? primaryForMirror : nil
            
            // Inspect all modes (both CoreGraphics and CGS)
            let availableModes = inspectAllModes(for: displayID)
            
            // Current active mode
            let currentMode = resolveCurrentMode(for: displayID, availableModes: availableModes)
            
            // Preserve current brightness if known, else default to 1.0 (100%)
            let existingBrightness = self.displays.first(where: { $0.id == displayID })?.brightness ?? 1.0
            
            let screen = DisplayScreen(
                id: displayID,
                name: name,
                isBuiltin: isBuiltin,
                isMain: isMain,
                isVirtual: isVirtual,
                vendorID: vendorID,
                modelID: modelID,
                serialNumber: serialNum,
                currentMode: currentMode,
                availableModes: availableModes,
                brightness: existingBrightness,
                isMirrored: isMirrored,
                mirroredDisplayID: mirroredID
            )
            
            updatedDisplays.append(screen)
        }
        
        // Sort: Main display first, then built-in, then external monitors
        self.displays = updatedDisplays.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            if a.isBuiltin != b.isBuiltin { return a.isBuiltin }
            return a.id < b.id
        }
    }
    
    // MARK: - Display Name Extraction
    
    private func resolveDisplayName(displayID: CGDirectDisplayID) -> String {
        // 1. If this is our virtual display, identify it clearly
        if displayID == virtualDisplayID {
            return "Virtual HiDPI Display (5K Canvas)"
        }
        
        // 2. Query NSScreen for modern localized display name
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                if screenNumber.uint32Value == displayID {
                    let name = screen.localizedName
                    if !name.isEmpty && name != "Unknown" {
                        return name
                    }
                }
            }
        }
        
        // 3. Fallback based on hardware characteristics
        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Retina Display"
        }
        
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        return "External Display (\(String(format: "0x%04X:0x%04X", vendor, model)))"
    }
    
    // MARK: - Deep Display Mode Inspection
    
    /// Queries both `CGDisplayCopyAllDisplayModes` (with hidden modes enabled)
    /// and private `CGS` WindowServer APIs to unlock fractional HiDPI modes.
    private func inspectAllModes(for displayID: CGDirectDisplayID) -> [DisplayModeItem] {
        var modeMap: [String: DisplayModeItem] = [:]
        
        // 1. Query public CoreGraphics modes with kCGDisplayShowDuplicateLowResolutionModes flag
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        if let modeList = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] {
            let activeCGMode = CGDisplayCopyDisplayMode(displayID)
            
            for cgMode in modeList {
                // Filter out unusable or interlaced modes
                let ioFlags = cgMode.ioFlags
                let isInterlaced = (ioFlags & 0x00000002) != 0
                if isInterlaced { continue }
                if cgMode.width < 800 || cgMode.height < 600 { continue }
                
                let isActive = (activeCGMode != nil &&
                                activeCGMode?.width == cgMode.width &&
                                activeCGMode?.height == cgMode.height &&
                                activeCGMode?.pixelWidth == cgMode.pixelWidth &&
                                activeCGMode?.pixelHeight == cgMode.pixelHeight &&
                                abs((activeCGMode?.refreshRate ?? 0) - cgMode.refreshRate) < 0.5)
                
                let item = DisplayModeItem(displayID: displayID, cgMode: cgMode, isActive: isActive)
                let key = "\(item.logicalWidth)x\(item.logicalHeight)_\(item.pixelWidth)x\(item.pixelHeight)_\(item.roundedRefreshRate)_\(item.isHiDPI)"
                
                if modeMap[key] == nil {
                    modeMap[key] = item
                }
            }
        }
        
        // 2. Query Private CGS APIs via bridging header for hidden fractional HiDPI modes
        var cgsCount: Int32 = 0
        if HDMCGSGetNumberOfDisplayModes(displayID, &cgsCount), cgsCount > 0 {
            var activeCGSIndex: Int32 = -1
            _ = HDMCGSGetCurrentDisplayMode(displayID, &activeCGSIndex)
            
            for index in 0..<cgsCount {
                var desc = CGSDisplayModeDescription()
                if HDMCGSGetDisplayModeDescription(displayID, index, &desc) {
                    // Check flags: skip interlaced (0x2)
                    if (desc.flags & 0x00000002) != 0 { continue }
                    if desc.width < 800 || desc.height < 600 { continue }
                    
                    let isActive = (index == activeCGSIndex)
                    let item = DisplayModeItem(displayID: displayID, cgsDesc: desc, modeIndex: index, isActive: isActive)
                    let key = "\(item.logicalWidth)x\(item.logicalHeight)_\(item.pixelWidth)x\(item.pixelHeight)_\(item.roundedRefreshRate)_\(item.isHiDPI)"
                    
                    if let existing = modeMap[key] {
                        // Merge CGS mode index into existing item if CGS offers direct WindowServer index
                        if existing.cgsModeIndex == nil {
                            modeMap[key] = DisplayModeItem(
                                displayID: displayID,
                                logicalWidth: existing.logicalWidth,
                                logicalHeight: existing.logicalHeight,
                                pixelWidth: existing.pixelWidth,
                                pixelHeight: existing.pixelHeight,
                                refreshRate: existing.refreshRate,
                                scaleFactor: existing.scaleFactor,
                                isHiDPI: existing.isHiDPI,
                                isInterlaced: existing.isInterlaced,
                                isActive: existing.isActive || isActive,
                                cgsModeIndex: index,
                                underlyingCGMode: existing.underlyingCGMode
                            )
                        }
                    } else {
                        modeMap[key] = item
                    }
                }
            }
        }
        
        // Convert to array and sort descending by logical width, logical height, then refresh rate
        let sortedModes = Array(modeMap.values).sorted { a, b in
            if a.logicalWidth != b.logicalWidth {
                return a.logicalWidth > b.logicalWidth
            }
            if a.logicalHeight != b.logicalHeight {
                return a.logicalHeight > b.logicalHeight
            }
            if a.isHiDPI != b.isHiDPI {
                return a.isHiDPI && !b.isHiDPI
            }
            return a.roundedRefreshRate > b.roundedRefreshRate
        }
        
        return sortedModes
    }
    
    private func resolveCurrentMode(for displayID: CGDirectDisplayID, availableModes: [DisplayModeItem]) -> DisplayModeItem? {
        if let currentCGMode = CGDisplayCopyDisplayMode(displayID) {
            let activeRate = currentCGMode.refreshRate
            let roundedRate = Int(activeRate.rounded())
            
            // Match in availableModes
            if let matched = availableModes.first(where: {
                $0.logicalWidth == currentCGMode.width &&
                $0.logicalHeight == currentCGMode.height &&
                $0.pixelWidth == currentCGMode.pixelWidth &&
                $0.pixelHeight == currentCGMode.pixelHeight &&
                abs($0.roundedRefreshRate - roundedRate) <= 1
            }) {
                return matched
            }
            
            return DisplayModeItem(displayID: displayID, cgMode: currentCGMode, isActive: true)
        }
        return nil
    }
    
    // MARK: - Transactional Resolution Switching & Safety Rollback
    
    /// Applies a requested display mode and initiates a 15-second safety confirmation timer.
    public func setDisplayMode(mode: DisplayModeItem, for screen: DisplayScreen) {
        guard !isReconfiguring else { return }
        
        let previousCGMode = CGDisplayCopyDisplayMode(screen.id)
        var previousCGSIndex: Int32 = -1
        _ = HDMCGSGetCurrentDisplayMode(screen.id, &previousCGSIndex)
        
        let rollback = SafetyRollbackState(
            displayID: screen.id,
            displayName: screen.name,
            previousCGMode: previousCGMode,
            previousCGSModeIndex: previousCGSIndex >= 0 ? previousCGSIndex : nil,
            targetMode: mode
        )
        
        // Execute hardware configuration switch
        let success = executeModeSwitch(displayID: screen.id, mode: mode)
        if success {
            self.activeRollback = rollback
            self.rollbackCountdown = 15
            self.startRollbackTimer()
            self.statusMessage = "Mode applied: \(mode.resolutionTitle) @ \(mode.roundedRefreshRate)Hz."
            self.refreshDisplays()
        } else {
            self.statusMessage = "Failed to switch resolution for \(screen.name)."
            self.logger.error("Failed to switch display mode: \(mode.resolutionTitle)")
        }
    }
    
    /// Switches refresh rate for current resolution while preserving pixel dimensions and HiDPI state.
    public func setRefreshRate(_ targetRate: Int, for screen: DisplayScreen) {
        guard let current = screen.currentMode else { return }
        
        // 1. Try finding mode with exact resolution + HiDPI flag matching the target rate
        if let target = screen.availableModes.first(where: {
            $0.logicalWidth == current.logicalWidth &&
            $0.logicalHeight == current.logicalHeight &&
            $0.isHiDPI == current.isHiDPI &&
            $0.roundedRefreshRate == targetRate
        }) {
            setDisplayMode(mode: target, for: screen)
            return
        }
        
        // 2. Try finding mode with same logical dimensions matching the target rate
        if let target = screen.availableModes.first(where: {
            $0.logicalWidth == current.logicalWidth &&
            $0.logicalHeight == current.logicalHeight &&
            $0.roundedRefreshRate == targetRate
        }) {
            setDisplayMode(mode: target, for: screen)
        }
    }
    
    /// Finds the best mode matching target resolution while preserving the current refresh rate (e.g. 160Hz/144Hz).
    public func findBestMode(
        targetWidth: Int,
        targetHeight: Int,
        preferHiDPI: Bool,
        desiredRate: Int,
        for screen: DisplayScreen
    ) -> DisplayModeItem? {
        let candidates = screen.availableModes.filter {
            $0.logicalWidth == targetWidth &&
            $0.logicalHeight == targetHeight &&
            ($0.isHiDPI == preferHiDPI || !preferHiDPI)
        }
        
        // Priority 1: Exact refresh rate match
        if let exact = candidates.first(where: { $0.roundedRefreshRate == desiredRate }) {
            return exact
        }
        
        // Priority 2: Highest available refresh rate for this resolution
        if let highest = candidates.sorted(by: { $0.roundedRefreshRate > $1.roundedRefreshRate }).first {
            return highest
        }
        
        // Fallback: any mode with same dimensions
        return screen.availableModes.first(where: { $0.logicalWidth == targetWidth && $0.logicalHeight == targetHeight })
    }
    
    /// Low-level configuration commit using CoreGraphics and CGS.
    private func executeModeSwitch(displayID: CGDirectDisplayID, mode: DisplayModeItem) -> Bool {
        var configRef: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&configRef)
        guard beginErr == .success, let config = configRef else {
            logger.error("CGBeginDisplayConfiguration failed: \(beginErr.rawValue)")
            return false
        }
        
        isReconfiguring = true
        defer { isReconfiguring = false }
        
        // Option A: Use CGSConfigureDisplayMode if mode has low-level WindowServer index
        if let cgsIndex = mode.cgsModeIndex {
            _ = HDMCGSConfigureDisplayMode(config, displayID, cgsIndex)
        }
        // Option B: Use public CGConfigureDisplayWithDisplayMode
        else if let cgMode = mode.underlyingCGMode {
            let configErr = CGConfigureDisplayWithDisplayMode(config, displayID, cgMode, nil)
            if configErr != .success {
                logger.error("CGConfigureDisplayWithDisplayMode failed: \(configErr.rawValue)")
                CGCancelDisplayConfiguration(config)
                return false
            }
        } else {
            // Find best matching CGDisplayMode on the fly
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            if let modeList = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] {
                if let match = modeList.first(where: {
                    $0.width == mode.logicalWidth &&
                    $0.height == mode.logicalHeight &&
                    $0.pixelWidth == mode.pixelWidth &&
                    $0.pixelHeight == mode.pixelHeight
                }) {
                    _ = CGConfigureDisplayWithDisplayMode(config, displayID, match, nil)
                }
            }
        }
        
        let completeErr = CGCompleteDisplayConfiguration(config, .permanently)
        if completeErr != .success {
            logger.error("CGCompleteDisplayConfiguration failed: \(completeErr.rawValue)")
            return false
        }
        
        return true
    }
    
    /// Starts the 15-second countdown timer. Reverts if unconfirmed.
    private func startRollbackTimer() {
        rollbackTimer?.cancel()
        rollbackTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.rollbackCountdown > 1 {
                    self.rollbackCountdown -= 1
                } else {
                    self.logger.warning("Rollback countdown reached 0. Automatically reverting resolution.")
                    self.revertToPreviousResolution()
                }
            }
    }
    
    /// User clicks "Keep Changes": commits new mode and cancels rollback timer.
    public func confirmResolutionChange() {
        rollbackTimer?.cancel()
        rollbackTimer = nil
        activeRollback = nil
        statusMessage = "Resolution confirmed successfully."
    }
    
    /// Reverts back to the previous working display mode.
    public func revertToPreviousResolution() {
        rollbackTimer?.cancel()
        rollbackTimer = nil
        
        guard let rollback = activeRollback else { return }
        self.activeRollback = nil
        self.statusMessage = "Resolution reverted to previous working mode."
        
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            return
        }
        
        if let cgsIndex = rollback.previousCGSModeIndex {
            _ = HDMCGSConfigureDisplayMode(config, rollback.displayID, cgsIndex)
        } else if let prevCG = rollback.previousCGMode {
            _ = CGConfigureDisplayWithDisplayMode(config, rollback.displayID, prevCG, nil)
        }
        
        _ = CGCompleteDisplayConfiguration(config, .permanently)
        self.refreshDisplays()
    }
    
    // MARK: - 4K Quick Preset Applicator
    
    public func applyPreset(_ preset: Display4KPreset, to screen: DisplayScreen) {
        if let mode = screen.matchingMode(for: preset) {
            setDisplayMode(mode: mode, for: screen)
        } else {
            // If the preset is HiDPI 1440p but the physical display has no native 1440p HiDPI mode,
            // guide the user or offer virtual dummy display mirroring.
            statusMessage = "\(preset.title) not directly exposed by monitor. Use Virtual Dummy Display Mirroring."
            logger.warning("Preset \(preset.rawValue) not found in direct mode list.")
        }
    }
    
    // MARK: - Hardware DDC & Native Display Brightness
    
    private typealias DisplayServicesSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    
    /// Adjusts display brightness using true hardware control:
    /// - For external monitors: physical hardware backlight lamps via DDC/CI (VCP 0x10) like MonitorControl.
    /// - For built-in Retina displays: native Apple DisplayServices backlight control.
    public func setBrightness(_ value: Float, for screen: DisplayScreen) {
        let clamped = max(0.0, min(1.0, value))
        
        if screen.isBuiltin {
            // Built-in MacBook Retina screen: Apple DisplayServices
            if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
               let sym = dlsym(handle, "DisplayServicesSetBrightness") {
                let fn = unsafeBitCast(sym, to: DisplayServicesSetBrightnessFn.self)
                _ = fn(screen.id, clamped)
            }
        } else {
            // External monitor: Physical Hardware Backlight via MonitorControl DDC (VCP 0x10)
            let percent = UInt8(round(clamped * 100.0))
            Arm64DDC.shared.setBrightness(percent: percent)
            
            // Keep GPU gamma table at 1.0 (neutral 100% full contrast, no software color degradation)
            _ = CGSetDisplayTransferByFormula(
                screen.id,
                0.0, 1.0, 1.0,
                0.0, 1.0, 1.0,
                0.0, 1.0, 1.0
            )
        }
        
        if let index = displays.firstIndex(where: { $0.id == screen.id }) {
            displays[index].brightness = clamped
        }
    }
    
    // MARK: - Virtual Dummy Display & Mirroring Engine
    
    /// Spawns a high-resolution 5K (5120x2880) virtual display with HiDPI enabled.
    public func createVirtualDisplay() -> Bool {
        guard virtualDisplayInstance == nil else {
            self.statusMessage = "Virtual display is already active."
            return true
        }
        
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "HiDPI Virtual Display"
        descriptor.maxPixelsWide = 5120
        descriptor.maxPixelsHigh = 2880
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340) // 27-inch 16:9 equivalent
        descriptor.serialNum = 0x5120
        descriptor.productID = 0x5120
        descriptor.vendorID = 0x05AC // Apple vendor tag
        descriptor.setDispatchQueue(DispatchQueue.main)
        
        guard let virtualDisp = CGVirtualDisplay(descriptor: descriptor) else {
            self.statusMessage = "Failed to create CGVirtualDisplay. Ensure SkyLight/CoreGraphics permissions."
            self.logger.error("Failed to allocate CGVirtualDisplay.")
            return false
        }
        
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        
        let mode5K = CGVirtualDisplayMode(width: 5120, height: 2880, refreshRate: 60.0)
        let mode4K = CGVirtualDisplayMode(width: 3840, height: 2160, refreshRate: 60.0)
        let modeQHD = CGVirtualDisplayMode(width: 2560, height: 1440, refreshRate: 60.0)
        settings.modes = [mode5K, mode4K, modeQHD]
        
        let applied = virtualDisp.apply(settings)
        if !applied {
            self.logger.warning("CGVirtualDisplay applySettings returned false; display created anyway.")
        }
        
        self.virtualDisplayInstance = virtualDisp
        self.virtualDisplayID = virtualDisp.displayID
        self.isVirtualDisplayActive = true
        self.statusMessage = "Virtual HiDPI Display created (ID: \(virtualDisp.displayID))."
        
        // Allow WindowServer 300ms to integrate the new display before refreshing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.refreshDisplays()
        }
        
        return true
    }
    
    /// Tears down the virtual display and restores normal screen topology.
    public func destroyVirtualDisplay() {
        guard virtualDisplayID != nil else { return }
        
        // If mirroring is active, disable mirroring first
        if let physicalID = mirroredPhysicalDisplayID {
            toggleMirrorVirtualDisplay(to: physicalID, enable: false)
        }
        
        self.virtualDisplayInstance = nil
        self.virtualDisplayID = nil
        self.isVirtualDisplayActive = false
        self.mirroredPhysicalDisplayID = nil
        self.statusMessage = "Virtual Display destroyed."
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.refreshDisplays()
        }
    }
    
    /// Hardware-mirrors the Virtual HiDPI display onto an external physical 4K monitor.
    /// This forces macOS WindowServer to render a 2560x1440 HiDPI desktop at 5120x2880,
    /// downscaled in hardware to the 4K panel with razor-sharp text and graphics.
    public func toggleMirrorVirtualDisplay(to physicalDisplayID: CGDirectDisplayID, enable: Bool) {
        guard let virtualID = virtualDisplayID else {
            self.statusMessage = "Please spawn a Virtual Display first."
            return
        }
        
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            self.statusMessage = "Failed to begin display configuration."
            return
        }
        
        if enable {
            // Mirror physical monitor onto the virtual display master
            CGConfigureDisplayMirrorOfDisplay(config, physicalDisplayID, virtualID)
            self.mirroredPhysicalDisplayID = physicalDisplayID
        } else {
            // Break mirror: set master to kCGNullDirectDisplay
            CGConfigureDisplayMirrorOfDisplay(config, physicalDisplayID, kCGNullDirectDisplay)
            self.mirroredPhysicalDisplayID = nil
        }
        
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result == .success {
            self.statusMessage = enable ? "Hardware Mirroring Enabled." : "Hardware Mirroring Disabled."
        } else {
            self.statusMessage = "Mirroring configuration failed: \(result.rawValue)"
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.refreshDisplays()
        }
    }
}

// MARK: - Global C Reconfiguration Callback Function

private func displayReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    // Ignore begin configuration notification
    if flags.contains(.beginConfigurationFlag) {
        return
    }
    Task { @MainActor in
        guard let context = userInfo else { return }
        let manager = Unmanaged<DisplayManager>.fromOpaque(context).takeUnretainedValue()
        manager.handleDisplayHardwareChange(display: display, flags: flags)
    }
}

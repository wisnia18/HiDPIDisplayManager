//
//  DisplayModels.swift
//  HiDPI Display Manager
//
//  Data models representing physical and virtual displays, display modes,
//  and resolution presets for macOS displays.
//

import Foundation
@preconcurrency import CoreGraphics
import AppKit

// MARK: - Display Mode Model

/// Represents an individual resolution / refresh rate mode for a display.
/// Supports both native CoreGraphics `CGDisplayMode` and low-level `CGS` WindowServer modes.
public struct DisplayModeItem: Identifiable, Hashable, Sendable {
    
    /// Unique identifier for UI binding and list reconciliation.
    public var id: String {
        return "\(displayID)_\(logicalWidth)x\(logicalHeight)_\(pixelWidth)x\(pixelHeight)_\(roundedRefreshRate)Hz_\(isHiDPI ? "hidpi" : "1x")_\(cgsModeIndex ?? -1)"
    }
    
    /// Associated display ID.
    public let displayID: CGDirectDisplayID
    
    /// Logical width in macOS points (determines UI scale & desktop canvas size).
    public let logicalWidth: Int
    
    /// Logical height in macOS points.
    public let logicalHeight: Int
    
    /// Physical backing width in hardware pixels (determines rendering sharpness).
    public let pixelWidth: Int
    
    /// Physical backing height in hardware pixels.
    public let pixelHeight: Int
    
    /// Raw floating-point refresh rate reported by the display driver.
    public let refreshRate: Double
    
    /// Backing scale factor (e.g. 1.0 for standard @1x, 2.0 for Retina @2x).
    public let scaleFactor: Double
    
    /// True if rendering at high-density (Retina / HiDPI @2x).
    public let isHiDPI: Bool
    
    /// True if this is an interlaced mode (which typically produces flicker and should be filtered out).
    public let isInterlaced: Bool
    
    /// True if this mode is currently active on the display.
    public let isActive: Bool
    
    /// Private WindowServer mode index used by `CGSConfigureDisplayMode`, if discovered via CGS.
    public let cgsModeIndex: Int32?
    
    /// Underlying `CGDisplayMode` pointer if obtained from public CoreGraphics API.
    public let underlyingCGMode: CGDisplayMode?

    // MARK: - Initializers
    
    /// Initialize from a public `CGDisplayMode`
    public init(displayID: CGDirectDisplayID, cgMode: CGDisplayMode, isActive: Bool = false) {
        self.displayID = displayID
        self.logicalWidth = cgMode.width
        self.logicalHeight = cgMode.height
        self.pixelWidth = cgMode.pixelWidth
        self.pixelHeight = cgMode.pixelHeight
        self.refreshRate = cgMode.refreshRate
        self.underlyingCGMode = cgMode
        self.cgsModeIndex = nil
        self.isActive = isActive
        
        let calculatedScale = Double(cgMode.pixelWidth) / max(Double(cgMode.width), 1.0)
        self.scaleFactor = calculatedScale
        self.isHiDPI = (calculatedScale >= 1.5) || (cgMode.pixelWidth >= cgMode.width * 2)
        
        // Check interlaced flag: kDisplayModeInterlacedFlag = 0x00000002
        let ioFlags = cgMode.ioFlags
        self.isInterlaced = (ioFlags & 0x00000002) != 0
    }
    
    /// Initialize from a private WindowServer `CGSDisplayModeDescription`
    public init(displayID: CGDirectDisplayID, cgsDesc: CGSDisplayModeDescription, modeIndex: Int32, isActive: Bool = false) {
        self.displayID = displayID
        self.logicalWidth = Int(cgsDesc.width)
        self.logicalHeight = Int(cgsDesc.height)
        
        let density = Double(cgsDesc.density)
        let effectiveScale = density > 0.0 ? density : 1.0
        self.scaleFactor = effectiveScale
        
        self.pixelWidth = Int(Double(cgsDesc.width) * effectiveScale)
        self.pixelHeight = Int(Double(cgsDesc.height) * effectiveScale)
        self.refreshRate = Double(cgsDesc.refreshRate)
        self.isHiDPI = effectiveScale >= 1.5
        
        // IODisplayModeFlags: 0x00000002 is kDisplayModeInterlacedFlag
        self.isInterlaced = (cgsDesc.flags & 0x00000002) != 0
        self.cgsModeIndex = modeIndex
        self.underlyingCGMode = nil
        self.isActive = isActive
    }

    /// Full custom initializer for virtual or synthetic modes
    public init(
        displayID: CGDirectDisplayID,
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        scaleFactor: Double,
        isHiDPI: Bool,
        isInterlaced: Bool,
        isActive: Bool,
        cgsModeIndex: Int32? = nil,
        underlyingCGMode: CGDisplayMode? = nil
    ) {
        self.displayID = displayID
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.scaleFactor = scaleFactor
        self.isHiDPI = isHiDPI
        self.isInterlaced = isInterlaced
        self.isActive = isActive
        self.cgsModeIndex = cgsModeIndex
        self.underlyingCGMode = underlyingCGMode
    }
    
    // MARK: - Computed Display Helpers
    
    /// Standardized, rounded refresh rate (e.g. 59.94Hz -> 60Hz, 143.98Hz -> 144Hz)
    public var roundedRefreshRate: Int {
        if refreshRate <= 0.0 { return 60 }
        let rounded = Int((refreshRate).rounded())
        return rounded > 0 ? rounded : 60
    }
    
    /// Human-friendly resolution label (e.g. "2560 x 1440")
    public var resolutionTitle: String {
        return "\(logicalWidth) × \(logicalHeight)"
    }
    
    /// Subtitle detailing backing resolution and HiDPI scale (e.g. "5120 × 2880 px (HiDPI @2x)")
    public var backingDetail: String {
        if isHiDPI {
            return "\(pixelWidth) × \(pixelHeight) px (Retina @2x)"
        } else {
            return "\(pixelWidth) × \(pixelHeight) px (Standard @1x)"
        }
    }
    
    /// Combined string for quick reading in dropdowns or lists
    public var fullDescription: String {
        return "\(resolutionTitle) @ \(roundedRefreshRate)Hz \(isHiDPI ? "• Retina" : "")"
    }
    
    /// Aspect ratio simplification (e.g. "16:9", "16:10", "21:9", "32:9", "4:3")
    public var aspectRatioString: String {
        let gcdVal = gcd(logicalWidth, logicalHeight)
        let w = logicalWidth / gcdVal
        let h = logicalHeight / gcdVal
        
        // Recognize common standard ratios even with slight rounding offsets
        let ratio = Double(logicalWidth) / Double(max(logicalHeight, 1))
        if abs(ratio - 16.0 / 9.0) < 0.02 { return "16:9 Widescreen" }
        if abs(ratio - 16.0 / 10.0) < 0.02 { return "16:10 Standard" }
        if abs(ratio - 21.0 / 9.0) < 0.05 { return "21:9 Ultrawide" }
        if abs(ratio - 32.0 / 9.0) < 0.05 { return "32:9 Super Ultrawide" }
        if abs(ratio - 4.0 / 3.0) < 0.02 { return "4:3 Classic" }
        if abs(ratio - 3.0 / 2.0) < 0.02 { return "3:2" }
        
        return "\(w):\(h)"
    }
    
    // MARK: - Hashable & Equatable
    
    public static func == (lhs: DisplayModeItem, rhs: DisplayModeItem) -> Bool {
        return lhs.displayID == rhs.displayID
            && lhs.logicalWidth == rhs.logicalWidth
            && lhs.logicalHeight == rhs.logicalHeight
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.roundedRefreshRate == rhs.roundedRefreshRate
            && lhs.isHiDPI == rhs.isHiDPI
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(displayID)
        hasher.combine(logicalWidth)
        hasher.combine(logicalHeight)
        hasher.combine(pixelWidth)
        hasher.combine(pixelHeight)
        hasher.combine(roundedRefreshRate)
        hasher.combine(isHiDPI)
    }
}

// MARK: - Greatest Common Divisor Helper

private func gcd(_ a: Int, _ b: Int) -> Int {
    var x = abs(a)
    var y = abs(b)
    while y != 0 {
        let temp = y
        y = x % y
        x = temp
    }
    return max(x, 1)
}

// MARK: - 4K Quick Presets

/// High-priority resolution presets tailored for 4K and external displays.
public enum Display4KPreset: String, CaseIterable, Identifiable {
    case hiDPI1080p = "1080p HiDPI"
    case hiDPI1440p = "1440p HiDPI"
    case native4K = "4K Native"
    
    public var id: String { rawValue }
    
    public var targetWidth: Int {
        switch self {
        case .hiDPI1080p: return 1920
        case .hiDPI1440p: return 2560
        case .native4K:   return 3840
        }
    }
    
    public var targetHeight: Int {
        switch self {
        case .hiDPI1080p: return 1080
        case .hiDPI1440p: return 1440
        case .native4K:   return 2160
        }
    }
    
    public var requiresHiDPI: Bool {
        switch self {
        case .hiDPI1080p, .hiDPI1440p: return true
        case .native4K: return false
        }
    }
    
    public var title: String {
        switch self {
        case .hiDPI1080p: return "1080p HiDPI"
        case .hiDPI1440p: return "1440p HiDPI"
        case .native4K:   return "Native 4K"
        }
    }
    
    public var subtitle: String {
        switch self {
        case .hiDPI1080p: return "1920 × 1080 @2x • Large UI, Crisp"
        case .hiDPI1440p: return "2560 × 1440 @2x • Balanced (Recommended)"
        case .native4K:   return "3840 × 2160 @1x • Maximum Workspace"
        }
    }
}

// MARK: - Display Screen Model

/// Represents a connected hardware screen or active virtual dummy display.
public struct DisplayScreen: Identifiable, Hashable, Sendable {
    
    /// Hardware display identifier from CoreGraphics.
    public let id: CGDirectDisplayID
    
    /// User-friendly name (e.g., "LG UltraFine 4K", "Built-in Retina Display", "Virtual HiDPI Display").
    public let name: String
    
    /// True if this display is an Apple Silicon internal laptop screen.
    public let isBuiltin: Bool
    
    /// True if this is the primary display hosting the menu bar and origin (0,0).
    public let isMain: Bool
    
    /// True if this is a software-spawned `CGVirtualDisplay`.
    public let isVirtual: Bool
    
    /// Hardware vendor ID (from IOKit or CGDisplayVendorNumber).
    public let vendorID: UInt32
    
    /// Hardware model/product ID.
    public let modelID: UInt32
    
    /// Serial number if reported by EDID.
    public let serialNumber: UInt32
    
    /// Currently active display mode.
    public var currentMode: DisplayModeItem?
    
    /// All validated, deduplicated display modes available for this screen.
    public var availableModes: [DisplayModeItem]
    
    /// Current gamma-based brightness (0.0 to 1.0).
    public var brightness: Float
    
    /// True if this display is currently mirroring another display.
    public var isMirrored: Bool
    
    /// ID of the display being mirrored, if mirroring is active.
    public var mirroredDisplayID: CGDirectDisplayID?
    
    // MARK: - Initializer
    
    public init(
        id: CGDirectDisplayID,
        name: String,
        isBuiltin: Bool,
        isMain: Bool,
        isVirtual: Bool = false,
        vendorID: UInt32 = 0,
        modelID: UInt32 = 0,
        serialNumber: UInt32 = 0,
        currentMode: DisplayModeItem? = nil,
        availableModes: [DisplayModeItem] = [],
        brightness: Float = 1.0,
        isMirrored: Bool = false,
        mirroredDisplayID: CGDirectDisplayID? = nil
    ) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.isVirtual = isVirtual
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
        self.currentMode = currentMode
        self.availableModes = availableModes
        self.brightness = brightness
        self.isMirrored = isMirrored
        self.mirroredDisplayID = mirroredDisplayID
    }
    
    // MARK: - Mode Grouping & Presets
    
    /// Returns only HiDPI modes.
    public var hidpiModes: [DisplayModeItem] {
        return availableModes.filter { $0.isHiDPI }
    }
    
    /// Returns available modes grouped by their aspect ratio label, sorted by resolution descending.
    public var modesGroupedByAspectRatio: [(aspectRatio: String, modes: [DisplayModeItem])] {
        let grouped = Dictionary(grouping: availableModes) { $0.aspectRatioString }
        return grouped
            .map { (aspectRatio: $0.key, modes: $0.value) }
            .sorted { groupA, groupB in
                let maxA = groupA.modes.first?.logicalWidth ?? 0
                let maxB = groupB.modes.first?.logicalWidth ?? 0
                return maxA > maxB
            }
    }
    
    /// Find the best matching mode for a given 4K quick preset.
    public func matchingMode(for preset: Display4KPreset) -> DisplayModeItem? {
        // First attempt: exact logical match + HiDPI flag match
        let directMatch = availableModes.first { mode in
            mode.logicalWidth == preset.targetWidth &&
            mode.logicalHeight == preset.targetHeight &&
            mode.isHiDPI == preset.requiresHiDPI
        }
        if let directMatch = directMatch {
            return directMatch
        }
        
        // Second attempt: exact logical match regardless of HiDPI flag (if HiDPI not found)
        return availableModes.first { mode in
            mode.logicalWidth == preset.targetWidth &&
            mode.logicalHeight == preset.targetHeight
        }
    }
    
    /// Returns unique refresh rates available for the currently selected resolution.
    public var availableRefreshRatesForCurrentResolution: [Int] {
        guard let current = currentMode else { return [60] }
        let rates = availableModes
            .filter { $0.logicalWidth == current.logicalWidth && $0.logicalHeight == current.logicalHeight && $0.isHiDPI == current.isHiDPI }
            .map { $0.roundedRefreshRate }
        let set = Set(rates)
        return set.sorted(by: >)
    }
    
    // MARK: - Hashable & Equatable
    
    public static func == (lhs: DisplayScreen, rhs: DisplayScreen) -> Bool {
        return lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.currentMode == rhs.currentMode
            && lhs.brightness == rhs.brightness
            && lhs.isMirrored == rhs.isMirrored
            && lhs.availableModes.count == rhs.availableModes.count
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(currentMode)
        hasher.combine(brightness)
        hasher.combine(isMirrored)
    }
}

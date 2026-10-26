//
//  AudioManager.swift
//  HiDPI Display Manager
//
//  Audio output device manager, MonitorControl Apple Silicon DDC volume engine,
//  and universal keyboard volume key interception (Media Keys & F10/F11/F12).
//

import Foundation
import CoreAudio
import AppKit
import AudioToolbox
import ApplicationServices
import IOKit
import Combine
import os.log

// MARK: - Audio Output Device Model

public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let isBuiltin: Bool
    public let isDefault: Bool
    public let isVolumeSettable: Bool
    public let transportType: String
}

// MARK: - Audio Manager Implementation

@MainActor
public final class AudioManager: ObservableObject {
    
    public static let shared = AudioManager()
    
    // MARK: - Published Properties
    
    /// All detected audio output devices (e.g. MacBook Pro Speakers, 27M2N3800A HDMI).
    @Published public private(set) var outputDevices: [AudioOutputDevice] = []
    
    /// The current system default audio output device ID.
    @Published public private(set) var defaultOutputDeviceID: AudioDeviceID = 0
    
    /// Target device ID that keyboard volume keys should adjust.
    @Published public var controlledDeviceID: AudioDeviceID = 0 {
        didSet {
            updateVolumeState()
        }
    }
    
    /// Current volume of the controlled device (0.0 ... 1.0).
    @Published public var volume: Float = 0.5 {
        didSet {
            if isUpdatingInternally { return }
            applyVolumeToDevice(volume)
        }
    }
    
    /// Mute state of the controlled device.
    @Published public var isMuted: Bool = false
    
    /// True if media key listening is enabled for external keyboards.
    @Published public var isKeyboardInterceptEnabled: Bool = true {
        didSet {
            restartKeyboardTap()
        }
    }
    
    /// If true, keyboard volume keys always adjust MacBook Pro speakers
    /// even when sound output is directed to external monitor.
    @Published public var alwaysControlMacBookSpeakers: Bool = false {
        didSet {
            UserDefaults.standard.set(alwaysControlMacBookSpeakers, forKey: "AlwaysControlMacBookSpeakers")
            if alwaysControlMacBookSpeakers, let builtin = outputDevices.first(where: { $0.isBuiltin }) {
                controlledDeviceID = builtin.id
            } else {
                controlledDeviceID = defaultOutputDeviceID
            }
        }
    }
    
    /// True if macOS Accessibility permission is granted to intercept global keystrokes.
    @Published public private(set) var isAccessibilityGranted: Bool = false
    
    // MARK: - Private State
    
    private let logger = Logger(subsystem: "com.hidpi.displaymanager", category: "AudioManager")
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var eventTapPort: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var isUpdatingInternally = false
    
    // Cached volume for DDC external monitors
    private var externalMonitorVolume: Float {
        get {
            let saved = UserDefaults.standard.float(forKey: "ExternalMonitorDDCVolume")
            return saved > 0.0 ? saved : 0.5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ExternalMonitorDDCVolume")
        }
    }
    private var preMuteVolume: Float = 0.5
    
    // MARK: - Initialization
    
    private init() {
        self.alwaysControlMacBookSpeakers = UserDefaults.standard.bool(forKey: "AlwaysControlMacBookSpeakers")
        checkAccessibility()
        refreshDevices()
        setupKeyboardInterception()
        registerCoreAudioListener()
    }
    
    deinit {
        if let tap = eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let rls = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), rls, .commonModes)
            CFRunLoopSourceInvalidate(rls)
        }
        if let g = globalEventMonitor { NSEvent.removeMonitor(g) }
        if let l = localEventMonitor { NSEvent.removeMonitor(l) }
    }
    
    // MARK: - Accessibility Permissions
    
    public func checkAccessibility() {
        self.isAccessibilityGranted = AXIsProcessTrusted()
    }
    
    public func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        
        // Also open System Settings directly to Privacy & Security -> Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.checkAccessibility()
            self.restartKeyboardTap()
        }
    }
    
    // MARK: - Device Enumeration
    
    public func refreshDevices() {
        checkAccessibility()
        
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let errSize = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize)
        guard errSize == noErr, propertySize > 0 else { return }
        
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceIDs) == noErr else { return }
        
        // Find default output device
        var defaultID: AudioDeviceID = 0
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &defaultSize, &defaultID)
        self.defaultOutputDeviceID = defaultID
        
        var list: [AudioOutputDevice] = []
        for id in deviceIDs {
            var streamSize: UInt32 = 0
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) == noErr && streamSize > 0 {
                let name = queryDeviceName(id: id)
                let isBuiltin = name.localizedCaseInsensitiveContains("MacBook") ||
                                name.localizedCaseInsensitiveContains("Internal") ||
                                name.localizedCaseInsensitiveContains("Built-in")
                let isSettable = checkVolumeSettable(id: id)
                let transport = queryTransportType(id: id)
                
                list.append(AudioOutputDevice(
                    id: id,
                    name: name,
                    isBuiltin: isBuiltin,
                    isDefault: (id == defaultID),
                    isVolumeSettable: isSettable,
                    transportType: transport
                ))
            }
        }
        
        // De-duplicate devices sharing the same name (e.g. multi-channel HDMI endpoints),
        // prioritizing the active default device.
        var uniqueDevices: [AudioOutputDevice] = []
        for dev in list {
            if let existingIndex = uniqueDevices.firstIndex(where: { $0.name == dev.name }) {
                if dev.isDefault {
                    uniqueDevices[existingIndex] = dev
                }
            } else {
                uniqueDevices.append(dev)
            }
        }
        
        self.outputDevices = uniqueDevices
        
        if alwaysControlMacBookSpeakers, let builtin = uniqueDevices.first(where: { $0.isBuiltin }) {
            self.controlledDeviceID = builtin.id
        } else if controlledDeviceID == 0 || !uniqueDevices.contains(where: { $0.id == controlledDeviceID }) {
            self.controlledDeviceID = defaultID != 0 ? defaultID : (uniqueDevices.first?.id ?? 0)
        }
        
        updateVolumeState()
    }
    
    // MARK: - Output Device Switching
    
    public func setDefaultOutputDevice(id: AudioDeviceID) {
        var deviceID = id
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            propertySize,
            &deviceID
        )
        if err == noErr {
            self.defaultOutputDeviceID = id
            if !alwaysControlMacBookSpeakers {
                self.controlledDeviceID = id
            }
            refreshDevices()
        } else {
            logger.error("Failed to set default output device: \(err)")
        }
    }
    
    // MARK: - Volume Query & Control
    
    public var isControlledDeviceDDC: Bool {
        guard let current = outputDevices.first(where: { $0.id == controlledDeviceID }) else {
            return false
        }
        return !current.isVolumeSettable
    }
    
    public var controlledDeviceName: String {
        outputDevices.first(where: { $0.id == controlledDeviceID })?.name ?? "Default Output"
    }
    
    private func updateVolumeState() {
        guard controlledDeviceID != 0 else { return }
        
        if isControlledDeviceDDC {
            isUpdatingInternally = true
            self.volume = externalMonitorVolume
            isUpdatingInternally = false
            return
        }
        
        // CoreAudio controllable device (MacBook speakers)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol: Float32 = 0.5
        var size = UInt32(MemoryLayout<Float32>.size)
        
        if AudioObjectGetPropertyData(controlledDeviceID, &address, 0, nil, &size, &vol) == noErr {
            isUpdatingInternally = true
            self.volume = vol
            isUpdatingInternally = false
        }
        
        // Mute state
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteVal: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(controlledDeviceID, &muteAddress, 0, nil, &muteSize, &muteVal) == noErr {
            self.isMuted = (muteVal != 0)
        }
    }
    
    private func applyVolumeToDevice(_ newVolume: Float) {
        guard controlledDeviceID != 0 else { return }
        let clamped = max(0.0, min(1.0, newVolume))
        
        if isControlledDeviceDDC {
            // MonitorControl Apple Silicon DDC
            externalMonitorVolume = clamped
            let ddcPercent = UInt8(round(clamped * 100.0))
            Arm64DDC.shared.setVolume(percent: ddcPercent)
            return
        }
        
        // CoreAudio devices (MacBook Pro Speakers, etc.)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol = Float32(clamped)
        let size = UInt32(MemoryLayout<Float32>.size)
        
        _ = AudioObjectSetPropertyData(controlledDeviceID, &address, 0, nil, size, &vol)
    }
    
    public func toggleMute() {
        guard controlledDeviceID != 0 else { return }
        
        if isControlledDeviceDDC {
            if isMuted {
                self.isMuted = false
                self.volume = preMuteVolume > 0 ? preMuteVolume : 0.4
                applyVolumeToDevice(self.volume)
                Arm64DDC.shared.setMute(isMuted: false)
            } else {
                self.preMuteVolume = self.volume
                self.isMuted = true
                self.volume = 0.0
                applyVolumeToDevice(0.0)
                Arm64DDC.shared.setMute(isMuted: true)
            }
            OSDManager.shared.showVolume(title: controlledDeviceName, volume: self.volume, isMuted: self.isMuted)
            return
        }
        
        let targetMute: UInt32 = isMuted ? 0 : 1
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<UInt32>.size)
        var val = targetMute
        if AudioObjectSetPropertyData(controlledDeviceID, &address, 0, nil, size, &val) == noErr {
            self.isMuted = (targetMute != 0)
            OSDManager.shared.showVolume(title: controlledDeviceName, volume: self.volume, isMuted: self.isMuted)
        }
    }
    
    public func stepVolume(up: Bool) {
        let step: Float = 0.05 // Exactly 5% increment
        let currentSteps = round(volume / step)
        let newSteps = up ? min(20.0, currentSteps + 1.0) : max(0.0, currentSteps - 1.0)
        let newVol = min(1.0, max(0.0, newSteps * step))
        
        if isMuted && up {
            self.isMuted = false
            if isControlledDeviceDDC {
                Arm64DDC.shared.setMute(isMuted: false)
            }
        }
        
        self.volume = newVol
        applyVolumeToDevice(newVol)
        
        // Show visual HUD and play standard feedback sound
        OSDManager.shared.showVolume(title: controlledDeviceName, volume: newVol, isMuted: isMuted)
        AudioServicesPlaySystemSound(1007)
    }
    
    // MARK: - Universal Keyboard Interception (CGEventTap + NSEvent Monitor)
    
    public func restartKeyboardTap() {
        stopEventTap()
        setupKeyboardInterception()
    }
    
    private func setupKeyboardInterception() {
        checkAccessibility()
        guard isKeyboardInterceptEnabled else { return }
        
        // 1. Try CGEventTap (MonitorControl method: catches events before system swallows them)
        startCGEventTap()
        
        // 2. Set up NSEvent global & local monitors as fallback
        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined, .keyDown]) { [weak self] event in
                self?.handleNSEvent(event)
            }
        }
        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.systemDefined, .keyDown]) { [weak self] event in
                if self?.handleNSEvent(event) == true {
                    return nil
                }
                return event
            }
        }
    }
    
    private func startCGEventTap() {
        guard isAccessibilityGranted else { return }
        
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << 14) // NX_SYSDEFINED
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let mgr = Unmanaged<AudioManager>.fromOpaque(refcon).takeUnretainedValue()
            
            // Check for NX_SYSDEFINED media keys
            if type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event) {
                if nsEvent.subtype.rawValue == 8 {
                    let data = nsEvent.data1
                    let keyCode = Int32((data & 0xFFFF0000) >> 16)
                    let keyFlags = (data & 0x0000FFFF)
                    let isDown = (((keyFlags & 0xFF00) >> 8)) == 0xA
                    
                    if isDown {
                        if keyCode == 0 { // Volume Up
                            DispatchQueue.main.async { mgr.stepVolume(up: true) }
                            return nil // Swallow event
                        } else if keyCode == 1 { // Volume Down
                            DispatchQueue.main.async { mgr.stepVolume(up: false) }
                            return nil
                        } else if keyCode == 7 { // Mute
                            DispatchQueue.main.async { mgr.toggleMute() }
                            return nil
                        }
                    }
                }
            }
            
            // Check for standard function keys F10, F11, F12 on external keyboards
            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                // F12 = 111, F11 = 103, F10 = 109
                if keyCode == 111 {
                    DispatchQueue.main.async { mgr.stepVolume(up: true) }
                    return nil
                } else if keyCode == 103 {
                    DispatchQueue.main.async { mgr.stepVolume(up: false) }
                    return nil
                } else if keyCode == 109 {
                    DispatchQueue.main.async { mgr.toggleMute() }
                    return nil
                }
            }
            
            return Unmanaged.passUnretained(event)
        }
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        ) else {
            logger.info("CGEvent.tapCreate failed (grant Accessibility in System Settings to enable)")
            return
        }
        
        self.eventTapPort = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.eventTapRunLoopSource = runLoopSource
        
        if let rls = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    
    private func stopEventTap() {
        if let tap = eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTapPort = nil
        }
        if let rls = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), rls, .commonModes)
            CFRunLoopSourceInvalidate(rls)
            eventTapRunLoopSource = nil
        }
    }
    
    @discardableResult
    private func handleNSEvent(_ event: NSEvent) -> Bool {
        if event.type == .systemDefined, event.subtype.rawValue == 8 {
            let data = event.data1
            let keyCode = Int32((data & 0xFFFF0000) >> 16)
            let keyFlags = (data & 0x0000FFFF)
            let isDown = (((keyFlags & 0xFF00) >> 8)) == 0xA
            
            guard isDown else { return false }
            
            if keyCode == 0 {
                stepVolume(up: true)
                return true
            } else if keyCode == 1 {
                stepVolume(up: false)
                return true
            } else if keyCode == 7 {
                toggleMute()
                return true
            }
        } else if event.type == .keyDown {
            if event.keyCode == 111 { // F12
                stepVolume(up: true)
                return true
            } else if event.keyCode == 103 { // F11
                stepVolume(up: false)
                return true
            } else if event.keyCode == 109 { // F10
                toggleMute()
                return true
            }
        }
        return false
    }
    
    // MARK: - Helpers
    
    private func queryDeviceName(id: AudioDeviceID) -> String {
        var nameCF: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var nameResult = ""
        withUnsafeMutablePointer(to: &nameCF) { ptr in
            if AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &propertySize, ptr) == noErr {
                nameResult = ptr.pointee as String
            }
        }
        return nameResult.isEmpty ? "Audio Device \(id)" : nameResult
    }
    
    private func queryTransportType(id: AudioDeviceID) -> String {
        var transport: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &propertySize, &transport) == noErr {
            switch transport {
            case 0x68646d69: return "HDMI"
            case 0x64737074: return "DisplayPort"
            case 0x626c746e: return "Built-in"
            case 0x75736220: return "USB"
            case 0x626c7565: return "Bluetooth"
            default: return "Digital"
            }
        }
        return "Digital"
    }
    
    private func checkVolumeSettable(id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(id, &address, &isSettable) == noErr {
            return isSettable.boolValue
        }
        return false
    }
    
    private func registerCoreAudioListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
    }
}

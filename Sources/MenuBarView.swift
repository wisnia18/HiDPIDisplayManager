//
//  MenuBarView.swift
//  HiDPI Display Manager
//
//  Apple Design System: Pixel-perfect, minimalist macOS Control Center aesthetics.
//  Strict 3-Color Palette: System Monochrome, Apple Accent, and Muted Amber.
//

import SwiftUI
@preconcurrency import CoreGraphics

// MARK: - Main Menu Bar View

public struct MenuBarView: View {
    @ObservedObject private var manager = DisplayManager.shared
    @ObservedObject private var audioManager = AudioManager.shared
    @ObservedObject private var launchManager = LaunchAtLoginManager.shared
    
    @State private var selectedDisplayID: CGDirectDisplayID? = nil
    
    public init() {}
    
    private var activeScreen: DisplayScreen? {
        if let id = selectedDisplayID, let screen = manager.displays.first(where: { $0.id == id }) {
            return screen
        }
        return manager.displays.first(where: { !$0.isBuiltin }) ?? manager.displays.first
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            AppHeaderView()
            
            Divider()
                .opacity(0.4)
            
            // Failsafe Rollback Warning (if active)
            if let rollback = manager.activeRollback {
                SafetyRollbackBanner(rollback: rollback, countdown: manager.rollbackCountdown)
                Divider().opacity(0.4)
            }
            
            // Display Selector Tabs (when multiple screens attached)
            if manager.displays.count > 1 {
                DisplaySelectorBar(
                    displays: manager.displays,
                    selectedID: activeScreen?.id ?? 0,
                    onSelect: { selectedDisplayID = $0 }
                )
                Divider().opacity(0.4)
            }
            
            // Main Content Area
            if let screen = activeScreen {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        
                        // 1. Display Overview & Status
                        DisplayOverviewCard(screen: screen)
                        
                        // 2. Fractional HiDPI Scaling (Apple-style segmented step bar)
                        UIScalingCard(screen: screen)
                        
                        // 3. Hardware Display Brightness Slider (Control Center Style)
                        BrightnessCard(screen: screen)
                        
                        // 4. Audio Output & 5% Keyboard Volume Controller
                        AudioCard()
                        
                        // 5. Refresh Rate & Advanced Modes
                        AdvancedDisplayCard(screen: screen)
                    }
                    .padding(14)
                }
                .frame(height: 520)
            } else {
                NoDisplaysPlaceholder()
                    .frame(height: 240)
            }
            
            Divider().opacity(0.4)
            
            // Footer
            AppFooterView()
        }
        .frame(width: 380, height: 630)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .onAppear {
            if selectedDisplayID == nil {
                selectedDisplayID = manager.displays.first(where: { !$0.isBuiltin })?.id ?? manager.displays.first?.id
            }
        }
    }
}

// MARK: - Header View

private struct AppHeaderView: View {
    @ObservedObject private var manager = DisplayManager.shared
    @ObservedObject private var audioManager = AudioManager.shared
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 1) {
                Text("Displays & Sound")
                    .font(.system(size: 13, weight: .semibold))
                Text("HiDPI Scaling & Hardware DDC")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button {
                manager.refreshDisplays()
                audioManager.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .help("Odśwież ekrany i urządzenia audio")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Display Selector Bar (Native Segmented Style)

private struct DisplaySelectorBar: View {
    let displays: [DisplayScreen]
    let selectedID: CGDirectDisplayID
    let onSelect: (CGDirectDisplayID) -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(displays) { screen in
                let isSelected = (screen.id == selectedID)
                Button {
                    onSelect(screen.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: screen.isBuiltin ? "laptopcomputer" : (screen.isVirtual ? "sparkles" : "display"))
                            .font(.system(size: 11))
                        Text(screen.name)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                    .foregroundColor(isSelected ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Display Overview Card

private struct DisplayOverviewCard: View {
    let screen: DisplayScreen
    
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                // Monitor Visual Outline
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
                        )
                    
                    Image(systemName: screen.isBuiltin ? "laptopcomputer" : "display")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.primary)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(screen.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        
                        if screen.isMain {
                            Text("GŁÓWNY")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let mode = screen.currentMode {
                        HStack(spacing: 6) {
                            Text(mode.resolutionTitle)
                                .font(.system(size: 12, weight: .medium))
                            
                            Text("•")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            Text("\(mode.roundedRefreshRate) Hz")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            
                            if mode.isHiDPI {
                                Text("Retina @2x")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
                
                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - UI Scaling Card (Fractional HiDPI)

private struct UIScalingStep: Identifiable {
    let id: Int
    let targetWidth: Int
    let targetHeight: Int
    let label: String
    let sublabel: String
    let isRecommended: Bool
}

private struct UIScalingCard: View {
    @ObservedObject private var manager = DisplayManager.shared
    let screen: DisplayScreen
    
    private let steps: [UIScalingStep] = [
        UIScalingStep(id: 1, targetWidth: 1920, targetHeight: 1080, label: "1080p", sublabel: "Większy tekst", isRecommended: false),
        UIScalingStep(id: 2, targetWidth: 2048, targetHeight: 1152, label: "1152p", sublabel: "187%", isRecommended: false),
        UIScalingStep(id: 3, targetWidth: 2560, targetHeight: 1440, label: "1440p", sublabel: "Domyślna", isRecommended: true),
        UIScalingStep(id: 4, targetWidth: 3008, targetHeight: 1692, label: "1692p", sublabel: "127%", isRecommended: false),
        UIScalingStep(id: 5, targetWidth: 3840, targetHeight: 2160, label: "4K", sublabel: "Więcej miejsca", isRecommended: false)
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skalowanie interfejsu (HiDPI)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let cur = screen.currentMode {
                    Text("\(cur.logicalWidth) × \(cur.logicalHeight)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            // Apple-style segmented scale picker
            HStack(spacing: 3) {
                ForEach(steps) { step in
                    let isSelected = (screen.currentMode?.logicalWidth == step.targetWidth &&
                                      screen.currentMode?.logicalHeight == step.targetHeight)
                    
                    Button {
                        applyScaleStep(step)
                    } label: {
                        VStack(spacing: 2) {
                            Text(step.label)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                            
                            Text(step.sublabel)
                                .font(.system(size: 8))
                                .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        )
                        .foregroundColor(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.2), lineWidth: 1)
        )
    }
    
    private func applyScaleStep(_ step: UIScalingStep) {
        let isHiDPI = (step.targetWidth < 3840)
        if let mode = screen.availableModes.first(where: {
            $0.logicalWidth == step.targetWidth &&
            $0.logicalHeight == step.targetHeight &&
            ($0.isHiDPI == isHiDPI || !isHiDPI)
        }) {
            manager.setDisplayMode(mode: mode, for: screen)
        } else if let fallback = screen.availableModes.first(where: {
            $0.logicalWidth == step.targetWidth && $0.logicalHeight == step.targetHeight
        }) {
            manager.setDisplayMode(mode: fallback, for: screen)
        }
    }
}

// MARK: - Hardware Brightness Card (Control Center Tactile Slider)

private struct BrightnessCard: View {
    @ObservedObject private var manager = DisplayManager.shared
    let screen: DisplayScreen
    @State private var localBrightness: Float = 1.0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(screen.isBuiltin ? "Jasność ekranu" : "Jasność sprzętowa (DDC)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(Int(localBrightness * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            // Apple Control Center Style Pill Slider
            ControlCenterSlider(
                value: Binding(
                    get: { localBrightness },
                    set: { newVal in
                        localBrightness = newVal
                        manager.setBrightness(newVal, for: screen)
                    }
                ),
                icon: "sun.max.fill"
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            localBrightness = screen.brightness
        }
        .onChange(of: screen.brightness) { newB in
            localBrightness = newB
        }
    }
}

// MARK: - Audio Card (Control Center Style)

private struct AudioCard: View {
    @ObservedObject private var audioManager = AudioManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section Header
            HStack {
                Text("Dźwięk i klawiatura")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if audioManager.isControlledDeviceDDC {
                    Text("DDC")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundColor(.secondary)
                }
            }
            
            // Accessibility Warning Callout (if missing)
            if !audioManager.isAccessibilityGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    
                    Text("Włącz uprawnienie Dostępność dla klawiszy głośności.")
                        .font(.system(size: 10))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button("Włącz") {
                        audioManager.requestAccessibility()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.1))
                )
            }
            
            // Sound Output Selector (Segmented buttons)
            HStack(spacing: 4) {
                ForEach(audioManager.outputDevices) { device in
                    let isDefault = (device.id == audioManager.defaultOutputDeviceID)
                    Button {
                        audioManager.setDefaultOutputDevice(id: device.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: device.isBuiltin ? "laptopcomputer" : "display")
                                .font(.system(size: 10))
                            Text(device.name)
                                .font(.system(size: 10, weight: isDefault ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isDefault ? Color.accentColor : Color.clear)
                        )
                        .foregroundColor(isDefault ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            
            // Volume Slider (Control Center Style)
            HStack(spacing: 8) {
                Button {
                    audioManager.toggleMute()
                } label: {
                    Image(systemName: audioManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .foregroundColor(audioManager.isMuted ? .orange : .primary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
                .buttonStyle(.plain)
                
                ControlCenterSlider(
                    value: $audioManager.volume,
                    icon: audioManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
                
                Text("\(Int(round(audioManager.volume * 100)))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            
            // Single Clean Toggle for Laptop Speakers
            Toggle(isOn: $audioManager.alwaysControlMacBookSpeakers) {
                Text("Klawisze głośności zawsze sterują głośnikami MacBooka")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.checkbox)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Advanced Display Card (Refresh Rate & Modes)

private struct AdvancedDisplayCard: View {
    @ObservedObject private var manager = DisplayManager.shared
    let screen: DisplayScreen
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Refresh Rate Row
            let availableRates = screen.availableRefreshRatesForCurrentResolution
            HStack {
                Text("Częstotliwość odświeżania")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if availableRates.count > 1 {
                    Picker("", selection: Binding(
                        get: { screen.currentMode?.roundedRefreshRate ?? 60 },
                        set: { selectedRate in
                            if let target = screen.availableModes.first(where: {
                                $0.logicalWidth == screen.currentMode?.logicalWidth &&
                                $0.logicalHeight == screen.currentMode?.logicalHeight &&
                                $0.isHiDPI == screen.currentMode?.isHiDPI &&
                                $0.roundedRefreshRate == selectedRate
                            }) {
                                manager.setDisplayMode(mode: target, for: screen)
                            }
                        }
                    )) {
                        ForEach(availableRates, id: \.self) { rate in
                            Text("\(rate) Hz").tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 90)
                } else if let mode = screen.currentMode {
                    Text("\(mode.roundedRefreshRate) Hz")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }
            
            // Collapsible All Modes
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 3) {
                    let displayedModes = manager.showHiDPIOnly ? screen.hidpiModes : screen.availableModes
                    ForEach(displayedModes.prefix(6)) { mode in
                        let isCurrent = (screen.currentMode?.logicalWidth == mode.logicalWidth &&
                                         screen.currentMode?.logicalHeight == mode.logicalHeight &&
                                         screen.currentMode?.isHiDPI == mode.isHiDPI)
                        
                        Button {
                            manager.setDisplayMode(mode: mode, for: screen)
                        } label: {
                            HStack {
                                Image(systemName: isCurrent ? "checkmark" : "circle.fill")
                                    .font(.system(size: isCurrent ? 10 : 3))
                                    .foregroundColor(isCurrent ? .accentColor : .clear)
                                    .frame(width: 14)
                                
                                Text(mode.resolutionTitle)
                                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                                
                                Spacer()
                                
                                if mode.isHiDPI {
                                    Text("Retina")
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                        .foregroundColor(.accentColor)
                                }
                                
                                Text("\(mode.roundedRefreshRate)Hz")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Wszystkie rozdzielczości (\(screen.availableModes.count))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Native Apple Control Center Style Pill Slider

private struct ControlCenterSlider: View {
    @Binding var value: Float
    let icon: String
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = CGFloat(max(0.0, min(1.0, value)))
            let fillWidth = max(28.0, width * clamped)
            
            ZStack(alignment: .leading) {
                // Background Track
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 1)
                    )
                
                // Active Fill Pill
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: fillWidth)
                
                // Left-aligned Symbol
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(clamped > 0.15 ? .white : .secondary)
                        .padding(.leading, 9)
                    
                    Spacer()
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let newProgress = max(0.0, min(1.0, Float(gesture.location.x / width)))
                        self.value = newProgress
                    }
            )
        }
        .frame(height: 28)
    }
}

// MARK: - Safety Rollback Banner (Muted Amber)

private struct SafetyRollbackBanner: View {
    @ObservedObject private var manager = DisplayManager.shared
    let rollback: SafetyRollbackState
    let countdown: Int
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 1) {
                Text("Test trybu: \(rollback.targetMode.resolutionTitle)")
                    .font(.system(size: 11, weight: .semibold))
                Text("Przywrócenie za \(countdown)s...")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Cofnij") {
                manager.revertToPreviousResolution()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            
            Button("Zatwierdź") {
                manager.confirmResolutionChange()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Footer View

private struct AppFooterView: View {
    @ObservedObject private var launchManager = LaunchAtLoginManager.shared
    
    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { launchManager.isEnabled },
                set: { launchManager.toggleLaunchAtLogin(enable: $0) }
            )) {
                Text("Uruchamiaj przy starcie")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.checkbox)
            
            Spacer()
            
            Button("Zakończ") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Empty State Placeholder

private struct NoDisplaysPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Brak podłączonych ekranów")
                .font(.system(size: 12, weight: .semibold))
            Text("Upewnij się, że kabel HDMI lub DisplayPort jest podłączony.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Translucent Popover Visual Effect

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

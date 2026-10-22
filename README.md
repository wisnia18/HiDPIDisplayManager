# HiDPI Display Manager (macOS 13.0+)

<p align="center">
  <strong>Native, lightweight macOS Menu Bar utility designed for external 4K monitors on Apple Silicon & Intel Macs.</strong><br>
  Unlocks fractional HiDPI (Retina @2x) scaling, bypasses macOS HDMI/DisplayPort audio locks, and controls monitor hardware brightness and volume via DDC/CI.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013.0+-blue" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-success" alt="Architecture">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  <img src="https://img.shields.io/badge/language-Swift%205.10+-orange" alt="Language">
</p>

---

## 🌟 Key Features

- **🎯 Fractional HiDPI (Retina @2x) Scaling**:
  - One-click scaling presets tailored for 4K panels: `1080p` (Large UI) | `1152p` | `1440p` (Ideal / 150%) | `1692p` | `Native 4K`.
  - Discovers hidden HiDPI duplicate modes via private `CGS` WindowServer APIs.
  - **Failsafe Rollback Timer**: 15-second safety countdown automatically reverts changes if an external display loses sync.

- **🔊 Hardware Volume & macOS HDMI Fix**:
  - Fixes the infamous macOS issue where external HDMI / DisplayPort audio volume is locked (crossed-out speaker icon).
  - Controls monitor internal amplifier volume using **DDC/CI (`VCP 0x62`)** directly over Apple Silicon I2C (`IOAVService`).
  - **Universal Keyboard Interception (`CGEventTap`)**: Smooth volume control with **5% increments** via external keyboard media keys or `F11` / `F12`.
  - Option to route volume keys directly to MacBook Pro speakers regardless of active display.

- **☀️ True Hardware Backlight Control**:
  - Controls physical display backlight LED lamps via DDC/CI (`VCP 0x10`) — no software gray overlay or contrast loss.
  - GPU Gamma transfer tables remain at 100% full native contrast.

- **🎨 Apple Control Center Design Language**:
  - Built from the ground up to match native macOS Control Center & System Settings aesthetics.
  - Strict **3-color palette** (System adaptive monochrome, Apple accent tint, and muted amber).
  - Tactile capsule pill sliders with embedded SF Symbols.
  - Floating translucent **OSD (Bezel HUD)** with 20 tick-marks (5% per tick).

- **🔄 Virtual 5K Dummy Display Engine**:
  - Hardware mirrors a virtual 5K canvas (`CGVirtualDisplay`) to force 1440p HiDPI on stubborn monitors.

- **🚀 Persistent Launch at Login**:
  - Multi-layer launch support combining `SMAppService`, user `LaunchAgent` (`com.hidpi.displaymanager.plist`), and System Events.

---

## 🛠️ Quick Installation

### 1-Command Build & Install

Clone the repository and run the build script:

```bash
git clone https://github.com/wisnia18/HiDPIDisplayManager.git
cd HiDPIDisplayManager
./build.sh
```

The script will automatically compile, sign, and install the application into `/Applications/HiDPIDisplayManager.app` and launch it in your Menu Bar.

---

## ⚙️ Requirements & Permissions

- **Operating System:** macOS 13.0 (Ventura), macOS 14.0 (Sonoma), macOS 15.0+ (Sequoia) or later.
- **Hardware:** Apple Silicon (M1/M2/M3/M4/M5) or Intel Mac.
- **Accessibility Permission (for keyboard shortcuts):**
  To allow external keyboards (`F11`, `F12`, Media Keys) to intercept volume adjustments globally, grant Accessibility access:
  * **System Settings → Privacy & Security → Accessibility → enable HiDPIDisplayManager**.

---

## 🏗️ Architecture & Technical Details

```
HiDPIDisplayManager/
├── Info.plist                         # Menu bar agent configuration (LSUIElement = true)
├── HiDPIDisplayManager.entitlements   # Non-sandboxed hardware entitlements
├── build.sh                           # Fast CLI compile, package, and installation script
└── Sources/
    ├── App.swift                      # NSApplication activation & MenuBarExtra entry point
    ├── Arm64DDC.swift                 # Apple Silicon I2C / IOAVService DDC engine (MonitorControl logic)
    ├── AudioManager.swift             # CoreAudio manager & CGEventTap keyboard listener (5% steps)
    ├── DisplayManager.swift           # Hardware enumeration, HiDPI mode switching & failsafe timer
    ├── DisplayModels.swift            # DisplayScreen & DisplayModeItem definitions
    ├── LaunchAtLoginManager.swift     # Multi-layer launch engine (SMAppService + LaunchAgent)
    ├── MenuBarView.swift              # Native Apple Control Center SwiftUI interface
    ├── OSDManager.swift               # Translucent on-screen volume bezel HUD
    └── PrivateDisplayAPIs.h           # WindowServer CGS & CGVirtualDisplay bridging declarations
```

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the [issues page](https://github.com/wisnia18/HiDPIDisplayManager/issues).

---

## 📄 License

This project is open-source under the [MIT License](LICENSE).

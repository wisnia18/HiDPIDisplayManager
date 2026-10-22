//
//  OSDManager.swift
//  HiDPI Display Manager
//
//  Native macOS-style translucent volume and brightness on-screen display (OSD / Bezel).
//

import SwiftUI
import AppKit

@MainActor
public final class OSDManager: ObservableObject {
    public static let shared = OSDManager()
    
    private var osdWindow: NSWindow?
    private var dismissWorkItem: DispatchWorkItem?
    
    @Published public var title: String = "Display"
    @Published public var volume: Float = 0.5
    @Published public var isMuted: Bool = false
    
    private init() {
        setupWindow()
    }
    
    private func setupWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = true
        
        let hostingView = NSHostingView(rootView: OSDView(manager: self))
        window.contentView = hostingView
        self.osdWindow = window
    }
    
    public func showVolume(title: String, volume: Float, isMuted: Bool) {
        self.title = title
        self.volume = volume
        self.isMuted = isMuted
        
        guard let window = osdWindow, let screen = NSScreen.main else { return }
        
        let screenRect = screen.frame
        let windowWidth: CGFloat = 200
        let windowHeight: CGFloat = 200
        let x = screenRect.midX - (windowWidth / 2.0)
        let y = screenRect.minY + 140 // Classic macOS bezel position
        
        window.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
        window.alphaValue = 1.0
        window.orderFrontRegardless()
        
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, let w = self.osdWindow else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                w.animator().alphaValue = 0.0
            } completionHandler: {
                w.orderOut(nil)
            }
        }
        self.dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }
}

private struct OSDView: View {
    @ObservedObject var manager: OSDManager
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.25), radius: 15, x: 0, y: 5)
            
            VStack(spacing: 16) {
                Text(manager.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(1)
                    .padding(.top, 4)
                
                Image(systemName: manager.isMuted ? "speaker.slash.fill" : (manager.volume > 0.6 ? "speaker.wave.3.fill" : (manager.volume > 0.2 ? "speaker.wave.2.fill" : "speaker.wave.1.fill")))
                    .font(.system(size: 48, weight: .medium))
                    .foregroundColor(manager.isMuted ? .red : .primary)
                    .frame(height: 52)
                
                // Percentage indicator
                Text("\(Int(round(manager.volume * 100)))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.7))
                
                // Volume tick-bar: exactly 20 ticks (5% per tick)
                HStack(spacing: 2.5) {
                    ForEach(0..<20, id: \.self) { index in
                        let threshold = Float(index + 1) * 0.05
                        let isFilled = !manager.isMuted && (manager.volume >= (threshold - 0.02))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isFilled ? Color.primary : Color.primary.opacity(0.18))
                            .frame(height: 7)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
            .padding(16)
        }
        .frame(width: 200, height: 200)
    }
}

//
//  Arm64DDC.swift
//  HiDPI Display Manager
//
//  Apple Silicon DDC/CI implementation copied from MonitorControl.
//  Communicates directly with external displays via IOAVService on Apple Silicon.
//

import Foundation
import IOKit
import os.log

public final class Arm64DDC: @unchecked Sendable {
    public static let shared = Arm64DDC()
    
    // Constants from MonitorControl
    public static let ddc7BitAddress: UInt8 = 0x37
    public static let ddcDataAddress: UInt8 = 0x51
    
    // VCP Command codes
    public static let vcpLuminance: UInt8 = 0x10
    public static let vcpContrast: UInt8 = 0x12
    public static let vcpAudioVolume: UInt8 = 0x62
    public static let vcpAudioMute: UInt8 = 0x8D
    
    private typealias IOAVServiceCreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias IOAVServiceWriteI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafePointer<UInt8>, UInt32) -> IOReturn
    private typealias IOAVServiceReadI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn
    
    private let logger = Logger(subsystem: "com.hidpi.displaymanager", category: "Arm64DDC")
    private let ddcQueue = DispatchQueue(label: "com.hidpi.ddcqueue", qos: .userInteractive)
    
    private var createFn: IOAVServiceCreateWithServiceFn?
    private var writeFn: IOAVServiceWriteI2CFn?
    
    private init() {
        if let createSym = dlsym(dlopen(nil, RTLD_LAZY), "IOAVServiceCreateWithService") ?? dlsym(dlopen(nil, RTLD_LAZY), "IOAVServiceCreate") {
            self.createFn = unsafeBitCast(createSym, to: IOAVServiceCreateWithServiceFn.self)
        }
        if let writeSym = dlsym(dlopen(nil, RTLD_LAZY), "IOAVServiceWriteI2C") {
            self.writeFn = unsafeBitCast(writeSym, to: IOAVServiceWriteI2CFn.self)
        }
    }
    
    // MARK: - MonitorControl Checksum Algorithm
    
    public static func checksum(chk: UInt8, data: inout [UInt8], start: Int, end: Int) -> UInt8 {
        var chkd = chk
        for i in start...end {
            chkd ^= data[i]
        }
        return chkd
    }
    
    // MARK: - Find External Services (MonitorControl Logic)
    
    private func getExternalAVServices() -> [AnyObject] {
        guard let createFn = self.createFn else { return [] }
        
        var services: [AnyObject] = []
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("DCPAVServiceProxy")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        
        var serv = IOIteratorNext(iter)
        while serv != 0 {
            var isExternal = false
            if let unmanagedLoc = IORegistryEntryCreateCFProperty(serv, "Location" as CFString, kCFAllocatorDefault, 0),
               let loc = unmanagedLoc.takeRetainedValue() as? String {
                isExternal = (loc == "External")
            }
            
            if isExternal {
                if let unmanagedSvc = createFn(kCFAllocatorDefault, serv) {
                    services.append(unmanagedSvc.takeRetainedValue())
                }
            }
            
            IOObjectRelease(serv)
            serv = IOIteratorNext(iter)
        }
        IOObjectRelease(iter)
        return services
    }
    
    // MARK: - MonitorControl DDC Write Logic
    
    @discardableResult
    public func write(command: UInt8, value: UInt16) -> Bool {
        let externalServices = getExternalAVServices()
        guard !externalServices.isEmpty else {
            logger.warning("No external IOAVService found for DDC write")
            return false
        }
        
        var success = false
        for service in externalServices {
            if writeToService(service: service, command: command, value: value) {
                success = true
            }
        }
        return success
    }
    
    public func writeAsync(command: UInt8, value: UInt16, completion: (@Sendable (Bool) -> Void)? = nil) {
        ddcQueue.async { [weak self] in
            guard let self = self else { return }
            let ok = self.write(command: command, value: value)
            if let completion = completion {
                DispatchQueue.main.async {
                    completion(ok)
                }
            }
        }
    }
    
    private func writeToService(service: AnyObject, command: UInt8, value: UInt16) -> Bool {
        guard let writeFn = self.writeFn else { return false }
        
        let send: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 0xFF)]
        let dataAddress = Self.ddcDataAddress
        
        // Exact MonitorControl packet framing:
        // [0x80 | (count + 1), count] + send + [checksum]
        var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        let chkInitial = (send.count == 1) ? (Self.ddc7BitAddress << 1) : ((Self.ddc7BitAddress << 1) ^ dataAddress)
        packet[packet.count - 1] = Self.checksum(chk: chkInitial, data: &packet, start: 0, end: packet.count - 2)
        
        var success = false
        // MonitorControl retry loop: up to 3 attempts, 2 write cycles per attempt with 10ms delay
        for _ in 1...3 {
            for _ in 1...2 {
                usleep(10000)
                let kr = writeFn(service, UInt32(Self.ddc7BitAddress), UInt32(dataAddress), packet, UInt32(packet.count))
                if kr == 0 {
                    success = true
                }
            }
            if success { break }
            usleep(20000)
        }
        return success
    }
    
    // MARK: - High Level Audio & Display Helpers
    
    public func setVolume(percent: UInt8) {
        let clamped = min(percent, 100)
        writeAsync(command: Self.vcpAudioVolume, value: UInt16(clamped))
    }
    
    public func setMute(isMuted: Bool) {
        if isMuted {
            // VCP 0x8D: 1 = mute, 2 = unmute
            writeAsync(command: Self.vcpAudioMute, value: 1)
        } else {
            writeAsync(command: Self.vcpAudioMute, value: 2)
        }
    }
    
    public func setBrightness(percent: UInt8) {
        let clamped = min(percent, 100)
        writeAsync(command: Self.vcpLuminance, value: UInt16(clamped))
    }
}

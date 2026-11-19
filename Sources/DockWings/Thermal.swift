// Die temperature of Apple silicon, from the on-die sensors in the HID event
// system (taken from readout's HIDSensors.swift). The functions are private
// API, so they are looked up at run time and everything may fail: then there
// is simply no reading. A read costs tens of milliseconds, so Health only
// reads while the batteries drawer is open.
import Foundation
import IOKit

final class Thermal {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int32, UInt32, UInt64) -> Unmanaged<AnyObject>?
    private typealias EventFloatValue = @convention(c) (AnyObject, UInt32) -> Double

    /// kIOHIDEventTypeTemperature and its float field.
    private static let temperatureEvent: Int32 = 15
    private static let temperatureField = UInt32(temperatureEvent) << 16

    private let copyEvent: CopyEvent
    private let eventFloatValue: EventFloatValue
    /// The client owns its services, so it lives as long as they do.
    private var client: AnyObject?
    private var services: [AnyObject] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", as: EventFloatValue.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        self.copyEvent = copyEvent
        eventFloatValue = floatValue
        // Apple vendor page, temperature sensor usage.
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005] as CFDictionary)
        guard let found = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return nil }
        self.client = client
        // Each die sensor shows up under several services with the same
        // name; one of each is enough and keeps a read affordable.
        var seen = Set<String>()
        services = found.filter { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else { return false }
            return name.hasPrefix("PMU tdie") && seen.insert(name).inserted
        }
        if services.isEmpty { return nil }
    }

    /// Hottest die sensor in °C.
    func peak() -> Double? {
        services.compactMap { service -> Double? in
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let celsius = eventFloatValue(event, Self.temperatureField)
            return celsius.isFinite && celsius > 1 && celsius < 150 ? celsius : nil
        }.max()
    }
}

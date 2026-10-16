import CoreMIDI
import Foundation

struct MIDIEndpointInfo: Identifiable, Equatable {
    var id: Int32
    var name: String
    var endpoint: MIDIEndpointRef
}

struct MIDIEvent {
    enum Kind {
        case noteOn
        case noteOff
        case control
        case program
        case pitchBend
        case clock
        case start
        case stop
        case resume
    }

    var kind: Kind
    var channel: Int = 0
    var data1: Int = 0
    var data2: Int = 0
    var sourceID: Int32 = 0
    /// mach host ticks of the packet; engines use it to place the event inside the audio buffer.
    var hostTime: UInt64 = 0
}

final class MIDIManager {
    private(set) var sources: [MIDIEndpointInfo] = []
    private(set) var destinations: [MIDIEndpointInfo] = []
    var enabledSourceIDs: Set<Int32> = []
    var onEvent: ((MIDIEvent) -> Void)?
    var onEndpointsChanged: (() -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var parsers: [Int32: MIDIByteParser] = [:]
    private var connectedSources: Set<MIDIEndpointRef> = []
    private let lock = NSLock()
    private let clientName: String

    init(clientName: String) {
        self.clientName = clientName
    }

    func start() {
        guard client == 0 else {
            refreshEndpoints()
            return
        }
        let status = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] _ in
            self?.refreshEndpoints()
        }
        guard status == noErr else { return }
        MIDIInputPortCreateWithBlock(client, "\(clientName) In" as CFString, &inputPort) { [weak self] packetList, refCon in
            self?.receive(packetList, refCon: refCon)
        }
        MIDIOutputPortCreate(client, "\(clientName) Out" as CFString, &outputPort)
        refreshEndpoints()
    }

    func endpointSnapshot() -> (sources: [MIDIEndpointInfo], destinations: [MIDIEndpointInfo]) {
        lock.lock()
        defer { lock.unlock() }
        return (sources, destinations)
    }

    func refreshEndpoints() {
        var nextSources: [MIDIEndpointInfo] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            guard let info = info(for: endpoint) else { continue }
            nextSources.append(info)
            if inputPort != 0, !connectedSources.contains(endpoint) {
                let refCon = UnsafeMutableRawPointer(bitPattern: Int(info.id))
                if MIDIPortConnectSource(inputPort, endpoint, refCon) == noErr {
                    connectedSources.insert(endpoint)
                }
            }
        }
        var nextDestinations: [MIDIEndpointInfo] = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(index)
            if let info = info(for: endpoint) {
                nextDestinations.append(info)
            }
        }
        lock.lock()
        sources = nextSources
        destinations = nextDestinations
        lock.unlock()
        onEndpointsChanged?()
    }

    func send(_ bytes: [UInt8], to destinationID: Int32?) {
        guard let destinationID else { return }
        lock.lock()
        let destination = destinations.first { $0.id == destinationID }?.endpoint
        let port = outputPort
        lock.unlock()
        guard let destination, port != 0, !bytes.isEmpty else { return }
        let capacity = 256
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(list)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            packet = MIDIPacketListAdd(list, capacity, packet, 0, buffer.count, base)
        }
        MIDISend(port, destination, list)
    }

    func sendClock(to destinationID: Int32?) { send([0xF8], to: destinationID) }
    func sendStart(to destinationID: Int32?) { send([0xFA], to: destinationID) }
    func sendStop(to destinationID: Int32?) { send([0xFC], to: destinationID) }

    private func receive(_ packetList: UnsafePointer<MIDIPacketList>, refCon: UnsafeMutableRawPointer?) {
        guard let refCon else { return }
        let sourceID = Int32(truncatingIfNeeded: Int(bitPattern: refCon))
        lock.lock()
        let enabled = enabledSourceIDs.contains(sourceID)
        lock.unlock()
        guard enabled else { return }
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let bytes = packetBytes(packet)
            lock.lock()
            var parser = parsers[sourceID] ?? MIDIByteParser()
            let events = parser.parse(bytes)
            parsers[sourceID] = parser
            lock.unlock()
            let host = packet.timeStamp != 0 ? packet.timeStamp : mach_absolute_time()
            for var event in events {
                event.sourceID = sourceID
                event.hostTime = host
                onEvent?(event)
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private func info(for endpoint: MIDIEndpointRef) -> MIDIEndpointInfo? {
        var unique: Int32 = 0
        let uniqueStatus = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &unique)
        if uniqueStatus != noErr { unique = Int32(endpoint) }
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        let label = name?.takeRetainedValue() as String? ?? "MIDI \(unique)"
        return MIDIEndpointInfo(id: unique, name: label, endpoint: endpoint)
    }

    private func packetBytes(_ packet: MIDIPacket) -> [UInt8] {
        let count = Int(packet.length)
        guard count > 0 else { return [] }
        var copy = packet
        return withUnsafeBytes(of: &copy.data) { raw in
            Array(raw.prefix(count))
        }
    }
}

private struct MIDIByteParser {
    var running: UInt8?
    var pending: [UInt8] = []
    var inSysEx = false

    mutating func parse(_ bytes: [UInt8]) -> [MIDIEvent] {
        var events: [MIDIEvent] = []
        for byte in bytes {
            if byte >= 0xF8 {
                if let event = realtime(byte) { events.append(event) }
                continue
            }
            if byte == 0xF0 {
                inSysEx = true
                running = nil
                pending.removeAll()
                continue
            }
            if byte == 0xF7 {
                inSysEx = false
                continue
            }
            if inSysEx { continue }
            if byte >= 0xF0 {
                running = nil
                pending.removeAll()
                continue
            }
            if byte & 0x80 != 0 {
                running = byte
                pending.removeAll()
                if expected(byte) == 0, let event = make(status: byte, data: []) {
                    events.append(event)
                }
                continue
            }
            guard let status = running else { continue }
            pending.append(byte)
            let need = expected(status)
            if pending.count >= need {
                if let event = make(status: status, data: pending) {
                    events.append(event)
                }
                pending.removeAll()
            }
        }
        return events
    }

    private func expected(_ status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: 1
        default: 2
        }
    }

    private func realtime(_ byte: UInt8) -> MIDIEvent? {
        switch byte {
        case 0xF8: MIDIEvent(kind: .clock)
        case 0xFA: MIDIEvent(kind: .start)
        case 0xFB: MIDIEvent(kind: .resume)
        case 0xFC: MIDIEvent(kind: .stop)
        default: nil
        }
    }

    private func make(status: UInt8, data: [UInt8]) -> MIDIEvent? {
        let channel = Int(status & 0x0F)
        let first = data.first.map(Int.init) ?? 0
        let second = data.dropFirst().first.map(Int.init) ?? 0
        switch status & 0xF0 {
        case 0x80:
            return MIDIEvent(kind: .noteOff, channel: channel, data1: first, data2: second)
        case 0x90:
            if second == 0 {
                return MIDIEvent(kind: .noteOff, channel: channel, data1: first, data2: 0)
            }
            return MIDIEvent(kind: .noteOn, channel: channel, data1: first, data2: second)
        case 0xB0:
            return MIDIEvent(kind: .control, channel: channel, data1: first, data2: second)
        case 0xC0:
            return MIDIEvent(kind: .program, channel: channel, data1: first)
        case 0xE0:
            return MIDIEvent(kind: .pitchBend, channel: channel, data1: first, data2: second)
        default:
            return nil
        }
    }
}

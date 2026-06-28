//
//  main.swift
//  SMA UDP
//
//  Created by Manuel Wentenschuh on 08.06.26.
//

import Network
import Foundation

// MARK: - Domain Models

/// Represents the phase of the electrical measurement.
enum PowerPhase: String {
    case total = "Total"
    case l1 = "Phase L1"
    case l2 = "Phase L2"
    case l3 = "Phase L3"
}

/// Represents the direction of the electrical flow.
enum MeasurementDirection: String {
    case importDirection = "Import"
    case exportDirection = "Export"
}

/// A structured OBIS code.
struct OBISCode: Hashable {
    let channel: UInt8
    let index: UInt8
    let type: UInt8
    let tariff: UInt8

    var description: String {
        "\(channel):\(index).\(type).\(tariff)"
    }
}

/// A semantic category for an OBIS measurement.
enum OBISCategory {
    case activePower(phase: PowerPhase, direction: MeasurementDirection)
    case activeEnergy(phase: PowerPhase, direction: MeasurementDirection)
    case reactivePower(phase: PowerPhase, direction: MeasurementDirection)
    case reactiveEnergy(phase: PowerPhase, direction: MeasurementDirection)
    case apparentPower(phase: PowerPhase, direction: MeasurementDirection)
    case apparentEnergy(phase: PowerPhase, direction: MeasurementDirection)
    case frequency
    case powerFactor(phase: PowerPhase)

    /// Initializes a category from raw OBIS components.
    init?(code: OBISCode) {
        guard 0 >= code.channel && code.channel <= 127 else {
            // custom channels not supported
            return nil
        }

        // 1. Map the Phase
        let phase: PowerPhase
        var index = code.index
        if code.index < 1 {
            return nil
        } else if code.index <= 20 {
            phase = .total
        } else if code.index <= 40 {
            phase = .l1
            index -= 20
        } else if code.index <= 60 {
            phase = .l2
            index -= 40
        } else if code.index <= 80 {
            phase = .l3
            index -= 60
        } else {
            return nil
        }

        // 2. Map the Category and Direction based on Index and Type
        switch (index, code.type) {
        // Active Power/Energy
        case (1, 4): self = .activePower(phase: phase, direction: .importDirection)
        case (2, 4): self = .activePower(phase: phase, direction: .exportDirection)
        case (1, 8): self = .activeEnergy(phase: phase, direction: .importDirection)
        case (2, 8): self = .activeEnergy(phase: phase, direction: .exportDirection)
        
        // Reactive Power/Energy
        case (3, 4): self = .reactivePower(phase: phase, direction: .importDirection)
        case (4, 4): self = .reactivePower(phase: phase, direction: .exportDirection)
        case (3, 8): self = .reactiveEnergy(phase: phase, direction: .importDirection)
        case (4, 8): self = .reactiveEnergy(phase: phase, direction: .exportDirection)
        
        // Apparent Power/Energy
        case (9, 4): self = .apparentPower(phase: phase, direction: .importDirection)
        case (10, 4): self = .apparentPower(phase: phase, direction: .exportDirection)
        case (9, 8): self = .apparentEnergy(phase: phase, direction: .importDirection)
        case (10, 8): self = .apparentEnergy(phase: phase, direction: .exportDirection)
        
        // Special cases
        case (13, 4): self = .powerFactor(phase: phase)
        case (14, 4): self = .frequency
        default: return nil
        }
    }

    /// Converts a raw value into a formatted Measurement.
    func toMeasurement(code: OBISCode, rawValue: Double) -> Measurement {
        switch self {
        case .activePower(let phase, let direction):
            return Measurement(code: code, value: rawValue / 10.0, unit: "W", description: "\(phase.rawValue) Active Power \(direction.rawValue)")
        case .activeEnergy(let phase, let direction):
            return Measurement(code: code, value: rawValue / 3_600_000.0, unit: "kWh", description: "\(phase.rawValue) Active Energy \(direction.rawValue)")
        case .reactivePower(let phase, let direction):
            return Measurement(code: code, value: rawValue / 10.0, unit: "var", description: "\(phase.rawValue) Reactive Power \(direction.rawValue)")
        case .reactiveEnergy(let phase, let direction):
            return Measurement(code: code, value: rawValue / 3_600_000.0, unit: "kWh", description: "\(phase.rawValue) Reactive Energy \(direction.rawValue)")
        case .apparentPower(let phase, let direction):
            return Measurement(code: code, value: rawValue / 10.0, unit: "VA", description: "\(phase.rawValue) Apparent Power \(direction.rawValue)")
        case .apparentEnergy(let phase, let direction):
            return Measurement(code: code, value: rawValue / 3_600_000.0, unit: "kVAh", description: "\(phase.rawValue) Apparent Energy \(direction.rawValue)")
        case .frequency:
            return Measurement(code: code, value: rawValue / 1000.0, unit: "Hz", description: "Grid Frequency")
        case .powerFactor:
            return Measurement(code: code, value: rawValue / 1000.0, unit: "-", description: "Power Factor")
        }
    }
}

/// A decoded measurement.
struct Measurement {
    let code: OBISCode
    let value: Double
    let unit: String
    let description: String
}

/// A parsed packet.
struct SpeedwirePacket {
    let serialNumber: UInt32
    let ticker: UInt32
    let measurements: [Measurement]
}

// MARK: - Parser

struct SpeedwireParser {
    
    enum ParserError: Error {
        case invalidSignature
        case offsetOutOfBounds(Int, Int)

        var localizedDescription: String {
            switch self {
            case .invalidSignature:
                return "Invalid signature"
            case .offsetOutOfBounds(let offset, let length):
                return "Offset \(offset) out of bounds for length \(length)"
            }
        }
    }

    static func parse(_ data: Data) throws -> SpeedwirePacket {
        guard data.count >= 4, data.prefix(4) == Data([0x53, 0x4d, 0x41, 0x00]) else {
            throw ParserError.invalidSignature
        }

        var offset = 4
        var serialNumber: UInt32 = 0
        var ticker: UInt32 = 0
        var measurements: [Measurement] = []

        while offset + 4 <= data.count {
            // Using loadUnaligned to safely read from any byte offset
            let length_U16 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian }
            let length = Int(length_U16)
            let tag = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self).bigEndian }
            offset += 4
            
            let newOffset = offset + length
            guard newOffset <= data.count else {
                throw ParserError.offsetOutOfBounds(offset, length)
            }

            let payload = data.subdata(in: offset..<newOffset)
            offset = newOffset

            // End of Data
            if tag == 0x0000 {
                break
            }

            // SMA Net 2
            if tag == 0x0010 {
                let parsed = parseSMAnet2(payload)
                serialNumber = parsed.serialNumber
                ticker = parsed.ticker
                measurements.append(contentsOf: parsed.measurements)
            }

            // Ignore other tags
        }

        return SpeedwirePacket(serialNumber: serialNumber, ticker: ticker, measurements: measurements)
    }

    private static func parseSMAnet2(_ data: Data) -> (serialNumber: UInt32, ticker: UInt32, measurements: [Measurement]) {
        guard data.count >= 12 else {
            return (0, 0, [])
        }

        let subTag = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self).bigEndian }
        guard subTag == 0x6069 else {
            return (0, 0, [])
        }

        // Using loadUnaligned to avoid "load from misaligned raw pointer" crashes
        let serialNumber = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian }
        let ticker = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).bigEndian }

        var measurements: [Measurement] = []
        var offset = 12
        
        while offset + 4 <= data.count {
            let channel = data[offset]
            let index = data[offset + 1]
            let type = data[offset + 2]
            let tariff = data[offset + 3]
            offset += 4
            
            let dataSize: Int
            switch type {
            case 4: dataSize = 4
            case 8: dataSize = 8
            default: dataSize = 0
            }
            
            guard offset + dataSize <= data.count else { break }
            
            let value: Double
            if dataSize == 4 {
                let val32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
                value = Double(val32)
            } else if dataSize == 8 {
                let val64 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian }
                value = Double(val64)
            } else {
                value = 0
            }
            
            offset += dataSize
            
            let code = OBISCode(channel: channel, index: index, type: type, tariff: tariff)
            if let category = OBISCategory(code: code) {
                measurements.append(category.toMeasurement(code: code, rawValue: value))
            }
        }

        return (serialNumber, ticker, measurements)
    }
}

// MARK: - Listener

class SMAEnergyMeterListener {
    private var connectionGroup: NWConnectionGroup?
    private let queue = DispatchQueue(label: "com.sma.energymeter.queue")
    
    private let smaIP = "239.12.255.254" 
    private let smaPort: UInt16 = 9522
    
    private var lastTicker: UInt32?

    init() {}

    func startListening() {
        do {
            let multicastAddress = NWEndpoint.hostPort(host: .init(smaIP), port: .init(rawValue: smaPort)!)
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true

            let multicastGroup = try NWMulticastGroup(for: [multicastAddress])
            let group = NWConnectionGroup(with: multicastGroup, using: parameters)
            self.connectionGroup = group

            group.stateUpdateHandler = { state in
                switch state {
                case .setup:
                    print("Initializing")
                case .ready:
                    print("Ready: Listen for SMA Energy Meter multicast messages (\(self.smaIP):\(self.smaPort))...")
                case .failed(let error):
                    print("Connection error: \(error.localizedDescription)")
                case .waiting(let error):
                    print("Waiting: \(error.localizedDescription)")
                case .cancelled:
                    print("Cancelled")
                default:
                    break
                }
            }

            group.setReceiveHandler(maximumMessageSize: 2048, rejectOversizedMessages: false) { (_, content, _) in
                guard let data = content else { return }
                self.handleReceivedData(data)
            }

            group.start(queue: queue)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }

    private func handleReceivedData(_ data: Data) {
        do {
            let packet = try SpeedwireParser.parse(data)
            
            let intervalInfo: String
            if let previous = lastTicker {
                let interval = packet.ticker &- previous
                intervalInfo = "Interval: \(interval) ms"
            } else {
                intervalInfo = "First packet: Interval cannot be calculated."
            }

            print("\n--- SMA Message ---")
            print("Serial number: \(packet.serialNumber)")
            print("Ticker: \(packet.ticker) ms")
            print(intervalInfo)
            
            if packet.measurements.isEmpty {
                print("No valid measurements found.")
            } else {
                for m in packet.measurements {
                    print("\(m.description): \(String(format: "%.4f", m.value)) \(m.unit)")
                }
            }
            
            lastTicker = packet.ticker

        } catch {
            print("Parsing error: \(error)")
        }
    }
}

// MARK: - Execution

let listener = SMAEnergyMeterListener()
listener.startListening()

RunLoop.main.run()

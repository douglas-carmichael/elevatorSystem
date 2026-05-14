import Foundation

enum Sim {
    static let floorCount: Int = 10
    static let firstFloor: Int = 1
    static let lastFloor: Int = floorCount

    static let travelFloorsPerSecond: Double = 0.9
    static let doorOpenDuration: Double = 0.7
    static let doorCloseDuration: Double = 0.7
    static let doorDwellDuration: Double = 2.8

    static let autoMinIdleSeconds: Double = 1.5
    static let autoMaxIdleSeconds: Double = 6.0
    static let autoSpawnCount: Int = 3
    static let autoDiscoveryGracePeriod: Double = 3.0

    static let tickHz: Double = 60.0
    static var tickInterval: Double { 1.0 / tickHz }

    static let bonjourServiceType: String = "_elevatorsys._tcp"
    static let bonjourPort: UInt16 = 0
}

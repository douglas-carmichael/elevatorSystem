import Foundation

enum Sim {
    static let floorCount: Int = 10
    static let firstFloor: Int = 1
    static let lastFloor: Int = floorCount

    // Passenger cab profile
    static let paxSpeed: Double = 0.9
    static let paxAccel: Double = 1.0     // floors / sec² ceiling
    static let paxDoorOpen: Double = 0.7
    static let paxDoorClose: Double = 0.7
    static let paxDoorDwell: Double = 2.8

    // Freight cab profile — slower travel, heavier doors, longer loading
    static let freightSpeed: Double = 0.5
    static let freightAccel: Double = 0.6
    static let freightDoorOpen: Double = 1.4
    static let freightDoorClose: Double = 1.6
    static let freightDoorDwell: Double = 5.0

    static let autoMinIdleSeconds: Double = 1.5
    static let autoMaxIdleSeconds: Double = 6.0
    static let autoSpawnCount: Int = 3
    static let autoDiscoveryGracePeriod: Double = 3.0

    static let tickHz: Double = 60.0
    static var tickInterval: Double { 1.0 / tickHz }

    static let bonjourServiceType: String = "_elevatorsys._tcp"
    static let bonjourPort: UInt16 = 0
}

import Foundation
import os

// MARK: - UpTimeLog
//
// Unified logging for the alarm path. Swift print() never reaches the device
// syslog in release builds; os.Logger with public formatting does — which is
// what makes the founder's USB routine work: phone on the cable, the agent
// streams `idevicesyslog` from the PC and verifies the morning against the
// spec without anyone touching the phone.
//
// Messages that the routine matches on are stable, greppable prefixes:
// [ALARM], [AUDIO], [MORNING], [SEED], [STORE], [DELIVERY], [REFERRAL].

enum UpTimeLog {
    private static let subsystem = "com.uptimeprizes.app"

    static let alarm = Logger(subsystem: subsystem, category: "alarm")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let counting = Logger(subsystem: subsystem, category: "counting")
    static let seed = Logger(subsystem: subsystem, category: "seed")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let delivery = Logger(subsystem: subsystem, category: "delivery")
    static let referral = Logger(subsystem: subsystem, category: "referral")
}

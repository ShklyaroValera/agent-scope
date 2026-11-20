import Foundation
import Testing
@testable import AgentScopeKit

struct KeepAwakeTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let policy = KeepAwakePolicy(idleMinutes: 5, minBattery: 20)

    func decide(
        _ mode: KeepAwakeMode, working: Bool = false, lastWorking: TimeInterval? = nil, at seconds: TimeInterval = 0,
        power: KeepAwakePolicy.Power? = nil, hot: Bool = false
    ) -> KeepAwakePolicy.Decision {
        policy.decide(
            mode: mode, agentsWorking: working, lastWorkingAt: lastWorking.map { start.addingTimeInterval($0) },
            enabledAt: start, now: start.addingTimeInterval(seconds), power: power, overheating: hot
        )
    }

    @Test func offSleepsNormally() {
        #expect(decide(.off, working: true) == .sleepNormally)
    }

    @Test func whileWorkingHoldsIdleSleepWithAGrace() {
        #expect(decide(.whileWorking, working: true) == .preventIdleSleep)
        #expect(decide(.whileWorking, lastWorking: 0, at: 60) == .preventIdleSleep)
        #expect(decide(.whileWorking, lastWorking: 0, at: 121) == .sleepNormally)
        #expect(decide(.whileWorking, at: 10) == .sleepNormally)
    }

    @Test func lidClosedHoldsAllSleepWhileAgentsWork() {
        #expect(decide(.lidClosed, working: true, at: 3600) == .preventAllSleep)
        // Just switched on, nothing running yet: give the agents a few minutes to start.
        #expect(decide(.lidClosed, at: 60) == .preventAllSleep)
    }

    @Test func lidClosedTurnsOffAfterAgentsFinish() {
        #expect(decide(.lidClosed, lastWorking: 600, at: 600 + 299) == .preventAllSleep)
        #expect(decide(.lidClosed, lastWorking: 600, at: 600 + 300) == .turnOff(reason: "Agents finished 5 min ago"))
        #expect(decide(.lidClosed, at: 300) == .turnOff(reason: "Agents finished 5 min ago"))
    }

    @Test func lidClosedTurnsOffOnLowBatteryOrHeat() {
        let low = KeepAwakePolicy.Power(percent: 19, charging: false)
        #expect(decide(.lidClosed, working: true, power: low) == .turnOff(reason: "Battery is at 19%"))
        #expect(decide(.lidClosed, working: true, power: .init(percent: 19, charging: true)) == .preventAllSleep)
        #expect(decide(.lidClosed, working: true, power: .init(percent: 20, charging: false)) == .preventAllSleep)
        #expect(KeepAwakePolicy(idleMinutes: 5, minBattery: nil).decide(
            mode: .lidClosed, agentsWorking: true, lastWorkingAt: nil, enabledAt: start, now: start,
            power: low, overheating: false
        ) == .preventAllSleep)
        #expect(decide(.lidClosed, working: true, hot: true) == .turnOff(reason: "Your Mac is running hot"))
    }

    @Test func sudoersRuleAllowsOnlyTheTwoPmsetCommands() {
        #expect(KeepAwakePolicy.sudoersRule(user: "me") ==
            "me ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n")
        #expect(KeepAwakePolicy.sudoersRule(user: "a b") == nil)
        #expect(KeepAwakePolicy.sudoersRule(user: "x,ALL") == nil)
        #expect(KeepAwakePolicy.sudoersRule(user: "") == nil)
    }
}

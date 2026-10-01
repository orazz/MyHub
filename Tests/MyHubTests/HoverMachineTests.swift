import Foundation
import Testing
@testable import MyHub

@Suite struct HoverMachineTests {
    let openRect = CGRect(x: 100, y: 900, width: 200, height: 40)
    let closeRect = CGRect(x: 0, y: 600, width: 400, height: 340)
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let inside = CGPoint(x: 200, y: 920)
    let nearby = CGPoint(x: 200, y: 700)
    let outside = CGPoint(x: 800, y: 100)

    func input(_ point: CGPoint, at ms: Int, isOpen: Bool = false, holding: Bool = false) -> HoverMachine.Input {
        .init(point: point, now: start.addingTimeInterval(Double(ms) / 1000),
              openRect: openRect, closeRect: closeRect, isOpen: isOpen, holding: holding,
              openDelay: 0.05, closeDelay: 0.06)
    }

    @Test func opensOnlyAfterTheDelay() {
        var machine = HoverMachine()
        #expect(machine.step(input(inside, at: 0)) == .none)
        #expect(machine.step(input(inside, at: 30)) == .none)
        #expect(machine.step(input(inside, at: 60)) == .open)
        #expect(machine.pointerInside)
    }

    @Test func aPassingPointerOpensNothing() {
        var machine = HoverMachine()
        #expect(machine.step(input(inside, at: 0)) == .none)
        #expect(machine.step(input(outside, at: 20)) == .none)
        #expect(machine.step(input(outside, at: 200)) == .none)
        #expect(!machine.pointerInside)
    }

    @Test func staysOpenInsideTheLargerCloseRect() {
        var machine = HoverMachine()
        machine.force(inside: true)
        #expect(machine.step(input(nearby, at: 0, isOpen: true)) == .none)
        #expect(machine.step(input(nearby, at: 500, isOpen: true)) == .none)
    }

    @Test func closesAfterLeaving() {
        var machine = HoverMachine()
        machine.force(inside: true)
        #expect(machine.step(input(outside, at: 0, isOpen: true)) == .none)
        #expect(machine.step(input(outside, at: 70, isOpen: true)) == .close)
    }

    @Test func holdingKeepsItOpen() {
        var machine = HoverMachine()
        machine.force(inside: true)
        #expect(machine.step(input(outside, at: 0, isOpen: true, holding: true)) == .none)
        #expect(machine.step(input(outside, at: 1000, isOpen: true, holding: true)) == .none)
    }

    @Test func anIslandOpenedElsewhereClosesWhenThePointerIsAway() {
        var machine = HoverMachine()
        #expect(machine.step(input(outside, at: 0, isOpen: true)) == .none)
        #expect(machine.step(input(outside, at: 100, isOpen: true)) == .close)
    }

    @Test func returningCancelsAPendingClose() {
        var machine = HoverMachine()
        machine.force(inside: true)
        #expect(machine.step(input(outside, at: 0, isOpen: true)) == .none)
        #expect(machine.step(input(nearby, at: 40, isOpen: true)) == .none)
        #expect(machine.step(input(outside, at: 80, isOpen: true)) == .none)
        #expect(machine.step(input(outside, at: 100, isOpen: true)) == .none)
    }
}

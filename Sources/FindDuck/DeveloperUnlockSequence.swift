import Foundation

struct RightClickEasterEggSequence {
    enum Feedback: Equatable { case ignored, flash, unlocked }
    // Physical key codes keep the sequence independent of the current input method.
    private let prefix: [UInt16] = [1, 2, 1, 0, 38, 1, 2, 1, 2] // sdsajsdsd
    private let chord: Set<UInt16> = [38, 37] // J + L
    private(set) var isArmed = false
    private(set) var progress = 0
    private var held: Set<UInt16> = []
    private var chordFirst: UInt16?
    private var chordStartedAt: TimeInterval = 0
    private var lastKeyAt: TimeInterval?

    mutating func arm() {
        self = Self()
        isArmed = true
    }

    mutating func reset() { self = Self() }

    mutating func handle(keyCode: UInt16, isDown: Bool, isRepeat: Bool = false,
                         hasModifiers: Bool = false, at time: TimeInterval) -> Feedback {
        guard isArmed else { return .ignored }
        if !isDown {
            held.remove(keyCode)
            if chordFirst == keyCode { restart() }
            return .ignored
        }
        guard !isRepeat, !held.contains(keyCode) else { return .ignored }
        held.insert(keyCode)
        if hasModifiers {
            restart()
            return .flash
        }
        if let lastKeyAt, time - lastKeyAt > 10 { restart() }
        lastKeyAt = time

        if progress < prefix.count {
            if keyCode == prefix[progress] {
                progress += 1
            } else {
                restart()
                if keyCode == prefix[0] { progress = 1 }
            }
            return .flash
        }

        guard chord.contains(keyCode) else {
            restart()
            if keyCode == prefix[0] { progress = 1 }
            return .flash
        }
        if let first = chordFirst {
            if first != keyCode, held.contains(first), time - chordStartedAt <= 0.18 {
                reset()
                return .unlocked
            }
            restart()
            return .flash
        }
        chordFirst = keyCode
        chordStartedAt = time
        return .flash
    }

    private mutating func restart() {
        progress = 0
        chordFirst = nil
        lastKeyAt = nil
    }
}

import Testing
@testable import CueKit

/// Ports the scenarios of the former native paste regression suite to the extracted rules.
@Suite struct PasteRulesTests {
    private func observe(_ change: (inout PasteRules.Observation) -> Void = { _ in }) -> PasteRules.Observation {
        var o = PasteRules.Observation()
        change(&o)
        return o
    }

    @Test func permissionsAreReportedSeparately() {
        #expect(PasteRules.check(observe(), foreground: false) == nil)
        #expect(PasteRules.check(observe { $0.canRead = false }, foreground: false) == .permission)
        #expect(PasteRules.check(observe { $0.canPost = false }, foreground: false) == .postPermission)
    }

    @Test func activeTargetMustKeepTheExactWindowAndField() {
        #expect(PasteRules.check(observe { $0.secureField = true }, foreground: false) == .protectedInput)
        #expect(PasteRules.check(observe { $0.focusedField = .different }, foreground: false) == .targetChanged)
        // Activation can precede the focus update: an absent focus is retryable.
        #expect(PasteRules.check(observe { $0.focusedField = .missing }, foreground: true) == .focusTimeout)
        // A changed window blocks even when the field is missing.
        #expect(PasteRules.check(observe { $0.focusedWindow = .different; $0.focusedField = .missing }, foreground: true) == .targetChanged)
    }

    @Test func inactiveTargetIsValidatedByExistenceWhileCueIsOpen() {
        // The regression behind TARGET_CHANGED: the app clears its focused field while Cue owns focus.
        #expect(PasteRules.check(observe { $0.front = .cue; $0.focusedField = .missing }, foreground: false) == nil)
        #expect(PasteRules.check(observe { $0.front = .cue; $0.windowExists = false }, foreground: false) == .targetChanged)
        #expect(PasteRules.check(observe { $0.front = .cue; $0.fieldExists = false }, foreground: false) == .targetChanged)
        #expect(PasteRules.check(observe { $0.front = .cue; $0.secureField = true }, foreground: false) == .protectedInput)
        // Never paste before activation.
        #expect(PasteRules.check(observe { $0.front = .cue }, foreground: true) == .focusTimeout)
    }

    @Test func sessionOrAppChangesStopDelivery() {
        #expect(PasteRules.check(observe { $0.front = .other }, foreground: false) == .targetChanged)
        #expect(PasteRules.check(observe { $0.sameSession = false }, foreground: false) == .targetChanged)
        #expect(PasteRules.check(observe { $0.terminated = true }, foreground: false) == .targetChanged)
    }

    @Test func finalGateChecksClipboardAndModifiers() {
        #expect(PasteRules.send(observe(), clipboardUnchanged: true, modifiersHeld: false) == nil)
        #expect(PasteRules.send(observe(), clipboardUnchanged: false, modifiersHeld: false) == .clipboardChanged)
        #expect(PasteRules.send(observe(), clipboardUnchanged: true, modifiersHeld: true) == .modifiersHeld)
        #expect(PasteRules.isRetryable(.modifiersHeld) && PasteRules.isRetryable(.focusTimeout))
        #expect(!PasteRules.isRetryable(.clipboardChanged) && !PasteRules.isRetryable(.targetChanged))
    }
}

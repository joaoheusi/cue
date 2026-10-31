import Testing
@testable import CueKit

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
        #expect(PasteRules.check(observe { $0.focusedField = .missing }, foreground: true) == .focusTimeout)
        #expect(PasteRules.check(observe { $0.focusedWindow = .missing; $0.focusedField = .missing }, foreground: false) == nil)
        #expect(PasteRules.check(observe { $0.focusedWindow = .missing; $0.focusedField = .different }, foreground: false) == .targetChanged)
        #expect(PasteRules.check(observe { $0.focusedWindow = .different; $0.focusedField = .missing }, foreground: true) == .targetChanged)
    }

    @Test func inactiveTargetIsValidatedByExistenceWhileCueIsOpen() {
        #expect(PasteRules.check(observe { $0.front = .cue; $0.focusedField = .missing }, foreground: false) == nil)
        #expect(PasteRules.check(observe { $0.front = .cue; $0.windowExists = false }, foreground: false) == .targetChanged)
        #expect(PasteRules.check(observe { $0.front = .cue; $0.fieldExists = false }, foreground: false) == .targetChanged)
        #expect(PasteRules.check(observe { $0.front = .cue; $0.secureField = true }, foreground: false) == .protectedInput)
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

    @Test func replaceNeedsTheExactOriginalSelection() {
        #expect(PasteRules.replace(original: "hello", current: "hello") == nil)
        #expect(PasteRules.replace(original: "hello", current: "hello world") == .selectionChanged)
        #expect(PasteRules.replace(original: "hello", current: "") == .selectionChanged)
        #expect(PasteRules.replace(original: "hello", current: nil) == .selectionChanged)
        #expect(!PasteRules.isRetryable(.selectionChanged))
    }

    @Test func replaceDoesNotNormalizeTheSelection() {
        #expect(PasteRules.replace(original: "a\nb", current: "a\r\nb") == .selectionChanged)
        #expect(PasteRules.replace(original: "a\r\nb", current: "a\nb") == .selectionChanged)
        #expect(PasteRules.replace(original: "a\r\nb", current: "a\r\nb") == nil)
        #expect(PasteRules.replace(original: "hello", current: "hello ") == .selectionChanged)
        #expect(PasteRules.replace(original: "Hello", current: "hello") == .selectionChanged)
    }
}

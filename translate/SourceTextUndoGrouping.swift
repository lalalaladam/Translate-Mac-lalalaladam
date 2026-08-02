//
//  SourceTextUndoGrouping.swift
//  translate
//

import AppKit

/// Adds user-visible edit boundaries while keeping source history independent
/// from NSTextView's native typing undo implementation.
final class SourceTextUndoGrouping {
    private enum Operation {
        case insertion
        case backwardDeletion
        case forwardDeletion
        case selectionDeletion
    }

    private struct Decision {
        let breakBefore: Bool
        let breakAfter: Bool
        let operation: Operation?

        static let none = Decision(
            breakBefore: false,
            breakAfter: false,
            operation: nil
        )

        static func atomic(_ operation: Operation) -> Decision {
            Decision(
                breakBefore: true,
                breakAfter: true,
                operation: operation
            )
        }
    }

    private enum Group: Equatable {
        case word
        case leadingWhitespace
        case backwardDeletion
        case forwardDeletion
    }

    private enum InsertKind {
        case word
        case whitespace
        case atomic
    }

    private struct Snapshot {
        let text: String
        let selection: NSRange
        let operation: Operation
    }

    private static let maximumHistoryCount = 100

    private var group: Group?
    private var expectedInsertionLocation: Int?
    private var pendingBreakAfter = false
    private var isComposing = false
    private var undoSnapshots: [Snapshot] = []
    private var redoSnapshots: [Snapshot] = []

    func prepareChange(
        in textView: NSTextView,
        affectedRange: NSRange,
        replacementString: String?,
        isPaste: Bool
    ) {
        guard !isComposing,
              !textView.hasMarkedText(),
              let replacementString else {
            return
        }

        let decision = decision(
            affectedRange: affectedRange,
            selection: textView.selectedRange(),
            replacementString: replacementString,
            isPaste: isPaste
        )
        if decision.breakBefore {
            textView.breakUndoCoalescing()
        }
        if let operation = decision.operation {
            recordNewOperation(operation, in: textView)
        }
        pendingBreakAfter = decision.breakAfter
    }

    func textDidChange(in textView: NSTextView) {
        if textView.hasMarkedText() {
            beginCompositionIfNeeded(in: textView)
            pendingBreakAfter = false
            return
        }

        if isComposing {
            finishComposition(in: textView)
            return
        }

        if pendingBreakAfter {
            textView.breakUndoCoalescing()
            pendingBreakAfter = false
        }
    }

    func willSetMarkedText(in textView: NSTextView) {
        beginCompositionIfNeeded(in: textView)
    }

    func didUnmarkText(in textView: NSTextView) {
        guard isComposing else { return }
        finishComposition(in: textView)
    }

    func finishPendingComposition(in textView: NSTextView) {
        guard isComposing, !textView.hasMarkedText() else { return }
        finishComposition(in: textView)
    }

    func beginNewSession(in textView: NSTextView) {
        resetGroupingState()
        undoSnapshots.removeAll()
        redoSnapshots.removeAll()
        textView.undoManager?.removeAllActions()
    }

    func endCurrentGroup(in textView: NSTextView) {
        resetGroupingState()
    }

    func performUndo(in textView: NSTextView) -> Bool {
        endCurrentGroup(in: textView)
        guard let target = undoSnapshots.popLast() else { return false }
        redoSnapshots.append(snapshot(in: textView, operation: target.operation))
        restore(target, in: textView)
        return true
    }

    func performRedo(in textView: NSTextView) -> Bool {
        endCurrentGroup(in: textView)
        guard let target = redoSnapshots.popLast() else { return false }
        appendUndoSnapshot(snapshot(in: textView, operation: target.operation))
        restore(target, in: textView)
        return true
    }

    private func beginCompositionIfNeeded(in textView: NSTextView) {
        guard !isComposing else { return }
        textView.breakUndoCoalescing()
        group = nil
        expectedInsertionLocation = nil
        pendingBreakAfter = false
        isComposing = true
        recordNewOperation(.insertion, in: textView)
    }

    private func finishComposition(in textView: NSTextView) {
        textView.breakUndoCoalescing()
        group = nil
        expectedInsertionLocation = nil
        pendingBreakAfter = false
        isComposing = false
    }

    private func resetGroupingState() {
        group = nil
        expectedInsertionLocation = nil
        pendingBreakAfter = false
        isComposing = false
    }

    private func recordNewOperation(_ operation: Operation, in textView: NSTextView) {
        appendUndoSnapshot(snapshot(in: textView, operation: operation))
        redoSnapshots.removeAll()
    }

    private func snapshot(in textView: NSTextView, operation: Operation) -> Snapshot {
        Snapshot(
            text: textView.string,
            selection: textView.selectedRange(),
            operation: operation
        )
    }

    private func appendUndoSnapshot(_ snapshot: Snapshot) {
        undoSnapshots.append(snapshot)
        if undoSnapshots.count > Self.maximumHistoryCount {
            undoSnapshots.removeFirst(undoSnapshots.count - Self.maximumHistoryCount)
        }
    }

    private func restore(_ snapshot: Snapshot, in textView: NSTextView) {
        textView.undoManager?.disableUndoRegistration()
        textView.string = snapshot.text
        textView.undoManager?.enableUndoRegistration()

        let documentLength = (snapshot.text as NSString).length
        let location = min(snapshot.selection.location, documentLength)
        let length = min(snapshot.selection.length, documentLength - location)
        let selection = NSRange(location: location, length: length)
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)
    }

    private func decision(
        affectedRange: NSRange,
        selection: NSRange,
        replacementString: String,
        isPaste: Bool
    ) -> Decision {
        if replacementString.isEmpty {
            return deletionDecision(
                affectedRange: affectedRange,
                selection: selection
            )
        }

        if isPaste || affectedRange.length > 0 || replacementString.count > 1 {
            group = nil
            expectedInsertionLocation = nil
            return .atomic(.insertion)
        }

        let kind = insertKind(for: replacementString)
        let isAdjacent = expectedInsertionLocation == affectedRange.location
        let decision: Decision

        switch kind {
        case .word:
            let joinsCurrentWord = isAdjacent &&
                (group == .word || group == .leadingWhitespace)
            decision = Decision(
                breakBefore: group != nil && !joinsCurrentWord,
                breakAfter: false,
                operation: joinsCurrentWord ? nil : .insertion
            )
            group = .word

        case .whitespace:
            let joinsWhitespace = isAdjacent && group == .leadingWhitespace
            decision = Decision(
                breakBefore: group != nil && !joinsWhitespace,
                breakAfter: false,
                operation: joinsWhitespace ? nil : .insertion
            )
            // Word associates an inter-word space with the word typed after
            // it, so undoing "alpha beta" removes " beta" as one action.
            group = .leadingWhitespace

        case .atomic:
            group = nil
            expectedInsertionLocation = nil
            return .atomic(.insertion)
        }

        expectedInsertionLocation = affectedRange.location + replacementString.utf16.count
        return decision
    }

    private func deletionDecision(
        affectedRange: NSRange,
        selection: NSRange
    ) -> Decision {
        guard affectedRange.length > 0 else { return .none }

        if selection.length > 0 {
            group = nil
            expectedInsertionLocation = nil
            return .atomic(.selectionDeletion)
        }

        let deletionGroup: Group = affectedRange.location < selection.location
            ? .backwardDeletion
            : .forwardDeletion
        let joinsDeletion = group == deletionGroup &&
            expectedInsertionLocation == selection.location
        group = deletionGroup
        expectedInsertionLocation = affectedRange.location
        let operation: Operation = deletionGroup == .backwardDeletion
            ? .backwardDeletion
            : .forwardDeletion
        return Decision(
            breakBefore: !joinsDeletion,
            breakAfter: false,
            operation: joinsDeletion ? nil : operation
        )
    }

    private func insertKind(for string: String) -> InsertKind {
        guard let character = string.first else { return .atomic }
        let scalars = character.unicodeScalars

        if scalars.contains(where: CharacterSet.newlines.contains) {
            return .atomic
        }
        if scalars.allSatisfy(CharacterSet.whitespaces.contains) {
            return .whitespace
        }
        if scalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                CharacterSet.nonBaseCharacters.contains(scalar) ||
                scalar.value == 0x5F
        }) {
            return .word
        }
        // Punctuation, emoji, and other symbols are deliberately isolated.
        return .atomic
    }
}

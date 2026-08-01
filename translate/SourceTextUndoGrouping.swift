//
//  SourceTextUndoGrouping.swift
//  translate
//

import AppKit

/// Adds user-visible edit boundaries while leaving storage, undo, redo, and
/// selection restoration to NSTextView's native undo manager.
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

    private var group: Group?
    private var expectedInsertionLocation: Int?
    private var pendingBreakAfter = false
    private var isComposing = false
    private var undoOperations: [Operation] = []
    private var redoOperations: [Operation] = []

    func prepareChange(
        in textView: NSTextView,
        affectedRange: NSRange,
        replacementString: String?,
        isPaste: Bool
    ) {
        guard let undoManager = textView.undoManager,
              !undoManager.isUndoing,
              !undoManager.isRedoing,
              !isComposing,
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
            recordNewOperation(operation)
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
        undoOperations.removeAll()
        redoOperations.removeAll()
        textView.undoManager?.removeAllActions()
    }

    func endCurrentGroup(in textView: NSTextView) {
        textView.breakUndoCoalescing()
        resetGroupingState()
    }

    func performUndo(in textView: NSTextView) -> Bool {
        endCurrentGroup(in: textView)
        guard let undoManager = textView.undoManager,
              undoManager.canUndo else { return false }
        let operation = undoOperations.last
        undoManager.undo()
        guard let operation else { return true }

        undoOperations.removeLast()
        redoOperations.append(operation)
        normalizeSelectionAfterUndo(operation, in: textView)
        return true
    }

    func performRedo(in textView: NSTextView) -> Bool {
        endCurrentGroup(in: textView)
        guard let undoManager = textView.undoManager,
              undoManager.canRedo else { return false }
        let operation = redoOperations.last
        undoManager.redo()
        guard let operation else { return true }

        redoOperations.removeLast()
        undoOperations.append(operation)
        return true
    }

    private func beginCompositionIfNeeded(in textView: NSTextView) {
        guard !isComposing else { return }
        textView.breakUndoCoalescing()
        group = nil
        expectedInsertionLocation = nil
        pendingBreakAfter = false
        isComposing = true
        recordNewOperation(.insertion)
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

    private func recordNewOperation(_ operation: Operation) {
        undoOperations.append(operation)
        redoOperations.removeAll()
    }

    private func normalizeSelectionAfterUndo(
        _ operation: Operation,
        in textView: NSTextView
    ) {
        let restoredRange = textView.selectedRange()
        guard restoredRange.length > 0 else { return }

        let caretLocation: Int
        switch operation {
        case .backwardDeletion:
            caretLocation = NSMaxRange(restoredRange)
        case .forwardDeletion:
            caretLocation = restoredRange.location
        case .insertion, .selectionDeletion:
            return
        }

        let documentLength = textView.string.utf16.count
        guard caretLocation <= documentLength else { return }
        let caretRange = NSRange(location: caretLocation, length: 0)
        textView.setSelectedRange(caretRange)
        textView.scrollRangeToVisible(caretRange)
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

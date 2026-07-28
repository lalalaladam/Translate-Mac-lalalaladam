import Cocoa

final class WorkspaceIconButton: NSButton {
    init(image: NSImage, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
        bezelStyle = .inline
        isBordered = false
        focusRingType = .none
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            animator().alphaValue = 0.48
        }
        super.mouseDown(with: event)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 1
        }
    }
}

/// Text swap control with the same mouse-down feedback as the footer icon
/// buttons. Keeping the feedback inside mouseDown makes it visible before the
/// language reload starts, instead of being hidden by the action that follows.
final class WorkspaceSwapButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .inline
        isBordered = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            animator().alphaValue = 0.48
        }
        super.mouseDown(with: event)
        restoreNormalAppearance()
    }

    func flashForKeyboardShortcut() {
        alphaValue = 0.48
        restoreNormalAppearance()
    }

    private func restoreNormalAppearance() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 1
        }
    }
}

/// Text-only language control.  NSButton's inline style grows a rounded
/// system background around titles on newer macOS releases, so use a truly
/// borderless bezel and draw only the language name.
final class WorkspaceLanguageButton: NSButton {
    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .shadowlessSquare
        isBordered = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        alignment = .center
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}

final class AppearanceObservingView: NSView {
    var effectiveAppearanceDidChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearanceDidChange?()
    }
}

enum NativeLanguagePickerSide {
    case source
    case target
}

final class NativeLanguagePickerController: NSViewController,
    NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let side: NativeLanguagePickerSide
    private let selectedLanguage: TranslateLanguage
    private let didSelect: (TranslateLanguage) -> Void
    private var languages: [TranslateLanguage] = []
    private var filteredLanguages: [TranslateLanguage] = []
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private var isApplyingSelection = false

    init(
        side: NativeLanguagePickerSide,
        selectedLanguage: TranslateLanguage,
        didSelect: @escaping (TranslateLanguage) -> Void
    ) {
        self.side = side
        self.selectedLanguage = selectedLanguage
        self.didSelect = didSelect
        super.init(nibName: nil, bundle: nil)
        languages = TranslateLanguage.allCases
            .filter { side == .source || $0.canBeTarget }
            .sorted { lhs, rhs in
                if lhs == .automatic { return true }
                if rhs == .automatic { return false }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        filteredLanguages = languages
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 390)
        )
        // Use the same behind-window glass treatment as the main translator
        // surface. The popover material is intentionally avoided because it
        // produces a denser grey sheet than the app's transparent window.
        background.material = isDark ? .dark : .light
        background.blendingMode = .behindWindow
        background.state = .active
        view = background

        searchField.placeholderString = interfaceText("搜索语言", "Search languages")
        searchField.delegate = self
        // NSSearchField renders an additional internal icon/well inside a
        // vibrancy popover on recent macOS versions. A plain text field plus
        // one explicit icon prevents the doubled, overlapping placeholder.
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 15)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let searchIcon = NSImageView(
            image: (NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))) ?? NSImage()
        )
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        let searchSurface = NSVisualEffectView()
        searchSurface.translatesAutoresizingMaskIntoConstraints = false
        searchSurface.material = isDark ? .dark : .light
        searchSurface.blendingMode = .withinWindow
        searchSurface.state = .active
        searchSurface.wantsLayer = true
        searchSurface.layer?.cornerRadius = 11
        searchSurface.layer?.masksToBounds = true
        searchSurface.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(isDark ? 0.08 : 0.045).cgColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        column.width = 276
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.delegate = self
        tableView.dataSource = self
        scrollView.documentView = tableView

        view.addSubview(searchSurface)
        view.addSubview(searchIcon)
        view.addSubview(searchField)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            searchSurface.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            searchSurface.heightAnchor.constraint(equalToConstant: 36),
            searchIcon.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 10),
            searchIcon.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchSurface.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let row = filteredLanguages.firstIndex(of: selectedLanguage) ?? -1
        if row >= 0 {
            isApplyingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            isApplyingSelection = false
        }
        view.window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isApplyingSelection = true
        tableView.deselectAll(nil)
        if query.isEmpty {
            filteredLanguages = languages
        } else {
            filteredLanguages = languages.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                    $0.rawValue.localizedCaseInsensitiveContains(query)
            }
        }
        tableView.reloadData()
        isApplyingSelection = false
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (searchField.currentEditor() as? NSTextView)?.insertionPointColor = .labelColor
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredLanguages.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("language-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier

        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let language = filteredLanguages[row]
        label.stringValue = language == selectedLanguage ? "✓  \(language.title)" : language.title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection,
              tableView.selectedRow >= 0,
              tableView.selectedRow < filteredLanguages.count else {
            return
        }
        didSelect(filteredLanguages[tableView.selectedRow])
    }
}

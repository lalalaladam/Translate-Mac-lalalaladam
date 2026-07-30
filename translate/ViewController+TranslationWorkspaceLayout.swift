//
//  ViewController+WorkspaceLayout.swift
//  translate
//

import Cocoa

extension ViewController {
    func updateWorkspaceLayoutIfNeeded() {
        guard let splitView = workspaceSplitView,
              let overlay = longTextOverlay else { return }

        // Match the old web view's responsive behavior: once two panes would
        // be narrower than a comfortable reading column, stack them and keep
        // each source/result line close to the full window width.
        let shouldStack = overlay.bounds.width < 720
        guard shouldStack != workspaceUsesStackedLayout else { return }
        workspaceUsesStackedLayout = shouldStack

        // Changing NSSplitView.isVertical during a layout pass otherwise lets
        // AppKit paint one frame of the old divider (a noticeable dark bar).
        // Commit the orientation, constraints, and the resulting layout as a
        // single transaction with implicit layer actions disabled.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        splitView.isVertical = !shouldStack
        workspaceEqualWidthConstraint?.isActive = !shouldStack
        workspaceEqualHeightConstraint?.isActive = shouldStack
        workspaceSplitBottomConstraint?.constant = shouldStack ? 0 : -12

        splitView.needsLayout = true
        view.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        splitView.displayIfNeeded()

        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    func installLongTextOverlay() {
        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true

        let sourceLanguageButton = WorkspaceLanguageButton(
            target: self,
            action: #selector(workspaceSourceLanguageClicked)
        )
        sourceLanguageButton.toolTip = interfaceText("选择源语言", "Choose source language")

        let swapButton = WorkspaceSwapButton(
            title: "⇄",
            target: self,
            action: #selector(workspaceSwapLanguages)
        )
        swapButton.toolTip = interfaceText("交换源语言和目标语言", "Swap source and target languages")

        let targetLanguageButton = WorkspaceLanguageButton(
            target: self,
            action: #selector(workspaceTargetLanguageClicked)
        )
        targetLanguageButton.toolTip = interfaceText("选择目标语言", "Choose target language")

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        ([sourceLanguageButton, swapButton, targetLanguageButton] as [NSView]).forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview($0)
        }
        swapButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        swapButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let sourceHeaderGuide = NSLayoutGuide()
        let targetHeaderGuide = NSLayoutGuide()
        header.addLayoutGuide(sourceHeaderGuide)
        header.addLayoutGuide(targetHeaderGuide)
        NSLayoutConstraint.activate([
            sourceHeaderGuide.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            sourceHeaderGuide.trailingAnchor.constraint(equalTo: swapButton.leadingAnchor, constant: -18),
            targetHeaderGuide.leadingAnchor.constraint(equalTo: swapButton.trailingAnchor, constant: 18),
            targetHeaderGuide.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            sourceHeaderGuide.widthAnchor.constraint(equalTo: targetHeaderGuide.widthAnchor),
            sourceLanguageButton.centerXAnchor.constraint(equalTo: sourceHeaderGuide.centerXAnchor),
            targetLanguageButton.centerXAnchor.constraint(equalTo: targetHeaderGuide.centerXAnchor)
        ])

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sourceLabel = NSTextField(labelWithString: "")
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.textColor = .labelColor
        sourceLabel.alignment = .right
        let translationLabel = NSTextField(labelWithString: "")
        translationLabel.font = .systemFont(ofSize: 12, weight: .medium)
        translationLabel.textColor = .labelColor
        translationLabel.alignment = .right
        translationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let sourceView = makeLongTextView(editable: true)
        sourceView.delegate = self
        let translationView = makeLongTextView(editable: false)
        let sourceScroll = makeLongTextScrollView(with: sourceView)
        let translationScroll = makeLongTextScrollView(with: translationView)
        let (sourcePronunciationRow, sourcePronunciationLabel) = makePronunciationRow()
        let (translationPronunciationRow, translationPronunciationLabel) = makePronunciationRow()

        // Keep footer actions secondary to the word/character count.  The
        // 30pt button frame remains an easy click target, while the SF Symbol
        // itself stays visually quieter.
        let footerIconConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let clearButton = WorkspaceIconButton(
            image: (NSImage(systemSymbolName: "trash", accessibilityDescription: interfaceText("清除原文", "Clear source"))?
                .withSymbolConfiguration(footerIconConfiguration)) ?? NSImage(),
            target: self,
            action: #selector(workspaceClearSource)
        )
        clearButton.toolTip = interfaceText("清除原文", "Clear source")
        clearButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        clearButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let sourceCopyButton = WorkspaceIconButton(
            image: (NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: interfaceText("复制原文", "Copy source"))?
                .withSymbolConfiguration(footerIconConfiguration)) ?? NSImage(),
            target: self,
            action: #selector(workspaceCopySource)
        )
        sourceCopyButton.toolTip = interfaceText("复制原文", "Copy source")
        sourceCopyButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        sourceCopyButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let sourceSpeakButton = WorkspaceIconButton(
            image: (NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: interfaceText("朗读原文", "Speak source"))?
                .withSymbolConfiguration(footerIconConfiguration)) ?? NSImage(),
            target: self,
            action: #selector(workspaceSpeakSource)
        )
        sourceSpeakButton.toolTip = interfaceText(
            "朗读原文（再次点击停止）",
            "Speak source (click again to stop)"
        )
        sourceSpeakButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        sourceSpeakButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let translationCopyButton = WorkspaceIconButton(
            image: (NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: interfaceText("复制译文", "Copy translation"))?
                .withSymbolConfiguration(footerIconConfiguration)) ?? NSImage(),
            target: self,
            action: #selector(workspaceCopyTranslation)
        )
        translationCopyButton.toolTip = interfaceText("复制译文", "Copy translation")
        translationCopyButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        translationCopyButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let translationSpeakButton = WorkspaceIconButton(
            image: (NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: interfaceText("朗读译文", "Speak translation"))?
                .withSymbolConfiguration(footerIconConfiguration)) ?? NSImage(),
            target: self,
            action: #selector(workspaceSpeakTranslation)
        )
        translationSpeakButton.toolTip = interfaceText(
            "朗读译文（再次点击停止）",
            "Speak translation (click again to stop)"
        )
        translationSpeakButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        translationSpeakButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        // Keep the source count and result status away from the split divider;
        // putting both labels at the centre makes them read as one string.
        let sourceFooter = NSStackView(views: [clearButton, sourceSpeakButton, sourceCopyButton, sourceLabel, NSView()])
        sourceFooter.orientation = .horizontal
        sourceFooter.alignment = .centerY
        sourceFooter.spacing = 12
        sourceFooter.setContentHuggingPriority(.required, for: .vertical)
        sourceFooter.setContentCompressionResistancePriority(.required, for: .vertical)
        sourceFooter.heightAnchor.constraint(equalToConstant: 32).isActive = true
        sourceFooter.views[4].setContentHuggingPriority(.defaultLow, for: .horizontal)
        let translationFooter = NSStackView(views: [NSView(), status, translationSpeakButton, translationCopyButton, translationLabel])
        translationFooter.orientation = .horizontal
        translationFooter.alignment = .centerY
        translationFooter.spacing = 12
        translationFooter.setContentHuggingPriority(.required, for: .vertical)
        translationFooter.setContentCompressionResistancePriority(.required, for: .vertical)
        translationFooter.heightAnchor.constraint(equalToConstant: 32).isActive = true
        translationFooter.views[0].setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Scroll views must take the remaining pane height, rather than
        // collapsing around a short sentence and leaving their footer at the
        // divider.  This also gives both stacked panes identical footers.
        sourceScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        sourceScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        translationScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        translationScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let sourceStack = NSStackView(views: [sourceScroll, sourcePronunciationRow, sourceFooter])
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 0
        sourceStack.translatesAutoresizingMaskIntoConstraints = false
        sourceScroll.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
        sourcePronunciationRow.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
        sourceFooter.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true

        let translationStack = NSStackView(views: [
            translationScroll,
            translationPronunciationRow,
            translationFooter
        ])
        translationStack.orientation = .vertical
        translationStack.alignment = .leading
        translationStack.spacing = 0
        translationStack.translatesAutoresizingMaskIntoConstraints = false
        translationScroll.widthAnchor.constraint(equalTo: translationStack.widthAnchor).isActive = true
        translationPronunciationRow.widthAnchor.constraint(equalTo: translationStack.widthAnchor).isActive = true
        translationFooter.widthAnchor.constraint(equalTo: translationStack.widthAnchor).isActive = true

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(sourceStack)
        splitView.addArrangedSubview(translationStack)

        overlay.addSubview(header)
        overlay.addSubview(splitView)
        view.addSubview(
            overlay,
            positioned: .above,
            relativeTo: workspaceBackgroundView ?? webView
        )
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Self.windowBehaviorBarHeight
            ),
            header.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 4),
            header.heightAnchor.constraint(equalToConstant: 36),
            sourceLanguageButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sourceLanguageButton.widthAnchor.constraint(lessThanOrEqualTo: sourceStack.widthAnchor, constant: -36),
            swapButton.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            swapButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            targetLanguageButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            targetLanguageButton.widthAnchor.constraint(lessThanOrEqualTo: translationStack.widthAnchor, constant: -36),
            splitView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
            splitView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
            splitView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2)
        ])

        workspaceSplitBottomConstraint = splitView.bottomAnchor.constraint(
            equalTo: overlay.bottomAnchor,
            constant: -12
        )
        workspaceSplitBottomConstraint?.isActive = true

        workspaceEqualWidthConstraint = sourceStack.widthAnchor.constraint(equalTo: translationStack.widthAnchor)
        workspaceEqualHeightConstraint = sourceStack.heightAnchor.constraint(equalTo: translationStack.heightAnchor)
        workspaceEqualWidthConstraint?.isActive = true

        longTextOverlay = overlay
        longTextSourceView = sourceView
        longTextTranslationView = translationView
        longTextStatusLabel = status
        longTextSourceLabel = sourceLabel
        longTextTranslationLabel = translationLabel
        self.sourcePronunciationRow = sourcePronunciationRow
        self.translationPronunciationRow = translationPronunciationRow
        self.sourcePronunciationLabel = sourcePronunciationLabel
        self.translationPronunciationLabel = translationPronunciationLabel
        workspaceSourceLanguageButton = sourceLanguageButton
        workspaceTargetLanguageButton = targetLanguageButton
        workspaceSwapButton = swapButton
        workspaceSplitView = splitView
        workspaceSourceStack = sourceStack
        workspaceTranslationStack = translationStack
        workspaceSourceCountLabel = sourceLabel
        workspaceTranslationCountLabel = translationLabel
        updateLongTextOverlayAppearance()
    }

    func makePronunciationRow() -> (NSView, NSTextField) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        row.isHidden = true

        let leadingInset = NSView()
        leadingInset.translatesAutoresizingMaskIntoConstraints = false
        leadingInset.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)

        let trailingSpace = NSView()
        trailingSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(leadingInset)
        row.addArrangedSubview(label)
        row.addArrangedSubview(trailingSpace)
        return (row, label)
    }

    func makeLongTextView(editable: Bool) -> NSTextView {
        let view: AlignmentTextView = editable
            ? TranslationSourceTextView()
            : TranslationResultTextView()
        if let sourceView = view as? TranslationSourceTextView {
            sourceView.onPasteReceived = { [weak self] text in
                self?.logTranslationCoordinator("native-paste-received", source: text)
            }
        }
        view.alignmentMenuTitle = editable
            ? interfaceText("在译文中定位对应句", "Find Corresponding Text in Translation")
            : interfaceText("在原文中定位对应句", "Find Corresponding Text in Source")
        view.onFindCorrespondingText = { [weak self] textView in
            self?.findCorrespondingText(from: textView, isSource: editable)
        }
        view.alignmentIsEnabled = { [weak self] textView in
            self?.alignmentSelection(in: textView) != nil
        }
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsImageEditing = false
        view.allowsUndo = true
        // Translation output must remain byte-for-byte equivalent to the
        // service response. Do not let AppKit reinterpret dates, links,
        // quotes, dashes, spelling, or replacement text while rendering it.
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.drawsBackground = false
        // Match the visible Google typography used before the native rewrite:
        // 18 px text on a fixed 28 px line. AppKit's default line metric is
        // much tighter, so define the paragraph style explicitly.
        let font = NSFont.systemFont(ofSize: 18)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = 28
        paragraphStyle.maximumLineHeight = 28
        view.font = font
        view.defaultParagraphStyle = paragraphStyle
        let textColor: NSColor = isDarkMode ? .white : .black
        view.textColor = textColor
        view.insertionPointColor = textColor
        view.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        // Keep the reading inset comfortable while allowing the final line
        // to sit closer to its footer actions when the text is scrolled down.
        view.textContainerInset = NSSize(width: 18, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.textContainer?.widthTracksTextView = true
        return view
    }

    func makeLongTextScrollView(with textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        // Let the parent vibrancy material remain visible in both light and
        // dark mode. The standard bezel draws an opaque white background.
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.borderWidth = 0.5
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor
        return scrollView
    }

    func updateLongTextOverlayAppearance() {
        applyWorkspaceTypography(to: longTextSourceView)
        applyWorkspaceTypography(to: longTextTranslationView)
        let textColor: NSColor = isDarkMode ? .white : .black
        longTextStatusLabel?.textColor = textColor
        longTextSourceLabel?.textColor = textColor
        longTextTranslationLabel?.textColor = textColor
        let pronunciationColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.72)
            : NSColor.secondaryLabelColor
        sourcePronunciationLabel?.textColor = pronunciationColor
        translationPronunciationLabel?.textColor = pronunciationColor
        refreshPronunciationDisplayLabels()
        refreshWorkspaceLanguageTitles()
    }

    func applyWorkspaceTypography(to view: NSTextView?) {
        guard let view else { return }
        let font = NSFont.systemFont(ofSize: 18)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = 28
        paragraphStyle.maximumLineHeight = 28
        let textColor: NSColor = isDarkMode ? .white : .black
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        view.font = font
        view.defaultParagraphStyle = paragraphStyle
        view.textColor = textColor
        view.insertionPointColor = textColor
        view.typingAttributes = attributes
        if !view.string.isEmpty {
            view.textStorage?.setAttributes(
                attributes,
                range: NSRange(location: 0, length: (view.string as NSString).length)
            )
        }
    }

}

//
//  ViewController+ConnectionOverlay.swift
//  translate
//

import Cocoa

extension ViewController {
    func installConnectionOverlay() {
        let overlay = NSVisualEffectView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.material = .popover
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 12

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.maximumNumberOfLines = 2

        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 390

        let retryButton = NSButton(
            title: interfaceText("立即重试", "Retry Now"),
            target: self,
            action: #selector(retryTranslationService)
        )
        retryButton.bezelStyle = .rounded

        let stack = NSStackView(views: [spinner, title, detail, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(stack)
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
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24)
        ])

        connectionOverlay = overlay
        connectionTitleLabel = title
        connectionDetailLabel = detail
        connectionSpinner = spinner
        connectionRetryButton = retryButton
        // The service load starts later in this same view lifecycle. Keep the
        // cover visible from the first rendered frame so the editor can never
        // appear interactive before WebKit and its warmup are ready.
        showConnectionOverlay(waitingForNetwork: true)
    }

}

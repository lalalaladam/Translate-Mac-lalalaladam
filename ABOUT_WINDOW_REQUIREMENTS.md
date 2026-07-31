# About Window Requirements

These requirements apply whenever the About window is created, modified,
debugged, reviewed, or rebuilt.

## Required Content and Order

The About window must preserve this order:

1. Application icon
2. Application name
3. Standard version line:

       Version X.Y.Z (Build N)

4. Debug metadata, in Debug builds only:

       Version: vX.Y.Z
       Build: N
       Commit: <hash>
       Status: <clean/dirty>
       Build Time: <timestamp>

5. Attribution and Credits

The Attribution and Credits section must permanently retain:

- GitHub information
- Original author attribution
- Original project information
- License and acknowledgement information

Release builds may hide only the Debug metadata section. They must not remove,
hide, collapse, truncate, or move Attribution or Credits to an inaccessible
secondary interface.

## Custom Window and Ownership

- Do not use `orderFrontStandardAboutPanel` or
  `orderFrontStandardAboutPanel(options:)`.
- Use a custom native `NSWindow` managed by `AboutWindowController`.
- The existing About menu item must use `AppDelegate` as its explicit,
  non-nil target.
- Do not rely on the responder chain for the About action.
- Use the uniquely named Objective-C action:

      @objc func showTranslateCustomAbout(_ sender: Any?)

- `AppDelegate` must retain `AboutWindowController` in a strong property.
- Do not create the controller only as a local variable.
- Set `NSWindow.isReleasedWhenClosed = false`.
- Closing and reopening About must reuse or safely recreate a working
  controller.

## Safe Construction and Presentation

- Give the window a valid, non-zero initial content size.
- Controller initialization must complete without depending on content fitting
  or recursive layout calculation.
- The initializer should create and configure only the window.
- Do not call `layoutSubtreeIfNeeded()`, read `fittingSize`, or perform
  potentially circular Auto Layout sizing from the controller initializer.
- Build or rebuild the content only after the controller has been assigned to
  the strong `AppDelegate` property.
- A layout or sizing failure must not prevent controller initialization from
  returning.
- Activate the application before presenting About.
- Do not assume a missing window is caused by Spaces until the menu action and
  controller initialization have been confirmed.

Recommended presentation order:

    NSApp.activate(ignoringOtherApps: true)

    if aboutWindowController == nil {
        aboutWindowController = AboutWindowController()
    }

    aboutWindowController?.rebuildContent()
    aboutWindowController?.showWindow(nil)
    aboutWindowController?.window?.makeKeyAndOrderFront(nil)
    aboutWindowController?.window?.orderFrontRegardless()

## Absolute No-Scroll Hierarchy

- The complete visible About hierarchy must be non-scrollable.
- Do not use `NSScrollView`, SwiftUI `ScrollView`, `List`, `Form`, `Table`,
  `TextEditor`, or another scroll-capable container.
- Do not retain a scroll view while merely hiding or disabling its indicators.
- Use non-scrollable native controls such as:
  - `NSView`
  - `NSImageView`
  - `NSTextField`
  - `NSStackView`
  - `NSBox`
- All required content must be visible simultaneously when the window first
  opens.
- Trackpad and mouse-wheel input must not move any About content.

## Deterministic Sizing

- The final content size must display the application icon, application name,
  standard version line, Debug metadata when present, and all Credits.
- Debug and Release builds may use different independently verified sizes.
- Prefer deterministic fixed or manually calculated sizing when the content is
  static.
- Do not allow the window to be resized below the size required to display all
  content.
- Set `contentMinSize` and `contentMaxSize` appropriately when using a fixed
  layout.
- Do not create ambiguous constraints or circular intrinsic-size calculations.
- If Auto Layout fitting is used, perform it only after initialization and
  verify that it produces a finite, non-zero size.
- Do not solve overflow by clipping, truncating, hiding Credits, removing
  attribution, or reducing text to an unreadable size.

## Alignment

The following elements must be explicitly horizontally centered:

- application icon
- application name
- standard version line
- every Debug metadata line
- Attribution and Credits text

For AppKit text fields, set:

    textField.alignment = .center

Centering the text field frame alone is insufficient. Multiline text must also
use centered paragraph alignment. Debug metadata may use a monospaced font, but
it must remain centered.

## Runtime Verification Scope

- Build and launch only the configuration explicitly requested by the user.
- A Debug-only request requires Debug runtime verification only.
- A Release-only request requires Release runtime verification only.
- Do not build, launch, archive, sign, notarize, or validate Release unless the
  user explicitly requests Release work.
- When preparing an official Release or changing behavior that intentionally
  differs by build configuration, verify both Debug and Release.
- Do not claim that an untested configuration was verified.

For each configuration within the requested verification scope:

1. Launch the exact newly built application binary.
2. Click the existing About menu item.
3. Confirm the custom action is invoked.
4. Confirm the window becomes visible and key.
5. Confirm all required content is visible simultaneously and in the required
   order.
6. Confirm all required text and the icon are centered.
7. Confirm no vertical or horizontal scroll bar exists.
8. Confirm trackpad and mouse-wheel input cannot move the content.
9. Inspect the complete About accessibility or view hierarchy and confirm that
   no scroll-capable container exists.
10. Close and reopen About to confirm controller retention works.

A successful build alone is not sufficient verification.

If presentation fails, temporarily log:

1. the menu item's actual target and action
2. entry into `showTranslateCustomAbout(_:)`
3. entry and completion of `AboutWindowController` initialization
4. state immediately before and after ordering the window front

Do not guess that Spaces or placement caused the failure before these stages
have been verified. Remove temporary diagnostic logs after the issue is
resolved.

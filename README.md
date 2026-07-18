# Translate Custom

An unofficial, redesigned macOS translation app built around Google Translate in a compact native window. This project started from [m-inan/mac-translate](https://github.com/m-inan/mac-translate), but has since received substantial feature extensions, interface changes, and window-behavior refactoring. It is not an official version of the original project and is not endorsed by its author.

## Current version

The current release is [Translate v1.3.17](https://github.com/lalalaladam/mac-translate-custom/releases/tag/v1.3.17).

![Translate v1.3.17 interface](media/translate-v1.3.17.png)

The screenshot shows the current compact interface with the native macOS **Translate** (`翻译`), **Languages** (`语言`), **Interface Language** (`界面语言`), **Display** (`显示`), and **Window** (`窗口`) menus, language controls, and the optional window-behavior bar.

## Features

- Google Translate embedded in a native Cocoa/AppKit window through `WKWebView`.
- Compact two-pane translation interface with selectable source and result text.
- Copy selected text or copy all source/result text from the native Translate menu.
- Configurable global and in-window keyboard shortcuts with duplicate detection and restore-defaults support.
- Native macOS **Translate** (`翻译`), **Languages** (`语言`), **Display** (`显示`), **Window** (`窗口`), and **Interface Language** (`界面语言`) menus.
- Persistent default source and target languages, with source-only automatic detection.
- 134 language entries in the language menu, subject to Google Translate availability.
- Simplified Chinese and English interface modes, including matching Google Translate locale labels.
- Optional compact-interface controls for pinyin/transliteration, Google selection actions, source/result action buttons, and selected-language highlighting.
- **Copy All Source Text** (`复制全部原文`), **Copy All Translation** (`复制全部译文`), source-copy control, result-copy-only toolbar, and cleanup of unwanted Google controls and overlays.
- Automatic window presentation on launch, connection feedback, retry handling, and manual retry support.
- macOS dark/light appearance-aware native controls.

## Improvements over the original project

Compared with the original [mac-translate](https://github.com/m-inan/mac-translate), this version includes:

- A native Carbon global hotkey implementation with editable **Shortcut Settings…** (`快捷键设置…`).
- A normal, activatable macOS window instead of a permanently floating panel.
- Independent current-Space **Keep on Top** (`置顶`) and **Show on All Spaces** (`所有 Space 显示`) preferences.
- Support for summoning the window from another application’s full-screen Space on macOS 13 and later.
- Persistent language, interface-language, display, and window-behavior preferences.
- Cold-launch presentation that does not wait for Google Translate or network readiness.
- Safer text selection, copying, dragging, and native menu behavior inside the web view.
- More extensive Google Translate DOM/CSS cleanup, including pinyin, selection toolbars, detail overlays, feedback controls, and extra action buttons.
- Input and result-rendering stability improvements, including coalesced DOM cleanup while typing and prevention of the result-toolbar “G” button flash.

## Download and installation

Download the latest release from the [GitHub Releases page](https://github.com/lalalaladam/mac-translate-custom/releases/latest). For v1.3.17, download `Translate-v1.3.17.zip`, unzip it, and move `Translate.app` to `/Applications`.

Because the app is distributed outside the Mac App Store and uses an ad-hoc/local signature, macOS may require approval under **System Settings → Privacy & Security → Open Anyway** the first time it is opened.

## Configuration

The initial default direction is **English** (`英语`) → **Chinese (Simplified)** (`中文（简体）`). Use the native **Languages** (`语言`) menu to choose a persistent default source and target language. Use **Apply Default Languages** (`应用默认语言`) to return to the saved pair after changing languages within Google Translate, or **Restore English → Chinese (Simplified)** (`恢复为英语 → 中文（简体）`) to restore the initial pair.

The **Display** (`显示`) menu controls four independent compact-interface options:

- **Hide Pinyin and Transliteration** (`隐藏拼音与音译`)
- **Hide Google Selection Toolbar** (`隐藏 Google 选词工具栏`)
- **Simplify Source and Result Actions** (`精简左右操作按钮`)
- **Highlight Selected Translation Languages** (`突出当前翻译语言`)

All four are enabled by default and can be restored with **Restore Recommended Display Settings** (`恢复推荐显示设置`).

## Keyboard shortcuts

All shortcuts can be changed from **Translate** (`翻译`) → **Shortcut Settings…** (`快捷键设置…`). The defaults below are read from the current source code and can be restored at any time.

| Default shortcut | Action |
| --- | --- |
| `⌘\\` | Show or hide the window globally (`全局显示或隐藏窗口`) |
| `⌘W` | Close/hide the window without quitting (`关闭/隐藏窗口但不退出应用`) |
| `⌘H` | Hide the application (`隐藏应用`) |
| `⌘Q` | Quit the application (`退出应用`) |
| `⌘A` | Select all source text (`选中全部原文`) |
| `⌘L` | Listen to the source text (`朗读原文`) |
| `⌘S` | Swap languages (`交换语言`) |
| `⌘↩` | Apply Google spelling correction when available (`应用 Google 拼写修正`) |
| `Tab` | Move focus out of the translation window (`将焦点移出翻译窗口`) |
| `⌘Z` | Undo (`撤销`) |
| `⌘R` | Redo (`重做`) |
| `⌘X` | Cut (`剪切`) |
| `⌘C` | Copy selected text (`复制所选文字`) |
| `⌘V` | Paste (`粘贴`) |

The native **Translate** (`翻译`) menu also provides **Copy All Source Text** (`复制全部原文`) and **Copy All Translation** (`复制全部译文`); these commands do not have default keyboard equivalents.

## Window and Spaces behavior

The translation window opens automatically on a cold launch and can be shown or hidden with the global shortcut or the native Translate menu. Closing the window hides it without terminating the application.

Under **Window** (`窗口`), the following preferences are independent and disabled by default:

- **Keep on Top in the Current Space** (`当前 Space 置顶`) keeps the window above normal windows in its current Space.
- **Show on All Spaces** (`所有 Space 显示`) makes the window available across Spaces. On macOS 13 and later, it can also be summoned over another application’s full-screen Space (`全屏 Space`).

Blank areas of the interface can be used to drag the window, while text areas retain selection and copying priority.

## Interface and translation language settings

The **Interface Language** (`界面语言`) menu switches between **Simplified Chinese** (`简体中文`) and **English** (`英语`) for native menus and Google Translate’s language labels. The choice is saved across launches. Changing it preserves the current source text and temporary translation direction.

The **Languages** (`语言`) menu stores the default translation pair independently from temporary changes made inside Google Translate. **Automatic Detection** (`自动检测`) is available only for the source language, and the app avoids saving the same language as both source and target.

## System requirements

- macOS 12.4 or later
- Apple Silicon (`arm64`) release build
- Network access to Google Translate
- A working internet connection, VPN, or system proxy where Google Translate is not directly reachable

This is a native macOS application and is not intended to run on Windows. It is not an offline translation engine; translation depends on Google Translate and its web interface, which may change independently of this project.

## Credits

This project is based on [Mac Translate by m-inan](https://github.com/m-inan/mac-translate). The original author and project are explicitly credited for the starting implementation and concept. This repository is an unofficial independent customization and is not affiliated with or endorsed by Google or m-inan.

## Reporting issues and contributing

Please [open an issue](https://github.com/lalalaladam/mac-translate-custom/issues) with reproduction steps, macOS version, app version, and relevant screenshots or logs. Contributions and focused pull requests are welcome. Changes involving Google Translate selectors should include a clear explanation of the affected interface behavior.

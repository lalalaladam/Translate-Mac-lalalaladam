# Comparison with the Original mac-translate

This document compares the original `mac-translate` project by [m-inan](https://github.com/m-inan/mac-translate) with this customized version.

| Area | Original Version | Revised Version | Benefit |
|---|---|---|---|
| Global shortcut | Uses the third-party `HotKey` package | Uses a native Carbon global hotkey | Removes the external hotkey dependency and improves background shortcut reliability |
| Window activation | Does not explicitly activate the application before showing the panel | Activates the application and brings the window to the front | The window appears even when another application is active |
| Shortcut toggle behavior | Mainly depends on `isPresented` and key-window state | Hides only when visible and frontmost; otherwise brings the window forward | `Command + \\` behaves as a predictable show/hide toggle |
| Window level | Uses a floating panel that remains above normal windows | Uses a normal window level | The translation window is no longer permanently always-on-top |
| Window type | Non-activating floating panel | Activatable normal panel | Behaves more like a standard macOS window |
| Window closing | Closing normally closes the panel | Closing hides and reuses the panel | The global shortcut can show it again reliably |
| Window dragging | Dragging inside the WebView generally moves the entire window | Only non-text areas drag the window | Text can be selected without losing normal window dragging |
| Source text selection | Text selection is interfered with by window dragging | Source text can be partially selected and copied | Individual words and sentences can be copied |
| First-input typography | Google may repaint source text while switching size states or loading its web font | Keeps visible source layers on a stable local font at `18px / 28px` while preserving Google’s hidden line-measurement layer | Prevents source-text size and font-swap flashes without changing the result pane |
| Long source-text insertion | Google defers textarea auto-height calculation, briefly showing only the final lines after a large paste | Synchronizes the source textarea height during the input event before the first intermediate frame is painted | Prevents the pasted text from appearing to sweep from its final lines into the complete text |
| Translation selection | Text selection is interfered with by window dragging | Translation results can be partially selected and copied | Users are not limited to copying the complete result |
| Result typography while resizing | Google switches the result between responsive `16/24`, `24/32`, and `18/28` typography states | Keeps the main translated text at `18px / 28px` across window sizes | Result text no longer changes size when the window crosses Google’s layout breakpoint |
| Source copy button | No dedicated source-copy button | Adds a source-copy button using the same visual style as the result-copy button | Source and result copy controls are visually consistent |
| Source toolbar | Microphone and source-audio controls remain visible | Microphone and source-audio controls are removed in compact mode | Cleaner source toolbar |
| Result toolbar | Multiple Google actions remain visible | Only the translation-copy button is retained in compact mode | Cleaner result toolbar |
| Copy-all commands | No native commands for copying complete source or translation text | Adds native menu commands for copying all source and translation text | Complete text can be copied from the macOS menu bar |
| Pinyin and transliteration | Pinyin or transliteration may remain visible in Chinese results | Dedicated DOM selectors and heuristics remove them | Translation results are less cluttered |
| Word-by-word detail panel | Clicking a result may open an overlapping detail layer | Result activation and detail overlays are blocked | Prevents overlapping and unreadable result panels |
| Double-click navigation | Double-clicking a result may open an empty detail page | Secondary and detail navigation is cancelled | Prevents the blank-page bug |
| Selection toolbar | Relies mainly on older Google CSS selectors | Uses early event interception, multiple selectors, and native context-menu suppression | Removes speaker, copy, dictionary, and lookup popovers more reliably |
| Native selection menu | WebKit and Google selection menus may appear | Native context menus, Quick Look, and dictionary presentation are suppressed | Keeps text selection and `Command + C` while removing unwanted popovers |
| Feedback control | Uses a limited legacy feedback selector | Handles current accessibility labels, `jsname` values, and dynamic DOM changes | Removes the “Send feedback” control more reliably |
| Selected languages | Uses Google’s default language-tab appearance | Selected languages use bold text, blue color, background, and underline | Active translation directions are easier to identify |
| Default language pair | Hard-coded as English → Turkish and requires editing source code to change | Configurable from the native `语言` menu; initially English → Simplified Chinese | Default languages can be changed without rebuilding the app |
| Language preference persistence | Does not store a user-configured default language pair | Saves the selected source and target languages in `UserDefaults` | The preferred pair is restored after relaunching the app |
| Language switching safety | No native validation for a configurable pair | Automatic detection is source-only, and choosing the same language on both sides swaps the other side | Prevents invalid or ambiguous default language combinations |
| DOM-change handling | Injects mostly static CSS after page loading | Uses document-start guards, a `MutationObserver`, stable attributes, and repeated cleanup | More resistant to Google Translate interface changes |
| Navigation control | Does not explicitly restrict secondary navigation | Only the main Google Translate page is allowed | Prevents unintended detail or external-page navigation |
| macOS application menu | Does not create a complete native main menu | Adds `translate`, `翻译`, `语言`, and `显示` menus | Custom features are accessible from the macOS menu bar |
| `Command + W` | No reliable native close-window command | Adds a native close-window menu action while retaining the panel | Hides the window without quitting, allowing the global shortcut to reopen it |
| `Command + Q` | No reliable native Quit menu item | Adds a Quit item targeting `NSApplication.terminate` | `Command + Q` fully terminates the application |
| Display customization | Interface changes are hard-coded | Four checkable display options control pinyin, selection toolbar, action buttons, and language highlighting | Visual customizations can be enabled or disabled |
| Settings persistence | No customization preferences | Stores display preferences in `UserDefaults` | Settings survive application restarts |
| Reset option | Not available | Adds a restore-recommended-settings command | Recommended display settings can be restored in one action |
| Reload safety | Not applicable | Preserves and restores source text when display settings reload the page | Changing a display setting does not normally erase the current input |
| Branding | Original neutral `translate` name | Keeps a neutral `translate` name without personal suffixes | Suitable for sharing as an unofficial customized version |

## Credits

This project is based on [Mac Translate](https://github.com/m-inan/mac-translate) by [m-inan](https://github.com/m-inan).

This is an unofficial personal customization and is not affiliated with Google or the original author.

<h1 align="center">Mac Translate</h1>

<div align="center">
  <img src="https://github.com/m-inan/mac-translate/blob/main/media/256.png?raw=true" />
</div>

<p align="center">
  Google Translate in Mac App like Spotlight
</p>

![](https://github.com/m-inan/mac-translate/blob/main/media/mac-translate-app.jpg?raw=true)

## Download

#### [Click To Download](https://github.com/m-inan/mac-translate/releases/download/1.2.1/translate.zip). If it gives an error when you try to open the application:
 
Go to `System Preferences > Privacy & Security` and there should be a button saying `Open Anyway`,  under the `Security` .

## Configuration

The initial translation direction is **English → Chinese (Simplified)**.

Use the native macOS menu **Language** (`语言`) to choose the default source
and target languages. The selected pair is saved and restored when the app is
opened again. Automatic detection is available for the source language only.

Use **Apply Default Languages** (`应用默认语言`) to return to the saved pair
after temporarily changing languages inside Google Translate, or use
**Restore English → Chinese (Simplified)**
(`恢复为英语 → 中文（简体）`) to restore the initial pair.

The translation window opens automatically on a cold launch. Under the native
**Window** (`窗口`) menu, both **Keep on Top in the Current Space** and
**Show on All Spaces** are disabled by default and can be enabled independently.
On macOS 13 or later, **Show on All Spaces** also allows the window to be
summoned over another application's full-screen Space.

Use the native **Interface Language** (`界面语言`) menu to switch all native
menus and Google Translate's source/target language labels between Simplified
Chinese and English. Simplified Chinese is the initial interface language, and
the selection is saved for future launches. Changing the interface language
preserves the current source text and temporary translation direction.

## Keybindings

Choose **Shortcut Settings…** (`快捷键设置…`) from the native **Translate**
application menu to open the shortcut-settings window. Every shortcut below
can be changed there; the defaults are listed here and can be restored with
**Restore Default Shortcuts**.

| Shortcuts                                   | Functionality        |
| ------------------------------------------- | -------------------- |
| `Tab` | Move focus out of the translation window |
| `CMD + \` | Show or hide the window globally |
| `CMD + W` | Close the window without quitting |
| `CMD + H` | Hide the application |
| `CMD + Q` | Quit the application |
| `CMD + A` | Select all source text |
| `CMD + L` | Listen to the source text |
| `CMD + S` | Swap languages |
| `CMD + Enter` | Apply Google's spelling correction when available |
| `CMD + Z` / `CMD + R` | Undo / redo |
| `CMD + X` / `CMD + C` / `CMD + V` | Cut / copy / paste |

## Native menus

| Menu | Functionality |
| --- | --- |
| `Translate` | Show or hide the panel, copy all source/result text, swap languages, and open shortcut settings |
| `语言` | Configure, apply, or restore the persistent default language pair |
| `显示` | Enable or disable the customized compact-interface features |
| `窗口` | Close the window and configure current-Space or all-Spaces behavior |
| `界面语言` | Switch all native menus and Google language labels between Chinese and English |

### Reporting Issues
If believe you've found an issue, please [report it](https://github.com/m-inan/mac-translate/issues) along with any relevant details to reproduce it.

### Asking for help 
Please do not use the issue tracker for personal support requests. Instead, use StackOverflow.

### Contributions 
Yes please! Feature requests / pull requests are welcome.

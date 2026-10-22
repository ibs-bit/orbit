# Orbit

Drag a file out of Finder, hold a key, and a wheel of options appears around your cursor.
Drop the file on a segment and Orbit does the work locally. Nothing is uploaded anywhere.

| Hold while dragging | Wheel | What's on it |
|---|---|---|
| **⇧ Shift** | Convert | Every format the file can become |
| **⌘ Command** | Tools | Compress, crop, trim, split, merge, metadata, OCR, … |
| **⌃ Control** | Actions | AirDrop, Float, Copy, Move, Copy Path, Terminal |

The keys are configurable in Settings. The wheel stays open after you release the key
until you drop the file or let go somewhere else.

## What it can do

- **500+ conversion paths** across images, video, audio, documents, slides, spreadsheets,
  subtitles, PDFs and archives. The exact count is shown in the menu bar menu.
- **36 file tools**: image compress / crop / resize / rotate / flip / grayscale / remove
  background / app icon / combine into PDF; video compress / trim / split / extract audio /
  mute / thumbnail / 2× speed / rotate / join; audio compress / trim / split / normalize /
  mono / tag / join; PDF compress / merge / split / rotate / extract text / OCR / lock /
  unlock / metadata; strip metadata, zip, SHA-256 for anything.
- **6 file actions**: AirDrop, Float (always-on-top Quick Look window), Copy, Move…,
  Copy Path, Terminal. Actions work on folders and mixed selections too.
- Multiple files at once, per-file progress, a small results panel with **Reveal**.

Images, PDFs, Word/RTF/HTML/Markdown documents, CSV/TSV/JSON, SRT/VTT subtitles and
ZIP/TAR archives are handled with Apple's own frameworks. Optional Homebrew helpers unlock
the rest and are detected automatically:

| Helper | Unlocks | Install |
|---|---|---|
| ffmpeg | video & audio encoding, GIF, WebP/AVIF, ASS subtitles | `brew install ffmpeg` |
| pandoc | Markdown export, EPUB, LaTeX | `brew install pandoc` |
| LibreOffice | Word/PowerPoint/Excel/OpenDocument, PDF → DOCX/PPTX | `brew install --cask libreoffice` |
| 7-Zip | .7z archives | `brew install sevenzip` |

Segments that need a missing helper are shown dimmed with the helper's name; dropping on
one shows the install command.

## Build

Requires macOS 14+ and Xcode 15+ (Swift 5.9).

```bash
scripts/package_app.sh      # → dist/Orbit.app and a zip
open dist/Orbit.app
```

Orbit lives in the menu bar. The first launch asks for **Accessibility** access, which
macOS requires to see modifier keys during a drag. Grant it in
System Settings → Privacy & Security → Accessibility, then relaunch.

For development:

```bash
swift build && swift test
ORBIT_DEMO=/path/to/photo.jpg ORBIT_DEMO_MODE=tools swift run   # shows the wheel without a drag
```

## How it works

- `DragMonitor` installs global `NSEvent` monitors. On the first drag event after a mouse
  down it reads the system drag pasteboard; if it holds file URLs, a drag is in flight.
- When the configured modifier is held, `WheelController` places a non-activating
  `NSPanel` under the cursor. The panel registers for file URL drops, so the Finder drag
  simply lands on it. Hovering **More** flips pages when a file has many targets.
- `Catalog` describes formats, which targets each reaches and which backend performs it.
  `Converter`, `Tools` and `Actions` dispatch to the engines in `Engines/`.
- `JobRunner` runs work off the main thread and reports to the `HUD` panel.

## License

MIT

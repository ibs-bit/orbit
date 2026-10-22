import AppKit

/// Small modal prompts used by tools that need a parameter. All run on the main thread.
enum Dialogs {
    struct Field {
        let label: String
        var value: String
        var secure = false
    }

    /// Generic form: returns the entered values in order, or nil if cancelled.
    static func form(title: String, message: String, fields: [Field], ok: String = "OK") -> [String]? {
        onMain {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: ok)
            alert.addButton(withTitle: "Cancel")
            let grid = NSGridView(numberOfColumns: 2, rows: 0)
            grid.rowSpacing = 6
            grid.columnSpacing = 8
            var inputs: [NSTextField] = []
            for f in fields {
                let label = NSTextField(labelWithString: f.label)
                label.alignment = .right
                let input: NSTextField = f.secure ? NSSecureTextField() : NSTextField()
                input.stringValue = f.value
                input.frame = NSRect(x: 0, y: 0, width: 200, height: 22)
                input.widthAnchor.constraint(equalToConstant: 200).isActive = true
                grid.addRow(with: [label, input])
                inputs.append(input)
            }
            grid.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(fields.count) * 28)
            alert.accessoryView = grid
            alert.window.initialFirstResponder = inputs.first
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return inputs.map(\.stringValue)
        }
    }

    static func choice(title: String, message: String, options: [String]) -> Int? {
        onMain {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
            popup.addItems(withTitles: options)
            alert.accessoryView = popup
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return popup.indexOfSelectedItem
        }
    }

    static func password(title: String, message: String) -> String? {
        form(title: title, message: message, fields: [Field(label: "Password", value: "", secure: true)])?.first
    }

    /// Start/end in seconds. Accepts "90", "1:30" or "0:01:30".
    static func trimRange(duration: Double) -> (Double, Double)? {
        let total = Timecode.format(duration)
        guard let values = form(title: "Trim", message: "Keep the part between these times (total \(total)).",
                                fields: [Field(label: "Start", value: "0:00"), Field(label: "End", value: total)]) else { return nil }
        guard let s = Timecode.parse(values[0]), let e = Timecode.parse(values[1]), e > s else { return nil }
        return (max(0, s), min(duration > 0 ? duration : e, e))
    }

    static func chooseFolder(title: String) -> URL? {
        onMain {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.title = title
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Move Here"
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    static func info(title: String, message: String) {
        onMain {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.runModal()
        }
    }
}

enum Timecode {
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            seconds = seconds * 60 + v
        }
        return seconds
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        let sec = s - Double(h * 3600 + m * 60)
        let secText = sec == sec.rounded() ? String(format: "%02d", Int(sec)) : String(format: "%05.2f", sec)
        return h > 0 ? "\(h):\(String(format: "%02d", m)):\(secText)" : "\(m):\(secText)"
    }
}

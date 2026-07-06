import AppKit
import AVFoundation
import ApplicationServices
import Carbon
import CoreImage
import Foundation

private let cartesiaURL = URL(string: "https://api.cartesia.ai/stt")!
private let cartesiaVersion = "2026-03-01"
private let cartesiaModel = "ink-whisper"
private let cartesiaLanguage = "en"
private let cartesiaKeyDefaultsKey = "voi.cartesiaKey"
private let recordedNotesDefaultsKey = "voi.recordedNotes"

// Shared semantic color palette — single source of truth for the accent and
// status colors, previously re-typed as raw literals throughout the file.
private let voiAccent = NSColor(calibratedRed: 0.965, green: 0.725, blue: 0.231, alpha: 1)
private let voiSuccess = NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
private let voiDanger = NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.44, alpha: 1)

private enum PasteResult {
    case pasted
    case copiedNeedsAccessibility
    case copiedNoTarget
}

private func fourCharCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { result, character in
        (result << 8) + OSType(character)
    }
}

struct RecordedNote: Codable {
    let id: UUID
    let text: String
    let createdAt: Date
}

private enum ChipState {
    case success
    case warning
    case blocked
    case neutral

    private var hue: NSColor {
        switch self {
        case .success:
            return voiSuccess
        case .warning:
            return voiAccent
        case .blocked:
            return voiDanger
        case .neutral:
            return NSColor(calibratedWhite: 0.78, alpha: 1)
        }
    }

    var textColor: NSColor {
        hue.blended(withFraction: 0.55, of: .white) ?? hue
    }

    var dotColor: NSColor { hue }

    var borderColor: NSColor {
        hue.withAlphaComponent(0.45)
    }

    var backgroundColor: NSColor {
        hue.withAlphaComponent(0.12)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate {
    private let bgColor = NSColor(calibratedRed: 0.043, green: 0.045, blue: 0.052, alpha: 1)
    private let panelColor = NSColor(calibratedWhite: 0.12, alpha: 0.34)
    private let borderColor = NSColor(calibratedWhite: 1, alpha: 0.08)
    private let primaryTextColor = NSColor(calibratedWhite: 0.93, alpha: 1)
    private let secondaryTextColor = NSColor(calibratedWhite: 0.62, alpha: 1)
    private let mutedTextColor = NSColor(calibratedWhite: 0.45, alpha: 1)
    private let accentColor = voiAccent
    private let accentInkColor = NSColor(calibratedRed: 0.10, green: 0.075, blue: 0.0, alpha: 1)

    private var statusItem: NSStatusItem!
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var functionKeyDown = false
    private var pushToTalkKeyDown = false
    private var targetApplication: NSRunningApplication?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var primaryHotKeyRef: EventHotKeyRef?
    private var fallbackHotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var setupWindow: NSWindow?
    private var recordingOverlayWindow: NSWindow?
    private var recordingOverlayStatusLabel: NSTextField?
    private var keyField: NSTextField?
    private var statusLabel: NSTextField?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var notesTextView: NSTextView?
    private var notesScrollView: NSScrollView?
    private var composerTextView: NSTextView?
    private var permissionLabel: NSTextField?
    private var settingsStatusTitleLabel: NSTextField?
    private var settingsStatusDetailLabel: NSTextField?
    private var settingsStatusButton: NSButton?
    private var micChip: NSTextField?
    private var accessibilityChip: NSTextField?
    private var inputChip: NSTextField?
    private var hotKeyDiagnosticsLabel: NSTextField?
    private var shortcutLabel: NSTextField?
    private var eventLogTextView: NSTextView?
    private var eventLogScrollView: NSScrollView?
    private var diagnosticsToggleButton: NSButton?
    private var manualDictationButton: NSButton?
    private var autoPasteSwitch: NSSwitch?
    private var overviewTabButton: NSButton?
    private var settingsTabButton: NSButton?
    private var settingsSummaryLabel: NSTextField?
    private var overviewViews: [NSView] = []
    private var settingsViews: [NSView] = []
    private var recentEvents: [String] = []
    private var notes: [RecordedNote] = []
    private var hasRequestedMicrophoneThisSession = false
    private var diagnosticsExpanded = false
    private var hotKeyDiagnosticsMessage = "Shortcut status pending."
    private var showingSettingsTab = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "Voi", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        notes = loadRecordedNotes()
        makeApplicationMenu()
        makeMenu()
        installPushToTalkHotKey()
        installKeyMonitors()
        writeLog("launch team=\(Bundle.main.object(forInfoDictionaryKey: "TeamIdentifier") as? String ?? "unknown") ax=\(AXIsProcessTrusted())")
        setStatus("Voi ready")
        showSetupWindow(activate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let primaryHotKeyRef {
            UnregisterEventHotKey(primaryHotKeyRef)
        }
        if let fallbackHotKeyRef {
            UnregisterEventHotKey(fallbackHotKeyRef)
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Voi"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Hold fn/Globe to dictate", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Option-Space is fallback", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Dashboard", action: #selector(showDashboard), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Set Speech API Key...", action: #selector(setCartesiaKey), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Use Clipboard as API Key", action: #selector(useClipboardAsCartesiaKey), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Test Paste", action: #selector(testPaste), keyEquivalent: "t"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Voi", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func makeApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Voi", action: #selector(quit), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func monoLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: size, weight: weight)
        label.textColor = color ?? primaryTextColor
        label.backgroundColor = .clear
        label.drawsBackground = false
        return label
    }

    private func uiLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color ?? primaryTextColor
        label.backgroundColor = .clear
        label.drawsBackground = false
        return label
    }

    private func styleButton(_ button: NSButton, accent: Bool = false) {
        button.setButtonType(.momentaryPushIn)
        button.sendAction(on: [.leftMouseUp])
        button.isEnabled = true
        button.refusesFirstResponder = true
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .center
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.layer?.borderWidth = 1
        button.layer?.borderColor = (accent ? accentColor.withAlphaComponent(0.32) : NSColor(calibratedWhite: 1, alpha: 0.10)).cgColor
        button.layer?.backgroundColor = (accent ? accentColor.withAlphaComponent(0.90) : NSColor(calibratedWhite: 1, alpha: 0.035)).cgColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: accent ? .semibold : .medium),
                .foregroundColor: accent ? accentInkColor : secondaryTextColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func styleTabButton(_ button: NSButton, active: Bool) {
        button.setButtonType(.momentaryPushIn)
        button.sendAction(on: [.leftMouseUp])
        button.isEnabled = true
        button.refusesFirstResponder = true
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .center
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 0
        button.layer?.backgroundColor = active
            ? NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
            : NSColor.clear.cgColor
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: active ? primaryTextColor : secondaryTextColor,
            ]
        )
    }

    private func makeButton(title: String, frame: NSRect, action: Selector, accent: Bool = false) -> NSButton {
        let button = VoiButton(frame: frame)
        button.title = title
        button.target = self
        button.action = action
        styleButton(button, accent: accent)
        return button
    }

    private func styleTextField(_ input: NSTextField) {
        input.font = .systemFont(ofSize: 14, weight: .regular)
        input.textColor = primaryTextColor
        setPlaceholder(input.placeholderString ?? "", for: input)
        input.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.24)
        input.isBezeled = false
        input.cell?.usesSingleLineMode = true
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        input.focusRingType = .none
        input.wantsLayer = true
        input.layer?.cornerRadius = 10
        input.layer?.borderWidth = 1
        input.layer?.borderColor = borderColor.cgColor
        input.layer?.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.24).cgColor
    }

    private func setPlaceholder(_ text: String, for input: NSTextField?) {
        input?.placeholderString = text
        input?.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: mutedTextColor,
            ]
        )
    }

    private func styleScrollView(_ scrollView: NSScrollView, textView: NSTextView, mono: Bool = false) {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = borderColor.cgColor
        scrollView.layer?.backgroundColor = panelColor.cgColor
        scrollView.layer?.masksToBounds = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = mono ? secondaryTextColor : primaryTextColor
        textView.font = mono
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 13.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 14)
    }

    private func stylePlainScrollView(_ scrollView: NSScrollView, textView: NSTextView) {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.wantsLayer = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = secondaryTextColor
        textView.font = .systemFont(ofSize: 14.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 0, height: 0)
    }

    private func makeGroupCard(frame: NSRect) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = borderColor.cgColor
        card.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.04).cgColor
        return card
    }

    private func addDivider(to parent: NSView, y: CGFloat) {
        let divider = NSView(frame: NSRect(x: 0, y: y, width: parent.bounds.width, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = borderColor.cgColor
        divider.autoresizingMask = [.width]
        parent.addSubview(divider)
    }

    private func makeStatusValue(frame: NSRect) -> NSTextField {
        let label = uiLabel("", size: 13, weight: .medium, color: secondaryTextColor)
        label.frame = frame
        label.alignment = .right
        return label
    }

    private func updateStatusValue(_ label: NSTextField?, title: String, color: NSColor) {
        let attributed = NSMutableAttributedString(
            string: "● ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: color,
                .baselineOffset: 1.5,
            ]
        )
        attributed.append(NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: color,
            ]
        ))
        label?.attributedStringValue = attributed
    }

    private func makeSwitch(frame: NSRect, action: Selector) -> NSSwitch {
        let toggle = NSSwitch(frame: frame)
        toggle.target = self
        toggle.action = action
        toggle.controlSize = .regular
        return toggle
    }

    private func makeChip(frame: NSRect) -> NSTextField {
        let chip = uiLabel("", size: 11.5, weight: .medium, color: primaryTextColor)
        chip.frame = frame
        chip.alignment = .center
        chip.wantsLayer = true
        chip.layer?.cornerRadius = frame.height / 2
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = borderColor.cgColor
        chip.layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 0.28).cgColor
        return chip
    }

    private func updateChip(_ chip: NSTextField?, title: String, state: ChipState) {
        let attributed = NSMutableAttributedString(
            string: "● ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: state.dotColor,
                .baselineOffset: 1.5,
            ]
        )
        attributed.append(NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: state.textColor,
            ]
        ))
        chip?.attributedStringValue = attributed
        chip?.layer?.borderColor = state.borderColor.cgColor
        chip?.layer?.backgroundColor = state.backgroundColor.cgColor
    }

    private func installPushToTalkHotKey() {
        let eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userInfo in
                guard let event, let userInfo else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == fourCharCode("Voi1") else { return noErr }

                let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                let eventKind = GetEventKind(event)
                Task { @MainActor in
                    let shortcutName = app.hotKeyName(for: hotKeyID.id)
                    if eventKind == UInt32(kEventHotKeyPressed) {
                        app.logHotKeyEvent("\(shortcutName) pressed")
                        app.handlePushToTalkKeyChange(true)
                    } else if eventKind == UInt32(kEventHotKeyReleased) {
                        app.logHotKeyEvent("\(shortcutName) released")
                        app.handlePushToTalkKeyChange(false)
                    }
                }
                return noErr
            },
            eventTypes.count,
            eventTypes,
            userInfo,
            &hotKeyHandler
        )

        guard handlerStatus == noErr else {
            setStatus("Shortcut unavailable")
            updateHotKeyDiagnostics("Hotkey handler failed: \(handlerStatus)")
            return
        }

        let primaryStatus = registerHotKey(
            id: 1,
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey),
            ref: &primaryHotKeyRef
        )
        let fallbackStatus = registerHotKey(
            id: 2,
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey | controlKey),
            ref: &fallbackHotKeyRef
        )

        updateHotKeyDiagnostics(registrationSummary(primaryStatus: primaryStatus, fallbackStatus: fallbackStatus))

        if primaryHotKeyRef == nil && fallbackHotKeyRef == nil {
            setStatus("Shortcut unavailable")
        }
    }

    private func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32, ref: inout EventHotKeyRef?) -> OSStatus {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("Voi1"), id: id)
        return RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
    }

    private func hotKeyName(for id: UInt32) -> String {
        id == 2 ? "Control-Option-Space" : "Option-Space"
    }

    private func registrationSummary(primaryStatus: OSStatus, fallbackStatus: OSStatus) -> String {
        let primary = primaryHotKeyRef != nil
            ? "Option-Space: registered"
            : hotKeyFailureMessage(primaryStatus, shortcut: "Option-Space")
        let fallback = fallbackHotKeyRef != nil
            ? "Control-Option-Space: registered"
            : hotKeyFailureMessage(fallbackStatus, shortcut: "Control-Option-Space")

        if primaryHotKeyRef != nil && fallbackHotKeyRef != nil {
            return "Fallback shortcuts active: Option-Space + Control-Option-Space"
        }
        if primaryHotKeyRef != nil {
            return "\(primary); \(fallback)"
        }
        if fallbackHotKeyRef != nil {
            return "\(primary); fallback active: Control-Option-Space"
        }
        return "\(primary); \(fallback)"
    }

    private var hasRegisteredHotKey: Bool {
        primaryHotKeyRef != nil || fallbackHotKeyRef != nil
    }

    nonisolated private func logFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Voi.log")
    }

    private func writeLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let url = logFileURL()
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func updateHotKeyDiagnostics(_ message: String) {
        writeLog("hotkey registration \(message)")
        hotKeyDiagnosticsMessage = message
        shortcutLabel?.stringValue = message
        hotKeyDiagnosticsLabel?.stringValue = message
        recentEvents.insert(message, at: 0)
        recentEvents = Array(recentEvents.prefix(20))
        refreshEventLog()
    }

    private func hotKeyFailureMessage(_ status: OSStatus, shortcut: String) -> String {
        if status == OSStatus(eventHotKeyExistsErr) {
            return "\(shortcut): conflict"
        }
        if status == noErr {
            return "\(shortcut): unavailable"
        }
        return "\(shortcut): failed \(status)"
    }

    private func logHotKeyEvent(_ phase: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        recentEvents.insert("\(formatter.string(from: Date())) hotKey \(phase)", at: 0)
        recentEvents = Array(recentEvents.prefix(20))
        refreshEventLog()
        writeLog("hotkey \(phase)")
    }

    private func installKeyMonitors() {
        let mask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                Task { @MainActor in
                    app.logKeyEvent(type: type, keyCode: keyCode, flags: event.flags)
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        app.reenableEventTap()
                        return
                    }

                    switch type {
                    case .flagsChanged:
                        app.handleFunctionFlagChange(app.isFunctionKeyDown(type: type, keyCode: keyCode, flags: event.flags))
                    default:
                        break
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            writeLog("eventTap unavailable")
            setStatus("Allow Accessibility")
            refreshPermissionStatus(eventTapActive: false)
            return
        }

        eventTap = tap
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        writeLog("eventTap active")
        refreshPermissionStatus(eventTapActive: true)
    }

    private func reenableEventTap() {
        guard let eventTap else {
            refreshPermissionStatus(eventTapActive: false)
            setStatus("Input events blocked")
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        refreshPermissionStatus(eventTapActive: true)
        shortcutLabel?.stringValue = "Input events resumed. Hold fn/Globe to dictate."
    }

    private func isFunctionKeyDown(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool? {
        guard type == .flagsChanged else { return nil }
        if flags.contains(.maskSecondaryFn) { return true }
        if functionKeyDown && (keyCode == 63 || keyCode == 0) { return false }
        if !functionKeyDown && keyCode == 63 { return true }
        return nil
    }

    fileprivate func handleFunctionFlagChange(_ isFunctionDown: Bool?) {
        guard let isFunctionDown else { return }
        if isFunctionDown && !functionKeyDown {
            shortcutLabel?.stringValue = "fn/Globe detected. Recording..."
            writeLog("fn down")
            functionKeyDown = startRecording()
        } else if !isFunctionDown && functionKeyDown {
            functionKeyDown = false
            writeLog("fn up")
            stopRecording()
        }
    }

    fileprivate func handlePushToTalkKeyChange(_ isDown: Bool) {
        if isDown && !pushToTalkKeyDown {
            shortcutLabel?.stringValue = "Fallback shortcut detected. Recording..."
            writeLog("pushToTalk down")
            pushToTalkKeyDown = startRecording()
        } else if !isDown && pushToTalkKeyDown {
            pushToTalkKeyDown = false
            writeLog("pushToTalk up")
            stopRecording()
        }
    }

    @discardableResult
    private func startRecording() -> Bool {
        guard recorder == nil else { return true }
        guard UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false else {
            writeLog("recording blocked missingCartesiaKey")
            setStatus("Add API key")
            showRecordingOverlay(status: "Add API key")
            hideRecordingOverlay(after: 1.2)
            shortcutLabel?.stringValue = "Add your speech API key before recording."
            showSetupWindow()
            return false
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            writeLog("recording blocked micNotDetermined")
            showRecordingOverlay(status: "Allow mic")
            hideRecordingOverlay(after: 1.2)
            requestMicrophoneAccessOnce()
            return false
        case .denied, .restricted:
            writeLog("recording blocked micDenied")
            setStatus("Microphone blocked")
            showRecordingOverlay(status: "Mic blocked")
            hideRecordingOverlay(after: 1.2)
            shortcutLabel?.stringValue = "MICROPHONE_BLOCKED / ENABLE_IN_SYSTEM_SETTINGS"
            showSetupWindow()
            refreshPermissionStatus(eventTapActive: eventTap != nil)
            return false
        @unknown default:
            setStatus("Microphone unknown")
            shortcutLabel?.stringValue = "Microphone permission state is unknown."
            return false
        }

        targetApplication = currentPasteTarget()
        writeLog("recording target=\(targetApplication?.bundleIdentifier ?? "none") ax=\(AXIsProcessTrusted())")
        if targetApplication == nil {
            shortcutLabel?.stringValue = "No target app captured. Click a text field, then hold fn/Globe."
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voi-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let nextRecorder = try AVAudioRecorder(url: url, settings: settings)
            nextRecorder.delegate = self
            guard nextRecorder.record() else {
                writeLog("recording failed recorderRecordFalse")
                setStatus("Mic permission needed")
                showRecordingOverlay(status: "Mic failed")
                hideRecordingOverlay(after: 1.2)
                shortcutLabel?.stringValue = "Microphone did not start recording."
                recorder = nil
                recordingURL = nil
                return false
            }
            recorder = nextRecorder
            manualDictationButton?.title = "Stop dictation"
            if let manualDictationButton {
                styleButton(manualDictationButton, accent: true)
            }
            writeLog("recording started url=\(url.path)")
            setStatus("Listening")
            showRecordingOverlay(status: "Listening")
            shortcutLabel?.stringValue = "Listening. Release fn/Globe to paste."
            return true
        } catch {
            writeLog("recording failed error=\(error.localizedDescription)")
            setStatus("Mic failed")
            showRecordingOverlay(status: "Mic failed")
            hideRecordingOverlay(after: 1.2)
            shortcutLabel?.stringValue = "Microphone failed: \(error.localizedDescription)"
            recorder = nil
            recordingURL = nil
            return false
        }
    }

    private func currentPasteTarget() -> NSRunningApplication? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return frontmost
    }

    private func showRecordingOverlay(status: String) {
        if recordingOverlayWindow == nil {
            let size = NSSize(width: 140, height: 46)
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let origin = NSPoint(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.minY + 86
            )
            let window = NSPanel(
                contentRect: NSRect(origin: origin, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true

            let content = RecordingOverlayView(frame: NSRect(origin: .zero, size: size), accent: accentColor)
            content.autoresizingMask = [.width, .height]
            window.contentView = content

            let label = uiLabel(status, size: 14, weight: .regular, color: primaryTextColor)
            label.alignment = .center
            label.frame = NSRect(x: 40, y: 14, width: 88, height: 18)
            content.addSubview(label)
            recordingOverlayStatusLabel = label

            recordingOverlayWindow = window
        }

        updateRecordingOverlay(status: status)
        recordingOverlayWindow?.alphaValue = 1
        recordingOverlayWindow?.orderFront(nil)
    }

    private func updateRecordingOverlay(status: String) {
        recordingOverlayStatusLabel?.stringValue = status
    }

    private func hideRecordingOverlay(after delay: TimeInterval = 0) {
        let window = recordingOverlayWindow
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            window?.orderOut(nil)
        }
    }

    private func requestMicrophoneAccessOnce() {
        guard !hasRequestedMicrophoneThisSession else {
            setStatus("Microphone pending")
            shortcutLabel?.stringValue = "MICROPHONE_PENDING / RESPOND_TO_SYSTEM_PROMPT"
            return
        }

        hasRequestedMicrophoneThisSession = true
        setStatus("Allow microphone")
        shortcutLabel?.stringValue = "MICROPHONE_REQUESTED / ALLOW_ONCE_THEN_PRESS_SHORTCUT"
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPermissionStatus(eventTapActive: self.eventTap != nil)
                if granted {
                    self.setStatus("Voi ready")
                    self.shortcutLabel?.stringValue = "Microphone allowed. Hold fn/Globe to dictate."
                } else {
                    self.setStatus("Microphone blocked")
                    self.shortcutLabel?.stringValue = "MICROPHONE_BLOCKED / ENABLE_IN_SYSTEM_SETTINGS"
                    self.showSetupWindow()
                }
            }
        }
    }

    private func stopRecording() {
        guard let recorder else {
            writeLog("stop ignored noRecorder")
            shortcutLabel?.stringValue = "No active recording to transcribe."
            setStatus("Voi ready")
            return
        }
        recorder.stop()
        self.recorder = nil
        manualDictationButton?.title = "Start dictation"
        if let manualDictationButton {
            styleButton(manualDictationButton)
        }
        writeLog("recording stopped")
        setStatus("Polishing")
        hideRecordingOverlay()
        shortcutLabel?.stringValue = "Released. Polishing..."

        guard let recordingURL else {
            writeLog("transcription skipped missingRecordingURL")
            setStatus("Voi ready")
            shortcutLabel?.stringValue = "Recording file was not created."
            return
        }

        Task {
            defer { try? FileManager.default.removeItem(at: recordingURL) }
            do {
                await MainActor.run { writeLog("transcription started file=\(recordingURL.path)") }
                let text = try await transcribeAndPolish(fileURL: recordingURL)
                await MainActor.run {
                    writeLog("transcription complete chars=\(text.count)")
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        setStatus("Didn't catch that")
                        shortcutLabel?.stringValue = "No speech detected. Hold fn/Globe a little longer and try again."
                        return
                    }
                    saveRecordedNote(text)
                    switch paste(text) {
                    case .pasted:
                        setStatus("Pasted")
                        shortcutLabel?.stringValue = "Pasted. Hold fn/Globe for another note."
                    case .copiedNeedsAccessibility:
                        setStatus("Copied")
                        shortcutLabel?.stringValue = "Copied to clipboard. Auto-Paste is blocked by macOS Accessibility."
                    case .copiedNoTarget:
                        setStatus("Copied")
                        shortcutLabel?.stringValue = "Copied. Click into another app before dictating to auto-paste."
                    }
                }
                try? await Task.sleep(for: .milliseconds(1200))
                await MainActor.run { setStatus("Voi ready") }
            } catch {
                await MainActor.run {
                    writeLog("transcription failed error=\(error.localizedDescription)")
                    setStatus(error.localizedDescription)
                    shortcutLabel?.stringValue = "Transcription failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func transcribeAndPolish(fileURL: URL) async throws -> String {
        guard let key = UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey), !key.isEmpty else {
            throw VoiError.message("Add API key")
        }

        var request = URLRequest(url: cartesiaURL)
        let boundary = "Boundary-\(UUID().uuidString)"
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(cartesiaVersion, forHTTPHeaderField: "Cartesia-Version")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(fileURL: fileURL, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw VoiError.message("Transcription failed")
        }

        let decoded = try JSONDecoder().decode(CartesiaResponse.self, from: data)
        return polish(decoded.text)
    }

    private func multipartBody(fileURL: URL, boundary: String) throws -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(cartesiaModel)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        append("\(cartesiaLanguage)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        append("\r\n--\(boundary)--\r\n")

        return body
    }

    private func paste(_ text: String) -> PasteResult {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        guard let targetApplication,
              targetApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
            writeLog("paste copiedOnly reason=noExternalTarget chars=\(text.count)")
            return .copiedNoTarget
        }

        guard AXIsProcessTrusted() else {
            writeLog("paste copiedOnly ax=false chars=\(text.count)")
            refreshPermissionStatus(eventTapActive: eventTap != nil)
            return .copiedNeedsAccessibility
        }

        writeLog("paste posting target=\(targetApplication.bundleIdentifier ?? "unknown") chars=\(text.count)")
        targetApplication.activate(options: [.activateAllWindows])

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
        return .pasted
    }

    private func setStatus(_ message: String) {
        statusItem.button?.title = message == "Voi ready" ? "Voi" : "Voi: \(message)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        if message == "Voi ready" {
            let attributed = NSMutableAttributedString(
                string: "● ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: voiSuccess,
                    .baselineOffset: 1.0,
                    .paragraphStyle: paragraph,
                ]
            )
            attributed.append(NSAttributedString(
                string: "Ready",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: secondaryTextColor,
                    .paragraphStyle: paragraph,
                ]
            ))
            statusLabel?.attributedStringValue = attributed
        } else {
            statusLabel?.attributedStringValue = NSAttributedString(
                string: message,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                    .foregroundColor: primaryTextColor,
                    .paragraphStyle: paragraph,
                ]
            )
        }
    }

    @objc private func showDashboard() {
        showSetupWindow(activate: true)
    }

    @objc private func setCartesiaKey() {
        showSetupWindow(activate: true)
        showingSettingsTab = true
        updateTabSelection()
        setupWindow?.makeFirstResponder(keyField)
    }

    @objc private func enableAutoPaste() {
        let granted = AXIsProcessTrusted()
        writeLog("autoPaste check ax=\(granted)")
        refreshPermissionStatus(eventTapActive: eventTap != nil)
        if granted {
            setStatus("Auto-Paste enabled")
            shortcutLabel?.stringValue = "Auto-Paste is enabled."
        } else {
            setStatus("Auto-Paste blocked")
            shortcutLabel?.stringValue = "Auto-Paste is still blocked. Re-add Voi in Accessibility, then reopen Voi."
            openAccessibilitySettings()
        }
    }

    @objc private func toggleAutoPasteSwitch() {
        if AXIsProcessTrusted() {
            autoPasteSwitch?.state = .on
            setStatus("Auto-Paste enabled")
            shortcutLabel?.stringValue = "Auto-Paste is enabled."
        } else {
            autoPasteSwitch?.state = .off
            enableAutoPaste()
        }
        refreshPermissionStatus(eventTapActive: eventTap != nil)
    }

    private func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func openMicrophoneSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @objc private func useClipboardAsCartesiaKey() {
        guard let clipboardText = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            setStatus("Clipboard empty")
            return
        }

        UserDefaults.standard.set(clipboardText, forKey: cartesiaKeyDefaultsKey)
        setStatus("API key saved")
    }

    private func showSetupWindow(activate: Bool = true) {
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }

        if let setupWindow {
            if activate {
                setupWindow.makeKeyAndOrderFront(nil)
            }
            updateSetupCopy()
            refreshPermissionStatus(eventTapActive: eventTap != nil)
            refreshNotesView()
            return
        }

        overviewViews.removeAll()
        settingsViews.removeAll()

        let windowSize = NSSize(width: 440, height: 480)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voi"
        window.backgroundColor = bgColor
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.minSize = windowSize
        window.maxSize = windowSize

        let content = DashboardBackgroundView(frame: NSRect(origin: .zero, size: windowSize))
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let margin: CGFloat = 24
        let contentWidth = windowSize.width - margin * 2

        let logo = WaveMarkView(frame: NSRect(x: margin, y: 430, width: 24, height: 24), color: accentColor)
        content.addSubview(logo)

        let brand = uiLabel("Voi", size: 17, weight: .semibold)
        brand.frame = NSRect(x: margin + 34, y: 426, width: 80, height: 28)
        content.addSubview(brand)

        let status = uiLabel("Ready", size: 12.5, weight: .medium, color: primaryTextColor)
        status.frame = NSRect(x: windowSize.width - margin - 136, y: 426, width: 136, height: 30)
        status.alignment = .right
        content.addSubview(status)
        statusLabel = status

        let tabGroup = NSView(frame: NSRect(x: margin, y: 376, width: contentWidth, height: 40))
        tabGroup.wantsLayer = true
        tabGroup.layer?.cornerRadius = 10
        tabGroup.layer?.borderWidth = 1
        tabGroup.layer?.borderColor = borderColor.cgColor
        tabGroup.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.05).cgColor
        content.addSubview(tabGroup)

        let overviewTab = VoiButton(frame: NSRect(x: 4, y: 4, width: (contentWidth - 12) / 2, height: 32))
        overviewTab.title = "Inputs"
        overviewTab.target = self
        overviewTab.action = #selector(showOverviewTab)
        tabGroup.addSubview(overviewTab)
        overviewTabButton = overviewTab

        let settingsTab = VoiButton(frame: NSRect(x: 8 + (contentWidth - 12) / 2, y: 4, width: (contentWidth - 12) / 2, height: 32))
        settingsTab.title = "Settings"
        settingsTab.target = self
        settingsTab.action = #selector(showSettingsTab)
        tabGroup.addSubview(settingsTab)
        settingsTabButton = settingsTab

        let notesLabel = uiLabel("Past inputs", size: 12, weight: .medium, color: mutedTextColor)
        notesLabel.frame = NSRect(x: margin, y: 344, width: 160, height: 18)
        content.addSubview(notesLabel)
        overviewViews.append(notesLabel)

        let notesRect = NSRect(x: margin, y: 96, width: contentWidth, height: 236)
        let scrollView = NSScrollView(frame: notesRect)
        let textView = NSTextView(frame: scrollView.bounds)
        stylePlainScrollView(scrollView, textView: textView)
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        scrollView.documentView = textView
        content.addSubview(scrollView)
        notesScrollView = scrollView
        notesTextView = textView
        composerTextView = nil
        overviewViews.append(scrollView)

        let copyButton = makeButton(
            title: "Copy Latest",
            frame: NSRect(x: margin, y: 40, width: 120, height: 40),
            action: #selector(copyLatestNote),
            accent: true
        )
        content.addSubview(copyButton)
        overviewViews.append(copyButton)

        let shortcut = uiLabel("Ready across your Mac", size: 12.5, weight: .regular, color: secondaryTextColor)
        shortcut.frame = NSRect(x: margin + 136, y: 51, width: contentWidth - 136, height: 18)
        shortcut.alignment = .left
        content.addSubview(shortcut)
        shortcutLabel = shortcut
        overviewViews.append(shortcut)

        let setupLabel = uiLabel("Setup", size: 12, weight: .medium, color: mutedTextColor)
        setupLabel.frame = NSRect(x: margin, y: 344, width: 160, height: 18)
        content.addSubview(setupLabel)
        permissionLabel = setupLabel
        settingsViews.append(setupLabel)

        let statusCard = makeGroupCard(frame: NSRect(x: margin, y: 264, width: contentWidth, height: 68))
        content.addSubview(statusCard)
        settingsViews.append(statusCard)

        let settingsStatusTitle = uiLabel("Ready across your Mac", size: 14, weight: .semibold, color: primaryTextColor)
        settingsStatusTitle.frame = NSRect(x: 16, y: 36, width: 244, height: 20)
        statusCard.addSubview(settingsStatusTitle)
        settingsStatusTitleLabel = settingsStatusTitle

        let settingsStatusDetail = uiLabel("Hold fn/Globe to dictate.", size: 12, weight: .regular, color: mutedTextColor)
        settingsStatusDetail.frame = NSRect(x: 16, y: 14, width: 244, height: 18)
        statusCard.addSubview(settingsStatusDetail)
        settingsStatusDetailLabel = settingsStatusDetail

        let settingsFixButton = makeButton(
            title: "Fix",
            frame: NSRect(x: contentWidth - 104, y: 16, width: 88, height: 36),
            action: #selector(resolveSettingsIssue)
        )
        statusCard.addSubview(settingsFixButton)
        settingsStatusButton = settingsFixButton

        let dictationCard = makeGroupCard(frame: NSRect(x: margin, y: 180, width: contentWidth, height: 68))
        content.addSubview(dictationCard)
        settingsViews.append(dictationCard)

        let dictationTitle = uiLabel("Auto-Paste after dictation", size: 14, weight: .regular, color: primaryTextColor)
        dictationTitle.frame = NSRect(x: 16, y: 36, width: 244, height: 20)
        dictationCard.addSubview(dictationTitle)
        let dictationCopy = uiLabel("Send text to the app you were using.", size: 12, weight: .regular, color: mutedTextColor)
        dictationCopy.frame = NSRect(x: 16, y: 14, width: 252, height: 18)
        dictationCard.addSubview(dictationCopy)
        let dictationSwitch = makeSwitch(frame: NSRect(x: contentWidth - 56, y: 23, width: 38, height: 22), action: #selector(toggleAutoPasteSwitch))
        dictationCard.addSubview(dictationSwitch)
        autoPasteSwitch = dictationSwitch

        let apiLabel = uiLabel("Speech API key", size: 12, weight: .medium, color: mutedTextColor)
        apiLabel.frame = NSRect(x: margin, y: 136, width: 160, height: 18)
        content.addSubview(apiLabel)
        settingsViews.append(apiLabel)

        let input = VoiTextField(frame: NSRect(x: margin, y: 80, width: 292, height: 40))
        let hasSavedKey = UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false
        input.placeholderString = hasSavedKey ? "Key saved. Paste a new key." : "Paste your speech API key"
        input.stringValue = ""
        styleTextField(input)
        content.addSubview(input)
        keyField = input
        settingsViews.append(input)

        let saveButton = makeButton(
            title: "Save",
            frame: NSRect(x: margin + 304, y: 80, width: 88, height: 40),
            action: #selector(saveCartesiaKeyFromWindow),
            accent: !hasSavedKey
        )
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)
        settingsViews.append(saveButton)

        setupWindow = window
        showingSettingsTab = !hasSavedKey
        if activate {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(showingSettingsTab ? keyField : nil)
        } else {
            window.orderOut(nil)
        }
        updateSetupCopy()
        refreshNotesView()
        refreshPermissionStatus(eventTapActive: eventTap != nil)
        updateTabSelection()
        updateDiagnosticsVisibility()
    }

    @objc private func saveCartesiaKeyFromWindow() {
        setupWindow?.makeFirstResponder(nil)
        let value = keyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hadExistingKey = UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false
        if value.isEmpty && hadExistingKey {
            setStatus("API key unchanged")
            shortcutLabel?.stringValue = "Key already saved. Paste a new key to replace it."
            return
        }

        UserDefaults.standard.set(value, forKey: cartesiaKeyDefaultsKey)
        if value.isEmpty {
            setStatus("API key cleared")
            setPlaceholder("Paste your speech API key", for: keyField)
            shortcutLabel?.stringValue = "Add your speech API key before recording."
        } else {
            setStatus("API key saved")
            keyField?.stringValue = ""
            setPlaceholder("Key saved. Paste a new key.", for: keyField)
            shortcutLabel?.stringValue = "Key saved. Hold fn/Globe to dictate."
            updateSetupCopy()
        }
        refreshPermissionStatus(eventTapActive: eventTap != nil)
    }

    @objc private func resolveSettingsIssue() {
        switch settingsStatusButton?.tag {
        case 1:
            requestMicrophoneAccessOnce()
        case 2:
            openMicrophoneSettings()
        case 3:
            enableAutoPaste()
        case 4:
            showingSettingsTab = true
            updateTabSelection()
            setupWindow?.makeFirstResponder(keyField)
        default:
            break
        }
    }

    private func updateSetupCopy() {
        let hasKey = UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false
        if hasKey {
            titleLabel?.stringValue = "Voice where you work"
            subtitleLabel?.stringValue = "Hold fn/Globe, speak, release to paste."
            setStatus("Voi ready")
        } else {
            titleLabel?.stringValue = "Set up Voi"
            subtitleLabel?.stringValue = "Add your speech API key, then hold fn/Globe to dictate."
            statusLabel?.attributedStringValue = NSAttributedString(
                string: "Not ready",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                    .foregroundColor: secondaryTextColor,
                ]
            )
        }
    }

    @objc private func showOverviewTab() {
        showingSettingsTab = false
        updateTabSelection()
        updateDiagnosticsVisibility()
    }

    @objc private func showSettingsTab() {
        showingSettingsTab = true
        updateTabSelection()
        updateDiagnosticsVisibility()
        if UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty != false {
            setupWindow?.makeFirstResponder(keyField)
        }
    }

    private func updateTabSelection() {
        for view in overviewViews {
            view.isHidden = showingSettingsTab
        }
        for view in settingsViews {
            view.isHidden = !showingSettingsTab
        }

        if let overviewTabButton {
            styleTabButton(overviewTabButton, active: !showingSettingsTab)
        }
        if let settingsTabButton {
            styleTabButton(settingsTabButton, active: showingSettingsTab)
        }
    }

    private func refreshPermissionStatus(eventTapActive: Bool) {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let micStatus: String
        let micColor: NSColor
        switch mic {
        case .authorized:
            micStatus = "Allowed"
            micColor = voiSuccess
        case .denied, .restricted:
            micStatus = "Blocked"
            micColor = voiDanger
        case .notDetermined:
            micStatus = "Not granted"
            micColor = secondaryTextColor
        @unknown default:
            micStatus = "Unknown"
            micColor = secondaryTextColor
        }

        let isAccessible = AXIsProcessTrusted()
        let hasKey = UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false
        updateStatusValue(micChip, title: micStatus, color: micColor)
        updateStatusValue(
            accessibilityChip,
            title: isAccessible ? "On" : "Off",
            color: isAccessible ? voiSuccess : secondaryTextColor
        )
        updateStatusValue(
            inputChip,
            title: hasKey ? "Saved" : "Missing",
            color: hasKey ? voiSuccess : voiDanger
        )
        autoPasteSwitch?.state = isAccessible ? .on : .off
        updateSettingsStatus(mic: mic, hasKey: hasKey, isAccessible: isAccessible, eventTapActive: eventTapActive)
        if !showingSettingsTab {
            shortcutLabel?.stringValue = eventTapActive || hasRegisteredHotKey
                ? "Ready across your Mac"
                : "Shortcut unavailable"
        }
    }

    private func updateSettingsStatus(mic: AVAuthorizationStatus, hasKey: Bool, isAccessible: Bool, eventTapActive: Bool) {
        let title: String
        let detail: String
        let buttonTitle: String?
        let buttonTag: Int
        let titleColor: NSColor

        if !hasKey {
            title = "API key missing"
            detail = "Add a speech API key before dictating."
            buttonTitle = "Add Key"
            buttonTag = 4
            titleColor = voiAccent
        } else {
            switch mic {
            case .authorized:
                if !isAccessible {
                    title = "Auto-Paste is off"
                    detail = "Allow Accessibility to paste into other apps."
                    buttonTitle = "Enable"
                    buttonTag = 3
                    titleColor = voiAccent
                } else if !eventTapActive && !hasRegisteredHotKey {
                    title = "Shortcut unavailable"
                    detail = "Reopen Voi or check input permissions."
                    buttonTitle = nil
                    buttonTag = 0
                    titleColor = voiDanger
                } else {
                    title = "Ready across your Mac"
                    detail = "Hold fn/Globe to dictate."
                    buttonTitle = nil
                    buttonTag = 0
                    titleColor = voiSuccess
                }
            case .notDetermined:
                title = "Microphone not allowed"
                detail = "Allow microphone access to start dictating."
                buttonTitle = "Allow"
                buttonTag = 1
                titleColor = voiAccent
            case .denied, .restricted:
                title = "Microphone blocked"
                detail = "Enable microphone access in System Settings."
                buttonTitle = "Open"
                buttonTag = 2
                titleColor = voiDanger
            @unknown default:
                title = "Microphone unknown"
                detail = "Check microphone permissions in System Settings."
                buttonTitle = "Open"
                buttonTag = 2
                titleColor = voiDanger
            }
        }

        settingsStatusTitleLabel?.stringValue = title
        settingsStatusTitleLabel?.textColor = titleColor
        settingsStatusDetailLabel?.stringValue = detail
        settingsStatusButton?.tag = buttonTag
        settingsStatusButton?.isHidden = buttonTitle == nil
        if let buttonTitle, let settingsStatusButton {
            settingsStatusButton.title = buttonTitle
            styleButton(settingsStatusButton, accent: buttonTag != 0)
        }
    }

    private func shortcutStatusTitle(eventTapActive: Bool) -> String {
        if eventTapActive && hasRegisteredHotKey {
            return "fn ready + fallback"
        }
        if eventTapActive {
            return "fn/Globe: ready"
        }
        switch (primaryHotKeyRef != nil, fallbackHotKeyRef != nil) {
        case (true, true):
            return "Fallbacks: active"
        case (true, false):
            return "Option-Space: active"
        case (false, true):
            return "Fallback: active"
        case (false, false):
            return "Shortcut: blocked"
        }
    }

    @objc private func toggleDiagnostics() {
        diagnosticsExpanded.toggle()
        updateDiagnosticsVisibility()
    }

    private func updateDiagnosticsVisibility() {
        notesScrollView?.isHidden = showingSettingsTab
        eventLogScrollView?.isHidden = !showingSettingsTab || !diagnosticsExpanded
        settingsSummaryLabel?.isHidden = !showingSettingsTab || diagnosticsExpanded
        diagnosticsToggleButton?.title = diagnosticsExpanded ? "Hide logs" : "Logs"
        if let diagnosticsToggleButton {
            styleButton(diagnosticsToggleButton)
        }
    }

    @objc private func copyLatestNote() {
        guard let text = notes.first?.text, !text.isEmpty else {
            setStatus("Nothing to copy yet")
            shortcutLabel?.stringValue = "No recorded note to copy yet."
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("Copied")
        shortcutLabel?.stringValue = "Latest note copied to clipboard."
    }

    fileprivate func logKeyEvent(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        let typeName: String
        switch type {
        case .tapDisabledByTimeout:
            typeName = "tapDisabledByTimeout"
        case .tapDisabledByUserInput:
            typeName = "tapDisabledByUserInput"
        case .flagsChanged:
            typeName = "flagsChanged"
        case .keyDown:
            typeName = "keyDown"
        case .keyUp:
            typeName = "keyUp"
        default:
            typeName = "\(type.rawValue)"
        }

        let flagsText = [
            flags.contains(.maskAlternate) ? "option" : nil,
            flags.contains(.maskControl) ? "control" : nil,
            flags.contains(.maskCommand) ? "command" : nil,
            flags.contains(.maskShift) ? "shift" : nil,
            flags.contains(.maskSecondaryFn) ? "fn" : nil,
        ].compactMap { $0 }.joined(separator: "+")

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) \(typeName) key=\(keyCode) flags=\(flagsText.isEmpty ? "-" : flagsText)"
        recentEvents.insert(line, at: 0)
        recentEvents = Array(recentEvents.prefix(20))
        refreshEventLog()
    }

    private func refreshEventLog() {
        eventLogTextView?.string = recentEvents.isEmpty
            ? "No key events received yet."
            : recentEvents.joined(separator: "\n")
    }

    @objc private func hideSetupWindow() {
        setupWindow?.orderOut(nil)
    }

    @objc private func toggleManualDictation() {
        if recorder == nil {
            writeLog("manual dictation start")
            if startRecording() {
                manualDictationButton?.title = "Stop dictation"
                if let manualDictationButton {
                    styleButton(manualDictationButton, accent: true)
                }
            }
        } else {
            writeLog("manual dictation stop")
            manualDictationButton?.title = "Start dictation"
            if let manualDictationButton {
                styleButton(manualDictationButton)
            }
            stopRecording()
        }
    }

    @objc private func testPaste() {
        switch paste("Voi is ready.") {
        case .pasted:
            setStatus("Pasted")
            shortcutLabel?.stringValue = "Test pasted into the active app."
        case .copiedNeedsAccessibility:
            setStatus("Copied")
            shortcutLabel?.stringValue = "Test copied. Auto-Paste is blocked by macOS Accessibility."
        case .copiedNoTarget:
            setStatus("Copied")
            shortcutLabel?.stringValue = "Test copied. Voi will not paste into its own dashboard."
        }
    }

    private func loadRecordedNotes() -> [RecordedNote] {
        guard let data = UserDefaults.standard.data(forKey: recordedNotesDefaultsKey),
              let decoded = try? JSONDecoder().decode([RecordedNote].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveRecordedNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        notes.insert(RecordedNote(id: UUID(), text: trimmed, createdAt: Date()), at: 0)
        notes = Array(notes.prefix(50))
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: recordedNotesDefaultsKey)
        }
        refreshNotesView()
    }

    private func refreshNotesView() {
        composerTextView?.string = notes.first?.text
            ?? "Nothing dictated yet."
        composerTextView?.textColor = notes.first == nil ? mutedTextColor : primaryTextColor

        guard let notesTextView else { return }
        if notes.isEmpty {
            notesTextView.textStorage?.setAttributedString(NSAttributedString(
                string: "Dictated text will appear here.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: mutedTextColor,
                ]
            ))
            return
        }

        let dayFormatter = DateFormatter()
        dayFormatter.doesRelativeDateFormatting = true
        dayFormatter.dateStyle = .medium
        dayFormatter.timeStyle = .none

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        let calendar = Calendar.current
        let textParagraph = NSMutableParagraphStyle()
        textParagraph.lineSpacing = 1

        let body = NSMutableAttributedString()
        var previousDay: Date?
        for (index, note) in notes.enumerated() {
            // Only repeat the full date when the day changes; otherwise show
            // just the time so a run of same-day entries reads cleanly.
            let day = calendar.startOfDay(for: note.createdAt)
            let stamp = previousDay == day
                ? timeFormatter.string(from: note.createdAt)
                : "\(dayFormatter.string(from: note.createdAt))  ·  \(timeFormatter.string(from: note.createdAt))"
            previousDay = day

            let stampParagraph = NSMutableParagraphStyle()
            stampParagraph.lineSpacing = 1
            stampParagraph.paragraphSpacingBefore = index == 0 ? 0 : 18
            stampParagraph.paragraphSpacing = 3

            body.append(NSAttributedString(
                string: "\(stamp)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: mutedTextColor,
                    .paragraphStyle: stampParagraph,
                ]
            ))
            body.append(NSAttributedString(
                string: note.text + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14.5, weight: .regular),
                    .foregroundColor: primaryTextColor,
                    .paragraphStyle: textParagraph,
                ]
            ))
        }
        notesTextView.textStorage?.setAttributedString(body)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// A calm, near-black canvas with a single soft amber glow behind the title.
/// Deliberately quiet: the content does the talking, the way Wispr Flow keeps
/// its surface clean. No photo, motif, grain, or grid competing with the form.
final class DashboardBackgroundView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSGradient(colors: [
            NSColor(calibratedRed: 0.055, green: 0.057, blue: 0.066, alpha: 1),
            NSColor(calibratedRed: 0.039, green: 0.040, blue: 0.047, alpha: 1),
        ])
        base?.draw(in: bounds, angle: -90)

        let glowCenter = NSPoint(x: bounds.width * 0.62, y: bounds.height * 0.9)
        let glowRadius = bounds.width * 0.45
        let glow = NSGradient(colors: [
            voiAccent.withAlphaComponent(0.14),
            voiAccent.withAlphaComponent(0.0),
        ])
        glow?.draw(
            fromCenter: glowCenter, radius: 0,
            toCenter: glowCenter, radius: glowRadius,
            options: []
        )
    }
}

/// The sidebar surface — a calm panel with a single hairline on its right edge.
final class SidebarView: NSView {
    private let fill: NSColor
    private let line: NSColor

    init(frame: NSRect, fill: NSColor, line: NSColor) {
        self.fill = fill
        self.line = line
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()

        let border = NSBezierPath()
        border.move(to: NSPoint(x: bounds.maxX - 0.5, y: 0))
        border.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        line.setStroke()
        border.lineWidth = 1
        border.stroke()
    }
}

/// The Voi signature — five amber bars echoing the brand waveform mark.
final class WaveMarkView: NSView {
    private let color: NSColor
    private var animationTimer: Timer?

    private struct DotConfig {
        let radius: CGFloat
        let size: CGFloat
        let speed: CGFloat
        let phase: CGFloat
        let opacity: CGFloat
    }

    private let dotConfigs: [DotConfig] = [
        DotConfig(radius: 3.2, size: 1.4, speed: 1.55, phase: 0.10, opacity: 0.84),
        DotConfig(radius: 4.4, size: 1.6, speed: 1.10, phase: 0.55, opacity: 0.72),
        DotConfig(radius: 5.3, size: 1.8, speed: 1.95, phase: 1.05, opacity: 0.90),
        DotConfig(radius: 6.2, size: 1.7, speed: 0.92, phase: 1.60, opacity: 0.64),
        DotConfig(radius: 4.8, size: 1.5, speed: 1.34, phase: 2.10, opacity: 0.78),
        DotConfig(radius: 5.8, size: 1.3, speed: 1.78, phase: 2.70, opacity: 0.58),
        DotConfig(radius: 3.8, size: 1.2, speed: 2.20, phase: 3.20, opacity: 0.66),
        DotConfig(radius: 6.6, size: 1.5, speed: 1.26, phase: 3.80, opacity: 0.74),
    ]

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            animationTimer?.invalidate()
            animationTimer = nil
        } else if animationTimer == nil {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.needsDisplay = true
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = CGFloat(Date().timeIntervalSinceReferenceDate)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let baseRadius = min(bounds.width, bounds.height) * 0.33

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.18)
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = 5
        shadow.set()

        color.withAlphaComponent(0.06).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 0.5)).fill()

        for cfg in dotConfigs {
            let angle = t * cfg.speed + cfg.phase
            let pulse = (sin(t * cfg.speed * 2.2 + cfg.phase) + 1) / 2
            let orbitRadius = baseRadius * (cfg.radius / 6.6)
            let dotSize = cfg.size * (0.8 + 0.32 * pulse)
            let point = NSPoint(
                x: center.x + orbitRadius * cos(angle) - dotSize / 2,
                y: center.y + orbitRadius * sin(angle) - dotSize / 2
            )
            let dotRect = NSRect(origin: point, size: NSSize(width: dotSize, height: dotSize))
            color.withAlphaComponent(cfg.opacity * (0.55 + 0.35 * pulse)).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class RecordingOverlayView: NSView {
    private var animationTimer: Timer?
    private let discColor = NSColor(calibratedWhite: 0.24, alpha: 0.44)
    private let glowColor = NSColor(calibratedWhite: 1.0, alpha: 1)

    private struct DotConfig {
        let radius: CGFloat
        let size: CGFloat
        let speed: CGFloat
        let phase: CGFloat
        let opacity: CGFloat
    }

    private let dotConfigs: [DotConfig] = [
        DotConfig(radius: 4.5, size: 2.5, speed: 1.85, phase: 0.10, opacity: 0.82),
        DotConfig(radius: 5.5, size: 2.7, speed: 1.30, phase: 0.55, opacity: 0.74),
        DotConfig(radius: 6.5, size: 2.9, speed: 2.15, phase: 0.95, opacity: 0.90),
        DotConfig(radius: 7.2, size: 3.0, speed: 1.05, phase: 1.35, opacity: 0.68),
        DotConfig(radius: 8.0, size: 2.4, speed: 1.55, phase: 1.80, opacity: 0.62),
        DotConfig(radius: 8.8, size: 2.7, speed: 0.92, phase: 2.20, opacity: 0.72),
        DotConfig(radius: 9.5, size: 2.3, speed: 1.40, phase: 2.65, opacity: 0.58),
        DotConfig(radius: 10.4, size: 2.6, speed: 2.05, phase: 3.00, opacity: 0.76),
        DotConfig(radius: 6.0, size: 2.2, speed: 1.72, phase: 3.45, opacity: 0.66),
        DotConfig(radius: 7.8, size: 2.3, speed: 1.18, phase: 3.95, opacity: 0.70),
        DotConfig(radius: 9.0, size: 2.6, speed: 1.62, phase: 4.35, opacity: 0.84),
        DotConfig(radius: 5.0, size: 2.1, speed: 2.30, phase: 4.80, opacity: 0.60)
    ]

    init(frame: NSRect, accent _: NSColor) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            animationTimer?.invalidate()
            animationTimer = nil
        } else if animationTimer == nil {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.needsDisplay = true
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13)
        NSColor(calibratedWhite: 0.025, alpha: 0.86).setFill()
        rounded.fill()

        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
        rounded.lineWidth = 1
        rounded.stroke()

        let markRect = NSRect(x: 11, y: 9, width: 28, height: 28)
        discColor.setFill()
        NSBezierPath(ovalIn: markRect).fill()
        drawOrbitDots(in: markRect)
    }

    private func drawOrbitDots(in rect: NSRect) {
        let t = CGFloat(Date().timeIntervalSinceReferenceDate)
        let scale = rect.width / 36.0
        let center = NSPoint(x: rect.midX, y: rect.midY)

        for cfg in dotConfigs {
            let angle = t * cfg.speed + cfg.phase
            let pulse = (sin(t * cfg.speed * 2.3 + cfg.phase) + 1) / 2
            let dotSize = cfg.size * scale * (0.75 + 0.25 * pulse)
            let point = NSPoint(
                x: center.x + cfg.radius * scale * cos(angle) - dotSize / 2,
                y: center.y + cfg.radius * scale * sin(angle) - dotSize / 2
            )
            let dotRect = NSRect(origin: point, size: NSSize(width: dotSize, height: dotSize))

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = glowColor.withAlphaComponent(cfg.opacity * 0.16)
            shadow.shadowOffset = .zero
            shadow.shadowBlurRadius = 1.6
            shadow.set()
            glowColor.withAlphaComponent(cfg.opacity * (0.64 + 0.24 * pulse)).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

final class VoiButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        layer?.opacity = 0.72
        super.mouseDown(with: event)
        layer?.opacity = 1
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class VoiTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = VoiTextFieldCell(textCell: "")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        cell = VoiTextFieldCell(textCell: stringValue)
    }
}

final class VoiTextFieldCell: NSTextFieldCell {
    private let horizontalInset: CGFloat = 14

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(in: rect)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centeredRect(in: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centeredRect(in: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    private func centeredRect(in rect: NSRect) -> NSRect {
        var textRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        textRect.origin.x = rect.origin.x + horizontalInset
        textRect.size.width = rect.width - horizontalInset * 2
        textRect.origin.y = rect.origin.y + floor((rect.height - textHeight) / 2)
        textRect.size.height = textHeight
        return textRect
    }
}

final class SignalLineView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.width, y: bounds.midY))
        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        path.lineWidth = 1
        path.stroke()

        let signal = NSBezierPath()
        signal.move(to: NSPoint(x: 0, y: bounds.midY))
        signal.line(to: NSPoint(x: bounds.width * 0.38, y: bounds.midY))
        NSColor(calibratedRed: 0.9, green: 0.0, blue: 0.08, alpha: 0.9).setStroke()
        signal.lineWidth = 1.4
        signal.stroke()
    }
}

struct CartesiaResponse: Decodable {
    let text: String
}

enum VoiError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

private func polish(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }

    let punctuation: [(String, String)] = [
        (#"\s+(?:full stop|period)\b"#, "."),
        (#"\s+comma\b"#, ","),
        (#"\s+question mark\b"#, "?"),
        (#"\s+exclamation mark\b"#, "!"),
        (#"\s+colon\b"#, ":"),
        (#"\s+semicolon\b"#, ";"),
        (#"\s+(?:new paragraph|new line)\b"#, "\n\n"),
    ]

    for (pattern, replacement) in punctuation {
        text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }

    let correctionPatterns: [(String, String)] = [
        (#"\b(at|by|around|about|for|on)\s+([^,.;!?]{1,40}?)\s*(?:\.{3}|,)?\s*(?:actually|no|sorry|rather)\s+([^,.;!?]{1,40}?)(?=([,.;!?])|\s+(?:and|but|so|then|because|when|if)\b|$)"#, "$1 $3"),
        (#"\b([^,.;!?]{1,50}?)\s*(?:\.{3}|,)?\s*(?:actually|no|sorry|rather|i mean)\s+([^,.;!?]{1,50}?)(?=([,.;!?])|\s+(?:and|but|so|then|because|when|if)\b|$)"#, "$2"),
    ]

    for (pattern, replacement) in correctionPatterns {
        text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }

    text = text.replacingOccurrences(
        of: #"\b(?:um+|uh+|erm+|ah+|hmm+|mm+|you know|i mean|sort of|kind of)\b[,\s]*"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
    )

    text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: #"([,.;:!?])([^\s\n])"#, with: "$1 $2", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if let first = text.first {
        text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
    }

    if let last = text.last, !".!?".contains(last) {
        text.append(".")
    }

    return text
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

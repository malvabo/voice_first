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

private enum PasteResult {
    case pasted
    case copiedNeedsAccessibility
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
            return NSColor(calibratedRed: 0.42, green: 0.82, blue: 0.52, alpha: 1)
        case .warning:
            return NSColor(calibratedRed: 0.965, green: 0.725, blue: 0.231, alpha: 1)
        case .blocked:
            return NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.44, alpha: 1)
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
    private let accentColor = NSColor(calibratedRed: 0.965, green: 0.725, blue: 0.231, alpha: 1)
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
    private var keyField: NSTextField?
    private var statusLabel: NSTextField?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var notesTextView: NSTextView?
    private var notesScrollView: NSScrollView?
    private var composerTextView: NSTextView?
    private var permissionLabel: NSTextField?
    private var micChip: NSTextField?
    private var accessibilityChip: NSTextField?
    private var inputChip: NSTextField?
    private var hotKeyDiagnosticsLabel: NSTextField?
    private var shortcutLabel: NSTextField?
    private var eventLogTextView: NSTextView?
    private var eventLogScrollView: NSScrollView?
    private var diagnosticsToggleButton: NSButton?
    private var manualDictationButton: NSButton?
    private var recentEvents: [String] = []
    private var notes: [RecordedNote] = []
    private var hasRequestedMicrophoneThisSession = false
    private var diagnosticsExpanded = false
    private var hotKeyDiagnosticsMessage = "Shortcut status pending."

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        notes = loadRecordedNotes()
        makeApplicationMenu()
        makeMenu()
        installPushToTalkHotKey()
        installKeyMonitors()
        writeLog("launch team=\(Bundle.main.object(forInfoDictionaryKey: "TeamIdentifier") as? String ?? "unknown") ax=\(AXIsProcessTrusted())")
        setStatus("Voi ready")
        if shouldShowSetupWindowOnLaunch {
            showSetupWindow(activate: true)
        }
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
        menu.addItem(NSMenuItem(title: "Hold Option-Space to dictate", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "fn/Globe is experimental", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Dashboard", action: #selector(showDashboard), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Set Cartesia API Key...", action: #selector(setCartesiaKey), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Use Clipboard as Cartesia Key", action: #selector(useClipboardAsCartesiaKey), keyEquivalent: ""))
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
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1
        button.layer?.borderColor = (accent ? NSColor.clear : borderColor).cgColor
        button.layer?.backgroundColor = (accent ? accentColor.withAlphaComponent(0.92) : NSColor(calibratedWhite: 1, alpha: 0.055)).cgColor
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: accent ? accentInkColor : primaryTextColor,
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
        input.font = .systemFont(ofSize: 13, weight: .regular)
        input.textColor = primaryTextColor
        input.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.32)
        input.isBezeled = false
        input.focusRingType = .none
        input.wantsLayer = true
        input.layer?.cornerRadius = 8
        input.layer?.borderWidth = 1
        input.layer?.borderColor = borderColor.cgColor
        input.layer?.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.32).cgColor
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
            return "Shortcuts active: Option-Space + Control-Option-Space"
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

    private var shouldShowSetupWindowOnLaunch: Bool {
        UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty != false
            || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            || !AXIsProcessTrusted()
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
        recentEvents.insert("\(formatter.string(from: Date())) hotKey option+space \(phase)", at: 0)
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
                let isFunctionDown = event.flags.contains(.maskSecondaryFn)
                Task { @MainActor in
                    app.logKeyEvent(type: type, keyCode: keyCode, flags: event.flags)
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        app.reenableEventTap()
                        return
                    }

                    switch type {
                    case .flagsChanged:
                        app.handleFunctionFlagChange(isFunctionDown)
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
        shortcutLabel?.stringValue = "INPUT_EVENTS_RESUMED / TRY_OPTION_SPACE_AGAIN"
    }

    fileprivate func handleFunctionFlagChange(_ isFunctionDown: Bool) {
        if isFunctionDown && !functionKeyDown {
            shortcutLabel?.stringValue = "fn/Globe detected. Recording..."
            functionKeyDown = startRecording()
        } else if !isFunctionDown && functionKeyDown {
            functionKeyDown = false
            stopRecording()
        }
    }

    fileprivate func handlePushToTalkKeyChange(_ isDown: Bool) {
        if isDown && !pushToTalkKeyDown {
            shortcutLabel?.stringValue = "Option-Space detected. Recording..."
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
            setStatus("Add Cartesia key")
            shortcutLabel?.stringValue = "Add your Cartesia key before recording."
            showSetupWindow()
            return false
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            writeLog("recording blocked micNotDetermined")
            requestMicrophoneAccessOnce()
            return false
        case .denied, .restricted:
            writeLog("recording blocked micDenied")
            setStatus("Microphone blocked")
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
            shortcutLabel?.stringValue = "No target app captured. Click a text field, then hold Option-Space."
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
            shortcutLabel?.stringValue = "Listening. Release Option-Space to paste."
            return true
        } catch {
            writeLog("recording failed error=\(error.localizedDescription)")
            setStatus("Mic failed")
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
                    self.shortcutLabel?.stringValue = "MICROPHONE_ALLOWED / TRY_OPTION_SPACE_AGAIN"
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
        shortcutLabel?.stringValue = "Option-Space released. Polishing..."

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
                    saveRecordedNote(text)
                    switch paste(text) {
                    case .pasted:
                        setStatus("Pasted")
                        shortcutLabel?.stringValue = "Pasted. Hold Option-Space for another note."
                    case .copiedNeedsAccessibility:
                        setStatus("Copied")
                        shortcutLabel?.stringValue = "Copied to clipboard. Auto-Paste is blocked by macOS Accessibility."
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
            throw VoiError.message("Add Cartesia key")
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

        guard AXIsProcessTrusted() else {
            writeLog("paste copiedOnly ax=false chars=\(text.count)")
            refreshPermissionStatus(eventTapActive: eventTap != nil)
            return .copiedNeedsAccessibility
        }

        writeLog("paste posting target=\(targetApplication?.bundleIdentifier ?? "none") chars=\(text.count)")
        if let targetApplication {
            targetApplication.activate(options: [.activateAllWindows])
        }

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
        statusLabel?.stringValue = message == "Voi ready" ? "Ready — hold Option-Space" : message
    }

    @objc private func showDashboard() {
        showSetupWindow(activate: true)
    }

    @objc private func setCartesiaKey() {
        showSetupWindow(activate: true)
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

    @objc private func useClipboardAsCartesiaKey() {
        guard let clipboardText = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            setStatus("Clipboard empty")
            return
        }

        UserDefaults.standard.set(clipboardText, forKey: cartesiaKeyDefaultsKey)
        setStatus("Cartesia key saved")
    }

    private func showSetupWindow(activate: Bool = true) {
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }

        if let setupWindow {
            if activate {
                setupWindow.makeKeyAndOrderFront(nil)
            }
            updateSetupCopy()
            refreshPermissionStatus(eventTapActive: eventTap != nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
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

        let content = DashboardBackgroundView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 820, height: 600))
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let sidebar = SidebarView(
            frame: NSRect(x: 0, y: 0, width: 272, height: 600),
            fill: NSColor(calibratedWhite: 0.02, alpha: 0.30),
            line: NSColor(calibratedWhite: 1, alpha: 0.045)
        )
        sidebar.autoresizingMask = [.height]
        content.addSubview(sidebar)

        let logo = WaveMarkView(frame: NSRect(x: 20, y: 556, width: 30, height: 26), color: accentColor)
        content.addSubview(logo)

        let brand = uiLabel("Voi", size: 18, weight: .semibold)
        brand.frame = NSRect(x: 56, y: 553, width: 150, height: 30)
        content.addSubview(brand)

        let status = uiLabel("Ready", size: 12, weight: .medium, color: primaryTextColor)
        status.frame = NSRect(x: 20, y: 510, width: 232, height: 32)
        status.alignment = .center
        status.wantsLayer = true
        status.layer?.cornerRadius = 7
        status.layer?.borderWidth = 1
        status.layer?.borderColor = borderColor.cgColor
        status.layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 0.24).cgColor
        content.addSubview(status)
        statusLabel = status

        let permission = uiLabel("Setup health", size: 12, weight: .semibold, color: secondaryTextColor)
        permission.frame = NSRect(x: 20, y: 476, width: 200, height: 18)
        content.addSubview(permission)
        permissionLabel = permission

        let mic = makeChip(frame: NSRect(x: 20, y: 440, width: 232, height: 28))
        content.addSubview(mic)
        micChip = mic

        let accessibility = makeChip(frame: NSRect(x: 20, y: 406, width: 232, height: 28))
        content.addSubview(accessibility)
        accessibilityChip = accessibility

        let inputEvents = makeChip(frame: NSRect(x: 20, y: 372, width: 232, height: 28))
        content.addSubview(inputEvents)
        inputChip = inputEvents

        let label = uiLabel("Cartesia API key", size: 12, weight: .semibold, color: secondaryTextColor)
        label.frame = NSRect(x: 20, y: 334, width: 200, height: 18)
        content.addSubview(label)

        let input = NSTextField(frame: NSRect(x: 20, y: 302, width: 232, height: 30))
        let hasSavedKey = UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false
        input.placeholderString = hasSavedKey ? "Key saved. Paste a new key to replace." : "Paste your Cartesia API key"
        input.stringValue = ""
        styleTextField(input)
        content.addSubview(input)
        keyField = input

        let saveButton = makeButton(
            title: "Save key",
            frame: NSRect(x: 20, y: 260, width: 232, height: 34),
            action: #selector(saveCartesiaKeyFromWindow),
            accent: !hasSavedKey
        )
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)

        let autoPasteButton = makeButton(
            title: "Enable Auto-Paste",
            frame: NSRect(x: 20, y: 218, width: 232, height: 30),
            action: #selector(enableAutoPaste),
            accent: !AXIsProcessTrusted()
        )
        content.addSubview(autoPasteButton)

        let hideButton = makeButton(
            title: "Hide",
            frame: NSRect(x: 20, y: 176, width: 110, height: 30),
            action: #selector(hideSetupWindow)
        )
        content.addSubview(hideButton)

        let testButton = makeButton(
            title: "Test paste",
            frame: NSRect(x: 142, y: 176, width: 110, height: 30),
            action: #selector(testPaste)
        )
        content.addSubview(testButton)

        let manualButton = makeButton(
            title: "Start dictation",
            frame: NSRect(x: 20, y: 134, width: 232, height: 30),
            action: #selector(toggleManualDictation),
            accent: false
        )
        content.addSubview(manualButton)
        manualDictationButton = manualButton

        let diagnosticsButton = makeButton(
            title: "Show diagnostics",
            frame: NSRect(x: 20, y: 20, width: 232, height: 30),
            action: #selector(toggleDiagnostics)
        )
        content.addSubview(diagnosticsButton)
        diagnosticsToggleButton = diagnosticsButton

        let mainX: CGFloat = 296
        let mainW: CGFloat = 500

        let title = uiLabel("Ready", size: 23, weight: .semibold)
        title.frame = NSRect(x: mainX, y: 548, width: mainW, height: 34)
        content.addSubview(title)
        titleLabel = title

        let subtitle = uiLabel("Hold Option-Space, speak, release to paste.", size: 13, weight: .regular, color: secondaryTextColor)
        subtitle.frame = NSRect(x: mainX, y: 520, width: mainW, height: 22)
        content.addSubview(subtitle)
        subtitleLabel = subtitle

        let composerScroll = NSScrollView(frame: NSRect(x: mainX, y: 300, width: mainW, height: 200))
        let composerView = NSTextView(frame: composerScroll.bounds)
        styleScrollView(composerScroll, textView: composerView)
        composerView.font = .systemFont(ofSize: 17, weight: .regular)
        composerView.textContainerInset = NSSize(width: 18, height: 16)
        composerScroll.documentView = composerView
        content.addSubview(composerScroll)
        composerTextView = composerView

        let shortcut = uiLabel("Waiting for Option-Space.", size: 12.5, weight: .regular, color: secondaryTextColor)
        shortcut.frame = NSRect(x: mainX, y: 266, width: 380, height: 20)
        content.addSubview(shortcut)
        shortcutLabel = shortcut

        let copyButton = makeButton(
            title: "Copy",
            frame: NSRect(x: mainX + mainW - 92, y: 262, width: 92, height: 30),
            action: #selector(copyLatestNote)
        )
        content.addSubview(copyButton)

        let hotKeyDiagnostics = uiLabel(hotKeyDiagnosticsMessage, size: 11, weight: .regular, color: mutedTextColor)
        hotKeyDiagnostics.frame = NSRect(x: mainX, y: 244, width: mainW, height: 18)
        content.addSubview(hotKeyDiagnostics)
        hotKeyDiagnosticsLabel = hotKeyDiagnostics

        let notesLabel = uiLabel("Recorded notes", size: 12, weight: .semibold, color: secondaryTextColor)
        notesLabel.frame = NSRect(x: mainX, y: 226, width: 220, height: 18)
        content.addSubview(notesLabel)

        let scrollView = NSScrollView(frame: NSRect(x: mainX, y: 52, width: mainW, height: 162))
        let textView = NSTextView(frame: scrollView.bounds)
        styleScrollView(scrollView, textView: textView)
        scrollView.documentView = textView
        content.addSubview(scrollView)
        notesScrollView = scrollView
        notesTextView = textView
        refreshNotesView()

        let eventScrollView = NSScrollView(frame: NSRect(x: mainX, y: 52, width: mainW, height: 162))

        let eventTextView = NSTextView(frame: eventScrollView.bounds)
        styleScrollView(eventScrollView, textView: eventTextView, mono: true)
        eventScrollView.documentView = eventTextView
        eventScrollView.isHidden = true
        content.addSubview(eventScrollView)
        eventLogScrollView = eventScrollView
        eventLogTextView = eventTextView
        refreshEventLog()

        setupWindow = window
        if activate {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderOut(nil)
        }
        updateSetupCopy()
        refreshPermissionStatus(eventTapActive: eventTap != nil)
        updateDiagnosticsVisibility()
    }

    @objc private func saveCartesiaKeyFromWindow() {
        setupWindow?.makeFirstResponder(nil)
        let value = keyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hadExistingKey = UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false
        if value.isEmpty && hadExistingKey {
            setStatus("Cartesia key unchanged")
            shortcutLabel?.stringValue = "Key already saved. Paste a new key to replace it."
            return
        }

        UserDefaults.standard.set(value, forKey: cartesiaKeyDefaultsKey)
        if value.isEmpty {
            setStatus("Cartesia key cleared")
            keyField?.placeholderString = "Paste your Cartesia API key"
            shortcutLabel?.stringValue = "Add your Cartesia key before recording."
        } else {
            setStatus("Cartesia key saved")
            keyField?.stringValue = ""
            keyField?.placeholderString = "Key saved. Paste a new key to replace."
            shortcutLabel?.stringValue = "Key saved. Hold Option-Space to dictate."
            updateSetupCopy()
        }
        refreshPermissionStatus(eventTapActive: eventTap != nil)
    }

    private func updateSetupCopy() {
        let hasKey = UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false
        if hasKey {
            titleLabel?.stringValue = "Voi is ready"
            subtitleLabel?.stringValue = "Hold Option-Space, speak, release to paste."
            statusLabel?.stringValue = "Ready"
        } else {
            titleLabel?.stringValue = "Set up Voi"
            subtitleLabel?.stringValue = "Add your Cartesia key, then hold Option-Space to dictate."
            statusLabel?.stringValue = "Waiting for Cartesia API key"
        }
    }

    private func refreshPermissionStatus(eventTapActive: Bool) {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let micStatus: String
        let micState: ChipState
        switch mic {
        case .authorized:
            micStatus = "Mic: allowed"
            micState = .success
        case .denied, .restricted:
            micStatus = "Mic: blocked"
            micState = .blocked
        case .notDetermined:
            micStatus = "Mic: not decided"
            micState = .warning
        @unknown default:
            micStatus = "Mic: unknown"
            micState = .neutral
        }

        let isAccessible = AXIsProcessTrusted()
        updateChip(micChip, title: micStatus, state: micState)
        updateChip(
            accessibilityChip,
            title: isAccessible ? "Auto-Paste: on" : "Auto-Paste: off",
            state: isAccessible ? .success : .warning
        )
        updateChip(
            inputChip,
            title: shortcutStatusTitle(),
            state: hasRegisteredHotKey ? .success : .blocked
        )
    }

    private func shortcutStatusTitle() -> String {
        switch (primaryHotKeyRef != nil, fallbackHotKeyRef != nil) {
        case (true, true):
            return "Shortcuts: active"
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
        // Diagnostics shares the notes area, so the dashboard keeps its visual weight on notes by default.
        eventLogScrollView?.isHidden = !diagnosticsExpanded
        notesScrollView?.isHidden = diagnosticsExpanded
        diagnosticsToggleButton?.title = diagnosticsExpanded ? "Hide diagnostics" : "Show diagnostics"
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
            ?? "Hold Option-Space and speak. Voi removes pauses, fixes changed thoughts, formats the text, and pastes it where you're typing."
        composerTextView?.textColor = notes.first == nil ? mutedTextColor : primaryTextColor

        guard let notesTextView else { return }
        if notes.isEmpty {
            notesTextView.string = "No recorded notes yet."
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        notesTextView.string = notes
            .map { note in
                "\(formatter.string(from: note.createdAt))\n\(note.text)"
            }
            .joined(separator: "\n\n")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class DashboardBackgroundView: NSView {
    private static let backgroundImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "PersonInDarkRoom", withExtension: "jpg") else {
            return nil
        }

        guard let inputImage = CIImage(contentsOf: url) else {
            return NSImage(contentsOf: url)
        }

        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(inputImage.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(18.0, forKey: kCIInputRadiusKey)

        guard let outputImage = filter?.outputImage?.cropped(to: inputImage.extent) else {
            return NSImage(contentsOf: url)
        }

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(outputImage, from: inputImage.extent) else {
            return NSImage(contentsOf: url)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: inputImage.extent.width, height: inputImage.extent.height))
    }()

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.035, green: 0.035, blue: 0.038, alpha: 1).setFill()
        bounds.fill()

        drawPhotoBackground()
        drawGrain()
    }

    private func drawPhotoBackground() {
        guard let image = Self.backgroundImage, image.size.width > 0, image.size.height > 0 else {
            let fallback = NSGradient(colors: [
                NSColor(calibratedWhite: 0.02, alpha: 0.98),
                NSColor(calibratedWhite: 0.10, alpha: 0.7),
                NSColor(calibratedWhite: 0.02, alpha: 0.98),
            ])
            fallback?.draw(in: bounds, angle: 0)
            return
        }

        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = NSRect(
            x: (bounds.width - drawSize.width) * 0.50,
            y: (bounds.height - drawSize.height) * 0.46,
            width: drawSize.width,
            height: drawSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 0.52)
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 0, alpha: 0.62).setFill()
        bounds.fill()

        let leftVignette = NSGradient(colors: [
            NSColor(calibratedWhite: 0, alpha: 0.78),
            NSColor(calibratedWhite: 0, alpha: 0.32),
            NSColor(calibratedWhite: 0, alpha: 0.10),
        ])
        leftVignette?.draw(in: bounds, angle: 0)

        let rightLight = NSGradient(colors: [
            NSColor(calibratedWhite: 0.85, alpha: 0.10),
            NSColor(calibratedWhite: 0.22, alpha: 0.08),
            NSColor.clear,
        ])
        rightLight?.draw(
            in: NSRect(x: bounds.width * 0.56, y: bounds.height * 0.24, width: bounds.width * 0.54, height: bounds.height * 0.44),
            relativeCenterPosition: NSPoint(x: 0.38, y: 0.04)
        )
    }

    private func drawGrain() {
        NSColor(calibratedWhite: 1, alpha: 0.010).setFill()
        for index in 0..<90 {
            let x = CGFloat((index * 47) % Int(max(bounds.width, 1)))
            let y = CGFloat((index * 83) % Int(max(bounds.height, 1)))
            NSBezierPath(rect: NSRect(x: x, y: y, width: 1, height: 1)).fill()
        }
    }
}

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

final class WaveMarkView: NSView {
    private let color: NSColor

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let heights: [CGFloat] = [0.32, 0.62, 1.0, 0.62, 0.32]
        let barWidth: CGFloat = 2.6
        let gap = (bounds.width - barWidth * CGFloat(heights.count)) / CGFloat(heights.count - 1)
        for (index, factor) in heights.enumerated() {
            let height = bounds.height * factor
            let rect = NSRect(
                x: CGFloat(index) * (barWidth + gap),
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
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

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

    var textColor: NSColor {
        switch self {
        case .success:
            return NSColor(calibratedWhite: 0.94, alpha: 1)
        case .warning:
            return NSColor(calibratedWhite: 0.92, alpha: 1)
        case .blocked:
            return NSColor(calibratedWhite: 1, alpha: 1)
        case .neutral:
            return NSColor(calibratedWhite: 0.70, alpha: 1)
        }
    }

    var borderColor: NSColor {
        switch self {
        case .success:
            return NSColor(calibratedWhite: 1, alpha: 0.22)
        case .warning:
            return NSColor(calibratedRed: 0.95, green: 0.48, blue: 0.08, alpha: 0.55)
        case .blocked:
            return NSColor(calibratedRed: 0.96, green: 0.02, blue: 0.12, alpha: 0.75)
        case .neutral:
            return NSColor(calibratedWhite: 1, alpha: 0.16)
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .success:
            return NSColor(calibratedWhite: 0.07, alpha: 0.82)
        case .warning:
            return NSColor(calibratedRed: 0.28, green: 0.13, blue: 0.02, alpha: 0.82)
        case .blocked:
            return NSColor(calibratedRed: 0.28, green: 0.0, blue: 0.03, alpha: 0.88)
        case .neutral:
            return NSColor(calibratedWhite: 0.03, alpha: 0.76)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate {
    private let bgColor = NSColor(calibratedRed: 0.035, green: 0.035, blue: 0.038, alpha: 1)
    private let panelColor = NSColor(calibratedRed: 0.075, green: 0.075, blue: 0.078, alpha: 0.92)
    private let borderColor = NSColor(calibratedWhite: 1, alpha: 0.16)
    private let primaryTextColor = NSColor(calibratedWhite: 0.92, alpha: 1)
    private let secondaryTextColor = NSColor(calibratedWhite: 0.64, alpha: 1)
    private let mutedTextColor = NSColor(calibratedWhite: 0.42, alpha: 1)
    private let signalColor = NSColor(calibratedRed: 0.86, green: 0.02, blue: 0.12, alpha: 1)

    private var statusItem: NSStatusItem!
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var functionKeyDown = false
    private var pushToTalkKeyDown = false
    private var targetApplication: NSRunningApplication?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var setupWindow: NSWindow?
    private var keyField: NSTextField?
    private var statusLabel: NSTextField?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var notesTextView: NSTextView?
    private var permissionLabel: NSTextField?
    private var micChip: NSTextField?
    private var accessibilityChip: NSTextField?
    private var inputChip: NSTextField?
    private var hotKeyDiagnosticsLabel: NSTextField?
    private var shortcutLabel: NSTextField?
    private var eventLogTextView: NSTextView?
    private var eventLogScrollView: NSScrollView?
    private var diagnosticsToggleButton: NSButton?
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
        setStatus("Voi ready")
        showSetupWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
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

    private func styleButton(_ button: NSButton, accent: Bool = false) {
        button.setButtonType(.momentaryPushIn)
        button.sendAction(on: [.leftMouseUp])
        button.isEnabled = true
        button.refusesFirstResponder = true
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .center
        button.wantsLayer = true
        button.layer?.cornerRadius = 2
        button.layer?.borderWidth = 1
        button.layer?.borderColor = (accent ? signalColor : borderColor).cgColor
        button.layer?.backgroundColor = (accent ? NSColor(calibratedRed: 0.32, green: 0.0, blue: 0.04, alpha: 0.92) : panelColor).cgColor
        button.attributedTitle = NSAttributedString(
            string: button.title.uppercased(),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: accent ? NSColor.white : primaryTextColor,
                .kern: 1.6,
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
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.textColor = primaryTextColor
        input.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.72)
        input.isBezeled = false
        input.focusRingType = .none
        input.wantsLayer = true
        input.layer?.cornerRadius = 2
        input.layer?.borderWidth = 1
        input.layer?.borderColor = borderColor.cgColor
        input.layer?.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.72).cgColor
    }

    private func styleScrollView(_ scrollView: NSScrollView, textView: NSTextView, mono: Bool = false) {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 2
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = borderColor.cgColor
        scrollView.layer?.backgroundColor = panelColor.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = panelColor
        textView.textColor = mono ? secondaryTextColor : primaryTextColor
        textView.font = mono
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 12)
    }

    private func makeChip(frame: NSRect) -> NSTextField {
        let chip = monoLabel("", size: 10, weight: .semibold, color: primaryTextColor)
        chip.frame = frame
        chip.alignment = .center
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 2
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = borderColor.cgColor
        chip.layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 0.76).cgColor
        return chip
    }

    private func updateChip(_ chip: NSTextField?, title: String, state: ChipState) {
        chip?.stringValue = title
        chip?.textColor = state.textColor
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
                guard status == noErr, hotKeyID.id == 1 else { return noErr }

                let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                let eventKind = GetEventKind(event)
                Task { @MainActor in
                    if eventKind == UInt32(kEventHotKeyPressed) {
                        app.logHotKeyEvent("pressed")
                        app.handlePushToTalkKeyChange(true)
                    } else if eventKind == UInt32(kEventHotKeyReleased) {
                        app.logHotKeyEvent("released")
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

        let hotKeyID = EventHotKeyID(signature: fourCharCode("Voi1"), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr {
            updateHotKeyDiagnostics("Shortcut registered: Option-Space")
        } else {
            setStatus("Shortcut unavailable")
            updateHotKeyDiagnostics(hotKeyFailureMessage(registerStatus))
        }
    }

    private func updateHotKeyDiagnostics(_ message: String) {
        hotKeyDiagnosticsMessage = message
        shortcutLabel?.stringValue = message
        hotKeyDiagnosticsLabel?.stringValue = message
        recentEvents.insert(message, at: 0)
        recentEvents = Array(recentEvents.prefix(20))
        refreshEventLog()
    }

    private func hotKeyFailureMessage(_ status: OSStatus) -> String {
        if status == OSStatus(eventHotKeyExistsErr) {
            return "Shortcut conflict: Option-Space is already registered by another app."
        }
        return "Shortcut registration failed: \(status)"
    }

    private func logHotKeyEvent(_ phase: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        recentEvents.insert("\(formatter.string(from: Date())) hotKey option+space \(phase)", at: 0)
        recentEvents = Array(recentEvents.prefix(20))
        refreshEventLog()
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
            pushToTalkKeyDown = startRecording()
        } else if !isDown && pushToTalkKeyDown {
            pushToTalkKeyDown = false
            stopRecording()
        }
    }

    @discardableResult
    private func startRecording() -> Bool {
        guard recorder == nil else { return true }
        guard UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false else {
            setStatus("Add Cartesia key")
            shortcutLabel?.stringValue = "Add your Cartesia key before recording."
            showSetupWindow()
            return false
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            requestMicrophoneAccessOnce()
            return false
        case .denied, .restricted:
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
                setStatus("Mic permission needed")
                shortcutLabel?.stringValue = "Microphone did not start recording."
                recorder = nil
                recordingURL = nil
                return false
            }
            recorder = nextRecorder
            setStatus("Listening")
            shortcutLabel?.stringValue = "Listening. Release Option-Space to paste."
            return true
        } catch {
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
            shortcutLabel?.stringValue = "No active recording to transcribe."
            setStatus("Voi ready")
            return
        }
        recorder.stop()
        self.recorder = nil
        setStatus("Polishing")
        shortcutLabel?.stringValue = "Option-Space released. Polishing..."

        guard let recordingURL else {
            setStatus("Voi ready")
            shortcutLabel?.stringValue = "Recording file was not created."
            return
        }

        Task {
            defer { try? FileManager.default.removeItem(at: recordingURL) }
            do {
                let text = try await transcribeAndPolish(fileURL: recordingURL)
                await MainActor.run {
                    saveRecordedNote(text)
                    switch paste(text) {
                    case .pasted:
                        setStatus("Pasted")
                        shortcutLabel?.stringValue = "Pasted. Hold Option-Space for another note."
                    case .copiedNeedsAccessibility:
                        setStatus("Copied")
                        shortcutLabel?.stringValue = "Copied to clipboard. Enable Auto-Paste to insert automatically."
                    }
                }
                try? await Task.sleep(for: .milliseconds(1200))
                await MainActor.run { setStatus("Voi ready") }
            } catch {
                await MainActor.run {
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
            refreshPermissionStatus(eventTapActive: eventTap != nil)
            return .copiedNeedsAccessibility
        }

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
        statusItem.button?.title = message == "Voi ready" ? "Voi Ready" : "Voi: \(message)"
        statusLabel?.stringValue = message == "Voi ready" ? "READY / HOLD_OPTION_SPACE" : message.uppercased().replacingOccurrences(of: " ", with: "_")
    }

    @objc private func showDashboard() {
        showSetupWindow()
    }

    @objc private func setCartesiaKey() {
        showSetupWindow()
    }

    @objc private func enableAutoPaste() {
        let prompt = "AXTrustedCheckOptionPrompt"
        let granted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        refreshPermissionStatus(eventTapActive: eventTap != nil)
        if granted {
            setStatus("Auto-Paste enabled")
            shortcutLabel?.stringValue = "Auto-Paste is enabled."
        } else {
            setStatus("Enable Auto-Paste")
            shortcutLabel?.stringValue = "Grant Accessibility in System Settings, then try Test Paste."
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

    private func showSetupWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
            setupWindow.orderFrontRegardless()
            updateSetupCopy()
            refreshPermissionStatus(eventTapActive: eventTap != nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voi"
        window.backgroundColor = bgColor
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]

        let content = DashboardBackgroundView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 760, height: 660))
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let title = monoLabel("Voi is ready", size: 27, weight: .bold)
        title.frame = NSRect(x: 28, y: 602, width: 704, height: 36)
        content.addSubview(title)
        titleLabel = title

        let subtitle = monoLabel("Hold Option-Space, speak, release to paste.", size: 12, weight: .medium, color: secondaryTextColor)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 28, y: 560, width: 704, height: 42)
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        content.addSubview(subtitle)
        subtitleLabel = subtitle

        let signalLine = SignalLineView(frame: NSRect(x: 28, y: 538, width: 704, height: 8))
        content.addSubview(signalLine)

        let permission = monoLabel("Setup health", size: 11, weight: .semibold, color: primaryTextColor)
        permission.frame = NSRect(x: 28, y: 510, width: 160, height: 20)
        content.addSubview(permission)
        permissionLabel = permission

        let mic = makeChip(frame: NSRect(x: 28, y: 478, width: 150, height: 28))
        content.addSubview(mic)
        micChip = mic

        let accessibility = makeChip(frame: NSRect(x: 188, y: 478, width: 168, height: 28))
        content.addSubview(accessibility)
        accessibilityChip = accessibility

        let inputEvents = makeChip(frame: NSRect(x: 366, y: 478, width: 150, height: 28))
        content.addSubview(inputEvents)
        inputChip = inputEvents

        let hideButton = makeButton(
            title: "Hide",
            frame: NSRect(x: 650, y: 476, width: 82, height: 32),
            action: #selector(hideSetupWindow)
        )
        content.addSubview(hideButton)

        let testButton = makeButton(
            title: "Test Paste",
            frame: NSRect(x: 526, y: 476, width: 112, height: 32),
            action: #selector(testPaste)
        )
        content.addSubview(testButton)

        let autoPasteButton = makeButton(
            title: "Enable Auto-Paste",
            frame: NSRect(x: 526, y: 438, width: 206, height: 30),
            action: #selector(enableAutoPaste),
            accent: !AXIsProcessTrusted()
        )
        content.addSubview(autoPasteButton)

        let label = monoLabel("Cartesia API key", size: 11, weight: .semibold, color: primaryTextColor)
        label.frame = NSRect(x: 28, y: 438, width: 190, height: 20)
        content.addSubview(label)

        let input = NSTextField(frame: NSRect(x: 28, y: 405, width: 572, height: 30))
        let hasSavedKey = UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false
        input.placeholderString = hasSavedKey ? "Key saved. Paste a new key to replace." : "Paste your Cartesia API key"
        input.stringValue = ""
        styleTextField(input)
        content.addSubview(input)
        keyField = input

        let saveButton = makeButton(
            title: "Save Key",
            frame: NSRect(x: 618, y: 403, width: 114, height: 34),
            action: #selector(saveCartesiaKeyFromWindow),
            accent: !hasSavedKey
        )
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)

        let notesLabel = monoLabel("Recorded notes", size: 13, weight: .semibold, color: primaryTextColor)
        notesLabel.frame = NSRect(x: 28, y: 358, width: 220, height: 22)
        content.addSubview(notesLabel)

        let scrollView = NSScrollView(frame: NSRect(x: 28, y: 150, width: 704, height: 202))
        scrollView.autoresizingMask = [.width]

        let textView = NSTextView(frame: scrollView.bounds)
        styleScrollView(scrollView, textView: textView)
        scrollView.documentView = textView
        content.addSubview(scrollView)
        notesTextView = textView
        refreshNotesView()

        let diagnosticsButton = makeButton(
            title: "Show Diagnostics",
            frame: NSRect(x: 28, y: 104, width: 168, height: 30),
            action: #selector(toggleDiagnostics)
        )
        content.addSubview(diagnosticsButton)
        diagnosticsToggleButton = diagnosticsButton

        let shortcut = monoLabel("Waiting for Option-Space.", size: 11, weight: .regular, color: secondaryTextColor)
        shortcut.frame = NSRect(x: 210, y: 108, width: 522, height: 20)
        content.addSubview(shortcut)
        shortcutLabel = shortcut

        let hotKeyDiagnostics = monoLabel(hotKeyDiagnosticsMessage, size: 10, weight: .regular, color: mutedTextColor)
        hotKeyDiagnostics.frame = NSRect(x: 210, y: 88, width: 522, height: 18)
        content.addSubview(hotKeyDiagnostics)
        hotKeyDiagnosticsLabel = hotKeyDiagnostics

        let eventScrollView = NSScrollView(frame: NSRect(x: 28, y: 18, width: 704, height: 62))

        let eventTextView = NSTextView(frame: eventScrollView.bounds)
        styleScrollView(eventScrollView, textView: eventTextView, mono: true)
        eventScrollView.documentView = eventTextView
        eventScrollView.isHidden = true
        content.addSubview(eventScrollView)
        eventLogScrollView = eventScrollView
        eventLogTextView = eventTextView
        refreshEventLog()

        let status = monoLabel("Ready", size: 11, weight: .medium, color: mutedTextColor)
        status.frame = NSRect(x: 28, y: 112, width: 704, height: 20)
        status.isHidden = true
        content.addSubview(status)
        statusLabel = status

        setupWindow = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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
            title: hotKeyRef != nil ? "Shortcut: active" : "Shortcut: blocked",
            state: hotKeyRef != nil ? .success : .blocked
        )
    }

    @objc private func toggleDiagnostics() {
        diagnosticsExpanded.toggle()
        updateDiagnosticsVisibility()
    }

    private func updateDiagnosticsVisibility() {
        eventLogScrollView?.isHidden = !diagnosticsExpanded
        diagnosticsToggleButton?.title = diagnosticsExpanded ? "Hide Diagnostics" : "Show Diagnostics"
        if let diagnosticsToggleButton {
            styleButton(diagnosticsToggleButton)
        }
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

    @objc private func testPaste() {
        switch paste("Voi is ready.") {
        case .pasted:
            setStatus("Pasted")
            shortcutLabel?.stringValue = "Test pasted into the active app."
        case .copiedNeedsAccessibility:
            setStatus("Copied")
            shortcutLabel?.stringValue = "Test copied. Enable Auto-Paste to insert automatically."
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
        drawFrequencyMotif()
        drawGrain()

        NSColor(calibratedWhite: 1, alpha: 0.06).setFill()
        let startX = bounds.width - 156
        let startY = 78.0
        for row in 0..<4 {
            for col in 0..<5 {
                let dot = NSRect(
                    x: startX + CGFloat(col) * 22,
                    y: startY + CGFloat(row) * 22,
                    width: 2,
                    height: 2
                )
                NSBezierPath(ovalIn: dot).fill()
            }
        }
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
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 0.88)
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 0, alpha: 0.46).setFill()
        bounds.fill()

        let leftVignette = NSGradient(colors: [
            NSColor(calibratedWhite: 0, alpha: 0.74),
            NSColor(calibratedWhite: 0, alpha: 0.30),
            NSColor(calibratedWhite: 0, alpha: 0.08),
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

    private func drawFrequencyMotif() {
        drawBackgroundLabel("FREQUENCY", x: 60, y: bounds.height - 180, alpha: 0.36)
        drawBackgroundLabel("Y -\n0.00", x: 58, y: bounds.height - 420, alpha: 0.28)
        drawBackgroundLabel("- X\n100.00", x: bounds.width * 0.38, y: bounds.height - 205, alpha: 0.26)
        drawBackgroundLabel("X - 0.00", x: bounds.width * 0.36, y: 86, alpha: 0.25)
        drawBackgroundLabel("- Y\n100.00", x: bounds.width - 220, y: bounds.height - 420, alpha: 0.18)

        drawWave(
            in: NSRect(x: bounds.width * 0.30, y: bounds.height - 275, width: 170, height: 88),
            color: NSColor(calibratedWhite: 0.82, alpha: 0.46),
            dashAlpha: 0.16
        )
        drawSignalBeam(y: bounds.height - 360)
        drawWave(
            in: NSRect(x: bounds.width * 0.30, y: bounds.height - 445, width: 170, height: 88),
            color: NSColor(calibratedRed: 0.94, green: 0, blue: 0.1, alpha: 0.56),
            dashAlpha: 0.22
        )
        drawWave(
            in: NSRect(x: bounds.width * 0.30, y: bounds.height - 605, width: 170, height: 88),
            color: NSColor(calibratedWhite: 0.78, alpha: 0.22),
            dashAlpha: 0.08
        )
    }

    private func drawSignalBeam(y: CGFloat) {
        let glow = NSGradient(colors: [
            NSColor(calibratedRed: 0.96, green: 0, blue: 0.08, alpha: 0.0),
            NSColor(calibratedRed: 0.96, green: 0, blue: 0.08, alpha: 0.30),
            NSColor(calibratedRed: 0.96, green: 0, blue: 0.08, alpha: 0.0),
        ])
        glow?.draw(in: NSRect(x: 0, y: y - 18, width: bounds.width * 0.72, height: 42), angle: 0)

        for offset in [-8.0, -3.0, 4.0, 10.0] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 0, y: y + offset))
            line.curve(
                to: NSPoint(x: bounds.width * 0.56, y: y + offset * 0.18),
                controlPoint1: NSPoint(x: bounds.width * 0.20, y: y + offset * 1.4),
                controlPoint2: NSPoint(x: bounds.width * 0.36, y: y - offset * 0.8)
            )
            NSColor(calibratedRed: 0.94, green: 0, blue: 0.08, alpha: 0.12).setStroke()
            line.lineWidth = 1
            line.stroke()
        }
    }

    private func drawWave(in rect: NSRect, color: NSColor, dashAlpha: CGFloat) {
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: rect.minX, y: rect.midY))
        baseline.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        baseline.setLineDash([4, 4], count: 2, phase: 0)
        NSColor(calibratedWhite: 1, alpha: dashAlpha).setStroke()
        baseline.lineWidth = 0.8
        baseline.stroke()

        let path = NSBezierPath()
        let steps = 80
        for index in 0...steps {
            let progress = CGFloat(index) / CGFloat(steps)
            let x = rect.minX + progress * rect.width
            let y = rect.midY + sin(progress * .pi * 4) * rect.height * 0.36
            if index == 0 {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        color.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawBackgroundLabel(_ text: String, x: CGFloat, y: CGFloat, alpha: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.86, alpha: alpha),
            .kern: 2.0,
        ]
        NSString(string: text).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }

    private func drawGrain() {
        NSColor(calibratedWhite: 1, alpha: 0.018).setFill()
        for index in 0..<180 {
            let x = CGFloat((index * 47) % Int(max(bounds.width, 1)))
            let y = CGFloat((index * 83) % Int(max(bounds.height, 1)))
            NSBezierPath(rect: NSRect(x: x, y: y, width: 1, height: 1)).fill()
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

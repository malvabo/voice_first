import AppKit
import AVFoundation
import ApplicationServices
import Foundation

private let cartesiaURL = URL(string: "https://api.cartesia.ai/stt")!
private let cartesiaVersion = "2026-03-01"
private let cartesiaModel = "ink-whisper"
private let cartesiaLanguage = "en"
private let cartesiaKeyDefaultsKey = "voi.cartesiaKey"
private let recordedNotesDefaultsKey = "voi.recordedNotes"

struct RecordedNote: Codable {
    let id: UUID
    let text: String
    let createdAt: Date
}

// A single, consistent status-chip language: one calm hue per state, with
// uniform fill and border alphas so the three chips read as a set rather than
// three unrelated colors.
private enum ChipState {
    case success
    case warning
    case blocked
    case neutral

    /// The hue that carries the state. Text, border, and fill all derive from it.
    private var hue: NSColor {
        switch self {
        case .success:
            return NSColor(calibratedRed: 0.42, green: 0.82, blue: 0.52, alpha: 1) // calm green
        case .warning:
            return NSColor(calibratedRed: 0.96, green: 0.725, blue: 0.231, alpha: 1) // amber
        case .blocked:
            return NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.44, alpha: 1) // soft red
        case .neutral:
            return NSColor(calibratedWhite: 0.78, alpha: 1)
        }
    }

    var textColor: NSColor {
        // Brighten the hue toward white so labels stay legible on the dark fill.
        hue.blended(withFraction: 0.55, of: NSColor.white) ?? hue
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
    private let panelColor = NSColor(calibratedWhite: 0.12, alpha: 0.55)
    private let borderColor = NSColor(calibratedWhite: 1, alpha: 0.10)
    private let primaryTextColor = NSColor(calibratedWhite: 0.93, alpha: 1)
    private let secondaryTextColor = NSColor(calibratedWhite: 0.62, alpha: 1)
    private let mutedTextColor = NSColor(calibratedWhite: 0.45, alpha: 1)
    // Voi's one accent — the amber of the waveform mark. Spent with restraint.
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
    private var shortcutLabel: NSTextField?
    private var eventLogTextView: NSTextView?
    private var eventLogScrollView: NSScrollView?
    private var diagnosticsToggleButton: NSButton?
    private var recentEvents: [String] = []
    private var notes: [RecordedNote] = []
    private var hasRequestedMicrophoneThisSession = false
    private var diagnosticsExpanded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu-bar accessory, not a regular Dock app. This keeps Voi
        // from becoming the frontmost application, so the user's target app
        // (Codex, Claude, an editor) stays focused and receives the paste.
        NSApp.setActivationPolicy(.accessory)
        notes = loadRecordedNotes()
        makeApplicationMenu()
        makeMenu()
        installKeyMonitors()
        // Posting the synthetic Cmd-V into another app requires Accessibility
        // (Input Monitoring only covers capturing the hotkey). Prompt for it up
        // front so the paste path isn't silently dropped later.
        requestAccessibilityPermission()
        setStatus("Voi ready")
        showSetupWindow()
    }

    /// Asks macOS to add Voi to System Settings → Privacy & Security →
    /// Accessibility, showing the system prompt if it has not been answered.
    /// Returns the current trust state. The option key is referenced by its
    /// stable string value to avoid Unmanaged<CFString> bridging differences
    /// across Swift toolchains.
    @discardableResult
    private func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
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

    // System-font UI label — the calm, friendly voice of the dashboard.
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
        button.layer?.cornerRadius = 9
        button.layer?.borderWidth = 1
        button.layer?.borderColor = (accent ? NSColor.clear : borderColor).cgColor
        button.layer?.backgroundColor = (accent ? accentColor : panelColor).cgColor
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
        input.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.55)
        input.isBezeled = false
        input.focusRingType = .none
        input.wantsLayer = true
        input.layer?.cornerRadius = 9
        input.layer?.borderWidth = 1
        input.layer?.borderColor = borderColor.cgColor
        input.layer?.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.55).cgColor
    }

    private func styleScrollView(_ scrollView: NSScrollView, textView: NSTextView, mono: Bool = false) {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 12
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
        chip.layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 0.5).cgColor
        return chip
    }

    private func updateChip(_ chip: NSTextField?, title: String, state: ChipState) {
        // A leading status dot in the state hue, then the label — a small,
        // consistent health-indicator pattern shared by all three chips.
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

    private func installKeyMonitors() {
        let mask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let isFunctionDown = event.flags.contains(.maskSecondaryFn)
                let isOptionSpace = keyCode == 49 && event.flags.contains(.maskAlternate)
                let shouldConsumeOptionSpace = keyCode == 49 && (
                    (type == .keyDown && event.flags.contains(.maskAlternate)) ||
                    type == .keyUp
                )
                Task { @MainActor in
                    app.logKeyEvent(type: type, keyCode: keyCode, flags: event.flags)
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        app.reenableEventTap()
                        return
                    }

                    switch type {
                    case .flagsChanged:
                        app.handleFunctionFlagChange(isFunctionDown)
                    case .keyDown:
                        if isOptionSpace { app.handlePushToTalkKeyChange(true) }
                    case .keyUp:
                        if keyCode == 49 { app.handlePushToTalkKeyChange(false) }
                    default:
                        break
                    }
                }
                if shouldConsumeOptionSpace {
                    return nil
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
        shortcutLabel?.stringValue = "Input events resumed. Try Option-Space again."
    }

    fileprivate func handleFunctionFlagChange(_ isFunctionDown: Bool) {
        if isFunctionDown && !functionKeyDown {
            functionKeyDown = true
            shortcutLabel?.stringValue = "fn/Globe detected. Recording..."
            startRecording()
        } else if !isFunctionDown && functionKeyDown {
            functionKeyDown = false
            shortcutLabel?.stringValue = "fn/Globe released. Polishing..."
            stopRecording()
        }
    }

    fileprivate func handlePushToTalkKeyChange(_ isDown: Bool) {
        if isDown && !pushToTalkKeyDown {
            pushToTalkKeyDown = true
            shortcutLabel?.stringValue = "Option-Space detected. Recording..."
            startRecording()
        } else if !isDown && pushToTalkKeyDown {
            pushToTalkKeyDown = false
            shortcutLabel?.stringValue = "Option-Space released. Polishing..."
            stopRecording()
        }
    }

    private func startRecording() {
        guard recorder == nil else { return }
        guard UserDefaults.standard.string(forKey: cartesiaKeyDefaultsKey)?.isEmpty == false else {
            setStatus("Add Cartesia key")
            showSetupWindow()
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            requestMicrophoneAccessOnce()
            return
        case .denied, .restricted:
            setStatus("Microphone blocked")
            shortcutLabel?.stringValue = "Microphone is blocked. Enable it in System Settings → Privacy."
            showSetupWindow()
            refreshPermissionStatus(eventTapActive: eventTap != nil)
            return
        @unknown default:
            setStatus("Microphone unknown")
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = frontmost
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
                recorder = nil
                recordingURL = nil
                return
            }
            recorder = nextRecorder
            setStatus("Listening")
        } catch {
            setStatus("Mic failed")
            recorder = nil
            recordingURL = nil
        }
    }

    private func requestMicrophoneAccessOnce() {
        guard !hasRequestedMicrophoneThisSession else {
            setStatus("Microphone pending")
            shortcutLabel?.stringValue = "Waiting on the microphone prompt — please respond to it."
            return
        }

        hasRequestedMicrophoneThisSession = true
        setStatus("Allow microphone")
        shortcutLabel?.stringValue = "Allow the microphone once, then hold Option-Space again."
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPermissionStatus(eventTapActive: self.eventTap != nil)
                if granted {
                    self.setStatus("Voi ready")
                    self.shortcutLabel?.stringValue = "Microphone allowed. Hold Option-Space to dictate."
                } else {
                    self.setStatus("Microphone blocked")
                    self.shortcutLabel?.stringValue = "Microphone is blocked. Enable it in System Settings → Privacy."
                    self.showSetupWindow()
                }
            }
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil
        setStatus("Polishing")

        guard let recordingURL else {
            setStatus("Voi ready")
            return
        }

        Task {
            do {
                let text = try await transcribeAndPolish(fileURL: recordingURL)
                await MainActor.run {
                    saveRecordedNote(text)
                    paste(text)
                    setStatus("Pasted")
                }
                try? FileManager.default.removeItem(at: recordingURL)
                try? await Task.sleep(for: .milliseconds(1200))
                await MainActor.run { setStatus("Voi ready") }
            } catch {
                await MainActor.run { setStatus(error.localizedDescription) }
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

    private func paste(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Without Accessibility, CGEvent.post into another app is silently
        // dropped — the note saves but nothing lands in the target. Guard
        // explicitly and tell the user what to do instead of failing quietly.
        guard AXIsProcessTrusted() else {
            setStatus("Allow Accessibility")
            shortcutLabel?.stringValue = "Text copied to clipboard. Enable Voi in System Settings → Privacy & Security → Accessibility to paste automatically."
            requestAccessibilityPermission()
            refreshPermissionStatus(eventTapActive: eventTap != nil)
            showSetupWindow()
            return
        }

        // If we captured a target app that isn't Voi, bring it forward and wait
        // until it is actually frontmost before posting Cmd-V — a fixed delay
        // races against activation and drops the paste into the wrong app.
        if let targetApplication, targetApplication.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication.activate(options: [.activateAllWindows])
            postPasteWhenFrontmost(target: targetApplication, attempt: 0)
        } else {
            postPasteKeystroke()
        }
    }

    /// Polls (up to ~1s) until `target` is the frontmost app, then posts the
    /// paste keystroke. Falls back to posting anyway on timeout.
    private func postPasteWhenFrontmost(target: NSRunningApplication, attempt: Int) {
        let maxAttempts = 20 // 20 × 50ms ≈ 1s ceiling
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleIdentifier
        if isFrontmost || attempt >= maxAttempts {
            postPasteKeystroke()
            return
        }
        target.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.postPasteWhenFrontmost(target: target, attempt: attempt + 1)
        }
    }

    private func postPasteKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func setStatus(_ message: String) {
        statusItem.button?.title = message == "Voi ready" ? "Voi" : "Voi: \(message)"
        statusLabel?.stringValue = message == "Voi ready" ? "Ready — hold Option-Space" : message
    }

    @objc private func showDashboard() {
        showSetupWindow()
    }

    @objc private func setCartesiaKey() {
        showSetupWindow()
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
        // A normal window level: the dashboard shouldn't float above the app
        // the user is dictating into.
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]

        let content = DashboardBackgroundView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 820, height: 600))
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        // --- Sidebar: brand, status, setup health, key, controls ----------
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 272, height: 600), fill: panelColor, line: borderColor)
        sidebar.autoresizingMask = [.height]
        content.addSubview(sidebar)

        let logo = WaveMarkView(frame: NSRect(x: 20, y: 556, width: 30, height: 26), color: accentColor)
        content.addSubview(logo)

        let brand = uiLabel("Voi", size: 20, weight: .bold)
        brand.frame = NSRect(x: 56, y: 553, width: 150, height: 30)
        content.addSubview(brand)

        let status = uiLabel("Ready", size: 12.5, weight: .medium, color: primaryTextColor)
        status.frame = NSRect(x: 20, y: 510, width: 232, height: 32)
        status.alignment = .center
        status.wantsLayer = true
        status.layer?.cornerRadius = 8
        status.layer?.borderWidth = 1
        status.layer?.borderColor = borderColor.cgColor
        status.layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 0.5).cgColor
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

        let hideButton = makeButton(
            title: "Hide",
            frame: NSRect(x: 20, y: 218, width: 110, height: 30),
            action: #selector(hideSetupWindow)
        )
        content.addSubview(hideButton)

        let testButton = makeButton(
            title: "Test paste",
            frame: NSRect(x: 142, y: 218, width: 110, height: 30),
            action: #selector(testPaste)
        )
        content.addSubview(testButton)

        let diagnosticsButton = makeButton(
            title: "Show diagnostics",
            frame: NSRect(x: 20, y: 20, width: 232, height: 30),
            action: #selector(toggleDiagnostics)
        )
        content.addSubview(diagnosticsButton)
        diagnosticsToggleButton = diagnosticsButton

        // --- Main: title, composer (latest dictation), notes list ----------
        let mainX: CGFloat = 296
        let mainW: CGFloat = 500

        let title = uiLabel("Voi is ready", size: 25, weight: .bold)
        title.frame = NSRect(x: mainX, y: 548, width: mainW, height: 34)
        content.addSubview(title)
        titleLabel = title

        let subtitle = uiLabel("Hold Option-Space, speak, release to paste.", size: 13, weight: .regular, color: secondaryTextColor)
        subtitle.frame = NSRect(x: mainX, y: 520, width: mainW, height: 22)
        content.addSubview(subtitle)
        subtitleLabel = subtitle

        // Composer — your most recent dictation, ready to copy. Read-only.
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
            title: isAccessible ? "Accessibility: allowed" : "Accessibility: needed",
            state: isAccessible ? .success : .warning
        )
        updateChip(
            inputChip,
            title: eventTapActive ? "Input events: active" : "Input events: blocked",
            state: eventTapActive ? .success : .blocked
        )
    }

    @objc private func toggleDiagnostics() {
        diagnosticsExpanded.toggle()
        updateDiagnosticsVisibility()
    }

    private func updateDiagnosticsVisibility() {
        // The diagnostics log shares the notes area; swap one for the other.
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
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("Copied")
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
        paste("Voi is ready.")
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
        // The composer mirrors the web hero: the most recent dictation, or a
        // gentle placeholder when there's nothing yet.
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

/// A calm, near-black canvas with a single soft amber glow behind the title.
/// Deliberately quiet: the content does the talking, the way Wispr Flow keeps
/// its surface clean. No photo, motif, grain, or grid competing with the form.
final class DashboardBackgroundView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Base: a deep, slightly cool ink with a gentle top-to-bottom falloff.
        let base = NSGradient(colors: [
            NSColor(calibratedRed: 0.055, green: 0.057, blue: 0.066, alpha: 1),
            NSColor(calibratedRed: 0.039, green: 0.040, blue: 0.047, alpha: 1),
        ])
        base?.draw(in: bounds, angle: -90)

        // One soft amber glow in the upper-right of the main area, clear of
        // the sidebar, anchored near the title.
        let glowCenter = NSPoint(x: bounds.width * 0.62, y: bounds.height * 0.9)
        let glowRadius = bounds.width * 0.45
        let glow = NSGradient(colors: [
            NSColor(calibratedRed: 0.965, green: 0.725, blue: 0.231, alpha: 0.14),
            NSColor(calibratedRed: 0.965, green: 0.725, blue: 0.231, alpha: 0.0),
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

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        // Relative heights of the five bars, tallest in the middle.
        let heights: [CGFloat] = [0.32, 0.62, 1.0, 0.62, 0.32]
        let barWidth: CGFloat = 2.6
        let gap = (bounds.width - barWidth * CGFloat(heights.count)) / CGFloat(heights.count - 1)
        for (index, factor) in heights.enumerated() {
            let h = bounds.height * factor
            let x = CGFloat(index) * (barWidth + gap)
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
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
        signal.line(to: NSPoint(x: bounds.width * 0.30, y: bounds.midY))
        NSColor(calibratedRed: 0.965, green: 0.725, blue: 0.231, alpha: 0.9).setStroke()
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
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

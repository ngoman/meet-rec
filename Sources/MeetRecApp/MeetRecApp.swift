import AppKit
import Combine
import MeetRecCore
import MeetRecUI
import os
import SwiftUI

var appLock: FileLock?

@MainActor var appModel: AppModel?

@MainActor var appDelegate: AppDelegate?

@main
enum MeetRecMain {
    static func main() {
        switch AppInstance.acquire() {
        case .acquired(let lock): appLock = lock
        case .alreadyRunning: exit(0)
        case .unavailable(let code):
            Logger(subsystem: "local.meetrec.app", category: "app").error("app.lock: errno \(code, privacy: .public)")
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            appModel = AppModel()
            let delegate = AppDelegate()
            appDelegate = delegate
            app.delegate = delegate
            app.mainMenu = mainMenu(quitTarget: delegate)
            app.run()
        }
    }
}

@MainActor
func mainMenu(quitTarget: AnyObject) -> NSMenu {
    func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.submenu = menu
        return root
    }
    let main = NSMenu()
    let quit = item("Выйти из MeetRec", #selector(AppDelegate.quitRequested), "q")
    quit.target = quitTarget
    main.addItem(submenu("MeetRec", [quit]))
    main.addItem(submenu("Правка", [
        item("Отменить", Selector(("undo:")), "z"),
        item("Повторить", Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item("Вырезать", #selector(NSText.cut(_:)), "x"),
        item("Копировать", #selector(NSText.copy(_:)), "c"),
        item("Вставить", #selector(NSText.paste(_:)), "v"),
        item("Выбрать все", #selector(NSText.selectAll(_:)), "a"),
    ]))
    return main
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var iconObserver: AnyCancellable?
    private var appearanceObserver: NSKeyValueObservation?
    private var iconState: StatusIconState?
    private var iconDark: Bool?
    private var iconPending = false
    private var lastIconUpdate = Date.distantPast
    private var closedAt = Date.distantPast

    var isPanelOpen: Bool { popover.isShown }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model = appModel else { return }
        let hosting = NSHostingController(rootView: PanelView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MeetRec"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item
        updateIcon()
        iconObserver = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        appearanceObserver = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    private func desiredIconState() -> StatusIconState {
        guard let model = appModel else { return .idle }
        if model.isRecording { return .recording }
        if model.processingID != nil {
            return .processing(fraction: model.iconFraction)
        }
        return .idle
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let state = desiredIconState()
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard state != iconState || dark != iconDark else { return }
        let wait = 0.25 - Date().timeIntervalSince(lastIconUpdate)
        if wait > 0 {
            guard !iconPending else { return }
            iconPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.iconPending = false
                self?.updateIcon()
            }
            return
        }
        iconState = state
        iconDark = dark
        lastIconUpdate = Date()
        button.image = StatusIcon.image(state, dark: dark)
    }

    @objc func quitRequested() {
        guard let model = appModel, model.isRecording else {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Идет запись. Остановить и выйти?"
        alert.addButton(withTitle: "Остановить и выйти")
        alert.addButton(withTitle: "Отмена")
        model.isConfirmingQuit = true
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        model.isConfirmingQuit = false
        if response == .alertFirstButtonReturn {
            model.quit()
        } else if !popover.isShown {
            NSApp.hide(nil)
        }
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(closedAt) < 0.3 {
            return
        } else if let button = statusItem?.button {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func popoverWillShow(_ notification: Notification) {
        appModel?.refresh()
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        appModel?.updateTick()
        guard appModel?.isPickingFolder != true, appModel?.isConfirmingQuit != true, NSApp.modalWindow == nil,
              !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) else { return }
        NSApp.hide(nil)
    }
}

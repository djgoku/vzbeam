import Virtualization
import AppKit

/// The VM display window shared by `run --gui` and the OpenBSD installer. Closing it only
/// hides it — the guest keeps running — and returning to the app brings the same window
/// (still attached to the VM) back; stopping the guest is the session's job, not the window's.
final class VMWindow: NSObject, NSApplicationDelegate {
    private let window: NSWindow

    init(vm: VZVirtualMachine, title: String, width: Int, height: Int) {
        let view = VZVirtualMachineView(); view.virtualMachine = vm
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(width / 2, 640), height: max(height / 2, 400)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.contentView = view
        window.collectionBehavior.insert(.fullScreenPrimary)   // green button: full screen (Option-click: fill)
        window.isReleasedWhenClosed = false    // close only hides it; the VM keeps running behind it
        super.init()
    }

    /// Show the window and run the app's event loop; the owning session exits the process.
    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)   // .regular gives a Dock icon so the window is findable
        app.delegate = self                 // weak; the owning session keeps self alive
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.run()
    }

    // Switching to the app (Cmd-Tab, Dock, Mission Control) fires didBecomeActive, which, as in
    // other apps, leaves a minimized window in the Dock. A Dock-icon click fires reopen (alone, if
    // the app is already frontmost, as it is right after the close) and restores the window
    // whether closed or minimized.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !window.isVisible, !window.isMiniaturized else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !window.isVisible else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) } else { window.makeKeyAndOrderFront(nil) }
        return false
    }
}

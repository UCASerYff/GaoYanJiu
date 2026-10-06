import AppKit
import SwiftUI

private struct ClosePortalWindowKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var closePortalWindow: () -> Void {
        get { self[ClosePortalWindowKey.self] }
        set { self[ClosePortalWindowKey.self] = newValue }
    }
}

@MainActor
final class PortalImportWindow: NSObject, NSWindowDelegate {
    static let shared = PortalImportWindow()
    private var controller: NSWindowController?

    func show(publisher: PublisherDefinition?, store: PaperStore, settings: AppSettings) {
        if let window = controller?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = AppLocalization.text("论文自动导入")
        window.minSize = NSSize(width: 920, height: 700)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ImportSheetView(initialPublisher: publisher)
            .environmentObject(store)
            .environmentObject(settings)
            .environment(\.locale, settings.language.locale)
            .environment(\.closePortalWindow, { [weak window] in window?.performClose(nil) }))
        window.center()
        window.setFrameAutosaveName("PortalImportWindow")
        controller = NSWindowController(window: window)
        controller?.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        controller = nil
    }
}

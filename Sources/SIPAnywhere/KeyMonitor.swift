import AppKit
import SwiftUI

/// Key codes of keys without a printable character.
enum KeyCode {
    static let delete: UInt16 = 51          // ⌫
    static let forwardDelete: UInt16 = 117  // ⌦
    static let escape: UInt16 = 53
    static let keypadClear: UInt16 = 71     // "Clear" on the numeric keypad
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}

extension View {
    /// Calls `handler` for every key pressed in the main window while no text field
    /// is being edited and no sheet is open; the handler returns true when it used
    /// the key (which is then not passed on).
    func onKeyDown(_ handler: @escaping (NSEvent) -> Bool) -> some View {
        modifier(KeyDownMonitor(handler: handler))
    }
}

private struct KeyDownMonitor: ViewModifier {
    let handler: (NSEvent) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard let window = event.window, !window.isSheet, window.attachedSheet == nil,
                          !(window.firstResponder is NSText)   // typing in a text field
                    else { return event }
                    return handler(event) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

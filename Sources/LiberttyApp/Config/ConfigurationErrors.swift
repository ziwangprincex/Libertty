import AppKit
import SwiftUI

/// Shown when the config has problems, as Ghostty does: the list of errors,
/// with Ignore and Reload Configuration. Settings themselves are edited in
/// the file (Libertty ▸ Settings… opens it).
final class ConfigurationErrorsController: NSWindowController, ObservableObject {
    static let shared = ConfigurationErrorsController()

    @Published var errors: [String] = [] {
        didSet { if errors.isEmpty, isWindowLoaded { window?.performClose(nil) } }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "Configuration Errors"
        window.titlebarAppearsTransparent = true
        window.level = .popUpMenu
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ConfigurationErrorsView(model: self))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Called on every config load; shows the window when there's something to fix.
    func update(_ errors: [String]) {
        self.errors = errors
        if !errors.isEmpty, window?.isVisible != true { showWindow(nil) }
    }
}

private struct ConfigurationErrorsView: View {
    @ObservedObject var model: ConfigurationErrorsController

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 52))
                    .padding()
                Text("""
                    ^[\(model.errors.count) error(s) were](inflect: true) found while loading the configuration. \
                    Please review the errors below and reload your configuration or ignore the erroneous lines.
                    """)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.errors, id: \.self) { error in
                            Text(error)
                                .lineLimit(nil)
                                .font(.system(size: 12).monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        Spacer()
                    }
                    .padding(.all)
                    .frame(minHeight: geo.size.height)
                    .background(Color(.controlBackgroundColor))
                }
            }

            HStack {
                Spacer()
                Button("Ignore") { model.errors = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Reload Configuration") { ConfigStore.shared.reloadByRequest() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding([.bottom, .trailing])
        }
        .frame(minWidth: 480, maxWidth: 960, minHeight: 270)
    }
}

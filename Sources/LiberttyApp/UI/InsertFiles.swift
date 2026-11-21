import AppKit
import PhotosUI
import UniformTypeIdentifiers

// Attach Files… and Attach from Photos… (insert_file, insert_photo): what's
// picked goes to the pane as a drop goes (TerminalView.insertFiles), so a
// pane on another machine gets it uploaded there and its paths there typed.
// A photo or video from Photos is saved as a file first, where pasted
// images are kept (PasteContent.imageDirectory), and goes with them after
// a week.

extension TerminalWindowController {
    /// What Attach Files… and Attach from Photos… type into: the terminal
    /// with the keyboard (a floating pane, or the split's focused one),
    /// when it takes input. Nil with a document in front, or read-only.
    var insertionPane: TerminalView? {
        guard let pane = focusedFloatingPane ?? (focusedLeaf as? TerminalView), !pane.isReadOnly else { return nil }
        return pane
    }
}

extension TerminalView {
    /// Attach Files…: files and folders picked in a sheet on the window.
    /// Cancelled, nothing changes.
    func chooseFilesToInsert() {
        #if LIBERTTY_PROBES
        if let picked = ProbePick.files {
            ProbePick.files = nil
            return insertFiles(picked)
        }
        #endif
        // Never during a probe (an off-screen window, the user's files); nor
        // over another sheet, where it would wait out of sight.
        guard !Probe.running else { return }
        guard let window, window.attachedSheet == nil else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.t("Attach")
        if let host = session.host {
            panel.message = L10n.t("They're sent to %@, and their paths there typed into the terminal.")
                .replacingOccurrences(of: "%@", with: host.destination)
        } else {
            panel.message = L10n.t("Their paths are typed into the terminal.")
            // Starting where the pane's shell is.
            if let folder = session.workingDirectory { panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true) }
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.insertFiles(panel.urls)
        }
    }

    /// Attach from Photos…: photos and videos picked in the system's Photos
    /// picker, a sheet on the window. The picker runs apart from Libertty,
    /// which gets only what's picked: no access to the library is asked for.
    func choosePhotosToInsert() {
        let insertion = PhotoInsertion(pane: self)
        #if LIBERTTY_PROBES
        if let picked = ProbePick.photos {
            ProbePick.photos = nil
            return insertion.export(picked)
        }
        #endif
        guard !Probe.running else { return }
        guard let window, window.attachedSheet == nil, let presenter = window.contentViewController else { return NSSound.beep() }
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 0  // as many as you like
        configuration.selection = .ordered  // typed in the order picked
        configuration.filter = .any(of: [.images, .videos])
        // As the library keeps it (a HEIC stays HEIC), not converted.
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = insertion
        // (Its delegate is weak: the picker holds it while it's up.)
        objc_setAssociatedObject(picker, &Self.photoInsertionKey, insertion, .OBJC_ASSOCIATION_RETAIN)
        // Its own size, or, should it come with none, most of the window.
        if picker.view.frame.width < 200 || picker.view.frame.height < 200 {
            let room = window.contentLayoutRect.size
            picker.view.setFrameSize(NSSize(width: min(900, max(480, room.width - 80)), height: min(640, max(360, room.height - 80))))
        }
        presenter.presentAsSheet(picker)
    }

    private static var photoInsertionKey: UInt8 = 0
}

/// One Attach from Photos…: the picker's delegate, then what was picked
/// saved as files (each as its item provider answers, off the main thread)
/// and typed into the pane once all are in, in the order picked. While
/// they come, the pane's upload tag says so.
@MainActor
final class PhotoInsertion: NSObject, PHPickerViewControllerDelegate {
    private weak var pane: TerminalView?
    private var outcomes: [PhotoExport.Outcome?] = []
    private var left = 0

    init(pane: TerminalView) {
        self.pane = pane
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        // (It stays up until it's told.) Cancelled, there's nothing to export.
        picker.dismiss(nil)
        export(results.map(\.itemProvider))
    }

    func export(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty, let pane else { return }
        outcomes = Array(repeating: nil, count: providers.count)
        left = providers.count
        pane.uploadsUnderWay += 1
        pane.showUploadTag(L10n.t("Exporting from Photos…"))
        let stamp = PasteContent.stamp.string(from: Date())
        let directory = PasteContent.imageDirectory
        for (i, provider) in providers.enumerated() {
            PhotoExport.export(provider, stamp: stamp, into: directory) { [self] outcome in
                outcomes[i] = outcome
                left -= 1
                if left == 0 { finish() }
            }
        }
    }

    private func finish() {
        let done = outcomes.compactMap { $0 }
        let files = done.compactMap(\.file), failures = done.compactMap(\.failure)
        guard let pane else { return }
        pane.uploadsUnderWay -= 1
        if pane.uploadsUnderWay == 0 { pane.showUploadTag(nil) }
        pane.insertFiles(files)
        // What couldn't be had says so, in the window (not only the ones that could).
        guard !failures.isEmpty, let window = pane.window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("Couldn't export from Photos")
        alert.informativeText = failures.joined(separator: "\n") + (files.isEmpty ? "" : "\n\n" + L10n.t("The rest were attached."))
        alert.addButton(withTitle: L10n.t("OK"))
        alert.beginSheetModal(for: window)
    }
}

/// A photo or video picked from Photos, as a file: which of its forms to
/// ask for, the name it's kept under, and keeping it.
enum PhotoExport {
    enum Outcome: Sendable {
        case saved(URL)
        /// What to say: "NAME: why".
        case failed(String)

        var file: URL? { if case .saved(let url) = self { url } else { nil } }
        var failure: String? { if case .failed(let why) = self { why } else { nil } }
    }

    /// The form to ask an item for: the first it offers that's a picture or
    /// a video (its best: an item lists its forms best first).
    static func fileType(among identifiers: [String]) -> UTType? {
        identifiers.lazy.compactMap { UTType($0) }.first { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) }
    }

    /// `provider`'s picture or video saved into `directory` (off the main
    /// thread, when the provider has it), and how that went told on the main thread.
    static func export(_ provider: NSItemProvider, stamp: String, into directory: URL,
                       then done: @escaping @MainActor @Sendable (Outcome) -> Void) {
        let suggested = provider.suggestedName
        let label = suggested ?? L10n.t("An item")
        guard let type = fileType(among: provider.registeredTypeIdentifiers) else {
            let why = label + ": " + L10n.t("it's neither a picture nor a video")
            DispatchQueue.main.async { done(.failed(why)) }
            return
        }
        let noFile = label + ": " + L10n.t("Photos gave no file for it")
        _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
            // The provider's copy goes when this returns: kept first.
            let outcome: Outcome
            if let url {
                do {
                    outcome = .saved(try keep(url, suggested: suggested, type: type, stamp: stamp, in: directory))
                } catch {
                    outcome = .failed(label + ": " + error.localizedDescription)
                }
            } else {
                outcome = .failed(error.map { label + ": " + $0.localizedDescription } ?? noFile)
            }
            DispatchQueue.main.async { done(outcome) }
        }
    }

    /// One at a time: two items of one name mustn't both find it free.
    private static let lock = NSLock()

    /// A copy of `file` in `directory` (a clone, on the same disk), never
    /// over a file already there, and dated now, so it's kept as long as a
    /// pasted image (a photo's file may carry the day it was taken). Where
    /// it went. (The picker removes its own file once it's been read.)
    static func keep(_ file: URL, suggested: String?, type: UTType, stamp: String, in directory: URL,
                     now: Date = Date()) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        PasteContent.prune(directory, before: now.addingTimeInterval(-PasteContent.keep))
        let (base, ext) = name(suggested: suggested, type: type, fileExtension: file.pathExtension, stamp: stamp)
        func named(_ base: String) -> URL { directory.appendingPathComponent(ext.isEmpty ? base : base + "." + ext) }
        var url = named(base), n = 2
        while fm.fileExists(atPath: url.path) {
            url = named("\(base)-\(n)"); n += 1
        }
        // Dated now before it takes its name: with the date its file came with
        // (a photo from years ago), a prune of the folder meanwhile would take it.
        let staging = directory.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try fm.copyItem(at: file, to: staging)
        do {
            try fm.setAttributes([.posixPermissions: 0o600, .modificationDate: now], ofItemAtPath: staging.path)
            try fm.moveItem(at: staging, to: url)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return url
    }

    /// The name a picked item is kept under: `photo-STAMP-NAME.EXT`, NAME
    /// what Photos calls it (IMG_1234) when it says, made one plain word;
    /// EXT its own format's (a HEIC stays .heic, a video .mov): the one its
    /// file came with when that's the format's, else the format's usual one.
    static func name(suggested: String?, type: UTType, fileExtension: String, stamp: String) -> (base: String, ext: String) {
        let given = fileExtension.lowercased()
        let ext: String
        if !given.isEmpty, let own = UTType(filenameExtension: given), own.conforms(to: type) {
            ext = given
        } else {
            ext = type.preferredFilenameExtension ?? given
        }
        // (Some names come with an extension of their own: IMG_1234.HEIC.)
        var name = suggested ?? ""
        let suffix = (name as NSString).pathExtension
        if !suffix.isEmpty, let own = UTType(filenameExtension: suffix),
           own.conforms(to: .image) || own.conforms(to: .audiovisualContent) {
            name = (name as NSString).deletingPathExtension
        }
        // Letters, digits, - _ and . only, anything else a dash.
        var word = ""
        for scalar in name.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.hasSuffix("-") {
                word += "-"
            }
        }
        let ends = CharacterSet(charactersIn: "-.")
        word = String(word.trimmingCharacters(in: ends).prefix(80)).trimmingCharacters(in: ends)
        return (word.isEmpty ? "photo-\(stamp)" : "photo-\(stamp)-\(word)", ext)
    }
}

#if LIBERTTY_PROBES
/// What the UI probe picks next, in place of the open panel or Photos'
/// picker (neither can be driven): taken by the next Attach Files… or
/// Attach from Photos…
enum ProbePick {
    nonisolated(unsafe) static var files: [URL]?
    nonisolated(unsafe) static var photos: [NSItemProvider]?
}
#endif

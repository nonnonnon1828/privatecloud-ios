// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2020 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import NextcloudKit
import QuickLook
import SafariServices
import WebKit

// MARK: - Windows shortcut (.url / .lnk) resolution

enum NCShortcutTarget {
    case url(URL)
    case filePath(String)
}

enum NCShortcut {

    /// Whether the given file name is a Windows shortcut we handle.
    static func isShortcut(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext == "url" || ext == "lnk"
    }

    /// Resolve the shortcut stored at `localPath` to its target.
    static func resolve(localPath: String) -> NCShortcutTarget? {
        guard let data = FileManager.default.contents(atPath: localPath) else { return nil }
        switch (localPath as NSString).pathExtension.lowercased() {
        case "url": return resolveInternetShortcut(data)
        case "lnk": return resolveShellLink(data)
        default: return nil
        }
    }

    // .url — INI text: "[InternetShortcut]" / "URL=https://..."
    private static func resolveInternetShortcut(_ data: Data) -> NCShortcutTarget? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.count > 4, line.prefix(4).lowercased() == "url=" {
                let value = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: value), url.scheme != nil {
                    return .url(url)
                }
            }
        }
        return nil
    }

    // .lnk — binary MS-SHLLINK. Heuristic: a web shortcut embeds the target URL as a
    // string (UTF-16LE in the IDList, or ANSI); a file shortcut embeds a Windows path
    // (UNC "\\server\share\..." or "C:\..."). Scan for whichever appears first.
    private static func resolveShellLink(_ data: Data) -> NCShortcutTarget? {
        if let url = embeddedURL(in: data) { return .url(url) }
        if let path = windowsPath(in: data) { return .filePath(path) }
        return nil
    }

    private static func embeddedURL(in data: Data) -> URL? {
        for encoding in [String.Encoding.utf16LittleEndian, .isoLatin1] {
            guard let string = String(data: data, encoding: encoding) else { continue }
            if let match = firstMatch(in: string, pattern: "https?://[^\\x00-\\x20\"<>]+"),
               let url = URL(string: match) {
                return url
            }
        }
        return nil
    }

    private static func windowsPath(in data: Data) -> String? {
        for encoding in [String.Encoding.utf16LittleEndian, .isoLatin1] {
            guard let string = String(data: data, encoding: encoding) else { continue }
            for run in printableRuns(string, minLength: 4) where isWindowsPath(run) {
                return run
            }
        }
        return nil
    }

    private static func printableRuns(_ string: String, minLength: Int) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in string {
            if let scalar = character.unicodeScalars.first,
               scalar.value >= 0x20, scalar.value != 0x7F, character != "\"" {
                current.append(character)
            } else {
                if current.count >= minLength { runs.append(current) }
                current = ""
            }
        }
        if current.count >= minLength { runs.append(current) }
        return runs
    }

    private static func isWindowsPath(_ string: String) -> Bool {
        if string.hasPrefix("\\\\") { return true } // UNC
        let chars = Array(string)
        if chars.count >= 3, chars[0].isLetter, chars[1] == ":", chars[2] == "\\" { return true } // drive
        return false
    }

    private static func firstMatch(in string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range, in: string) else { return nil }
        return String(string[range])
    }
}

class NCViewer: NSObject {
    let utilityFileSystem = NCUtilityFileSystem()
    let utility = NCUtility()
    let database = NCManageDatabase.shared
    private var viewerQuickLook: NCViewerQuickLook?

    @MainActor
    func getViewerController(metadata: tableMetadata, ocIds: [String]? = nil, image: UIImage? = nil, delegate: UIViewController? = nil) async -> UIViewController? {
        let session = NCSession.shared.getSession(account: metadata.account)
        // Set Last Opening Date
        await self.database.setLocalFileLastOpeningDateAsync(metadata: metadata)

        // Windows shortcut (.url / .lnk): resolve to a URL (in-app browser) or a target path.
        // (Nextcloud Talk links are also ".url" — leave those to the Talk handler below.)
        if NCShortcut.isShortcut(metadata.fileNameView), metadata.name != NCGlobal.shared.talkName {
            let localPath = utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                                              fileName: metadata.fileNameView,
                                                                              userId: metadata.userId,
                                                                              urlBase: metadata.urlBase)
            if let target = NCShortcut.resolve(localPath: localPath) {
                switch target {
                case .url(let url):
                    if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                        delegate?.present(SFSafariViewController(url: url), animated: true)
                    } else if UIApplication.shared.canOpenURL(url) {
                        await UIApplication.shared.open(url)
                    }
                    return nil
                case .filePath(let path):
                    presentShortcutPathInfo(path: path, fileName: metadata.fileNameView, delegate: delegate)
                    return nil
                }
            }
            // Couldn't resolve → fall through to QuickLook so the raw file is still viewable.
        }

        // Text / code / Markdown / SVG → native viewer-editor
        if NCViewerText.canHandle(metadata.fileNameView) {
            let viewerText = NCViewerText()
            viewerText.metadata = metadata
            return viewerText
        }

        // URL
        if metadata.classFile == NKTypeClassFile.url.rawValue,
           !NCUtilityFileSystem().isDirectoryE2EE(serverUrl: metadata.serverUrl, urlBase: session.urlBase, userId: session.userId, account: session.account) {
            // nextcloudtalk://open-conversation?server={serverURL}&user={userId}&withRoomToken={roomToken}
            if metadata.name == NCGlobal.shared.talkName {
                let pathComponents = metadata.url.components(separatedBy: "/")
                if pathComponents.contains("call") {
                    let talkComponents = pathComponents.last?.components(separatedBy: "#")
                    if let roomToken = talkComponents?.first {
                        let urlString = "nextcloudtalk://open-conversation?server=\(session.urlBase)&user=\(session.userId)&withRoomToken=\(roomToken)"
                        if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                            await UIApplication.shared.open(url)
                        }
                    }
                }
            } else if let url = URL(string: metadata.url) {
                await UIApplication.shared.open(url)
            }
            return nil
        }

        // IMAGE AUDIO VIDEO
        else if metadata.isImage || metadata.isAudioOrVideo {
            let viewerMediaPageContainer = UIStoryboard(name: "NCViewerMediaPage", bundle: nil).instantiateInitialViewController() as? NCViewerMediaPage

            viewerMediaPageContainer?.delegateViewController = delegate
            if let ocIds {
                viewerMediaPageContainer?.currentIndex = ocIds.firstIndex(where: { $0 == metadata.ocId }) ?? 0
                viewerMediaPageContainer?.ocIds = ocIds
            } else {
                viewerMediaPageContainer?.currentIndex = 0
                viewerMediaPageContainer?.ocIds = [metadata.ocId]
            }

            return viewerMediaPageContainer
        }

        // DOCUMENTS
        else if metadata.classFile == NKTypeClassFile.document.rawValue,
                !NCUtilityFileSystem().isDirectoryE2EE(serverUrl: metadata.serverUrl, urlBase: session.urlBase, userId: session.userId, account: session.account) {

            // PDF
            if metadata.isPDF {
                let vc = UIStoryboard(name: "NCViewerPDF", bundle: nil).instantiateInitialViewController() as? NCViewerPDF

                vc?.metadata = metadata
                vc?.imageIcon = image
                vc?.navigationItem.setBidiSafeTitle(metadata.fileNameView)

                return vc
            }

            // DirectEditing
            if metadata.isAvailableDirectEditingEditorView {
                let editors = utility.editorsDirectEditing(account: metadata.account, contentType: metadata.contentType).map { $0.lowercased() }
                guard let editorAdapter = NCDirectEditorAdapter.resolve(from: editors) else {
                    self.QLPreview(metadata: metadata, delegate: delegate)
                    return nil
                }
                let editor = editorAdapter.apiKey
                let editorViewController = editorAdapter.viewControllerEditor
                let options = NKRequestOptions(customUserAgent: editorAdapter.userAgent(utility))
                if metadata.url.isEmpty {
                    let fileNamePath = utilityFileSystem.getRelativeFilePath(metadata.fileName, serverUrl: metadata.serverUrl, session: session)

                    NCActivityIndicator.shared.start(backgroundView: delegate?.view)
                    let results = await NextcloudKit.shared.textOpenFileAsync(fileNamePath: fileNamePath, editor: editor, account: metadata.account, options: options) { task in
                        Task {
                            let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: metadata.account,
                                                                                                        path: fileNamePath,
                                                                                                        name: "textOpenFile")
                            await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
                        }
                    }
                    NCActivityIndicator.shared.stop()

                    guard results.error == .success, let url = results.url else {
                        let windowScene = SceneManager.shared.getWindowScene(controller: delegate?.tabBarController as? NCMainTabBarController)
                        await showErrorBanner(windowScene: windowScene, text: results.error.errorDescription, errorCode: results.error.errorCode)
                        return nil
                    }

                    let vc = UIStoryboard(name: "NCViewerDirectEditing", bundle: nil).instantiateInitialViewController() as? NCViewerDirectEditing

                    vc?.metadata = metadata
                    vc?.editor = editorViewController
                    vc?.link = url
                    vc?.imageIcon = image
                    vc?.navigationItem.setBidiSafeTitle(metadata.fileNameView)

                    return vc
                } else {
                    let vc = UIStoryboard(name: "NCViewerDirectEditing", bundle: nil).instantiateInitialViewController() as? NCViewerDirectEditing

                    vc?.metadata = metadata
                    vc?.editor = editorViewController
                    vc?.link = metadata.url
                    vc?.imageIcon = image
                    vc?.navigationItem.setBidiSafeTitle(metadata.fileNameView)

                    return vc
                }
            }

            // RichDocument: Collabora
            if metadata.isAvailableRichDocumentEditorView {
                if metadata.url.isEmpty {
                    NCActivityIndicator.shared.start(backgroundView: delegate?.view)
                    let results = await NextcloudKit.shared.createUrlRichdocumentsAsync(fileID: metadata.fileId, account: metadata.account) { task in
                        Task {
                            let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: metadata.account,
                                                                                                        path: metadata.fileId,
                                                                                                        name: "createUrlRichdocuments")
                            await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
                        }
                    }
                    NCActivityIndicator.shared.stop()

                    guard results.error == .success, let url = results.url else {
                        let windowScene = SceneManager.shared.getWindowScene(controller: delegate?.tabBarController as? NCMainTabBarController)
                        await showErrorBanner(windowScene: windowScene, text: results.error.errorDescription, errorCode: results.error.errorCode)
                        return nil
                    }

                    let vc = UIStoryboard(name: "NCViewerRichdocument", bundle: nil).instantiateInitialViewController() as? NCViewerRichDocument

                    vc?.metadata = metadata
                    vc?.link = url
                    vc?.imageIcon = image
                    vc?.navigationItem.setBidiSafeTitle(metadata.fileNameView)

                    return vc

                } else {
                    let vc = UIStoryboard(name: "NCViewerRichdocument", bundle: nil).instantiateInitialViewController() as? NCViewerRichDocument

                    vc?.metadata = metadata
                    vc?.link = metadata.url
                    vc?.imageIcon = image
                    vc?.navigationItem.setBidiSafeTitle(metadata.fileNameView)

                    return vc
                }
            }
        }

        // iOS QL-Preview
        self.QLPreview(metadata: metadata, delegate: delegate)

        return nil
    }

    @MainActor
    private func presentShortcutPathInfo(path: String, fileName: String, delegate: UIViewController?) {
        let message = NSLocalizedString("_shortcut_target_is_",
                                        value: "このショートカットの参照先（この端末では直接開けません）:",
                                        comment: "") + "\n\n" + path
        let alert = UIAlertController(title: fileName, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default))
        delegate?.present(alert, animated: true)
    }

    func QLPreview(metadata: tableMetadata, delegate: UIViewController? = nil) {
        let item = URL(fileURLWithPath: utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                                                          fileName: metadata.fileNameView,
                                                                                          userId: metadata.userId,
                                                                                          urlBase: metadata.urlBase))
        if QLPreviewController.canPreview(item as QLPreviewItem) {
            let fileNamePath = NSTemporaryDirectory() + metadata.fileNameView
            utilityFileSystem.copyFile(atPath: utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                                                                 fileName: metadata.fileNameView,
                                                                                                 userId: metadata.userId,
                                                                                                 urlBase: metadata.urlBase), toPath: fileNamePath)
            let viewerQuickLook = NCViewerQuickLook(with: URL(fileURLWithPath: fileNamePath), isEditingEnabled: false, metadata: metadata)
            delegate?.present(viewerQuickLook, animated: true)
        } else {
            // Document Interaction Controller
            if let controller = delegate?.tabBarController as? NCMainTabBarController {
                Task {
                    await NCCreate().createActivityViewController(selectedMetadata: [metadata], controller: controller, sender: nil)
                }
            }
        }
    }
}

// MARK: - Native text / code / Markdown / SVG viewer-editor (provisional)

final class NCViewerText: UIViewController, UITextViewDelegate {

    var metadata: tableMetadata!

    private let utilityFileSystem = NCUtilityFileSystem()
    private let textView = UITextView()
    private var webView: WKWebView?
    private var isPreviewing = false

    private static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "log", "json", "yaml", "yml", "xml", "html", "htm",
        "css", "js", "mjs", "ts", "tsx", "jsx", "vue", "swift", "py", "sh", "bash", "zsh", "rb",
        "go", "rs", "c", "h", "cpp", "hpp", "cc", "java", "kt", "kts", "php", "pl", "sql", "toml",
        "ini", "cfg", "conf", "env", "csv", "tsv", "plist", "gradle", "properties", "r", "lua",
        "dart", "scala", "groovy", "svg"
    ]

    static func canHandle(_ fileName: String) -> Bool {
        textExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    private var fileExtension: String { (metadata.fileNameView as NSString).pathExtension.lowercased() }
    private var canRender: Bool { ["md", "markdown", "html", "htm", "svg"].contains(fileExtension) }
    private var localPath: String {
        utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                          fileName: metadata.fileNameView,
                                                          userId: metadata.userId,
                                                          urlBase: metadata.urlBase)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.setBidiSafeTitle(metadata.fileNameView)

        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.delegate = self
        textView.text = (try? String(contentsOfFile: localPath, encoding: .utf8))
            ?? (try? String(contentsOfFile: localPath, encoding: .isoLatin1)) ?? ""
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])

        if canRender {
            isPreviewing = true
            showPreview()
        }
        updateNavigationItems()
    }

    private func updateNavigationItems() {
        var items: [UIBarButtonItem] = [
            UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        ]
        if canRender {
            let title = isPreviewing ? NSLocalizedString("_edit_", value: "編集", comment: "")
                                     : NSLocalizedString("_preview_", value: "プレビュー", comment: "")
            items.append(UIBarButtonItem(title: title, style: .plain, target: self, action: #selector(togglePreview)))
        }
        navigationItem.rightBarButtonItems = items
    }

    @objc private func togglePreview() {
        isPreviewing.toggle()
        if isPreviewing {
            showPreview()
        } else {
            webView?.isHidden = true
            textView.isHidden = false
        }
        updateNavigationItems()
    }

    private func showPreview() {
        let web = webView ?? makeWebView()
        webView = web
        textView.isHidden = true
        web.isHidden = false
        switch fileExtension {
        case "svg":
            if let data = FileManager.default.contents(atPath: localPath) {
                web.load(data, mimeType: "image/svg+xml", characterEncodingName: "utf-8",
                         baseURL: URL(fileURLWithPath: localPath).deletingLastPathComponent())
            }
        case "html", "htm":
            web.loadHTMLString(textView.text, baseURL: nil)
        default:
            web.loadHTMLString(Self.markdownToHTMLDocument(textView.text), baseURL: nil)
        }
    }

    private func makeWebView() -> WKWebView {
        let web = WKWebView()
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        return web
    }

    func textViewDidChange(_ textView: UITextView) { }

    @objc private func saveTapped() {
        view.endEditing(true)
        Task { @MainActor in await self.save() }
    }

    private func save() async {
        do {
            try textView.text.write(toFile: localPath, atomically: true, encoding: .utf8)
        } catch {
            return presentError(error.localizedDescription)
        }
        let results = await NextcloudKit.shared.uploadAsync(
            serverUrlFileName: metadata.serverUrlFileName,
            fileNameLocalPath: localPath,
            autoMkcol: true,
            account: metadata.account) { _ in } progressHandler: { _ in }

        if results.error == .success {
            let serverUrl = metadata.serverUrl
            await NCNetworking.shared.transferDispatcher.notifyAllDelegatesAsync { delegate in
                delegate.transferReloadDataSource(serverUrl: serverUrl, requestData: false, status: nil)
            }
            if isPreviewing { showPreview() }
        } else {
            presentError(results.error.errorDescription)
        }
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: NSLocalizedString("_error_", comment: ""), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default))
        present(alert, animated: true)
    }

    // MARK: - Minimal Markdown → HTML (provisional)

    static func markdownToHTMLDocument(_ markdown: String) -> String {
        var body = ""
        var inCodeBlock = false
        var inList = false
        func closeList() { if inList { body += "</ul>\n"; inList = false } }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock { body += "</code></pre>\n" } else { closeList(); body += "<pre><code>" }
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock { body += escapeHTML(rawLine) + "\n"; continue }
            if let level = headingLevel(trimmed) {
                closeList()
                body += "<h\(level)>\(inlineMarkdown(String(trimmed.dropFirst(level + 1))))</h\(level)>\n"
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList { body += "<ul>\n"; inList = true }
                body += "<li>\(inlineMarkdown(String(trimmed.dropFirst(2))))</li>\n"
                continue
            }
            closeList()
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("> ") {
                body += "<blockquote>\(inlineMarkdown(String(trimmed.dropFirst(2))))</blockquote>\n"
            } else {
                body += "<p>\(inlineMarkdown(rawLine))</p>\n"
            }
        }
        closeList()
        if inCodeBlock { body += "</code></pre>\n" }

        let css = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + "<style>body{font:-apple-system-body;-webkit-text-size-adjust:100%;margin:16px;line-height:1.6;color:#1c1c1e;background:#fff;}"
            + "@media(prefers-color-scheme:dark){body{color:#e5e5ea;background:#000;}pre,code{background:#1c1c1e;}}"
            + "h1,h2,h3,h4{line-height:1.25;}pre{background:#f2f2f7;padding:12px;border-radius:8px;overflow:auto;}"
            + "code{font-family:ui-monospace,Menlo,monospace;background:#f2f2f7;padding:2px 4px;border-radius:4px;}"
            + "pre code{background:none;padding:0;}blockquote{border-left:3px solid #c7c7cc;margin:0;padding-left:12px;color:#6c6c70;}"
            + "a{color:#007aff;}img{max-width:100%;}</style>"
        return "<!doctype html><html><head>\(css)</head><body>\(body)</body></html>"
    }

    private static func headingLevel(_ line: String) -> Int? {
        var count = 0
        for ch in line { if ch == "#" { count += 1 } else { break } }
        let chars = Array(line)
        if count >= 1, count <= 6, chars.count > count, chars[count] == " " { return count }
        return nil
    }

    private static func inlineMarkdown(_ string: String) -> String {
        var text = escapeHTML(string)
        text = regexReplace(text, #"\*\*(.+?)\*\*"#, "<strong>$1</strong>")
        text = regexReplace(text, #"\*(.+?)\*"#, "<em>$1</em>")
        text = regexReplace(text, "`(.+?)`", "<code>$1</code>")
        text = regexReplace(text, #"\[(.+?)\]\((.+?)\)"#, "<a href=\"$2\">$1</a>")
        return text
    }

    private static func escapeHTML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
              .replacingOccurrences(of: "<", with: "&lt;")
              .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func regexReplace(_ string: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        return regex.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: template)
    }
}

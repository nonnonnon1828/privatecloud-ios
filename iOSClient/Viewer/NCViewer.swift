// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2020 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import NextcloudKit
import QuickLook
import SafariServices

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

// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit
import NextcloudKit
import Alamofire
import LucidBanner

extension NCCollectionViewCommon: UICollectionViewDelegate {
    @MainActor
    func didSelectMetadata(_ metadata: tableMetadata, withOcIds: Bool) async {
        let capabilities = await NKCapabilities.shared.getCapabilities(for: session.account)

        if metadata.e2eEncrypted {
            if capabilities.e2EEEnabled {
                if !NCPreferences().isEndToEndEnabled(account: metadata.account) {
                    do {
                        let e2ee = NCEndToEndSetup(controller: controller)
                        try await e2ee.start()
                    } catch let error as NKError {
                        if error.errorCode == NSUserCancelledError {
                            return
                        }
                        await showErrorBanner(
                            windowScene: windowScene,
                            text: error.errorDescription
                        )
                        return
                    } catch {
                        // fallback (non NKError)
                        await showErrorBanner(
                            windowScene: windowScene,
                            text: error.localizedDescription
                        )
                        return
                    }
                }
            } else {
                await showInfoBanner(windowScene: windowScene, text: "_e2e_server_disabled_")
                return
            }
        }

        func downloadFile() async {
            var downloadRequest: DownloadRequest?
            var banner: LucidBanner?
            var token: Int?

            (banner, token) = showHudBanner(windowScene: windowScene,
                                            title: "_download_in_progress_",
                                            stage: .button,
                                            onButtonTap: {
                if let request = downloadRequest {
                    request.cancel()
                }
            })

            guard let  metadata = await database.setMetadataSessionInWaitDownloadAsync(ocId: metadata.ocId,
                                                                                       session: self.networking.sessionDownload,
                                                                                       selector: global.selectorLoadFileView,
                                                                                       sceneIdentifier: self.controller?.sceneIdentifier) else {
                return
            }

            let results = await self.networking.downloadFile(metadata: metadata) { request in
                downloadRequest = request
            } progressHandler: { progress in
                Task {@MainActor in
                    banner?.update(
                        payload: LucidBannerPayload.Update(progress: Double(progress.fractionCompleted)),
                        for: token)
                }
            }

            if let banner {
                await banner.dismissAsync()
            }

            if results.nkError == .success || results.nkError == .cancelled {
                print("ok")
            } else {
                await showErrorBanner(windowScene: windowScene, text: results.nkError.errorDescription, errorCode: results.nkError.errorCode)
            }
        }

        if metadata.directory {
            await pushMetadata(metadata)
        } else {
            let image = utility.getImage(ocId: metadata.ocId, etag: metadata.etag, ext: self.global.previewExt1024, userId: metadata.userId, urlBase: metadata.urlBase)
            let fileExists = utilityFileSystem.fileProviderStorageExists(metadata)

            // --- E2EE -------
            if metadata.isDirectoryE2EE {
                if fileExists {
                    if let vc = await NCViewer().getViewerController(metadata: metadata, delegate: self) {
                        self.navigationController?.pushViewController(vc, animated: true)
                    }
                } else {
                    await downloadFile()
                }
                return
            }
            // ---------------

            if metadata.isImage || metadata.isAudioOrVideo {
                let metadatas = self.dataSource.getMetadatas()
                let ocIds = metadatas.filter { $0.classFile == NKTypeClassFile.image.rawValue ||
                    $0.classFile == NKTypeClassFile.video.rawValue ||
                    $0.classFile == NKTypeClassFile.audio.rawValue }.map(\.ocId)

                if let vc = await NCViewer().getViewerController(metadata: metadata, ocIds: withOcIds ? ocIds : nil, image: image, delegate: self) {
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            } else if NCViewerText.canHandle(metadata.fileNameView), !utilityFileSystem.fileProviderStorageExists(metadata), NextcloudKit.shared.isNetworkReachable() {
                // Text/code/Markdown/SVG not cached: download first; the transfer delegate then opens it.
                guard let metadata = await database.setMetadataSessionInWaitDownloadAsync(ocId: metadata.ocId,
                                                                                          session: self.networking.sessionDownload,
                                                                                          selector: global.selectorLoadFileView,
                                                                                          sceneIdentifier: self.controller?.sceneIdentifier) else {
                    return
                }
                await downloadFile()
            } else if !metadata.isDirectoryE2EE, metadata.isAvailableEditorView || utilityFileSystem.fileProviderStorageExists(metadata) || metadata.name == self.global.talkName {
                if let vc = await NCViewer().getViewerController(metadata: metadata, image: image, delegate: self) {
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            } else if NCShortcut.isShortcut(metadata.fileNameView), NextcloudKit.shared.isNetworkReachable() {
                // Windows shortcut not cached yet: download it; the transfer delegate then opens it.
                guard let metadata = await database.setMetadataSessionInWaitDownloadAsync(ocId: metadata.ocId,
                                                                                          session: self.networking.sessionDownload,
                                                                                          selector: global.selectorLoadFileView,
                                                                                          sceneIdentifier: self.controller?.sceneIdentifier) else {
                    return
                }
                await downloadFile()
            } else if NextcloudKit.shared.isNetworkReachable() {
                guard let  metadata = await database.setMetadataSessionInWaitDownloadAsync(ocId: metadata.ocId,
                                                                                           session: self.networking.sessionDownload,
                                                                                           selector: global.selectorLoadFileView,
                                                                                           sceneIdentifier: self.controller?.sceneIdentifier) else {
                    return
                }

                if metadata.name == "files" {
                    await downloadFile()
                } else if !metadata.url.isEmpty,
                          let vc = await NCViewer().getViewerController(metadata: metadata, delegate: self) {
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            } else {
                await showErrorBanner(windowScene: windowScene, text: "_go_online_", errorCode: NCGlobal.shared.errorOfflineNotAllowed)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let metadata = self.dataSource.getMetadata(indexPath: indexPath) else {
            return
        }

        if self.isEditMode {
            if let index = self.fileSelect.firstIndex(of: metadata.ocId) {
                self.fileSelect.remove(at: index)
            } else {
                self.fileSelect.append(metadata.ocId)
            }
            self.collectionView.reloadItems(at: [indexPath])
            self.tabBarSelect?.update(fileSelect: self.fileSelect, metadatas: self.getSelectedMetadatas(), userId: metadata.userId)
            self.collectionView.collectionViewLayout.invalidateLayout()
            // PrivateCloud: leave selection mode automatically once nothing is selected.
            if self.fileSelect.isEmpty {
                Task { await self.setEditMode(false) }
            }
            return
        }

        Task {
            await didSelectMetadata(metadata, withOcIds: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        // PrivateCloud: long-pressing an item enters selection mode (see longPressCollecationView),
        // so the single-item long-press menu is disabled here. The same actions stay on the cell's
        // "⋯" button. Returning nil unconditionally avoids the race where the system menu would
        // otherwise appear before the (async) setEditMode switch takes effect in this browser.
        return nil
    }

    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        animator.addCompletion {
            if let indexPath = configuration.identifier as? IndexPath {
                self.collectionView(collectionView, didSelectItemAt: indexPath)
            }
        }
    }
}

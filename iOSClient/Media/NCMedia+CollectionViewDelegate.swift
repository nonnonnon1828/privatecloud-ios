// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import NextcloudKit
import RealmSwift
import AVFoundation

extension NCMedia: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        Task {
            guard let metadata = dataSource.getMetadata(indexPath: indexPath),
                  let cell = collectionView.cellForItem(at: indexPath) as? NCMediaCell else { return }

            if isEditMode {
                if let index = fileSelect.firstIndex(of: metadata.ocId) {
                    fileSelect.remove(at: index)
                    cell.selected(false, color: NCBrandColor.shared.getElement(account: session.account))
                } else {
                    fileSelect.append(metadata.ocId)
                    cell.selected(true, color: NCBrandColor.shared.getElement(account: session.account))
                }
                tabBarSelect.selectCount = fileSelect.count
                // PrivateCloud: leave selection mode automatically once nothing is selected.
                if fileSelect.isEmpty {
                    setEditMode(false)
                }
            } else if let metadata = await self.database.getMetadataFromOcIdAsync(metadata.ocId) {
                // PrivateCloud: videos open in the in-house streaming player (AVPlayer + mTLS byte
                // ranges, short-video gestures). Photos keep the standard paged viewer.
                if metadata.isVideo {
                    self.presentStreamPlayer(metadata: metadata)
                    return
                }
                let image = utility.getImage(ocId: metadata.ocId, etag: metadata.etag, ext: global.previewExt1024, userId: metadata.userId, urlBase: metadata.urlBase)
                let ocIds = dataSource.metadatas.map { $0.ocId }

                if let vc = await NCViewer().getViewerController(metadata: metadata, ocIds: ocIds, image: image, delegate: self) {
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        // PrivateCloud: while selecting (long-press paint), suppress the single-item context menu.
        guard !isEditMode else {
            return nil
        }
        guard let ocId = dataSource.getMetadata(indexPath: indexPath)?.ocId,
              let metadata = database.getMetadataFromOcId(ocId)
        else {
            return nil
        }
        let identifier = indexPath as NSCopying
        let image = utility.getImage(ocId: metadata.ocId, etag: metadata.etag, ext: global.previewExt1024, userId: metadata.userId, urlBase: metadata.urlBase)

        return UIContextMenuConfiguration(identifier: identifier, previewProvider: {
            return NCViewerProviderContextMenu(metadata: metadata, image: image, sceneIdentifier: self.sceneIdentifier)
        }, actionProvider: { _ in
            let contextMenu = NCContextMenuMain(metadata: metadata.detachedCopy(), viewController: self, controller: self.controller, sender: collectionView)
            return contextMenu.viewMenu()
        })
    }

    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        animator.addCompletion {
            if let indexPath = configuration.identifier as? IndexPath {
                self.collectionView(collectionView, didSelectItemAt: indexPath)
            }
        }
    }
}

// MARK: - PrivateCloud: video streaming player entry

extension NCMedia {
    /// Open a video in the in-house AVPlayer streaming player. Cached files play locally; remote
    /// files stream over the app's mTLS session via byte ranges. If AVPlayer cannot decode the
    /// asset it calls back to the standard paged viewer (VLC, download-first).
    func presentStreamPlayer(metadata: tableMetadata) {
        var asset: AVURLAsset
        var loader: NCVideoStreamLoader? = nil

        if utilityFileSystem.fileProviderStorageExists(metadata) {
            let localPath = utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId, fileName: metadata.fileNameView, userId: metadata.userId, urlBase: metadata.urlBase)
            asset = AVURLAsset(url: URL(fileURLWithPath: localPath))
        } else if let realURL = URL(string: metadata.serverUrlFileName),
                  let made = NCVideoStreamLoader.makeAsset(realURL: realURL,
                                                           user: session.user,
                                                           password: NCPreferences().getPassword(account: metadata.account)) {
            asset = made.asset
            loader = made.loader
        } else {
            openInPagedViewer(metadata: metadata)
            return
        }

        let playerVC = NCStreamPlayerViewController(asset: asset, loader: loader, title: metadata.fileNameView)
        playerVC.onUnsupported = { [weak self] in
            self?.openInPagedViewer(metadata: metadata)
        }
        present(playerVC, animated: true)
    }

    /// Standard paged media viewer (used for unsupported video codecs as a fallback).
    func openInPagedViewer(metadata: tableMetadata) {
        Task {
            let image = utility.getImage(ocId: metadata.ocId, etag: metadata.etag, ext: global.previewExt1024, userId: metadata.userId, urlBase: metadata.urlBase)
            let ocIds = dataSource.metadatas.map { $0.ocId }
            if let vc = await NCViewer().getViewerController(metadata: metadata, ocIds: ocIds, image: image, delegate: self) {
                self.navigationController?.pushViewController(vc, animated: true)
            }
        }
    }
}

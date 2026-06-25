// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit
import NextcloudKit
import SwiftUI

extension NCMedia {
    func setEditMode(_ editMode: Bool) {
        if dataSource.metadatas.isEmpty {
            isEditMode = false
        } else {
            isEditMode = editMode
        }

        fileSelect.removeAll()
        tabBarSelect.selectCount = fileSelect.count

        if let visibleCells = collectionView?.indexPathsForVisibleItems.compactMap({ collectionView?.cellForItem(at: $0) }) {
            for case let cell as NCMediaCell in visibleCells {
                cell.selected(false, color: NCBrandColor.shared.getElement(account: session.account))
            }
        }

        self.collectionView.reloadData()

        Task {
            await (self.navigationController as? NCMainNavigationController)?.setNavigationLeftItems()
            await (self.navigationController as? NCMainNavigationController)?.setNavigationRightItems()
        }
    }

    func setTitleDate() {
        if let layoutAttributes = collectionView.collectionViewLayout.layoutAttributesForElements(in: collectionView.bounds) {
            let sortedAttributes = layoutAttributes.sorted { $0.frame.minY < $1.frame.minY || ($0.frame.minY == $1.frame.minY && $0.frame.minX < $1.frame.minX) }

            if let firstAttribute = sortedAttributes.first, let metadata = dataSource.getMetadata(indexPath: firstAttribute.indexPath) {
                titleDate?.text = utility.getTitleFromDate(metadata.date)
                return
            }
        }

        titleDate?.text = ""
    }

    func setElements() {
        let highTextTitle = titleDate.frame.height
        let isOver = self.collectionView.contentOffset.y + highTextTitle <= -view.safeAreaInsets.top && self.collectionView.contentOffset.y != -view.safeAreaInsets.top

        if isOver || dataSource.metadatas.isEmpty {
            UIView.animate(withDuration: 0.3) { [self] in
                gradientView.isHidden = true
                titleDate?.textColor = NCBrandColor.shared.textColor
                activityIndicator.color = NCBrandColor.shared.textColor

                if #unavailable(iOS 26.0) {
                    (self.navigationController as? NCMediaNavigationController)?.updateRightBarButtonsTint(to: NCBrandColor.shared.textColor)
                }
            }
        } else {
            UIView.animate(withDuration: 0.3) { [self] in
                gradientView.isHidden = false
                titleDate?.textColor = .white
                activityIndicator.color = .white

                if #unavailable(iOS 26.0) {
                    (self.navigationController as? NCMediaNavigationController)?.updateRightBarButtonsTint(to: .white)
                }
            }
        }
        setTitleDate()
    }
}

extension NCMedia: NCMediaSelectTabBarDelegate {
    func selectAll() {
        fileSelect = dataSource.metadatas.map { $0.ocId }
        tabBarSelect.selectCount = fileSelect.count
        collectionView.reloadData()
    }

    /// PrivateCloud: one-tap "download" = save the selected photos/videos to the iOS photo
    /// library (camera roll). Queue each as a background download tagged with `selectorSaveAlbum`;
    /// the transfer pipeline downloads the full-resolution file and the transfer delegate writes
    /// it to the camera roll on completion. This makes "share" and "download" clearly separate.
    func download() {
        Task {
            let ocIds = self.fileSelect.map { $0 }
            let metadatas = await database.getMetadatasFromOcIdsAsync(ocIds)
            let mediaToSave = metadatas.filter { $0.isImage || $0.isVideo }

            setEditMode(false)

            guard !mediaToSave.isEmpty else {
                return
            }
            await showInfoBanner(windowScene: windowScene, text: "_download_in_progress_")

            for metadata in mediaToSave {
                _ = await database.setMetadataSessionInWaitDownloadAsync(
                    ocId: metadata.ocId,
                    session: networking.sessionDownloadBackground,
                    selector: global.selectorSaveAlbum,
                    sceneIdentifier: controller?.sceneIdentifier)
            }
        }
    }

    func move() {
        Task {
            let ocIds = self.fileSelect.map { $0 }
            let metadatas = await database.getMetadatasFromOcIdsAsync(ocIds)

            setEditMode(false)

            NCSelectOpen.shared.openView(items: metadatas, controller: self.controller)
        }
    }

    func share() {
        Task {
            let ocIds = self.fileSelect.map { $0 }
            let metadatas = await database.getMetadatasFromOcIdsAsync(ocIds)

            setEditMode(false)
            await NCCreate().createActivityViewController(
                selectedMetadata: metadatas,
                controller: self.controller,
                sender: nil)
        }
    }

    func delete() {
        let ocIds = self.fileSelect.map { $0 }
        var alertStyle = UIAlertController.Style.actionSheet

        if UIDevice.current.userInterfaceIdiom == .pad {
            alertStyle = .alert
        }

        if !ocIds.isEmpty {
            let alertController = UIAlertController(title: nil, message: nil, preferredStyle: alertStyle)

            alertController.addAction(UIAlertAction(title: NSLocalizedString("_delete_selected_photos_", comment: ""), style: .destructive) { (_: UIAlertAction) in
                self.isEditMode = false
                Task {
                    await (self.navigationController as? NCMediaNavigationController)?.setNavigationRightItems()

                    for ocId in ocIds {
                        await self.deleteImage(with: ocId)
                    }
                    self.collectionViewReloadData()
                }
            })

            alertController.addAction(UIAlertAction(title: NSLocalizedString("_cancel_", comment: ""), style: .cancel) { (_: UIAlertAction) in })

            present(alertController, animated: true, completion: { })
        }
    }

    func deleteImage(with ocId: String) async {
        guard let metadata = await self.database.getMetadataFromOcIdAsync(ocId) else {
            await MainActor.run {
                self.dataSource.removeMetadata([ocId])
                self.collectionViewReloadData()
            }
            return
        }

        let resultsDeleteFileOrFolder = await NextcloudKit.shared.deleteFileOrFolderAsync(serverUrlFileName: metadata.serverUrlFileName, account: metadata.account) { task in
            Task {
                let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: metadata.account,
                                                                                            path: metadata.serverUrlFileName,
                                                                                            name: "deleteFileOrFolder")
                await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
            }
        }

        guard resultsDeleteFileOrFolder.error == .success || resultsDeleteFileOrFolder.error.errorCode == self.global.errorResourceNotFound else {
            return
        }

        await self.database.deleteMetadataAsync(id: ocId)

        await MainActor.run {
            if let indexPath = self.dataSource.indexPath(forOcId: ocId) {
                self.collectionView.performBatchUpdates {
                    self.dataSource.removeMetadata([ocId])
                    self.collectionView.deleteItems(at: [indexPath])
                }
            } else {
                self.dataSource.removeMetadata([ocId])
                self.collectionViewReloadData()
            }
        }
    }
}

// MARK: - Long-press paint selection (PrivateCloud)

extension NCMedia: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    /// Long-press a photo to enter selection, then drag a finger across the grid to select many
    /// items in one stroke. Scrolling is suspended while painting so the drag doesn't scroll.
    @objc func handleLongPressSelect(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard collectionView.indexPathForItem(at: gesture.location(in: collectionView)) != nil else {
                return
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if !isEditMode {
                setEditMode(true)
            }
            collectionView.isScrollEnabled = false
            lastTouchInView = gesture.location(in: view)
            paintSelect(at: gesture.location(in: collectionView))
        case .changed:
            lastTouchInView = gesture.location(in: view)
            paintSelect(at: gesture.location(in: collectionView))
            updateAutoScroll()
        default:
            stopAutoScroll()
            collectionView.isScrollEnabled = true
        }
    }

    // PrivateCloud: drag-to-select auto-scrolls when the finger nears the top/bottom edge, so you can
    // keep selecting beyond the visible tiles (Apple Photos style) without lifting the finger.
    private func updateAutoScroll() {
        let edge: CGFloat = 90
        let maxSpeed: CGFloat = 18
        let frame = collectionView.frame
        let y = lastTouchInView.y
        if y < frame.minY + edge {
            autoScrollSpeed = -maxSpeed * min(1, (frame.minY + edge - y) / edge)
            startAutoScroll()
        } else if y > frame.maxY - edge {
            autoScrollSpeed = maxSpeed * min(1, (y - (frame.maxY - edge)) / edge)
            startAutoScroll()
        } else {
            stopAutoScroll()
        }
    }

    private func startAutoScroll() {
        guard autoScrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
        link.add(to: .main, forMode: .common)
        autoScrollLink = link
    }

    func stopAutoScroll() {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
        autoScrollSpeed = 0
    }

    @objc private func autoScrollTick() {
        let minOffset = -collectionView.adjustedContentInset.top
        let maxOffset = max(minOffset, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let newY = min(maxOffset, max(minOffset, collectionView.contentOffset.y + autoScrollSpeed))
        guard newY != collectionView.contentOffset.y else { return }
        collectionView.contentOffset.y = newY
        paintSelect(at: collectionView.convert(lastTouchInView, from: view))
    }

    private func paintSelect(at point: CGPoint) {
        guard isEditMode,
              let indexPath = collectionView.indexPathForItem(at: point),
              let metadata = dataSource.getMetadata(indexPath: indexPath),
              !fileSelect.contains(metadata.ocId) else {
            return
        }
        fileSelect.append(metadata.ocId)
        tabBarSelect.selectCount = fileSelect.count
        if let cell = collectionView.cellForItem(at: indexPath) as? NCMediaCell {
            cell.selected(true, color: NCBrandColor.shared.getElement(account: session.account))
        }
    }
}

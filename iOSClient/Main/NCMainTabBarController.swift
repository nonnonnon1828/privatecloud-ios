// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import SwiftUI
import NextcloudKit

struct NavigationCollectionViewCommon {
    var serverUrl: String
    var navigationController: UINavigationController?
    var viewController: NCCollectionViewCommon
}

class NCMainTabBarController: UITabBarController {
    var sceneIdentifier: String = UUID().uuidString
    var account: String = "" {
        didSet {
            // NCImageCache.shared.controller = self
        }
    }
    var availableNotifications: Bool = false
    var documentPickerViewController: NCDocumentPickerViewController?
    let navigationCollectionViewCommon = ThreadSafeArray<NavigationCollectionViewCommon>()
    private var previousIndex: Int?
    private var checkUserDelaultErrorInProgress: Bool = false
    private var timerTask: Task<Void, Never>?
    private let global = NCGlobal.shared

    var window: UIWindow? {
        return SceneManager.shared.getWindow(controller: self)
    }

    var barHeightBottom: CGFloat {
        return tabBar.frame.height - tabBar.safeAreaInsets.bottom
    }

    var barHeightTop: CGFloat {
        return tabBar.frame.height - tabBar.safeAreaInsets.top
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self

        NCNetworking.shared.setupScene(sceneIdentifier: sceneIdentifier, controller: self)

        tabBar.tintColor = NCBrandColor.shared.getElement(account: account)

        // PrivateCloud: the "More" tab is removed; its only kept settings (appearance + clear cache)
        // live in the account menu now, leaving four simple tabs.
        configureTabBarItems()
        configureTabBarAppearance()
        setupTabSwipeGestures()

        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: self.global.notificationCenterChangeTheming), object: nil, queue: .main) { [weak self] notification in
            if let userInfo = notification.userInfo as? NSDictionary,
               let account = userInfo["account"] as? String,
               self?.account == account {
                self?.tabBar.tintColor = NCBrandColor.shared.getElement(account: account)
            }
        }

        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: self.global.notificationCenterCheckUserDelaultErrorDone), object: nil, queue: nil) { notification in
            if let userInfo = notification.userInfo,
               let account = userInfo["account"] as? String,
               let controller = userInfo["controller"] as? NCMainTabBarController,
               account == self.account,
               controller == self {
                self.checkUserDelaultErrorInProgress = false
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            self.timerTask?.cancel()
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            if !isAppInBackground {
                self.timerTask = Task { @MainActor [weak self] in
                    await self?.timerCheck()
                }
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        previousIndex = selectedIndex

        if NCBrandOptions.shared.enforce_passcode_lock && NCPreferences().passcode.isEmptyOrNil {
            let vc = UIHostingController(rootView: SetupPasscodeView(isLockActive: .constant(false), controller: self))
            vc.isModalInPresentation = true

            present(vc, animated: true)
        }
    }

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()

        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
    }

    // PrivateCloud: horizontal paging between the main tabs. On a clear horizontal drag or flick the
    // current screen is covered by a snapshot of itself, the tab is swapped underneath (so the raw
    // swap and any reload flash are hidden), then the new tab slides in while the snapshot slides out
    // — a clean paged transition with a light haptic. A direction lock (see gestureRecognizerShouldBegin)
    // only starts the pan for clearly horizontal drags so it is never confused with vertical scrolling.
    // Gated to a tab's root (not while selecting, drilled into a detail/viewer, or with something
    // presented). Tapping the tab bar always still works.
    private func setupTabSwipeGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTabPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    @objc private func handleTabPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let width = max(view.bounds.width, 1)
        let translationX = gesture.translation(in: view).x
        let velocityX = gesture.velocity(in: view).x
        guard abs(translationX) > width * 0.28 || abs(velocityX) > 600 else { return }
        changeTab(forward: translationX < 0)
    }

    private func changeTab(forward: Bool) {
        guard let count = viewControllers?.count, count > 0,
              let currentView = selectedViewController?.view else { return }
        let target = forward ? selectedIndex + 1 : selectedIndex - 1
        guard target >= 0, target < count, target != selectedIndex else { return }
        let width = view.bounds.width

        let snapshot = currentView.snapshotView(afterScreenUpdates: false)
        if let snapshot {
            snapshot.frame = currentView.frame
            view.insertSubview(snapshot, belowSubview: tabBar)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        selectedIndex = target

        guard let newView = selectedViewController?.view else {
            snapshot?.removeFromSuperview()
            return
        }
        newView.transform = CGAffineTransform(translationX: forward ? width : -width, y: 0)
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut, animations: {
            newView.transform = .identity
            snapshot?.transform = CGAffineTransform(translationX: forward ? -width : width, y: 0)
        }, completion: { _ in
            newView.transform = .identity
            snapshot?.removeFromSuperview()
        })
    }

    private func configureMoreController() {
        guard var controllers = viewControllers else { return }

        controllers.append(makeMoreNavigationController())
        viewControllers = controllers
    }

    private func makeMoreNavigationController() -> UIViewController {
        let moreView = NCMoreView(account: account, controller: self)
        let hostingController = UIHostingController(rootView: moreView)

        hostingController.navigationItem.title = NSLocalizedString("_more_", comment: "")

        let navigationController = NCMoreNavigationController(rootViewController: hostingController)

        navigationController.tabBarItem = UITabBarItem(
            title: NSLocalizedString("_more_", comment: ""),
            image: UIImage(systemName: "ellipsis.circle.fill"),
            selectedImage: UIImage(systemName: "ellipsis.circle.fill")
        )
        navigationController.tabBarItem.tag = 104

        return navigationController
    }

    private func configureTabBarItems() {
        configureTabBarItem(
            at: 0,
            title: "_home_",
            imageName: "folder.fill",
            tag: 100
        )

        configureTabBarItem(
            at: 1,
            title: "_favorites_",
            imageName: "star.fill",
            tag: 101
        )

        configureTabBarItem(
            at: 2,
            title: "_media_",
            imageName: "photo.fill",
            tag: 102
        )

        configureTabBarItem(
            at: 3,
            title: "_activity_",
            imageName: "bolt.fill",
            tag: 103
        )
    }

    private func configureTabBarItem(at index: Int, title: String, imageName: String, tag: Int) {
        guard let items = tabBar.items, items.indices.contains(index) else { return }

        let item = items[index]
        item.title = NSLocalizedString(title, comment: "")
        item.image = UIImage(systemName: imageName)
        item.selectedImage = item.image
        item.tag = tag
    }

    @MainActor
    private func timerCheck() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))

            guard isViewLoaded, view.window != nil else {
                continue
            }

            // Check error
            await NCNetworking.shared.checkServerError(account: self.account, controller: self)
        }
    }

    func currentViewController() -> UIViewController? {
        return (selectedViewController as? UINavigationController)?.topViewController
    }

    func currentNavigationController() -> UINavigationController? {
        return selectedViewController as? UINavigationController
    }

    func currentServerUrl() -> String {
        let session = NCSession.shared.getSession(account: account)
        var serverUrl = NCUtilityFileSystem().getHomeServer(session: session)
        let viewController = currentViewController()
        if let collectionViewCommon = viewController as? NCCollectionViewCommon {
            if !collectionViewCommon.serverUrl.isEmpty {
                serverUrl = collectionViewCommon.serverUrl
            }
        }
        return serverUrl
    }

    func hide() {
        if #available(iOS 18.0, *) {
            setTabBarHidden(true, animated: true)
        } else {
            tabBar.isHidden = true
        }
    }

    func show() {
        if #available(iOS 18.0, *) {
            setTabBarHidden(false, animated: true)
        } else {
            tabBar.isHidden = false
        }
    }
}

extension NCMainTabBarController: UITabBarControllerDelegate {
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        if previousIndex == tabBarController.selectedIndex {
            scrollToTop(viewController: viewController)
        }
        previousIndex = tabBarController.selectedIndex
    }

    private func scrollToTop(viewController: UIViewController) {
        guard let navigationController = viewController as? UINavigationController,
              let topViewController = navigationController.topViewController else { return }

        if let scrollView = topViewController.view.subviews.compactMap({ $0 as? UIScrollView }).first {
            scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: true)
        }
    }
}

extension NCMainTabBarController: UIGestureRecognizerDelegate {
    /// Allow the tab swipe only at a tab's root grid: not while something is presented, not when
    /// drilled into a detail/viewer (pushed), and not in selection mode (drag-to-select conflicts).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Direction lock: only begin for a clearly horizontal drag, so vertical scrolling is never
        // taken for a tab change (this is what keeps the two gestures from being confused).
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: view)
            if abs(velocity.x) < abs(velocity.y) * 1.25 {
                return false
            }
        }
        if presentedViewController != nil {
            return false
        }
        guard let navigationController = selectedViewController as? UINavigationController else {
            return true
        }
        if navigationController.viewControllers.count > 1 {
            return false
        }
        if let common = navigationController.topViewController as? NCCollectionViewCommon, common.isEditMode {
            return false
        }
        if let media = navigationController.topViewController as? NCMedia, media.isEditMode {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Let the tab pan begin alongside a scroll view's pan; the direction lock above keeps them on
        // separate axes (horizontal = tabs, vertical = scrolling), so they don't fight.
        return true
    }
}

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

    // PrivateCloud: interactive horizontal paging between the main tabs that tracks the finger using
    // the framework's OWN transition system (a UIPercentDrivenInteractiveTransition driving a custom
    // slide animator). Because UIKit performs the real from/to view swap, there is none of the black
    // flash or start-of-drag pop-in that manual view juggling caused. A direction lock (see
    // gestureRecognizerShouldBegin) only starts the pan for clearly horizontal drags so it is never
    // confused with vertical scrolling. Gated to a tab's root (not while selecting, drilled into a
    // detail/viewer, or with something presented). Tapping the tab bar always still works.
    private var tabInteraction: UIPercentDrivenInteractiveTransition?

    private func setupTabSwipeGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTabPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    @objc private func handleTabPan(_ gesture: UIPanGestureRecognizer) {
        let translationX = gesture.translation(in: view).x
        let width = max(view.bounds.width, 1)

        switch gesture.state {
        case .changed:
            if tabInteraction == nil {
                guard abs(translationX) > 1 else { return }
                let target = translationX < 0 ? selectedIndex + 1 : selectedIndex - 1
                guard let count = viewControllers?.count, target >= 0, target < count else { return }
                tabInteraction = UIPercentDrivenInteractiveTransition()
                selectedIndex = target
            }
            tabInteraction?.update(min(0.99, abs(translationX) / width))
        case .ended, .cancelled, .failed:
            guard let interaction = tabInteraction else { return }
            tabInteraction = nil
            let velocityX = gesture.velocity(in: view).x
            if abs(translationX) / width > 0.4 || abs(velocityX) > 700 {
                UISelectionFeedbackGenerator().selectionChanged()
                interaction.finish()
            } else {
                interaction.cancel()
            }
        default:
            break
        }
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

    func tabBarController(_ tabBarController: UITabBarController, animationControllerForTransitionFrom fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        // Only slide while an interactive tab pan is in progress; plain tab taps stay instant.
        guard tabInteraction != nil,
              let controllers = viewControllers,
              let fromIndex = controllers.firstIndex(of: fromVC),
              let toIndex = controllers.firstIndex(of: toVC) else {
            return nil
        }
        return NCTabSlideAnimator(forward: toIndex > fromIndex)
    }

    func tabBarController(_ tabBarController: UITabBarController, interactionControllerFor animationController: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        return tabInteraction
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

// PrivateCloud: slides the outgoing tab off one side while the incoming slides in from the other.
// Driven interactively by the tab pan's UIPercentDrivenInteractiveTransition.
final class NCTabSlideAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let forward: Bool

    init(forward: Bool) {
        self.forward = forward
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.3
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        guard let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        let width = container.bounds.width
        toView.frame = container.bounds
        toView.transform = CGAffineTransform(translationX: forward ? width : -width, y: 0)
        container.addSubview(toView)

        UIView.animate(withDuration: transitionDuration(using: transitionContext), delay: 0, options: .curveLinear, animations: {
            toView.transform = .identity
            fromView.transform = CGAffineTransform(translationX: self.forward ? -width : width, y: 0)
        }, completion: { _ in
            // Reset both transforms regardless of finish/cancel: on cancel UIKit removes toView from
            // the container but leaves the transform on it, which would show that tab off-screen the
            // next time it is selected.
            fromView.transform = .identity
            toView.transform = .identity
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        })
    }
}

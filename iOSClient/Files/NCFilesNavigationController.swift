// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2025 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import SwiftUI
import NextcloudKit

class NCFilesNavigationController: NCMainNavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: NCGlobal.shared.notificationCenterReloadAvatar), object: nil, queue: nil) { notification in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.collectionViewCommon?.showTipAccounts()
            }
            guard let userInfo = notification.userInfo as NSDictionary?,
                  let error = userInfo["error"] as? NKError,
                  error.errorCode != self.global.errorNotModified
            else {
                return
            }

            Task {
                await self.setNavigationLeftItems()
            }
        }
    }

    // MARK: - Right

    override func createOptionMenu() async -> UIMenu? {
        guard let collectionViewCommon,
              let items = await NCContextMenuNavigation().viewMenuOption(
                collectionViewCommon: collectionViewCommon,
                mainNavigationController: self,
                session: self.session)
        else {
            return nil
        }

        if collectionViewCommon.serverUrl == utilityFileSystem.getHomeServer(session: session) {
            let fileSettings = UIMenu(title: "", options: .displayInline, children: [items.personalFilesOnly, items.favoriteOnTop, items.directoryOnTop, items.hiddenFiles])
            var children: [UIMenuElement] = [items.showDescription]
            if let showRecommendedFiles = items.showRecommendedFiles {
                children.insert(showRecommendedFiles, at: 0)
            }
            let additionalSettings = UIMenu(title: "", options: .displayInline, children: children)

            return UIMenu(children: [items.select, items.viewStyleSubmenu, items.sortSubmenu, fileSettings, additionalSettings])
        } else {
            let fileSettings = UIMenu(title: "", options: .displayInline, children: [items.favoriteOnTop, items.directoryOnTop, items.hiddenFiles, items.showDescription])
            let additionalSettings = UIMenu(title: "", options: .displayInline, children: [items.showDescription])

            return UIMenu(children: [items.select, items.viewStyleSubmenu, items.sortSubmenu, fileSettings, additionalSettings])
        }
    }

    // MARK: - Left

    override func setNavigationLeftItems() async {
        guard let tableAccount = database.getTableAccount(predicate: NSPredicate(format: "account == %@", self.session.account))
        else {
            self.collectionViewCommon?.navigationItem.leftBarButtonItems = nil
            return
        }
        let image = utility.loadUserImage(for: tableAccount.user, displayName: tableAccount.displayName, urlBase: tableAccount.urlBase)

        class AccountSwitcherButton: UIButton {
            var onMenuOpened: (() -> Void)?

            override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
                super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
                onMenuOpened?()
            }
        }

        @MainActor
        func createLeftMenu() async -> UIMenu? {
            var childrenAccountSubmenu: [UIMenuElement] = []
            let accounts = await database.getAllAccountOrderAliasAsync()
            guard !accounts.isEmpty,
                  let controller = collectionViewCommon?.controller
            else {
                return nil
            }

            let accountActions: [UIAction] = accounts.map { account in
                let image = utility.loadUserImage(for: account.user, displayName: account.displayName, urlBase: account.urlBase)
                var name: String = ""
                var url: String = ""

                if account.alias.isEmpty {
                    name = account.displayName
                    url = (URL(string: account.urlBase)?.host ?? "")
                } else {
                    name = account.alias
                }

                let attributes: UIMenuElement.Attributes = account.account == controller.account ? [.disabled] : []
                let action = UIAction(title: name, image: image, attributes: attributes, state: account.account == controller.account ? .on : .off) { _ in
                    Task { @MainActor in
                        await NCAccount().changeAccount(account.account, userProfile: nil, controller: self.controller)
                        await self.collectionViewCommon?.setEditMode(false)
                    }
                }

                action.subtitle = url
                return action
            }

            let addAccountAction = UIAction(title: NSLocalizedString("_add_account_", comment: ""), image: utility.loadImage(named: "person.crop.circle.badge.plus", colors: NCBrandColor.shared.iconImageMultiColors)) { _ in
                if NCBrandOptions.shared.disable_intro {
                    if let viewController = UIStoryboard(name: "NCLogin", bundle: nil).instantiateViewController(withIdentifier: "NCLogin") as? NCLogin {
                        viewController.controller = self.controller
                        let navigationController = UINavigationController(rootViewController: viewController)
                        navigationController.modalPresentationStyle = .fullScreen
                        self.present(navigationController, animated: true)
                    }
                } else {
                    if let navigationController = UIStoryboard(name: "NCIntro", bundle: nil).instantiateInitialViewController() as? UINavigationController {
                        if let viewController = navigationController.topViewController as? NCIntroViewController {
                            viewController.controller = nil
                        }
                        navigationController.modalPresentationStyle = .fullScreen
                        self.present(navigationController, animated: true)
                    }
                }
            }

            let settingsAccountAction = UIAction(title: NSLocalizedString("_account_settings_", comment: ""), image: utility.loadImage(named: "gear", colors: [NCBrandColor.shared.iconImageColor])) { _ in
                let accountSettingsModel = NCAccountSettingsModel(controller: self.controller, delegate: self.collectionViewCommon)
                let accountSettingsView = NCAccountSettingsView(model: accountSettingsModel)
                let accountSettingsController = UIHostingController(rootView: accountSettingsView)

                self.present(accountSettingsController, animated: true, completion: nil)
            }

            if !NCBrandOptions.shared.disable_multiaccount {
                childrenAccountSubmenu.append(addAccountAction)
            }
            childrenAccountSubmenu.append(settingsAccountAction)

            let addAccountSubmenu = UIMenu(title: "", options: .displayInline, children: childrenAccountSubmenu)

            // PrivateCloud: appearance (light/dark/system) + clear cache, moved here from the
            // removed "More" tab so the only settings worth keeping stay one tap away.
            let prefs = NCPreferences()
            let isAuto = prefs.appearanceAutomatic
            let currentStyle = prefs.appearanceInterfaceStyle
            let autoAction = UIAction(title: NSLocalizedString("_use_system_style_", comment: ""),
                                      image: utility.loadImage(named: "circle.lefthalf.filled", colors: [NCBrandColor.shared.iconImageColor]),
                                      state: isAuto ? .on : .off) { _ in
                NCPreferences().appearanceAutomatic = true
                self.applyInterfaceStyle(.unspecified)
            }
            let lightAction = UIAction(title: NSLocalizedString("_light_", comment: ""),
                                       image: utility.loadImage(named: "sun.max", colors: [NCBrandColor.shared.iconImageColor]),
                                       state: (!isAuto && currentStyle == .light) ? .on : .off) { _ in
                let pref = NCPreferences(); pref.appearanceAutomatic = false; pref.appearanceInterfaceStyle = .light
                self.applyInterfaceStyle(.light)
            }
            let darkAction = UIAction(title: NSLocalizedString("_dark_", comment: ""),
                                      image: utility.loadImage(named: "moon.fill", colors: [NCBrandColor.shared.iconImageColor]),
                                      state: (!isAuto && currentStyle == .dark) ? .on : .off) { _ in
                let pref = NCPreferences(); pref.appearanceAutomatic = false; pref.appearanceInterfaceStyle = .dark
                self.applyInterfaceStyle(.dark)
            }
            let appearanceSubmenu = UIMenu(title: NSLocalizedString("_appearance_", comment: ""),
                                           image: utility.loadImage(named: "circle.lefthalf.filled", colors: [NCBrandColor.shared.iconImageColor]),
                                           children: [autoAction, lightAction, darkAction])
            let clearCacheAction = UIAction(title: NSLocalizedString("_clear_cache_", comment: ""),
                                            image: utility.loadImage(named: "trash", colors: [NCBrandColor.shared.iconImageColor])) { _ in
                self.confirmClearCache()
            }
            let appSettingsSubmenu = UIMenu(title: "", options: .displayInline, children: [appearanceSubmenu, clearCacheAction])

            let menu = UIMenu(children: accountActions + [addAccountSubmenu, appSettingsSubmenu])

            return menu
        }

        if self.topViewController != self.viewControllers.first {
            return
        }

        if self.collectionViewCommon?.navigationItem.leftBarButtonItems == nil {
            let accountButton = AccountSwitcherButton(type: .custom)

            accountButton.accessibilityIdentifier = "accountSwitcher"
            accountButton.setImage(image, for: .normal)
            accountButton.semanticContentAttribute = .forceLeftToRight
            accountButton.sizeToFit()

            accountButton.menu = await createLeftMenu()
            accountButton.showsMenuAsPrimaryAction = true

            accountButton.onMenuOpened = {
                self.collectionViewCommon?.dismissTip()
            }

            self.collectionViewCommon?.navigationItem.setLeftBarButtonItems([UIBarButtonItem(customView: accountButton)], animated: true)

        } else {

            let accountButton = self.collectionViewCommon?.navigationItem.leftBarButtonItems?.first?.customView as? UIButton
            accountButton?.setImage(image, for: .normal)
            accountButton?.menu = await createLeftMenu()
        }
    }

    // MARK: - PrivateCloud account-menu helpers (appearance + clear cache, ex-"More" tab)

    private func applyInterfaceStyle(_ style: UIUserInterfaceStyle) {
        for windowScene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    private func confirmClearCache() {
        let alert = UIAlertController(title: NSLocalizedString("_clear_cache_", comment: ""), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("_cancel_", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("_clear_cache_", comment: ""), style: .destructive) { _ in
            Task { @MainActor in
                NCActivityIndicator.shared.startActivity(backgroundView: self.controller?.view, style: .large, blurEffect: true)
                NCNetworking.shared.cancelAllTask()
                try? await Task.sleep(for: .seconds(1))
                NCNetworking.shared.removeServerErrorAccount(self.session.account)
                NCManageDatabase.shared.clearDBCache()
                let ufs = NCUtilityFileSystem()
                ufs.removeGroupDirectoryProviderStorage()
                ufs.removeGroupLibraryDirectory()
                ufs.removeDocumentsDirectory()
                ufs.removeTemporaryDirectory()
                ufs.createDirectoryStandard()
                await NCService().startRequestServicesServer(account: self.session.account, controller: self.controller)
                NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterClearCache)
                NCActivityIndicator.shared.stop()
            }
        })
        self.present(alert, animated: true)
    }
}

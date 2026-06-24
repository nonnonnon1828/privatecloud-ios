// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2025 Marino Faggiana
// SPDX-FileCopyrightText: 2025 Milen Pivchev
// SPDX-License-Identifier: GPL-3.0-or-later

import UniformTypeIdentifiers
import UIKit
import NextcloudKit
import SwiftUI
import SafariServices
import LucidBanner

class NCLogin: UIViewController, UITextFieldDelegate, NCLoginQRCodeDelegate {
    @IBOutlet weak var imageBrand: UIImageView!
    @IBOutlet weak var imageBrandConstraintY: NSLayoutConstraint!
    @IBOutlet weak var baseUrlTextField: UITextField!
    @IBOutlet weak var loginAddressDetail: UILabel!
    @IBOutlet weak var loginButton: UIButton!
    @IBOutlet weak var qrCode: UIButton!
    @IBOutlet weak var certificate: UIButton!
    @IBOutlet weak var enforceServersButton: UIButton!
    @IBOutlet weak var enforceServersDropdownImage: UIImageView!

    private let appDelegate = (UIApplication.shared.delegate as? AppDelegate)!
    private var textColor: UIColor = .white
    private var textColorOpponent: UIColor = .black
    private var activeTextfieldDiff: CGFloat = 0
    private var activeTextField = UITextField()

    private var shareAccounts: [NKShareAccounts.DataAccounts]?

    /// Controller
    var controller: NCMainTabBarController?

    /// The URL that will show up on the URL field when this screen appears
    var urlBase = ""

    // Used for MDM
    var configServerUrl: String?
    var configUsername: String?
    var configPassword: String?
    var configAppPassword: String?

    private var QRCodeCheck: Bool = false
    private var activeLoginProvider: NCLoginProvider?

    // LucidBanner
    var banner: LucidBanner?

    // PrivateCloud minimal login UI
    private var statusLabel: UILabel?
    private var primaryLoginButton: UIButton?

    // MARK: - View Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Text color
        if NCBrandColor.shared.customer.isTooLight() {
            textColor = .black
            textColorOpponent = .white
        } else if NCBrandColor.shared.customer.isTooDark() {
            textColor = .white
            textColorOpponent = .black
        } else {
            textColor = .white
            textColorOpponent = .black
        }

        // Image Brand
        imageBrand.image = UIImage(named: "logo")

        // Url
        baseUrlTextField.textColor = textColor
        baseUrlTextField.tintColor = textColor
        baseUrlTextField.layer.cornerRadius = 10
        baseUrlTextField.layer.borderWidth = 1
        baseUrlTextField.layer.borderColor = textColor.cgColor
        baseUrlTextField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 15, height: baseUrlTextField.frame.height))
        baseUrlTextField.leftViewMode = .always
        baseUrlTextField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 35, height: baseUrlTextField.frame.height))
        baseUrlTextField.rightViewMode = .always
        baseUrlTextField.attributedPlaceholder = NSAttributedString(string: NSLocalizedString("_login_url_", comment: ""), attributes: [NSAttributedString.Key.foregroundColor: textColor.withAlphaComponent(0.5)])
        baseUrlTextField.delegate = self

        baseUrlTextField.isEnabled = !NCBrandOptions.shared.disable_request_login_url

        // Login button
        loginAddressDetail.textColor = textColor
        loginAddressDetail.text = String.localizedStringWithFormat(NSLocalizedString("_login_address_detail_", comment: ""), NCBrandOptions.shared.brand)

        // QR code button
        qrCode.tintColor = NCBrandColor.shared.customer.isTooLight() ? .black : .white

        // brand
        if NCBrandOptions.shared.disable_request_login_url {
            baseUrlTextField.isEnabled = false
            baseUrlTextField.isUserInteractionEnabled = false
            baseUrlTextField.alpha = 0.5
            urlBase = NCBrandOptions.shared.loginBaseUrl
        }

        // certificate
        certificate.setImage(UIImage(named: "certificate")?.image(color: textColor, size: 100), for: .normal)
        certificate.isHidden = true
        certificate.isEnabled = false

        // navigation
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.shadowColor = .clear
        navBarAppearance.shadowImage = UIImage()
        navBarAppearance.titleTextAttributes = [.foregroundColor: textColor]
        navBarAppearance.largeTitleTextAttributes = [.foregroundColor: textColor]
        self.navigationController?.navigationBar.standardAppearance = navBarAppearance
        self.navigationController?.view.backgroundColor = NCBrandColor.shared.customer
        self.navigationController?.navigationBar.tintColor = textColor

        if let dirGroupApps = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NCBrandOptions.shared.capabilitiesGroupApps) {
            // Nextcloud update share accounts
            Task {
                await NCAccount().updateAppsShareAccounts()
            }
            // Nextcloud get share accounts
            if let shareAccounts = NKShareAccounts().getShareAccount(at: dirGroupApps, application: UIApplication.shared) {
                var accountTemp = [NKShareAccounts.DataAccounts]()
                for shareAccount in shareAccounts {
                    if NCManageDatabase.shared.getTableAccount(predicate: NSPredicate(format: "urlBase == %@ AND user == %@", shareAccount.url, shareAccount.user)) == nil {
                        accountTemp.append(shareAccount)
                    }
                }
                if !accountTemp.isEmpty {
                    self.shareAccounts = accountTemp
                    let image = NCUtility().loadImage(named: "person.badge.plus")
                    let navigationItem = UIBarButtonItem(image: image, style: .plain, target: self, action: #selector(openShareAccountsViewController(_:)))
                    navigationItem.tintColor = textColor
                    self.navigationItem.rightBarButtonItem = navigationItem
                }
            }
        }

        self.navigationController?.navigationBar.setValue(true, forKey: "hidesShadow")
        view.backgroundColor = NCBrandColor.shared.customer

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)

        handleLoginWithAppConfig()
        baseUrlTextField.text = urlBase

        enforceServersButton.setTitle(NSLocalizedString("_select_server_", comment: ""), for: .normal)

        let enforceServers = NCBrandOptions.shared.enforce_servers

        if enforceServers.count == 1 {
            baseUrlTextField.isHidden = true
            enforceServersDropdownImage.isHidden = true
            enforceServersButton.isHidden = false
            enforceServersButton.isUserInteractionEnabled = false
            enforceServersButton.setTitle(enforceServers[0].name, for: .normal)
            baseUrlTextField.text = enforceServers[0].url
        } else if !enforceServers.isEmpty {
            baseUrlTextField.isHidden = true
            enforceServersDropdownImage.isHidden = false
            enforceServersButton.isHidden = false

            let actions = enforceServers.map { server in
                UIAction(title: server.name, handler: { [self] _ in
                    enforceServersButton.setTitle(server.name, for: .normal)
                    baseUrlTextField.text = server.url
                })
            }

            enforceServersButton.layer.cornerRadius = 10
            enforceServersButton.menu = .init(title: NSLocalizedString("_servers_", comment: ""), children: actions)
            enforceServersButton.showsMenuAsPrimaryAction = true
            enforceServersButton.configuration?.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.systemFont(ofSize: 13)
                return outgoing
            }
        }

        setupPrivateCloudUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if !NCManageDatabase.shared.getAllTableAccount().isEmpty,
           self.navigationController?.viewControllers.count ?? 0 == 1 {
            let navigationItemCancel = UIBarButtonItem(image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(actionCancel(_:)))
            navigationItemCancel.tintColor = textColor
            navigationItem.leftBarButtonItem = navigationItemCancel
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if self.shareAccounts != nil,
           let windowScene = view.window?.windowScene {
            let title = String(format: NSLocalizedString("_apps_nextcloud_detect_", comment: ""), NCBrandOptions.shared.brand)
            let subtitle = String(format: NSLocalizedString("_add_existing_account_", comment: ""), NCBrandOptions.shared.brand)
            self.banner = LucidBannerRegistry.shared.banner(for: windowScene)

            showAlertActionBanner(lucidBanner: banner,
                                  windowScene: windowScene,
                                  title: title,
                                  subtitle: subtitle) {
                self.openShareAccountsViewController(nil)
            }
        }

        if NCBrandOptions.shared.enforce_servers.count == 1,
           NCManageDatabase.shared.getAllTableAccount().isEmpty {
            runMTLSPrecheck()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        self.banner?.dismiss()
    }

    private func handleLoginWithAppConfig() {
        let accountCount = NCManageDatabase.shared.getAccounts()?.count ?? 0

        // load AppConfig
        if (NCBrandOptions.shared.disable_multiaccount == false) || (NCBrandOptions.shared.disable_multiaccount == true && accountCount == 0) {
            if let configurationManaged = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed"), NCBrandOptions.shared.use_AppConfig {
                if let serverUrl = configurationManaged[NCGlobal.shared.configuration_serverUrl] as? String {
                    self.configServerUrl = serverUrl
                }
                if let username = configurationManaged[NCGlobal.shared.configuration_username] as? String, !username.isEmpty, username.lowercased() != "username" {
                    self.configUsername = username
                }
                if let password = configurationManaged[NCGlobal.shared.configuration_password] as? String, !password.isEmpty, password.lowercased() != "password" {
                    self.configPassword = password
                }
                if let apppassword = configurationManaged[NCGlobal.shared.configuration_apppassword] as? String, !apppassword.isEmpty, apppassword.lowercased() != "apppassword" {
                    self.configAppPassword = apppassword
                }
            }
        }

        // AppConfig
        if let url = configServerUrl {
            Task {
                if let user = self.configUsername, let password = configAppPassword {
                    await createAccount(urlBase: url, user: user, password: password)
                    return
                } else if let user = self.configUsername, let password = configPassword {
                    await getAppPassword(urlBase: url, user: user, password: password)
                    return
                } else {
                    urlBase = url
                }
            }
        }
    }

    // MARK: - TextField

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        actionButtonLogin(self)
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        self.activeTextField = textField
    }

    // MARK: - Keyboard notification

    @objc internal func keyboardWillShow(_ notification: Notification?) {
        activeTextfieldDiff = 0
        if let info = notification?.userInfo, let centerObject = self.activeTextField.superview?.convert(self.activeTextField.center, to: nil) {

            let frameEndUserInfoKey = UIResponder.keyboardFrameEndUserInfoKey
            if let keyboardFrame = info[frameEndUserInfoKey] as? CGRect {
                let diff = keyboardFrame.origin.y - centerObject.y - self.activeTextField.frame.height
                if diff < 0 {
                    activeTextfieldDiff = diff
                    imageBrandConstraintY.constant += diff
                }
            }
        }
    }

    @objc func keyboardWillHide(_ notification: Notification) {
        imageBrandConstraintY.constant -= activeTextfieldDiff
    }

    // MARK: - Action

    @objc func actionCancel(_ sender: Any?) {
        dismiss(animated: true) { }
    }

    @IBAction func actionButtonLogin(_ sender: Any) {
        primaryLoginButton?.isEnabled = false
        primaryLoginButton?.alpha = 0.6
        primaryLoginButton?.setTitle(NSLocalizedString("_pc_opening_", value: "接続中…", comment: ""), for: .normal)
        login()
    }

    @IBAction func actionQRCode(_ sender: Any) {
        let qrCode = NCLoginQRCode(delegate: self)
        qrCode.scan()
    }

    @IBAction func actionCertificate(_ sender: Any) {

    }

    // MARK: - Share accounts View Controller

    @objc func openShareAccountsViewController(_ sender: Any?) {
        if let shareAccounts = self.shareAccounts, let vc = UIStoryboard(name: "NCShareAccounts", bundle: nil).instantiateInitialViewController() as? NCShareAccounts {
            vc.accounts = shareAccounts
            vc.enableTimerProgress = false
            vc.dismissDidEnterBackground = false
            vc.delegate = self

            let screenHeighMax = UIScreen.main.bounds.height - (UIScreen.main.bounds.height / 5)
            let numberCell = shareAccounts.count
            let height = min(CGFloat(numberCell * Int(vc.heightCell) + 45), screenHeighMax)
            let popup = NCPopupViewController(contentController: vc, popupWidth: 300, popupHeight: height + 20)

            self.present(popup, animated: true)
        }
    }

    // MARK: - PrivateCloud minimal UI

    private func setupPrivateCloudUI() {
        // Hide the stock Nextcloud login chrome
        imageBrand.isHidden = true
        baseUrlTextField.isHidden = true
        loginAddressDetail.isHidden = true
        loginButton.isHidden = true
        qrCode.isHidden = true
        certificate.isHidden = true
        enforceServersButton.isHidden = true
        enforceServersDropdownImage.isHidden = true

        view.backgroundColor = .systemBackground
        navigationController?.view.backgroundColor = .systemBackground
        navigationController?.navigationBar.tintColor = .label

        let logoView = UIImageView(image: UIImage(named: "logo"))
        logoView.contentMode = .scaleAspectFit
        logoView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        logoView.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let titleLabel = UILabel()
        titleLabel.text = "やまなかネット PrivateCloud"
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.7

        let status = UILabel()
        status.text = NSLocalizedString("_pc_checking_connection_", value: "接続を確認中…", comment: "")
        status.font = .systemFont(ofSize: 14)
        status.textColor = .secondaryLabel
        status.textAlignment = .center
        status.numberOfLines = 0
        self.statusLabel = status

        let button = UIButton(type: .system)
        button.setTitle(NSLocalizedString("_pc_login_", value: "ログイン", comment: ""), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = NCBrandColor.shared.customer
        button.layer.cornerRadius = 10
        button.isEnabled = false
        button.alpha = 0.4
        button.addTarget(self, action: #selector(actionButtonLogin(_:)), for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        self.primaryLoginButton = button

        let hint = UILabel()
        hint.text = NSLocalizedString("_pc_opens_in_browser_", value: "外部ブラウザで開きます", comment: "")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabel
        hint.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [logoView, titleLabel, status, button, hint])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(10, after: logoView)
        stack.setCustomSpacing(30, after: titleLabel)
        stack.setCustomSpacing(8, after: button)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 280),
            button.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func runMTLSPrecheck() {
        guard let url = baseUrlTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return }
        statusLabel?.text = NSLocalizedString("_pc_checking_connection_", value: "接続を確認中…", comment: "")
        statusLabel?.textColor = .secondaryLabel
        primaryLoginButton?.isEnabled = false
        primaryLoginButton?.alpha = 0.4

        NextcloudKit.shared.getServerStatus(serverUrl: url) { [weak self] _, serverInfoResult in
            DispatchQueue.main.async {
                guard let self else { return }
                switch serverInfoResult {
                case .success:
                    if let host = URL(string: url)?.host {
                        NCNetworking.shared.writeCertificate(host: host)
                    }
                    self.statusLabel?.text = NSLocalizedString("_pc_connection_ok_", value: "✓ 接続を確認しました", comment: "")
                    self.statusLabel?.textColor = .systemGreen
                    self.primaryLoginButton?.isEnabled = true
                    self.primaryLoginButton?.alpha = 1.0
                case .failure(let error):
                    self.statusLabel?.text = String(format: NSLocalizedString("_pc_connection_failed_", value: "接続を確認できません\n%@", comment: ""), error.errorDescription)
                    self.statusLabel?.textColor = .systemRed
                    self.primaryLoginButton?.isEnabled = false
                    self.primaryLoginButton?.alpha = 0.4
                }
            }
        }
    }

    // MARK: - Login

    private func login() {
        guard var url = baseUrlTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        if url.isEmpty { return }

        // Check whether baseUrl contain protocol. If not add https:// by default.
        if url.hasPrefix("https") == false && url.hasPrefix("http") == false {
            url = "https://" + url
        }
        self.baseUrlTextField.text = url
        isUrlValid(url: url)
    }

    func isUrlValid(url: String, user: String? = nil) {
        loginButton.isEnabled = false
        loginButton.hideButtonAndShowSpinner()

        NextcloudKit.shared.getServerStatus(serverUrl: url) { [self] _, serverInfoResult in
            switch serverInfoResult {
            case .success:
                if let host = URL(string: url)?.host {
                    NCNetworking.shared.writeCertificate(host: host)
                }
                let loginOptions = NKRequestOptions(customUserAgent: userAgent)
                NextcloudKit.shared.getLoginFlowV2(serverUrl: url, options: loginOptions) { [self] token, endpoint, login, _, error in
                    // Login Flow V2
                    if error == .success, let token, let endpoint, let login {
                        nkLog(debug: "Successfully received login flow information.")
                        let loginProvider = NCLoginProvider()
                        loginProvider.initialURLString = login
                        loginProvider.delegate = self
                        loginProvider.controller = self.controller
                        loginProvider.presentingViewController = self
                        loginProvider.startPolling(loginFlowV2Token: token, loginFlowV2Endpoint: endpoint, loginFlowV2Login: login)
                        loginProvider.startAuthentication()
                        self.activeLoginProvider = loginProvider
                    }
                }
            case .failure(let error):
                loginButton.hideSpinnerAndShowButton()
                loginButton.isEnabled = true
                MDMCertificate.reportDiagPublic("login_error_code_\(error.errorCode)_desc_\(error.errorDescription)")
                let nsErr = error.error as NSError
                if let under = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
                    MDMCertificate.reportDiagPublic("login_underlying_domain_\(under.domain)_code_\(under.code)")
                    if let sslErr = under.userInfo["_kCFStreamErrorCodeKey"] as? Int {
                        MDMCertificate.reportDiagPublic("login_ssl_error_\(sslErr)")
                    }
                }

                if error.errorCode == NSURLErrorServerCertificateUntrusted {
                    let alertController = UIAlertController(title: NSLocalizedString("_ssl_certificate_untrusted_", comment: ""), message: NSLocalizedString("_connect_server_anyway_", comment: ""), preferredStyle: .alert)
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("_yes_", comment: ""), style: .default, handler: { _ in
                        if let host = URL(string: url)?.host {
                            NCNetworking.shared.writeCertificate(host: host)
                        }
                    }))
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("_no_", comment: ""), style: .default, handler: { _ in }))
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("_certificate_details_", comment: ""), style: .default, handler: { _ in
                        if let navigationController = UIStoryboard(name: "NCViewCertificateDetails", bundle: nil).instantiateInitialViewController() as? UINavigationController,
                           let viewController = navigationController.topViewController as? NCViewCertificateDetails {
                            if let host = URL(string: url)?.host {
                                viewController.host = host
                            }
                            self.present(navigationController, animated: true)
                        }
                    }))
                    self.present(alertController, animated: true)
                } else {
                    let alertController = UIAlertController(title: NSLocalizedString("_connection_error_", comment: ""), message: error.errorDescription, preferredStyle: .alert)
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default, handler: { _ in }))
                    self.present(alertController, animated: true, completion: { })
                }
            }
        }
    }

    // MARK: - QRCode

    func dismissQRCode(_ value: String?, metadataType: String?) {
        guard let value, !QRCodeCheck else {
            return
        }
        QRCodeCheck = true

        Task { @MainActor in
            let protocolLogin = NCBrandOptions.shared.webLoginAutenticationProtocol + "login/"
            let protocolLoginOneTime = NCBrandOptions.shared.webLoginAutenticationProtocol + "onetime-login/"
            var parameters: String = ""

            if value.hasPrefix(protocolLoginOneTime) {
                parameters = value.replacingOccurrences(of: protocolLoginOneTime, with: "")
            } else if value.hasPrefix(protocolLogin) {
                parameters = value.replacingOccurrences(of: protocolLogin, with: "")
            } else {
                QRCodeCheck = false
                return
            }

            guard parameters.contains("user:"),
                  parameters.contains("password:"),
                  parameters.contains("server:") else {
                QRCodeCheck = false
                return
            }
            let parametersArray = parameters.components(separatedBy: "&")
            let user = parametersArray[0].replacingOccurrences(of: "user:", with: "")
            let password = parametersArray[1].replacingOccurrences(of: "password:", with: "")
            let server = parametersArray[2].replacingOccurrences(of: "server:", with: "")

            if value.hasPrefix(protocolLoginOneTime) {
                let results = await NextcloudKit.shared.getAppPasswordOnetimeAsync(url: server, user: user, onetimeToken: password)
                if results.error == .success, let token = results.token {
                    await createAccount(urlBase: server, user: user, password: token)
                } else {
                    let windowScene = SceneManager.shared.getWindowScene(controller: self.controller)
                    await showErrorBanner(windowScene: windowScene, text: results.error.errorDescription, errorCode: results.error.errorCode)
                    dismiss(animated: true, completion: nil)
                }
            } else if value.hasPrefix(protocolLogin) {
                await self.createAccount(urlBase: server, user: user, password: password)
            }
        }
    }

    private func getAppPassword(urlBase: String, user: String, password: String) async {
        let results = await NextcloudKit.shared.getAppPasswordAsync(url: urlBase, user: user, password: password)

        if results.error == .success, let password = results.token {
            await self.createAccount(urlBase: urlBase, user: user, password: password)
        } else {
            let windowScene = SceneManager.shared.getWindowScene(controller: self.controller)
            await showErrorBanner(windowScene: windowScene, text: results.error.errorDescription, errorCode: results.error.errorCode)
            dismiss(animated: true, completion: nil)
        }
    }

    @MainActor
    private func createAccount(urlBase: String, user: String, password: String) async {
        if self.controller == nil {
            self.controller = UIApplication.shared.mainAppWindow?.rootViewController as? NCMainTabBarController
        }

        if let host = URL(string: urlBase)?.host {
            NCNetworking.shared.writeCertificate(host: host)
        }

        await NCAccount().createAccount(viewController: self, urlBase: urlBase, user: user, password: password, controller: self.controller)
    }
}

// MARK: - NCShareAccountsDelegate

extension NCLogin: NCShareAccountsDelegate {
    func selected(url: String, user: String) {
        isUrlValid(url: url, user: user)
    }
}

// MARK: - UIDocumentPickerDelegate

// MARK: - NCLoginProviderDelegate

extension NCLogin: NCLoginProviderDelegate {
    func onBack() {
        loginButton.isEnabled = true
        loginButton.hideSpinnerAndShowButton()
        activeLoginProvider?.cancel()
        activeLoginProvider = nil
        primaryLoginButton?.isEnabled = true
        primaryLoginButton?.alpha = 1.0
        primaryLoginButton?.setTitle(NSLocalizedString("_pc_login_", value: "ログイン", comment: ""), for: .normal)
    }
}

// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2019 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

#if !EXTENSION_FILE_PROVIDER_EXTENSION
import OpenSSL
import Queuer
import SwiftUI
#endif

import UIKit
import NextcloudKit
import Alamofire

// MARK: - In-app SCEP enrollment for mTLS (replaces MDM cert which iOS apps cannot access)
enum MDMCertificate {
    private static let keyTag = "com.ymnknet.privatecloud.mtls.key"
    private static let certLabel = "com.ymnknet.privatecloud.mtls"
    private static let enrollURL = "https://mdm.ymnk-private-connect.com/api/v1/app/enroll/ios"
    private static let enrollChallenge = "KL462l8SxKUg8/O8bOpXQflLbSe0Kj08eKh0kV322OA="

    private static let enrollOnce: Void = {
        guard findIdentityInKeychain() == nil else { return }
        performEnrollment()
    }()

    static func ensureEnrolled() { _ = enrollOnce }

    static func findIdentityCredential() -> URLCredential? {
        _ = enrollOnce
        guard let identity = findIdentityInKeychain() else { return nil }
        return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    }

    // MARK: - Keychain lookup

    private static func findIdentityInKeychain() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: certLabel,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return (result as! SecIdentity) // swiftlint:disable:this force_cast
    }

    // MARK: - Enrollment

    private static func performEnrollment() {
        guard let privateKey = generateKeyPair(),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            NSLog("[SCEP] key generation failed")
            return
        }

        guard let csrDER = buildCSR(privateKey: privateKey, publicKey: publicKey) else {
            NSLog("[SCEP] CSR build failed")
            return
        }

        let csrPEM = toPEM(csrDER, type: "CERTIFICATE REQUEST")
        guard let certPEM = sendCSR(csrPEM: csrPEM) else {
            NSLog("[SCEP] enrollment request failed")
            deleteKey()
            return
        }

        guard importCert(pemString: certPEM) else {
            NSLog("[SCEP] cert import failed")
            deleteKey()
            return
        }
        NSLog("[SCEP] enrollment success")
    }

    // MARK: - Key generation (EC P-256, Keychain-backed)

    private static func generateKeyPair() -> SecKey? {
        deleteKey()
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrLabel as String: certLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            NSLog("[SCEP] SecKeyCreateRandomKey: \(error!.takeRetainedValue())")
            return nil
        }
        return key
    }

    private static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - CSR builder (PKCS#10, EC P-256)

    private static func buildCSR(privateKey: SecKey, publicKey: SecKey) -> Data? {
        guard let pubKeyData = exportPublicKey(publicKey) else { return nil }
        let cn = UIDevice.current.identifierForVendor?.uuidString ?? "PrivateCloud-iOS"
        let tbs = buildCertRequestInfo(cn: cn, ou: "client-auth", publicKey: pubKeyData)

        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) else {
            NSLog("[SCEP] sign failed: \(error!.takeRetainedValue())")
            return nil
        }

        return derSequence([
            tbs,
            derSequence([derOIDBytes(oidECDSASHA256)]),
            derBitString(sig as Data)
        ])
    }

    private static func exportPublicKey(_ key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) else { return nil }
        return data as Data
    }

    private static func buildCertRequestInfo(cn: String, ou: String, publicKey: Data) -> Data {
        let subject = derSequence([
            derSet([derSequence([derOIDBytes(oidCN), derUTF8String(cn)])]),
            derSet([derSequence([derOIDBytes(oidOU), derUTF8String(ou)])])
        ])

        let spki = derSequence([
            derSequence([derOIDBytes(oidECPublicKey), derOIDBytes(oidPrime256v1)]),
            derBitString(publicKey)
        ])

        return derSequence([
            derInteger(0),
            subject,
            spki,
            derContext0(Data())
        ])
    }

    // MARK: - Network

    private static func sendCSR(csrPEM: String) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var resultPEM: String?

        guard let url = URL(string: enrollURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: String] = ["csr_pem": csrPEM, "challenge": enrollChallenge]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        session.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pem = json["cert_pem"] as? String, !pem.isEmpty else {
                if let error = error { NSLog("[SCEP] request error: \(error)") }
                if let http = response as? HTTPURLResponse { NSLog("[SCEP] HTTP \(http.statusCode)") }
                return
            }
            resultPEM = pem
        }.resume()

        sem.wait()
        return resultPEM
    }

    // MARK: - Certificate import

    private static func importCert(pemString: String) -> Bool {
        guard let certData = fromPEM(pemString) else { return false }
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            NSLog("[SCEP] SecCertificateCreateWithData failed")
            return false
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: certLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            NSLog("[SCEP] SecItemAdd cert: \(status)")
            return false
        }
        return true
    }

    // MARK: - PEM helpers

    private static func toPEM(_ der: Data, type: String) -> String {
        let b64 = der.base64EncodedString(options: .lineLength64Characters)
        return "-----BEGIN \(type)-----\n\(b64)\n-----END \(type)-----\n"
    }

    private static func fromPEM(_ pem: String) -> Data? {
        let lines = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        return Data(base64Encoded: lines.joined())
    }

    // MARK: - ASN.1 DER encoding

    private static let oidCN: [UInt8]          = [0x55, 0x04, 0x03]
    private static let oidOU: [UInt8]          = [0x55, 0x04, 0x0B]
    private static let oidECPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let oidPrime256v1: [UInt8]  = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let oidECDSASHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]

    private static func derTag(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let len = content.count
        if len < 128 {
            out.append(UInt8(len))
        } else if len < 256 {
            out.append(contentsOf: [0x81, UInt8(len)])
        } else {
            out.append(contentsOf: [0x82, UInt8(len >> 8), UInt8(len & 0xFF)])
        }
        out.append(content)
        return out
    }

    private static func derSequence(_ items: [Data]) -> Data {
        var content = Data()
        items.forEach { content.append($0) }
        return derTag(0x30, content)
    }

    private static func derSet(_ items: [Data]) -> Data {
        var content = Data()
        items.forEach { content.append($0) }
        return derTag(0x31, content)
    }

    private static func derInteger(_ value: Int) -> Data {
        return derTag(0x02, Data([UInt8(value)]))
    }

    private static func derUTF8String(_ s: String) -> Data {
        return derTag(0x0C, Data(s.utf8))
    }

    private static func derBitString(_ content: Data) -> Data {
        var bs = Data([0x00])
        bs.append(content)
        return derTag(0x03, bs)
    }

    private static func derOIDBytes(_ oid: [UInt8]) -> Data {
        return derTag(0x06, Data(oid))
    }

    private static func derContext0(_ content: Data) -> Data {
        return derTag(0xA0, content)
    }
}

protocol NCTransferDelegate: AnyObject {
    var sceneIdentifier: String { get }

    func transferChange(status: String,
                        account: String,
                        fileName: String,
                        serverUrl: String,
                        selector: String?,
                        ocId: String,
                        destination: String?,
                        error: NKError)
    func transferReloadDataSource(serverUrl: String?, requestData: Bool, status: Int?)
    func transferReloadData(serverUrl: String?)
    func transferProgressDidUpdate(progress: Float,
                                   totalBytes: Int64,
                                   totalBytesExpected: Int64,
                                   fileName: String,
                                   serverUrl: String)
}

class NCNetworking: @unchecked Sendable, NextcloudKitDelegate {
    static let shared = NCNetworking()

    struct FileNameServerUrl: Hashable {
        var fileName: String
        var serverUrl: String
    }

    let sessionDownload = NextcloudKit.shared.nkCommonInstance.identifierSessionDownload
    let sessionDownloadBackground = NextcloudKit.shared.nkCommonInstance.identifierSessionDownloadBackground
    let sessionDownloadBackgroundExt = NextcloudKit.shared.nkCommonInstance.identifierSessionDownloadBackgroundExt

    let sessionUpload = NextcloudKit.shared.nkCommonInstance.identifierSessionUpload
    let sessionUploadBackground = NextcloudKit.shared.nkCommonInstance.identifierSessionUploadBackground
    let sessionUploadBackgroundWWan = NextcloudKit.shared.nkCommonInstance.identifierSessionUploadBackgroundWWan
    let sessionUploadBackgroundExt = NextcloudKit.shared.nkCommonInstance.identifierSessionUploadBackgroundExt

    let utilityFileSystem = NCUtilityFileSystem()
    let global = NCGlobal.shared
    let backgroundSession = NKBackground(nkCommonInstance: NextcloudKit.shared.nkCommonInstance)
    let nkComm = NextcloudKit.shared.nkCommonInstance

    var lastReachability: Bool = true
    var networkReachability: NKTypeReachability?

    internal var sceneIdentifier: String = ""
    internal var controller: UIViewController?

    var isOffline: Bool {
        return networkReachability == NKTypeReachability.notReachable || networkReachability == NKTypeReachability.unknown
    }
    var isOnline: Bool {
        return networkReachability == NKTypeReachability.reachableEthernetOrWiFi || networkReachability == NKTypeReachability.reachableCellular
    }

    // Capabilities
    var capabilities = ThreadSafeDictionary<String, NKCapabilities.Capabilities>()

    // Actors
    let transferDispatcher = NCTransferDelegateDispatcher()
    let networkingTasks = NetworkingTasks()
    let progressQuantizer = ProgressQuantizer()

#if !EXTENSION
    let metadataTranfersSuccess = NCMetadataTranfersSuccess()

    // OPERATIONQUEUE
    let downloadThumbnailQueue = Queuer(name: "downloadThumbnailQueue", maxConcurrentOperationCount: 10, qualityOfService: .default)
    let downloadThumbnailActivityQueue = Queuer(name: "downloadThumbnailActivityQueue", maxConcurrentOperationCount: 10, qualityOfService: .default)
    let downloadThumbnailTrashQueue = Queuer(name: "downloadThumbnailTrashQueue", maxConcurrentOperationCount: 10, qualityOfService: .default)
    let saveLivePhotoQueue = Queuer(name: "saveLivePhotoQueue", maxConcurrentOperationCount: 1, qualityOfService: .default)
    let downloadAvatarQueue = Queuer(name: "downloadAvatarQueue", maxConcurrentOperationCount: 10, qualityOfService: .default)
#endif

    // MARK: - init

    init() { }

    func setupScene(sceneIdentifier: String, controller: UIViewController?) {
        self.sceneIdentifier = sceneIdentifier
        self.controller = controller
    }

    func authenticationChallenge(_ session: URLSession,
                                 didReceive challenge: URLAuthenticationChallenge,
                                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            if let credential = MDMCertificate.findIdentityCredential() {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }
#if EXTENSION
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
#else
        self.checkTrustedChallenge(session, didReceive: challenge, completionHandler: completionHandler)
#endif
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
#if !EXTENSION
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate, let completionHandler = appDelegate.backgroundSessionCompletionHandler {
            nkLog(debug: "Called urlSessionDidFinishEvents for Background URLSession")
            appDelegate.backgroundSessionCompletionHandler = nil
            completionHandler()
        }
#endif
    }

    func request<Value>(_ request: DataRequest, didParseResponse response: AFDataResponse<Value>) { }

    // MARK: - Pinning check

    public func checkTrustedChallenge(_ session: URLSession,
                                      didReceive challenge: URLAuthenticationChallenge,
                                      completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
#if EXTENSION
        DispatchQueue.main.async {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
#else
        let protectionSpace = challenge.protectionSpace
        let directoryCertificate = utilityFileSystem.directoryCertificates
        let host = protectionSpace.host
        let certificateSavedPath = (directoryCertificate as NSString).appendingPathComponent("\(host).der")

        guard let trust = protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        DispatchQueue.global(qos: .utility).async {
            self.saveX509Certificate(certificate, host: host, directoryCertificate: directoryCertificate)

            let isServerTrusted = SecTrustEvaluateWithError(trust, nil)
            let certificateCopyData = SecCertificateCopyData(certificate)
            let data = CFDataGetBytePtr(certificateCopyData)
            let size = CFDataGetLength(certificateCopyData)
            let certificateData = Data(bytes: data!, count: size)

            let tmpPath = (directoryCertificate as NSString).appendingPathComponent("\(host).tmp")
            try? certificateData.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)

            var isTrusted = false

            if isServerTrusted {
                isTrusted = true
            } else if let savedData = try? Data(contentsOf: URL(fileURLWithPath: certificateSavedPath)),
                      savedData == certificateData {
                isTrusted = true
            }

            DispatchQueue.main.async {
                if isTrusted {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    (UIApplication.shared.delegate as? AppDelegate)?.trustCertificateError(host: host)
                    completionHandler(.performDefaultHandling, nil)
                }
            }
        }
        #endif
    }

#if !EXTENSION
    func writeCertificate(host: String) {
        let directoryCertificate = utilityFileSystem.directoryCertificates
        let certificateAtPath = directoryCertificate + "/" + host + ".tmp"
        let certificateToPath = directoryCertificate + "/" + host + ".der"

        if !utilityFileSystem.copyFile(atPath: certificateAtPath, toPath: certificateToPath) {
            nkLog(error: "Write certificare error")
        }
    }

    func saveX509Certificate(_ certificate: SecCertificate, host: String, directoryCertificate: String) {
        let certNamePathTXT = directoryCertificate + "/" + host + ".txt"
        let data: CFData = SecCertificateCopyData(certificate)
        let mem = BIO_new_mem_buf(CFDataGetBytePtr(data), Int32(CFDataGetLength(data)))
        let x509cert = d2i_X509_bio(mem, nil)

        if x509cert == nil {
            nkLog(error: "OpenSSL couldn't parse X509 Certificate")
        } else {
            // save details
            if FileManager.default.fileExists(atPath: certNamePathTXT) {
                do {
                    try FileManager.default.removeItem(atPath: certNamePathTXT)
                } catch { }
            }
            let fileCertInfo = fopen(certNamePathTXT, "w")
            if fileCertInfo != nil {
                let output = BIO_new_fp(fileCertInfo, BIO_NOCLOSE)
                X509_print_ex(output, x509cert, UInt(XN_FLAG_COMPAT), UInt(X509_FLAG_COMPAT))
                BIO_free(output)
            }
            fclose(fileCertInfo)
            X509_free(x509cert)
        }

        BIO_free(mem)
    }

#endif

#if !EXTENSION
    @inline(__always)
    func isInBackground() -> Bool {
       return isAppInBackground
    }
#else
    @inline(__always)
    func isInBackground() -> Bool {
        return false
    }
#endif
}

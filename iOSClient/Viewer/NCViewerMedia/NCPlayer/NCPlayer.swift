// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2021 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit
import UIKit
import MobileVLCKit
import AVFoundation
import UniformTypeIdentifiers

class NCPlayer: NSObject, VLCMediaDelegate {
    internal var url: URL?
    internal var player = VLCMediaPlayer()
    internal var dialogProvider: VLCDialogProvider?
    internal var metadata: tableMetadata
    internal var singleTapGestureRecognizer: UITapGestureRecognizer?
    internal var activityIndicator: UIActivityIndicatorView
    internal let database = NCManageDatabase.shared
    internal var width: Int?
    internal var height: Int?
    internal var length: Int?
    internal var pauseAfterPlay: Bool = false

    internal weak var playerToolBar: NCPlayerToolBar?
    internal weak var viewerMediaPage: NCViewerMediaPage?

    weak var imageVideoContainer: UIImageView?

    internal var counterSeconds: Double = 0

    // MARK: - View Life Cycle

    init(imageVideoContainer: UIImageView, playerToolBar: NCPlayerToolBar?, metadata: tableMetadata, viewerMediaPage: NCViewerMediaPage?) {
        self.imageVideoContainer = imageVideoContainer
        self.playerToolBar = playerToolBar
        self.metadata = metadata
        self.viewerMediaPage = viewerMediaPage

        self.activityIndicator = UIActivityIndicatorView(style: .large)
        self.activityIndicator.color = .white
        self.activityIndicator.hidesWhenStopped = true
        self.activityIndicator.translatesAutoresizingMaskIntoConstraints = false

        if let viewerMediaPage = viewerMediaPage {
            viewerMediaPage.view.addSubview(activityIndicator)
            NSLayoutConstraint.activate([
                activityIndicator.centerXAnchor.constraint(equalTo: viewerMediaPage.view.centerXAnchor),
                activityIndicator.centerYAnchor.constraint(equalTo: viewerMediaPage.view.centerYAnchor)
            ])
        }

        super.init()
    }

    deinit {
        player.stop()
        print("deinit NCPlayer with ocId \(metadata.ocId)")
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterPlayerStoppedPlaying)
    }

    func openAVPlayer(url: URL, autoplay: Bool = false) {
        var position: Float = 0
        let userAgent = userAgent

        self.url = url
        self.singleTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(didSingleTapWith(gestureRecognizer:)))

        print("Playing URL: \(url)")
        let media = VLCMedia(url: url)

        media.parse(options: url.isFileURL ? .fetchLocal : .fetchNetwork)

        player.media = media
        player.delegate = self

        dialogProvider = VLCDialogProvider(library: VLCLibrary.shared(), customUI: true)
        dialogProvider?.customRenderer = self

        player.media?.addOption(":http-user-agent=\(userAgent)")

        if let result = self.database.getVideo(metadata: metadata),
           let resultPosition = result.position {
            position = resultPosition
        }

        if metadata.isVideo {
            player.drawable = imageVideoContainer
            if let view = player.drawable as? UIView, let singleTapGestureRecognizer = singleTapGestureRecognizer {
                view.isUserInteractionEnabled = true
                view.addGestureRecognizer(singleTapGestureRecognizer)
            }
        }

        player.play()
        player.position = position

        if autoplay {
            pauseAfterPlay = false
        } else {
            pauseAfterPlay = true
        }

        playerToolBar?.setBarPlayer(position: position, ncplayer: self, metadata: metadata, viewerMediaPage: viewerMediaPage)

        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func restartAVPlayer(position: Float, pauseAfterPlay: Bool) {
        if let url = self.url, !player.isPlaying {

            player.media = VLCMedia(url: url)
            player.position = position
            playerToolBar?.setBarPlayer(position: position)
            viewerMediaPage?.changeScreenMode(mode: .normal)
            self.pauseAfterPlay = pauseAfterPlay
            player.play()

            if metadata.isVideo {
                if position == 0 {
                    imageVideoContainer?.image = NCUtility().getImage(ocId: metadata.ocId, etag: metadata.etag, ext: NCGlobal.shared.previewExt1024, userId: metadata.userId, urlBase: metadata.urlBase)
                } else {
                    imageVideoContainer?.image = nil
                }
            }
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    @objc func didSingleTapWith(gestureRecognizer: UITapGestureRecognizer) {
        changeScreenMode()
    }

    func changeScreenMode() {
        guard let viewerMediaPage = viewerMediaPage else { return }

        if viewerMediaScreenMode == .full {
            viewerMediaPage.changeScreenMode(mode: .normal)
        } else {
            viewerMediaPage.changeScreenMode(mode: .full)
        }
    }

    // MARK: - NotificationCenter

    @objc func applicationDidEnterBackground(_ notification: NSNotification) {
        if metadata.isVideo {
            playerPause()
        }
    }

    // MARK: -

    func isPlaying() -> Bool {
        return player.isPlaying
    }

    func playerPlay() {
        playerToolBar?.playbackSliderEvent = .began

        if let result = self.database.getVideo(metadata: metadata), let position = result.position {
            player.position = position
            playerToolBar?.playbackSliderEvent = .moved
        }

        player.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.playerToolBar?.playbackSliderEvent = .ended
        }
    }

    @objc func playerStop() {
        savePosition()
        player.stop()
    }

    @objc func playerPause() {
        savePosition()
        player.pause()
    }

    func playerPosition(_ position: Float) {
        self.database.addVideo(metadata: metadata, position: position)
        player.position = position
    }

    func savePosition() {
        guard metadata.isVideo, isPlaying() else { return }
        self.database.addVideo(metadata: metadata, position: player.position)
    }

    func jumpForward(_ seconds: Int32) {
        player.play()
        player.jumpForward(seconds)
    }

    func jumpBackward(_ seconds: Int32) {
        player.play()
        player.jumpBackward(seconds)
    }
}

extension NCPlayer: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {

        if player.state == .buffering && player.isPlaying {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        switch player.state {
        case .stopped:
            playerToolBar?.showPlayButton()

            NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterPlayerStoppedPlaying)

            print("Player mode: STOPPED")
        case .opening:
            print("Player mode: OPENING")
        case .buffering:
            print("Player mode: BUFFERING")
        case .ended:
            self.database.addVideo(metadata: self.metadata, position: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let playRepeat = self.playerToolBar?.playRepeat {
                    self.restartAVPlayer(position: 0, pauseAfterPlay: !playRepeat)
                }
            }
            playerToolBar?.showPlayButton()
            print("Player mode: ENDED")
        case .error:
            print("Player mode: ERROR")
        case .playing:
            guard let playerToolBar = playerToolBar else { return }
            if playerToolBar.playerButtonView.isHidden {
                playerToolBar.playerButtonView.isHidden = false
                viewerMediaPage?.changeScreenMode(mode: .normal)
            }
            if pauseAfterPlay {
                player.pause()
                pauseAfterPlay = false
                self.viewerMediaPage?.updateCommandCenter(ncplayer: self, title: metadata.fileNameView)
            } else {
                playerToolBar.showPauseButton()
                // Set track audio/subtitle
                let data = self.database.getVideo(metadata: metadata)
                if let currentAudioTrackIndex = data?.currentAudioTrackIndex {
                    player.currentAudioTrackIndex = Int32(currentAudioTrackIndex)
                }
                if let currentVideoSubTitleIndex = data?.currentVideoSubTitleIndex {
                    player.currentVideoSubTitleIndex = Int32(currentVideoSubTitleIndex)
                }
            }
            let size = player.videoSize
            if let mediaLength = player.media?.length.intValue {
                self.length = Int(mediaLength)
            }
            self.width = Int(size.width)
            self.height = Int(size.height)
            playerToolBar.updatePlaybackPosition()
            playerToolBar.updateTopToolBar(videoSubTitlesIndexes: player.videoSubTitlesIndexes, audioTrackIndexes: player.audioTrackIndexes)
            self.database.addVideo(metadata: metadata, width: self.width, height: self.height, length: self.length)

            NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterPlayerIsPlaying)

            print("Player mode: PLAYING")
        case .paused:
            NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterPlayerStoppedPlaying)

            playerToolBar?.showPlayButton()
            print("Player mode: PAUSED")
        default: break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        activityIndicator.stopAnimating()
        playerToolBar?.updatePlaybackPosition()
    }
}

extension NCPlayer: VLCMediaThumbnailerDelegate {
    func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) { }
    func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) { }
}

extension NCPlayer: VLCCustomDialogRendererProtocol {
    func showError(withTitle error: String, message: String) {
        let alert = UIAlertController(title: error, message: message, preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default, handler: { _ in
            self.playerToolBar?.removeFromSuperview()
            self.viewerMediaPage?.navigationController?.popViewController(animated: true)
        }))

        self.viewerMediaPage?.present(alert, animated: true)
    }

    func showLogin(withTitle title: String, message: String, defaultUsername username: String?, askingForStorage: Bool, withReference reference: NSValue) {
        // UIAlertController other states...
    }

    func showQuestion(withTitle title: String, message: String, type questionType: VLCDialogQuestionType, cancel cancelString: String?, action1String: String?, action2String: String?, withReference reference: NSValue) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        if let action1String = action1String {
            alert.addAction(UIAlertAction(title: action1String, style: .default, handler: { _ in
                self.dialogProvider?.postAction(1, forDialogReference: reference)
            }))
        }
        if let action2String = action2String {
            alert.addAction(UIAlertAction(title: action2String, style: .default, handler: { _ in
                self.dialogProvider?.postAction(2, forDialogReference: reference)
            }))
        }
        if let cancelString = cancelString {
            alert.addAction(UIAlertAction(title: cancelString, style: .cancel, handler: { _ in
                self.dialogProvider?.postAction(3, forDialogReference: reference)
            }))
        }

        self.viewerMediaPage?.present(alert, animated: true)
    }

    func showProgress(withTitle title: String, message: String, isIndeterminate: Bool, position: Float, cancel cancelString: String?, withReference reference: NSValue) {
        // UIAlertController other states...
    }

    func updateProgress(withReference reference: NSValue, message: String?, position: Float) {
        // UIAlertController other states...
    }

    func cancelDialog(withReference reference: NSValue) {
        // UIAlertController other states...
    }
}

// MARK: - PrivateCloud: AVPlayer streaming over the app's mTLS session
//
// AVPlayer / AVURLAsset use their own networking and cannot present the device client
// certificate that the Cloudflare mTLS gate requires, so a plain remote URL never loads.
// This resource-loader delegate intercepts AVPlayer's byte-range reads and serves them with
// HTTP Range requests issued from a URLSession that DOES present the client certificate (and
// the WebDAV basic auth), streaming the bytes back to AVPlayer. The byte-range bridge gives
// instant start and seeking without downloading the whole file.
final class NCVideoStreamLoader: NSObject {
    static let scheme = "ncvideostream"

    private let realURL: URL
    private let authHeader: String
    private var pendingRequests: [Int: AVAssetResourceLoadingRequest] = [:]
    private var pendingTasks: [Int: URLSessionDataTask] = [:]
    private let lock = NSLock()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(realURL: URL, user: String, password: String) {
        self.realURL = realURL
        self.authHeader = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        super.init()
    }

    /// Build an AVURLAsset whose network loads are routed through this loader. Keep the returned
    /// loader alive for the asset's lifetime (the asset holds only a weak delegate reference).
    static func makeAsset(realURL: URL, user: String, password: String) -> (asset: AVURLAsset, loader: NCVideoStreamLoader)? {
        guard var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        guard let customURL = components.url else { return nil }
        let loader = NCVideoStreamLoader(realURL: realURL, user: user, password: password)
        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "com.ymnknet.privatecloud.videostream"))
        return (asset, loader)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }
}

extension NCVideoStreamLoader: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        var request = URLRequest(url: realURL)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let dataRequest = loadingRequest.dataRequest {
            if dataRequest.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(dataRequest.requestedOffset)-", forHTTPHeaderField: "Range")
            } else {
                let end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
                request.setValue("bytes=\(dataRequest.requestedOffset)-\(end)", forHTTPHeaderField: "Range")
            }
        } else {
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        lock.lock()
        pendingRequests[task.taskIdentifier] = loadingRequest
        pendingTasks[task.taskIdentifier] = task
        lock.unlock()
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        let identifier = pendingRequests.first { $0.value === loadingRequest }?.key
        let task = identifier.flatMap { pendingTasks[$0] }
        if let identifier {
            pendingRequests[identifier] = nil
            pendingTasks[identifier] = nil
        }
        lock.unlock()
        task?.cancel()
    }
}

extension NCVideoStreamLoader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            completionHandler(.useCredential, MDMCertificate.findIdentityCredential())
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let loadingRequest = pendingRequests[dataTask.taskIdentifier]; lock.unlock()
        if let info = loadingRequest?.contentInformationRequest, let http = response as? HTTPURLResponse {
            var total = response.expectedContentLength
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = contentRange.lastIndex(of: "/"),
               let parsed = Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
                total = parsed
            }
            info.contentLength = total
            if let mime = http.value(forHTTPHeaderField: "Content-Type")?
                .components(separatedBy: ";").first?
                .trimmingCharacters(in: .whitespaces),
               let uti = UTType(mimeType: mime) {
                info.contentType = uti.identifier
            }
            info.isByteRangeAccessSupported = http.statusCode == 206
                || (http.value(forHTTPHeaderField: "Accept-Ranges")?.range(of: "bytes", options: .caseInsensitive) != nil)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let loadingRequest = pendingRequests[dataTask.taskIdentifier]; lock.unlock()
        loadingRequest?.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let loadingRequest = pendingRequests[task.taskIdentifier]
        pendingRequests[task.taskIdentifier] = nil
        pendingTasks[task.taskIdentifier] = nil
        lock.unlock()
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            loadingRequest?.finishLoading(with: error)
        } else if error == nil {
            loadingRequest?.finishLoading()
        }
    }
}

// MARK: - PrivateCloud: short-video style AVPlayer view controller
//
// A self-contained fullscreen player built on a bare AVPlayerLayer so we own the gestures:
// hold to play at 2x, double-tap left/right to skip -/+ 10s, single tap to toggle controls,
// drag the scrubber to seek. If AVPlayer cannot decode the asset (unsupported codec) it calls
// `onUnsupported` so the caller can fall back to the VLC download path.
final class NCStreamPlayerViewController: UIViewController {
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let playerItem: AVPlayerItem
    private var streamLoader: NCVideoStreamLoader?
    private let videoTitle: String

    var onUnsupported: (() -> Void)?

    private let controlsView = UIView()
    private let bottomBar = UIView()
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let scrubber = UISlider()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let speedBadge = UILabel()
    private let skipBadge = UILabel()

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var controlsHideTimer: Timer?
    private var skipBadgeTimer: Timer?
    private var isScrubbing = false
    private var wasPlayingBeforeSpeedUp = false
    private var didFinishFallback = false

    init(asset: AVURLAsset, loader: NCVideoStreamLoader?, title: String) {
        self.playerItem = AVPlayerItem(asset: asset)
        self.streamLoader = loader
        self.videoTitle = title
        super.init(nibName: nil, bundle: nil)
        player.replaceCurrentItem(with: playerItem)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObservation?.invalidate()
        timeControlObservation?.invalidate()
        controlsHideTimer?.invalidate()
        skipBadgeTimer?.invalidate()
        player.pause()
        streamLoader?.invalidate()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)

        setupControls()
        setupGestures()
        observePlayer()

        spinner.startAnimating()
        player.play()
        scheduleControlsHide()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player.pause()
    }

    // MARK: Setup

    private func setupControls() {
        controlsView.frame = view.bounds
        controlsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controlsView)

        // dimming so controls stay legible over bright frames
        let dim = UIView()
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        dim.frame = controlsView.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controlsView.addSubview(dim)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        controlsView.addSubview(closeButton)

        titleLabel.text = videoTitle
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(titleLabel)

        playPauseButton.setImage(Self.controlSymbol("pause.fill"), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        controlsView.addSubview(playPauseButton)

        currentTimeLabel.text = "0:00"
        durationLabel.text = "0:00"
        for label in [currentTimeLabel, durationLabel] {
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        scrubber.minimumTrackTintColor = .white
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(bottomBar)
        bottomBar.addSubview(currentTimeLabel)
        bottomBar.addSubview(scrubber)
        bottomBar.addSubview(durationLabel)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        speedBadge.text = "2x  ▶▶"
        speedBadge.textColor = .white
        speedBadge.font = .systemFont(ofSize: 13, weight: .bold)
        speedBadge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        speedBadge.textAlignment = .center
        speedBadge.layer.cornerRadius = 6
        speedBadge.clipsToBounds = true
        speedBadge.isHidden = true
        speedBadge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(speedBadge)

        skipBadge.textColor = .white
        skipBadge.font = .systemFont(ofSize: 16, weight: .bold)
        skipBadge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        skipBadge.textAlignment = .center
        skipBadge.layer.cornerRadius = 22
        skipBadge.clipsToBounds = true
        skipBadge.isHidden = true
        skipBadge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(skipBadge)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),

            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            speedBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            speedBadge.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            speedBadge.widthAnchor.constraint(equalToConstant: 80),
            speedBadge.heightAnchor.constraint(equalToConstant: 28),

            skipBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            skipBadge.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            skipBadge.widthAnchor.constraint(equalToConstant: 88),
            skipBadge.heightAnchor.constraint(equalToConstant: 44),

            bottomBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            bottomBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            bottomBar.heightAnchor.constraint(equalToConstant: 34),

            currentTimeLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            currentTimeLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            durationLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            durationLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            scrubber.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 10),
            scrubber.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -10),
            scrubber.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor)
        ])
    }

    private func setupGestures() {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        let panDismiss = UIPanGestureRecognizer(target: self, action: #selector(handlePanDismiss(_:)))
        panDismiss.delegate = self
        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(panDismiss)
    }

    @objc private func handlePanDismiss(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            if translation.y > 0 {
                view.transform = CGAffineTransform(translationX: 0, y: translation.y)
                view.alpha = max(0.4, 1 - translation.y / 600)
            }
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: view).y
            if translation.y > 120 || velocity > 900 {
                player.pause()
                dismiss(animated: true)
            } else {
                UIView.animate(withDuration: 0.2) {
                    self.view.transform = .identity
                    self.view.alpha = 1
                }
            }
        default:
            break
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            self?.updateTime(current: time)
        }
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.handleStatus(item.status) }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async { self?.handleTimeControl(player.timeControlStatus) }
        }
    }

    // MARK: Player state

    private func handleStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            let seconds = playerItem.duration.seconds
            if seconds.isFinite, seconds > 0 {
                scrubber.maximumValue = Float(seconds)
                durationLabel.text = Self.formatTime(seconds)
            }
        case .failed:
            fallbackToDownload()
        default:
            break
        }
    }

    private func handleTimeControl(_ status: AVPlayer.TimeControlStatus) {
        if status == .waitingToPlayAtSpecifiedRate {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        if status == .paused {
            playPauseButton.setImage(Self.controlSymbol("play.fill"), for: .normal)
        } else {
            playPauseButton.setImage(Self.controlSymbol("pause.fill"), for: .normal)
        }
    }

    private func updateTime(current: CMTime) {
        guard !isScrubbing else { return }
        let seconds = current.seconds
        if seconds.isFinite {
            scrubber.value = Float(seconds)
            currentTimeLabel.text = Self.formatTime(seconds)
        }
    }

    private func fallbackToDownload() {
        guard !didFinishFallback else { return }
        didFinishFallback = true
        let handler = onUnsupported
        dismiss(animated: false) { handler?() }
    }

    // MARK: Actions

    @objc private func closeTapped() {
        player.pause()
        dismiss(animated: true)
    }

    @objc private func togglePlayPause() {
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
        scheduleControlsHide()
    }

    @objc private func scrubBegan() {
        isScrubbing = true
        controlsHideTimer?.invalidate()
    }

    @objc private func scrubChanged() {
        currentTimeLabel.text = Self.formatTime(Double(scrubber.value))
    }

    @objc private func scrubEnded() {
        player.seek(to: CMTime(seconds: Double(scrubber.value), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        isScrubbing = false
        scheduleControlsHide()
    }

    // MARK: Gestures

    @objc private func handleSingleTap() {
        setControlsHidden(controlsView.alpha > 0.5)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: view).x
        let forward = x > view.bounds.width / 2
        seek(by: forward ? 10 : -10)
        showSkipBadge(forward: forward)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            wasPlayingBeforeSpeedUp = player.timeControlStatus == .playing
            player.rate = 2.0
            speedBadge.isHidden = false
        case .ended, .cancelled, .failed:
            player.rate = wasPlayingBeforeSpeedUp ? 1.0 : 0.0
            speedBadge.isHidden = true
        default:
            break
        }
    }

    private func seek(by seconds: Double) {
        let current = player.currentTime().seconds
        var target = current + seconds
        let duration = playerItem.duration.seconds
        if duration.isFinite { target = min(target, duration) }
        target = max(0, target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Controls visibility

    private func setControlsHidden(_ hidden: Bool) {
        UIView.animate(withDuration: 0.2) { self.controlsView.alpha = hidden ? 0 : 1 }
        if !hidden { scheduleControlsHide() }
    }

    private func scheduleControlsHide() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            guard let self, self.player.timeControlStatus == .playing, !self.isScrubbing else { return }
            UIView.animate(withDuration: 0.2) { self.controlsView.alpha = 0 }
        }
    }

    private func showSkipBadge(forward: Bool) {
        skipBadge.text = forward ? "+10s ⏩" : "⏪ -10s"
        skipBadge.isHidden = false
        skipBadge.alpha = 1
        skipBadgeTimer?.invalidate()
        skipBadgeTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.2, animations: { self?.skipBadge.alpha = 0 }) { _ in
                self?.skipBadge.isHidden = true
            }
        }
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func controlSymbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular))
    }
}

extension NCStreamPlayerViewController: UIGestureRecognizerDelegate {
    // Only let the swipe-to-dismiss pan begin for primarily-vertical drags, so horizontal
    // scrubber drags (and the rest of the controls) are not hijacked.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }
}

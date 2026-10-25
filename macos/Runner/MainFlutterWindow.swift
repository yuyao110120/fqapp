import Cocoa
import FlutterMacOS
import MediaPlayer

/// macOS Now Playing + media key bridge for the Flutter desktop port.
///
/// The Windows port routes `fqapp/native_player` listening metadata into SMTC;
/// macOS has no SMTC, so the same Dart call is forwarded here over the
/// `fqapp/now_playing` method channel and published through
/// MPNowPlayingInfoCenter. Remote commands travel back to Dart as
/// `remoteAction` calls, which the desktop adapter turns into the same
/// `onNotificationAction` events the Android plugin emits.
final class NowPlayingBridge {
  private let channel: FlutterMethodChannel
  private var artworkTask: URLSessionDataTask?
  private var artworkURL: String = ""
  private var artwork: MPMediaItemArtwork?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "fqapp/now_playing",
      binaryMessenger: messenger
    )
    configureRemoteCommands()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in
      self?.sendAction("playPause")
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      self?.sendAction("playPause")
      return .success
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.sendAction("playPause")
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      self?.sendAction("next")
      return .success
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      self?.sendAction("prev")
      return .success
    }
    // The desktop adapter has no seek action on the Dart side yet.
    center.changePlaybackPositionCommand.isEnabled = false
    center.stopCommand.addTarget { [weak self] _ in
      self?.sendAction("stop")
      return .success
    }
    disableCommands()
  }

  private func disableCommands() {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = false
    center.pauseCommand.isEnabled = false
    center.togglePlayPauseCommand.isEnabled = false
    center.nextTrackCommand.isEnabled = false
    center.previousTrackCommand.isEnabled = false
    center.stopCommand.isEnabled = false
  }

  private func sendAction(_ action: String) {
    channel.invokeMethod("remoteAction", arguments: ["action": action])
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      update(args)
      result(nil)
    case "stop":
      stop()
      result(nil)
    case "debugTrigger":
      // Test-only: exercises the exact callback the media keys use, without
      // needing real hardware input. Never called by the shipped app.
      if let args = call.arguments as? [String: Any],
         let action = args["action"] as? String {
        sendAction(action)
      }
      result(nil)
    case "debug":
      let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      let center = MPRemoteCommandCenter.shared()
      result([
        "title": info[MPMediaItemPropertyTitle] ?? "",
        "artist": info[MPMediaItemPropertyArtist] ?? "",
        "duration": info[MPMediaItemPropertyPlaybackDuration] ?? 0,
        "elapsed": info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?? 0,
        "rate": info[MPNowPlayingInfoPropertyPlaybackRate] ?? 0,
        "hasArtwork": (info[MPMediaItemPropertyArtwork] != nil),
        "nextEnabled": center.nextTrackCommand.isEnabled,
        "prevEnabled": center.previousTrackCommand.isEnabled,
        "playEnabled": center.playCommand.isEnabled,
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func update(_ args: [String: Any]) {
    let title = args["title"] as? String ?? ""
    let artist = args["episode"] as? String ?? ""
    let durationMs = args["durationMs"] as? Int ?? 0
    let positionMs = args["positionMs"] as? Int ?? 0
    let speed = args["speed"] as? Double ?? 1.0
    let playing = args["playing"] as? Bool ?? false

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: artist,
      MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000.0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000.0,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    if let artwork = artwork {
      info[MPMediaItemPropertyArtwork] = artwork
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused

    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = true
    center.pauseCommand.isEnabled = true
    center.togglePlayPauseCommand.isEnabled = true
    center.stopCommand.isEnabled = true
    center.nextTrackCommand.isEnabled = args["hasNext"] as? Bool ?? false
    center.previousTrackCommand.isEnabled = args["hasPrev"] as? Bool ?? false

    updateArtwork(args["coverUrl"] as? String ?? "")
  }

  private func updateArtwork(_ url: String) {
    guard !url.isEmpty, url != artworkURL else {
      return
    }
    artworkURL = url
    artworkTask?.cancel()
    guard let parsed = URL(string: url) else {
      return
    }
    artworkTask = URLSession.shared.dataTask(with: parsed) { [weak self] data, _, _ in
      guard let self, let data, let image = NSImage(data: data) else {
        return
      }
      let item = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      DispatchQueue.main.async {
        guard self.artworkURL == url else {
          return
        }
        self.artwork = item
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = item
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    }
    artworkTask?.resume()
  }

  private func stop() {
    artworkTask?.cancel()
    artworkTask = nil
    artworkURL = ""
    artwork = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    disableCommands()
  }
}

class MainFlutterWindow: NSWindow {
  private var nowPlayingBridge: NowPlayingBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    nowPlayingBridge = NowPlayingBridge(
      messenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}

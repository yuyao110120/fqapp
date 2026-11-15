import Cocoa
import FlutterMacOS
import MediaPlayer

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    NowPlayingBridge.register(with: flutterViewController)

    super.awakeFromNib()
  }
}

/// macOS system media integration.
///
/// Android hands the app a MediaSession and Windows uses SMTC; on macOS the
/// equivalent is MPNowPlayingInfoCenter (lock screen, Control Center, AirPods
/// and keyboard media keys) plus MPRemoteCommandCenter for the incoming
/// commands. Dart drives both through the `fqapp/now_playing` channel that the
/// desktop adapter already speaks.
final class NowPlayingBridge {
  private static var channel: FlutterMethodChannel?
  private static var handlers: [MPRemoteCommand: Any] = [:]
  private static var artworkTask: URLSessionDataTask?

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "fqapp/now_playing",
      binaryMessenger: controller.engine.binaryMessenger
    )
    Self.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "update":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "bad_args", message: "expected a map", details: nil))
          return
        }
        update(args)
        result(nil)
      case "stop":
        clear()
        result(nil)
      case "debug":
        result(debugSnapshot())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    installCommands()
  }

  private static func installCommands() {
    let center = MPRemoteCommandCenter.shared()
    func bind(_ command: MPRemoteCommand, _ action: String) {
      command.isEnabled = true
      if let token = handlers[command] { command.removeTarget(token) }
      let token = command.addTarget { _ in
        channel?.invokeMethod("remote", arguments: ["action": action])
        return .success
      }
      handlers[command] = token
    }
    bind(center.playCommand, "playPause")
    bind(center.pauseCommand, "playPause")
    bind(center.togglePlayPauseCommand, "playPause")
    bind(center.nextTrackCommand, "next")
    bind(center.previousTrackCommand, "prev")
    bind(center.stopCommand, "stop")
  }

  private static func update(_ args: [String: Any]) {
    var info: [String: Any] = [:]
    if let title = args["title"] as? String, !title.isEmpty {
      info[MPMediaItemPropertyTitle] = title
    }
    if let artist = args["artist"] as? String, !artist.isEmpty {
      info[MPMediaItemPropertyArtist] = artist
    }
    if let album = args["album"] as? String, !album.isEmpty {
      info[MPMediaItemPropertyAlbumTitle] = album
    }
    if let duration = args["durationMs"] as? NSNumber, duration.doubleValue > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = duration.doubleValue / 1000.0
    }
    if let position = args["positionMs"] as? NSNumber {
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position.doubleValue / 1000.0
    }
    if let rate = args["rate"] as? NSNumber {
      info[MPNowPlayingInfoPropertyPlaybackRate] = rate.doubleValue
    }
    if let playing = args["playing"] as? Bool {
      info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
    }
    info[MPNowPlayingInfoPropertyExternalContentIdentifier] = "fqapp"
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    if let artwork = args["artworkUrl"] as? String, !artwork.isEmpty {
      loadArtwork(artwork, title: args["title"] as? String)
    }
  }

  /// Covers arrive as http(s) URLs; the lock screen needs real image data, so
  /// fetch once per URL and re-publish the info dictionary when it lands.
  private static func loadArtwork(_ url: String, title: String?) {
    artworkTask?.cancel()
    guard let parsed = URL(string: url) else { return }
    artworkTask = URLSession.shared.dataTask(with: parsed) { data, _, _ in
      guard let data = data, let image = NSImage(data: data) else { return }
      DispatchQueue.main.async {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if title != nil, (info[MPMediaItemPropertyTitle] as? String) != title { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    }
    artworkTask?.resume()
  }

  private static func clear() {
    artworkTask?.cancel()
    artworkTask = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  private static func debugSnapshot() -> [String: Any] {
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    return [
      "title": info[MPMediaItemPropertyTitle] as? String ?? "",
      "artist": info[MPMediaItemPropertyArtist] as? String ?? "",
      "duration": info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0,
      "elapsed": info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0,
      "rate": info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0,
      "hasArtwork": info[MPMediaItemPropertyArtwork] != nil,
    ]
  }
}

import 'package:screen_retriever/screen_retriever.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:window_manager/window_manager.dart';

import '../widgets/desktop_login.dart';
import '../widgets/macos_login.dart';
import 'desktop_media.dart';
import 'app_log.dart';
import 'platform_channel.dart';
import 'linux_platform.dart';

bool get isWindowsDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

bool get isMacOSDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Windows and macOS share the wide desktop shell (NavigationRail on the left,
/// desktop page layouts). Linux's first desktop release keeps the bottom dock.
bool get isDesktopShell => isWindowsDesktop || isMacOSDesktop;

/// Platforms that use the media_kit desktop player stack: the in-process
/// window/player channel adapter, the system media integration and the
/// `Video` widget all come from here.
bool get isMediaDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// On Windows an inactive window is still visible; it simply lacks input focus.
/// Only hidden/paused/detached windows should defer foreground video playback.
bool playbackAppIsActive(AppLifecycleState? state) =>
    !(isLinuxDesktop && DesktopSystemSession.instance.blocked) &&
    (state == null ||
        state == AppLifecycleState.resumed ||
        (isMediaDesktop && state == AppLifecycleState.inactive));

/// 桌面窗口只是失焦时，是否仍算「在前台」。
///
/// Flutter 3.13 起桌面端有真正的生命周期：窗口失去焦点报 `inactive`，
/// 最小化报 `hidden` / `paused`。**失焦不是退到后台** —— 窗口还在、渲染还在
/// 跑；把它当后台会让听书跟随停止翻页（鼠标点一下别的窗口，页面就不跟了）。
///
/// 与 [playbackAppIsActive] 是同一件事的两处用法：那个管视频前台播放，这个
/// 管阅读页的跟随与高亮。平台范围比它宽一点，三个桌面平台都成立。
bool desktopInactiveStillVisible(AppLifecycleState state) =>
    !(isLinuxDesktop && DesktopSystemSession.instance.blocked) &&
    (state == AppLifecycleState.resumed ||
        ((!kIsWeb &&
                (defaultTargetPlatform == TargetPlatform.windows ||
                    defaultTargetPlatform == TargetPlatform.macOS ||
                    defaultTargetPlatform == TargetPlatform.linux)) &&
            state == AppLifecycleState.inactive));

/// logind hints are observable, but compositor lock reliability is unverified.
class DesktopSystemSession extends ChangeNotifier {
  static final instance = DesktopSystemSession();
  bool locked = false;
  bool suspended = false;
  bool serviceAvailable = false;
  bool get blocked => locked || suspended;
  void accept(dynamic event) {
    if (event is! Map || event['value'] is! bool) return;
    final value = event['value'] as bool;
    switch (event['type']) {
      case 'locked':
        if (locked == value) return;
        locked = value;
      case 'suspend':
        if (suspended == value) return;
        suspended = value;
      case 'service':
        serviceAvailable = value;
        if (!value) AppLog.w('session', 'logind 不可用，无法保证锁屏/挂起通知');
      default:
        return;
    }
    notifyListeners();
  }

  AppLifecycleState get lifecycle => blocked
      ? AppLifecycleState.hidden
      : WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
}

class DesktopPlatform with WindowListener {
  DesktopPlatform._();
  static final instance = DesktopPlatform._();
  static final navigatorKey = GlobalKey<NavigatorState>();
  static final readerBrightness = ValueNotifier<double>(1);
  static final fullscreen = ValueNotifier<bool>(false);
  static final maximized = ValueNotifier<bool>(false);
  final _events = <String, StreamController<dynamic>>{};
  final _players = <int, _DesktopPlayer>{};
  final _tts = FlutterTts();
  SMTCWindows? _smtc;
  String? _utterance;
  int _nextId = 1000000;
  bool _closing = false;
  Future<void> Function()? beforeClose;
  Future<void> _awakeQueue = Future.value();
  bool _readerAwake = false;
  bool _playerAwake = false;
  String? _readerSession;
  Timer? _readerTimer;
  Process? _caffeinate;
  static const _nowPlaying = MethodChannel('fqapp/now_playing');
  bool _nowPlayingReady = false;

  Stream<dynamic> events(String name) =>
      (_events[name] ??= StreamController<dynamic>.broadcast()).stream;
  void _emit(String name, dynamic event) => _events[name]?.add(event);

  Future<void> initialize() async {
    if (!isDesktopShell) return;
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    PlatformChannels.invoke = invoke;
    PlatformChannels.events = events;
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    final display = await screenRetriever.getPrimaryDisplay();
    final available = display.visibleSize ?? display.size;
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: Size(min(1280, available.width), min(800, available.height)),
        minimumSize: Size(
          min(880, available.width),
          min(560, available.height),
        ),
        center: true,
        title: '什锦铺',
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
        try {
          maximized.value = await windowManager.isMaximized();
        } catch (_) {}
      },
    );
    _tts.setCompletionHandler(() {
      final id = _utterance;
      if (id != null) {
        _utterance = null;
        _emit('fqapp/system_tts_events', {'type': 'done', 'id': id});
      }
    });
    _tts.setErrorHandler((dynamic _) {
      final id = _utterance;
      _utterance = null;
      _emit('fqapp/system_tts_events', {'type': 'error', 'id': id});
    });
    if (isMacOSDesktop) _installNowPlayingBridge();
    // Optional system media integration must not prevent reading or startup.
    if (isWindowsDesktop) {
      try {
        await SMTCWindows.initialize();
        _smtc = SMTCWindows();
        _smtc!.buttonPressStream.listen((button) {
          final action = switch (button) {
            PressedButton.play => 'playPause',
            PressedButton.pause => 'playPause',
            PressedButton.next => 'next',
            PressedButton.previous => 'prev',
            PressedButton.stop => 'stop',
            _ => null,
          };
          if (action != null) {
            unawaited(
              PlatformChannels.notify(
                'fqapp/native_player',
                'onNotificationAction',
                {'action': action},
              ),
            );
          }
        });
        await _smtc!.disableSmtc();
      } catch (_) {
        _smtc = null;
      }
    }
  }

  Future<void> disposeMedia() async {
    final hosts = _players.values.toList();
    _players.clear();
    for (final host in hosts) {
      await host.dispose();
    }
  }

  Widget videoSurface(int id, {Key? key}) {
    final host = _players[id];
    return host == null
        ? const SizedBox.expand()
        : Video(
            key: key,
            controller: host.video,
            controls: NoVideoControls,
            fit: BoxFit.fill,
            pauseUponEnteringBackgroundMode: false,
            resumeUponEnteringForegroundMode: false,
          );
  }

  Future<void> setFullscreen(bool value) async {
    try {
      await windowManager.setFullScreen(value);
    } catch (_) {}
    fullscreen.value = value;
    if (!value) {
      try {
        maximized.value = await windowManager.isMaximized();
      } catch (_) {}
    }
  }

  Future<void> minimizeWindow() async {
    if (!isDesktopShell) return;
    try {
      await windowManager.minimize();
    } catch (_) {}
  }

  Future<void> toggleMaximizeWindow() async {
    if (!isDesktopShell) return;
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {}
  }

  Future<void> closeWindow() async {
    if (!isDesktopShell) return;
    try {
      await windowManager.close();
    } catch (_) {}
  }

  Future<void> startWindowDragging() async {
    if (!isDesktopShell) return;
    try {
      await windowManager.startDragging();
    } catch (_) {}
  }

  @override
  void onWindowMaximize() {
    maximized.value = true;
  }

  @override
  void onWindowUnmaximize() {
    maximized.value = false;
  }

  @override
  void onWindowLeaveFullScreen() {
    fullscreen.value = false;
  }

  @override
  void onWindowEnterFullScreen() {
    fullscreen.value = true;
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      try {
        await beforeClose?.call();
      } catch (_) {}
      for (final host in _players.values.toList()) {
        await host.dispose();
      }
      _players.clear();
      _utterance = null;
      await _tts.stop();
      await _smtc?.disableSmtc();
      _readerTimer?.cancel();
      _readerAwake = _playerAwake = false;
      _updateAwake();
    } finally {
      await windowManager.destroy();
    }
  }

  Future<dynamic> invoke(
    String channel,
    String method,
    dynamic arguments,
  ) async {
    final args = arguments is Map ? arguments : const <dynamic, dynamic>{};
    switch (channel) {
      case 'fqapp/native_player':
        if (method == 'create') {
          MediaKit.ensureInitialized();
          final id = _nextId++;
          final host = _DesktopPlayer(
            id,
            (event) => _emit('fqapp/native_player/events', event),
          );
          _players[id] = host;
          unawaited(
            host.open(
              args['cdnUrl'] as String,
              args['keyHex'] as String,
              startPositionMs: args['startPositionMs'],
            ),
          );
          return {'playerId': id};
        }
        if (method == 'setKeepScreenOn') {
          await _setAwake(player: args['on'] == true);
          return null;
        }
        if (method == 'startListenForeground') {
          if (isMacOSDesktop) {
            await _publishNowPlaying(args);
            return null;
          }
          final smtc = _smtc;
          if (smtc == null) return null;
          await smtc.updateMetadata(
            MusicMetadata(
              title: args['title'] as String?,
              artist: args['episode'] as String?,
              // Windows 的「正在播放」卡片同样用作品封面（issue #123）；
              // SMTC 自己按 URL 拉图，取不到就保留应用图标。
              thumbnail: switch (args['coverUrl']) {
                final String url when url.isNotEmpty => url,
                _ => null,
              },
            ),
          );
          await smtc.setIsPrevEnabled(args['hasPrev'] == true);
          await smtc.setIsNextEnabled(args['hasNext'] == true);
          await smtc.updateTimeline(
            PlaybackTimeline(
              startTimeMs: 0,
              endTimeMs: (args['durationMs'] as num?)?.toInt() ?? 0,
              positionMs: (args['positionMs'] as num?)?.toInt() ?? 0,
              minSeekTimeMs: 0,
              maxSeekTimeMs: (args['durationMs'] as num?)?.toInt() ?? 0,
            ),
          );
          await smtc.setPlaybackStatus(
            args['playing'] == true
                ? PlaybackStatus.playing
                : PlaybackStatus.paused,
          );
          await smtc.enableSmtc();
          return null;
        }
        if (method == 'stopListenForeground') {
          if (isMacOSDesktop) {
            await _invokeNowPlaying('stop');
            return null;
          }
          await _smtc?.disableSmtc();
          return null;
        }
        if (isLinuxDesktop &&
            !const {
              'dispose',
              'play',
              'pause',
              'seek',
              'setRate',
              'setVolume',
              'getPlaybackSettings',
            }.contains(method)) {
          throw PlatformException(
            code: 'unsupported_platform',
            message: method,
          );
        }
        final id = (args['id'] as num?)?.toInt();
        final host = _players[id];
        if (method == 'dispose') {
          _players.remove(id);
          await host?.dispose();
          return null;
        }
        if (host == null) {
          throw PlatformException(code: 'player_closed', message: '播放器已关闭');
        }
        if (method == 'getPlaybackSettings') {
          return {
            'volume': host.player.state.volume / 100,
            'rate': host.player.state.rate,
          };
        }
        await host.command(method, args);
        return null;
      case 'fqapp/library_backup':
        return _backup(method, args);
      case 'fqapp/local_books':
        if (method == 'pickBookFile') return pickBook();
      case 'fqapp/downloads':
        if (method == 'saveText') {
          final path = await _save(
            args['fileName'] as String,
            Uint8List.fromList(utf8.encode(args['text'] as String)),
            ['txt'],
          );
          if (path == null) {
            throw PlatformException(code: 'cancelled', message: '已取消保存');
          }
          return {'path': path, 'public': true};
        }
      case 'fqapp/reader':
        return _reader(method, args);
      case 'fqapp/system_tts':
        return _speech(method, args);
      case 'fqapp/fanqie_account':
        if (method == 'login') {
          final context = navigatorKey.currentContext;
          if (context == null) {
            throw PlatformException(code: 'not_ready', message: '窗口尚未就绪');
          }
          if (isMacOSDesktop) return MacLogin.open(context);
          return DesktopLogin.open(context);
        }
        if (method == 'cancelLogin') {
          if (isMacOSDesktop) {
            MacLogin.cancel();
          } else {
            DesktopLogin.cancel();
          }
          return null;
        }
        if (method == 'clearSession') {
          if (isMacOSDesktop) {
            await MacLogin.clearSession();
          } else {
            await DesktopLogin.clearSession();
          }
          return null;
        }
      case 'fqapp/eink-refresh':
        return false;
      case 'fqapp/volume-key':
        return null;
      case 'fqapp/fair_memory':
        return null;
    }
    throw MissingPluginException('$channel/$method');
  }

  Future<dynamic> _speech(String method, Map args) async {
    switch (method) {
      case 'engines':
        final voices = await _tts.getVoices;
        return {
          'defaultEngine': 'windows',
          'engines': [
            {'package': 'windows', 'label': 'Windows 默认语音'},
            if (voices is List)
              for (final voice in voices)
                if (voice is Map && voice['name'] is String)
                  {
                    'package': jsonEncode({
                      'name': voice['name'],
                      'locale': voice['locale'],
                    }),
                    'label': '${voice['name']} (${voice['locale']})',
                  },
          ],
        };
      case 'initialize':
        await _tts.stop();
        _utterance = null;
        final engine = args['engine'];
        if (engine is String && engine.startsWith('{')) {
          final voice = (jsonDecode(engine) as Map).cast<String, String>();
          await _tts.setVoice(voice);
        } else {
          await _tts.setLanguage('zh-CN');
        }
        // flutter_tts 的 Windows 实现内部会再 +0.5（SAPI SpeakingRate 的
        // 0.5 基线），所以这里减掉同一个偏移才是 app 侧的 rate。
        // 早先是 *0.5，等效 0.5r+0.5：拉满 2.0× 实际只有 1.5×。
        await _tts.setSpeechRate(
          ((args['rate'] as num?)?.toDouble() ?? 1) - .5,
        );
        return 300;
      case 'speak':
        _utterance = args['id'] as String;
        final result = await _tts.speak(args['text'] as String);
        if (result == 0) {
          throw PlatformException(
            code: 'tts_failed',
            message: 'Windows 语音不可用，请安装中文语音',
          );
        }
        return null;
      case 'stop':
      case 'shutdown':
        _utterance = null;
        await _tts.stop();
        return null;
      case 'settings':
        await Process.run('explorer.exe', ['ms-settings:speech']);
        return null;
    }
    throw MissingPluginException(method);
  }

  Future<dynamic> _reader(String method, Map args) async {
    if (isLinuxDesktop &&
        (method == 'setImmersive' || method == 'setBrightness')) {
      throw PlatformException(
        code: 'unsupported_platform',
        message: 'Linux does not provide this Android device control',
      );
    }
    switch (method) {
      case 'start':
        _readerSession = args['session'] as String?;
        _readerTimer?.cancel();
        _readerTimer = Timer.periodic(
          const Duration(minutes: 1),
          (_) => _emit('fqapp/reader/events', _readerStatus()),
        );
        if (!isLinuxDesktop) _setBrightness(args['brightness']);
        return _readerStatus();
      case 'setBrightness':
        _setBrightness(args['brightness']);
        return true;
      case 'keepScreenOn':
        await _setAwake(reader: args['on'] == true);
        return null;
      case 'stop':
      case 'suspend':
        _readerTimer?.cancel();
        readerBrightness.value = 1;
        await _setAwake(reader: false);
        return null;
      case 'setImmersive':
        return null;
      case 'pickFont':
        final file = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(label: '字体', extensions: ['ttf', 'otf', 'ttc']),
          ],
        );
        if (file == null) return null;
        if (await file.length() > 32 * 1024 * 1024) {
          throw PlatformException(code: 'file_size', message: '字体不能超过 32 MB');
        }
        final root = await getApplicationSupportDirectory();
        final fonts = await Directory(
          '${root.path}/fonts',
        ).create(recursive: true);
        final target = File(
          '${fonts.path}/${DateTime.now().microsecondsSinceEpoch}-${_safeName(file.name)}',
        );
        await File(file.path).copy(target.path);
        return {'path': target.path, 'name': file.name};
    }
    if (isLinuxDesktop) {
      throw PlatformException(code: 'unsupported_platform', message: method);
    }
    return null;
  }

  void _setBrightness(dynamic raw) {
    final value = raw is num ? raw.toDouble() : -1.0;
    readerBrightness.value = value < 0 ? 1 : value.clamp(.05, 1);
  }

  Map<String, dynamic> _readerStatus() => {
    'session': _readerSession,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    if (!isLinuxDesktop) 'systemBrightness': 1.0,
  };
  Future<void> _setAwake({bool? reader, bool? player}) {
    final request = _awakeQueue.then((_) async {
      final oldReader = _readerAwake, oldPlayer = _playerAwake;
      _readerAwake = reader ?? oldReader;
      _playerAwake = player ?? oldPlayer;
      try {
        await _updateAwake();
      } catch (_) {
        _readerAwake = oldReader;
        _playerAwake = oldPlayer;
        rethrow;
      }
    });
    _awakeQueue = request.catchError((Object _) {});
    return request;
  }

  /// Installs the Now Playing bridge that the Runner registers in Swift.
  ///
  /// macOS surfaces media state through MPNowPlayingInfoCenter instead of
  /// SMTC, and the lock screen / keyboard media keys arrive as
  /// MPRemoteCommand events. Both directions share one channel so the Dart
  /// side keeps a single code path with Windows.
  void _installNowPlayingBridge() {
    _nowPlaying.setMethodCallHandler((call) async {
      if (call.method != 'remote') return null;
      final args = call.arguments;
      final action = args is Map ? args['action'] : null;
      if (action is! String || action.isEmpty) return null;
      await PlatformChannels.notify(
        'fqapp/native_player',
        'onNotificationAction',
        {'action': action},
      );
      return null;
    });
    _nowPlayingReady = true;
  }

  Future<void> _publishNowPlaying(Map args) async {
    if (!_nowPlayingReady) return;
    try {
      await _nowPlaying.invokeMethod<void>('update', {
        'title': args['title'],
        'artist': args['episode'],
        'album': args['album'],
        'artworkUrl': args['coverUrl'],
        'durationMs': (args['durationMs'] as num?)?.toInt() ?? 0,
        'positionMs': (args['positionMs'] as num?)?.toInt() ?? 0,
        'playing': args['playing'] == true,
      });
    } on MissingPluginException {
      _nowPlayingReady = false;
    } on PlatformException catch (error) {
      AppLog.w('now_playing', '更新系统「正在播放」失败：${error.code}');
    }
  }

  Future<void> _invokeNowPlaying(String method) async {
    if (!_nowPlayingReady) return;
    try {
      await _nowPlaying.invokeMethod<void>(method);
    } on MissingPluginException {
      _nowPlayingReady = false;
    } on PlatformException {
      // Best effort: stopping a stale card must not break shutdown.
    }
  }

  Future<void> _updateAwake() async {
    if (isLinuxDesktop) {
      await const MethodChannel('fqapp/desktop_session').invokeMethod<void>(
        'setKeepScreenOn',
        {'on': _readerAwake || _playerAwake},
      );
      return;
    }
    if (isMacOSDesktop) {
      // macOS has no SetThreadExecutionState: hold a child caffeinate while
      // either the reader or a player asks for the display to stay awake.
      final wantAwake = _readerAwake || _playerAwake;
      if (!wantAwake) {
        _caffeinate?.kill();
        _caffeinate = null;
        return;
      }
      if (_caffeinate != null) return;
      try {
        final process = await Process.start('caffeinate', ['-d', '-i']);
        if (_readerAwake || _playerAwake) {
          _caffeinate = process;
        } else {
          process.kill();
        }
      } catch (_) {
        // Best-effort only: staying awake must never break reading.
      }
      return;
    }
    final call = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
          'SetThreadExecutionState',
        );
    call(0x80000000 | (_readerAwake || _playerAwake ? 3 : 0));
  }

  String _safeName(String name) =>
      name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  Future<String?> _save(
    String name,
    Uint8List bytes,
    List<String> extensions,
  ) async {
    final location = await getSaveLocation(
      suggestedName: _safeName(name),
      acceptedTypeGroups: [XTypeGroup(label: '文件', extensions: extensions)],
    );
    if (location == null) return null;
    if (isLinuxDesktop) {
      if (!await _saveLinux(location.path, bytes)) return null;
    } else {
      await XFile.fromData(bytes, name: name).saveTo(location.path);
    }
    return location.path;
  }

  Future<bool> _saveLinux(String path, Uint8List bytes) async {
    final libc = DynamicLibrary.process();
    final open = libc
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32, Uint32),
          int Function(Pointer<Utf8>, int, int)
        >('open');
    final close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'close',
    );
    final errno = libc
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          '__errno_location',
        );
    // Linux open flags: write-only, no symlink following, nonblocking, close-on-exec.
    const flags = 0x1 | 0x20000 | 0x800 | 0x80000;
    final nativePath = path.toNativeUtf8();
    int fd;
    var existing = false;
    try {
      fd = open(
        nativePath,
        flags | 0x40 | 0x80,
        0x1b6,
      ); // O_CREAT | O_EXCL, 0666
      if (fd < 0 && errno().value == 17) {
        // EEXIST
        existing = true;
        fd = open(nativePath, flags, 0);
      }
      if (fd < 0) {
        throw FileSystemException('无法打开保存文件', path, OSError('', errno().value));
      }
    } finally {
      malloc.free(nativePath);
    }
    try {
      // Pin the opened inode: a replaced path must never redirect this write.
      final file = File('/proc/self/fd/$fd');
      final before = await file.stat();
      if (before.type != FileSystemEntityType.file) {
        throw FileSystemException('只能保存到普通文件', path);
      }
      if (existing) {
        final context = navigatorKey.currentContext;
        if (context == null || !context.mounted) {
          throw PlatformException(code: 'not_ready', message: '窗口尚未就绪');
        }
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('覆盖已有文件？'),
            content: Text('文件已存在，覆盖后无法撤销：\n$path'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('覆盖'),
              ),
            ],
          ),
        );
        if (confirmed != true) return false;
      }
      final after = await file.stat();
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          await Link(file.path).target() !=
              await File(path).resolveSymbolicLinks() ||
          before.size != after.size ||
          before.modified != after.modified ||
          before.changed != after.changed ||
          before.mode != after.mode) {
        throw PlatformException(
          code: 'file_changed',
          message: '目标文件已变化，请重新选择保存位置',
        );
      }
      await file.writeAsBytes(bytes, flush: true);
      if (await Link(file.path).target() !=
          await File(path).resolveSymbolicLinks()) {
        throw PlatformException(code: 'file_changed', message: '保存期间目标文件已被替换');
      }
      return true;
    } finally {
      close(fd);
    }
  }

  Future<Directory> _captureDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/fanqie_capture').create(recursive: true);
  }

  bool _validPart(String name) =>
      RegExp(r'^part-[0-9]+-[a-fA-F0-9-]+\.json$').hasMatch(name);
  Future<dynamic> _backup(String method, Map args) async {
    switch (method) {
      case 'saveBackup':
        return await _save(args['name'] as String, args['bytes'] as Uint8List, [
              'json',
            ]) !=
            null;
      case 'openBackup':
        final selected = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(label: '备份文件', extensions: ['json']),
          ],
        );
        if (selected == null) return null;
        if (await selected.length() > 128 * 1024 * 1024) {
          throw PlatformException(code: 'file_size', message: '备份文件过大');
        }
        return selected.readAsBytes();
      case 'storeFanqieCapture':
        final root = await _captureDirectory();
        final temp = File('${root.path}/latest.tmp');
        await temp.writeAsBytes(args['bytes'] as Uint8List, flush: true);
        await temp.rename('${root.path}/latest.json');
        return true;
      case 'latestFanqieCapture':
        final root = await _captureDirectory();
        final file = File('${root.path}/latest.json');
        return await file.exists() ? file.readAsBytes() : null;
      case 'storeFanqieCapturePart':
        final root = await _captureDirectory();
        final random = Random.secure();
        final suffix = List.generate(
          12,
          (_) => random.nextInt(16).toRadixString(16),
        ).join();
        final name =
            'part-${DateTime.now().microsecondsSinceEpoch}-$suffix.json';
        await File(
          '${root.path}/$name',
        ).writeAsBytes(args['bytes'] as Uint8List, flush: true);
        return name;
      case 'readFanqieCapturePart':
        final name = args['name'] as String;
        if (!_validPart(name)) {
          throw PlatformException(code: 'invalid_part', message: '分卷名称无效');
        }
        final root = await _captureDirectory();
        final file = File('${root.path}/$name');
        return await file.exists() ? file.readAsBytes() : null;
      case 'exportFanqieCapture':
        final root = await _captureDirectory();
        final archive = Archive();
        final bytes = args['bytes'] as Uint8List;
        archive.addFile(ArchiveFile('capture.json', bytes.length, bytes));
        for (final name in (args['parts'] as List).cast<String>().toSet()) {
          if (!_validPart(name)) throw PlatformException(code: 'invalid_part');
          final bytes = await File('${root.path}/$name').readAsBytes();
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }
        return await _save(
              args['name'] as String,
              Uint8List.fromList(ZipEncoder().encode(archive)),
              ['zip'],
            ) !=
            null;
    }
    throw MissingPluginException(method);
  }

  Future<Map<String, dynamic>?> pickBook() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '本地书籍', extensions: ['txt', 'epub']),
      ],
    );
    if (file == null) return null;
    if (await file.length() > 32 * 1024 * 1024) {
      throw PlatformException(code: 'file_size', message: '书籍不能超过 32 MB');
    }
    final bytes = await file.readAsBytes();
    final text = Platform.isLinux && file.name.toLowerCase().endsWith('.txt')
        ? await decodeLinuxText(bytes)
        : null;
    return {
      'name': file.name,
      'bytes': bytes,
      'byteLength': bytes.length,
      if (file.name.toLowerCase().endsWith('.txt'))
        'text': text ?? decodeDesktopText(bytes),
    };
  }
}

/// Decode the already size-checked bytes; never re-read a mutable picked file.
Future<String> decodeLinuxText(Uint8List bytes) async {
  if (bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255))) {
    return decodeDesktopText(bytes);
  }
  try {
    return utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
  } on FormatException {
    final process = await Process.start('iconv', [
      '-f',
      'GB18030',
      '-t',
      'UTF-8',
    ]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    process.stdin.add(bytes);
    await process.stdin.close();
    final text = await output;
    await errors;
    if (await process.exitCode != 0) throw const FormatException('无法解码本地书籍');
    return text;
  }
}

String decodeDesktopText(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255))) {
    final little = bytes[0] == 255;
    return String.fromCharCodes([
      for (var i = 2; i + 1 < bytes.length; i += 2)
        little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
    ]);
  }
  try {
    return utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
  } on FormatException {
    final convert = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(
            Uint32,
            Uint32,
            Pointer<Uint8>,
            Int32,
            Pointer<Uint16>,
            Int32,
          ),
          int Function(int, int, Pointer<Uint8>, int, Pointer<Uint16>, int)
        >('MultiByteToWideChar');
    final input = calloc<Uint8>(bytes.length);
    input.asTypedList(bytes.length).setAll(0, bytes);
    Pointer<Uint16> output = nullptr;
    try {
      final length = convert(54936, 0, input, bytes.length, nullptr, 0);
      if (length == 0) throw const FormatException('无法识别 TXT 编码');
      output = calloc<Uint16>(length);
      if (convert(54936, 0, input, bytes.length, output, length) == 0) {
        throw const FormatException('无法读取 TXT');
      }
      return String.fromCharCodes(output.asTypedList(length));
    } finally {
      calloc.free(input);
      if (output != nullptr) calloc.free(output);
    }
  }
}

/// `create` 下发的续播起点（`startPositionMs`，> 0 才有）落到 media_kit 的
/// [Media.start] 上。
///
/// media_kit 在 mpv 的 on_load 钩子里把它设成 `start` 属性，即 prepare 前生效，
/// 与 Android 端约定一致；Dart 侧 `NativePlayer` 也已按起点显示进度和弹幕锚点。
/// 加密流走本地 CENC 代理，起点处的读取是普通的 `Range: bytes=N-` 请求，
/// 与拖动进度条走同一条路。
@visibleForTesting
Media desktopPlaybackMedia(String uri, Object? startPositionMs) {
  final startMs = startPositionMs is num ? startPositionMs.toInt() : 0;
  return Media(
    uri,
    start: startMs > 0 ? Duration(milliseconds: startMs) : null,
  );
}

/// 为刚建好的 media_kit [VideoController] 请求一帧。
///
/// `VideoController` 构造时用 `addPostFrameCallback` 推迟纹理创建，
/// `Player.open` 又会等 `VideoController` 初始化完成；而 `addPostFrameCallback`
/// 本身不请求帧。窗口静止时（例如 Windows 短剧 feed 起播第一集，画面上只有
/// 一张静态封面），没有任何东西请求新帧，`open` 就一直挂着，直到鼠标划过
/// 窗口触发重绘，或 Dart 侧 25 秒的创建超时报「播放失败」。后续集数不受影响，
/// 因为正在播的视频会持续驱动帧。Windows 与 Linux 都会遇到。
@visibleForTesting
void requestVideoControllerFrame() => WidgetsBinding.instance.scheduleFrame();

/// 诊断构建开关：`--dart-define=FQAPP_PLAYER_DIAGNOSTICS=true` 时把 mpv 日志
/// 放宽到 info 级写进应用日志，用来排查「某些剧集播不了」。产品构建不开。
const desktopPlayerDiagnostics = bool.fromEnvironment(
  'FQAPP_PLAYER_DIAGNOSTICS',
);

class _DesktopPlayer {
  _DesktopPlayer(this.id, this.emit) {
    video = VideoController(player);
    requestVideoControllerFrame();
    void event(String type, dynamic value) {
      if (!disposed) emit({'playerId': id, 'type': type, 'value': value});
    }

    subscriptions.addAll([
      player.stream.position.listen((v) => event('position', v.inMilliseconds)),
      player.stream.duration.listen((v) => event('duration', v.inMilliseconds)),
      player.stream.playing.listen((v) {
        AppLog.d('desktop-player', 'id=$id playing=$v');
        event('playing', v);
      }),
      player.stream.buffering.listen((v) => event('buffering', v)),
      player.stream.completed.listen((v) => event('completed', v)),
      player.stream.width.listen((_) => _size()),
      player.stream.height.listen((_) => _size()),
      player.stream.error.listen((message) {
        // 界面只给通用提示；原始错误（解码器、HTTP 状态、解密）留在日志里排查。
        AppLog.w('desktop-player', 'id=$id mpv error: $message');
        event('error', {'message': '媒体播放失败，请重试或切换清晰度'});
      }),
      // 默认只有 error 级会到这里；诊断构建放宽到 info，能看到开流、
      // 选轨、编码格式、硬解是否生效等起播过程。
      player.stream.log.listen(
        (log) => AppLog.d(
          'mpv',
          'id=$id [${log.prefix}] ${log.level}: ${log.text.trimRight()}',
        ),
      ),
    ]);
    unawaited(
      video.waitUntilFirstFrameRendered.then((_) => event('firstFrame', true)),
    );
  }
  final int id;
  final void Function(Map<String, dynamic>) emit;
  final player = Player(
    configuration: const PlayerConfiguration(
      logLevel: desktopPlayerDiagnostics ? MPVLogLevel.info : MPVLogLevel.error,
    ),
  );
  late final VideoController video;
  final subscriptions = <StreamSubscription<dynamic>>[];
  final ready = Completer<void>();
  DesktopMedia? media;
  bool disposed = false;
  Future<void> open(String url, String key, {Object? startPositionMs}) async {
    ready.future.ignore();
    try {
      var playbackUrl = url;
      if (key.isNotEmpty) {
        final session = await DesktopMedia.open(url, key);
        if (disposed) {
          session.close();
          return;
        }
        media = session;
        playbackUrl = session.url;
      }
      // Plain audio/video follows the original URI player contract. Some
      // public audio origins return 200 only and must not require CENC Range I/O.
      if (disposed) return;
      await player.open(
        desktopPlaybackMedia(playbackUrl, startPositionMs),
        play: false,
      );
      AppLog.d('desktop-player', 'id=$id opened paused');
      if (disposed) return;
      ready.complete();
      emit({'playerId': id, 'type': 'created', 'value': id});
      _size();
    } catch (error) {
      if (!ready.isCompleted) ready.completeError(StateError('无法打开媒体'));
      final value = desktopOpenFailure(id, error);
      if (!disposed) {
        emit({'playerId': id, 'type': 'error', 'value': value});
      }
      media?.close();
    }
  }

  void _size() {
    if (!disposed) {
      emit({
        'playerId': id,
        'type': 'videoSize',
        'width': player.state.width ?? 0,
        'height': player.state.height ?? 0,
        'rotationCorrection': 0,
      });
    }
  }

  Future<void> command(String method, Map args) async {
    await ready.future;
    if (disposed) return;
    AppLog.d('desktop-player', 'id=$id command=$method');
    switch (method) {
      case 'play':
        await player.play();
        emit({'playerId': id, 'type': 'playWhenReady', 'value': true});
      case 'pause':
        await player.pause();
        emit({'playerId': id, 'type': 'playWhenReady', 'value': false});
      case 'seek':
        await player.seek(
          Duration(milliseconds: (args['positionMs'] as num).toInt()),
        );
      case 'setRate':
        await player.setRate((args['rate'] as num).toDouble());
      case 'setVolume':
        await player.setVolume(
          (args['volume'] as num).toDouble().clamp(0, 1) * 100,
        );
      default:
        throw MissingPluginException(method);
    }
  }

  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    if (!ready.isCompleted) ready.complete();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    try {
      await player.dispose();
    } finally {
      media?.close();
    }
  }
}

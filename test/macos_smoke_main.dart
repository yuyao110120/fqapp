// ignore_for_file: avoid_print
//
// Throwaway macOS port smoke entrypoint (never part of the shipped app).
//
// Verifies on macOS:
//   1. DesktopPlatform.initialize() installs the in-process platform channels;
//   2. Keychain availability and the file-fallback encrypted Hive path;
//   3. Now Playing bridge (MPNowPlayingInfoCenter) metadata + remote commands;
//   4. the WKWebView (flutter_inappwebview) can load the official login page;
//   5. the Rust desktop media bridge (fq_desktop_media_open) is reachable.
//
// Build/run:
//   flutter build macos --debug -t test/macos_smoke_main.dart
//   open -n -g build/macos/Build/Products/Debug/fqapp.app
// Results are written to <app support>/macos_smoke.txt.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fqapp/services/desktop_media.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/services/secure_key_provider.dart';

final _lines = <String>[];

Future<void> _save() async {
  try {
    final dir = await getApplicationSupportDirectory();
    await File(
      '${dir.path}/macos_smoke.txt',
    ).writeAsString(_lines.join('\n'), flush: true);
  } catch (_) {
    // The result file is best-effort; stdout is a second channel.
  }
}

void _log(String line) {
  print('SMOKE $line');
  _lines.add(line);
  unawaited(_save());
}

Future<void> _finish() async {
  await _save();
  exit(0);
}

Future<void> _testSecureStorage() async {
  const storage = FlutterSecureStorage();
  try {
    await storage.write(key: 'fqapp_smoke_key', value: 'smoke_value');
    final value = await storage.read(key: 'fqapp_smoke_key');
    await storage.delete(key: 'fqapp_smoke_key');
    _log('keychain: available value=$value');
  } catch (error) {
    _log('keychain: unavailable => $error');
  }

  try {
    final key = await SecureKeyProvider().getOrCreateKey(
      name: 'fqapp_smoke_hive_key',
    );
    _log('secure-key: ${key == null ? 'unavailable' : 'ok(${key.length})'}');
    if (key == null) return;
    final directory = await Directory.systemTemp.createTemp('fqapp-smoke-hive');
    Hive.init(directory.path);
    final box = await EncryptedHive.openBox<String>(
      Hive,
      'smoke',
      requireEncryption: true,
    );
    await box.put('k', 'v');
    await box.close();
    final files =
        directory
            .listSync(recursive: true)
            .map((entity) => entity.path.split(Platform.pathSeparator).last)
            .toList()
          ..sort();
    _log('hive-encrypted: files=$files');
  } catch (error) {
    _log('hive-encrypted: FAILED => $error');
  }
}

Future<void> _testNowPlaying() async {
  String? remoteAction;
  NativePlayer.setRemoteCommandHandler(
    onAction: (action) => remoteAction = action,
  );
  try {
    await NativePlayer.startListenForeground(
      title: '冒烟听书',
      episode: '第 1 章',
      playing: true,
      hasPrev: false,
      hasNext: true,
      positionMs: 12000,
      durationMs: 60000,
      speed: 1.25,
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final info = await const MethodChannel(
      'fqapp/now_playing',
    ).invokeMethod<Map<Object?, Object?>>('debug');
    _log('now-playing: $info');
    await const MethodChannel(
      'fqapp/now_playing',
    ).invokeMethod<void>('debugTrigger', {'action': 'playPause'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _log('remote-action: $remoteAction');
    await NativePlayer.stopListenForeground();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final cleared = await const MethodChannel(
      'fqapp/now_playing',
    ).invokeMethod<Map<Object?, Object?>>('debug');
    _log(
      'now-playing-stop: title=${cleared?['title']} '
      'playEnabled=${cleared?['playEnabled']}',
    );
  } catch (error) {
    _log('now-playing: FAILED => $error');
  } finally {
    NativePlayer.clearRemoteCommandHandler();
  }
}

Future<void> _testLoginWebView() async {
  final loaded = Completer<String>();
  runApp(
    MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri('https://fanqienovel.com/main/writer/login'),
          ),
          initialSettings: InAppWebViewSettings(
            isInspectable: false,
            supportMultipleWindows: false,
          ),
          onLoadStop: (controller, url) async {
            if (loaded.isCompleted) return;
            String? title;
            try {
              title = await controller.getTitle();
            } catch (_) {}
            loaded.complete('url=$url title=$title');
          },
          onReceivedError: (controller, request, error) {
            if (!loaded.isCompleted) {
              loaded.complete('ERROR ${error.description}');
            }
          },
        ),
      ),
    ),
  );
  try {
    _log(
      'inappwebview: ${await loaded.future.timeout(const Duration(seconds: 25))}',
    );
  } catch (error) {
    _log('inappwebview: FAILED => $error');
  }
}

Future<void> _testDesktopMedia() async {
  try {
    await DesktopMedia.open(
      'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
      '000102030405060708090a0b0c0d0e0f',
    );
    _log('desktop-media: opened a session (bridge reachable)');
  } on ArgumentError catch (error) {
    _log('desktop-media: SYMBOL MISSING $error');
  } catch (error) {
    _log('desktop-media: bridge reachable, request rejected => $error');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('macOS smoke'))),
    ),
  );
  _log('smoke: start');
  await DesktopPlatform.instance.initialize();
  _log('desktop-adapter: initialized');

  await _testSecureStorage();
  await _testNowPlaying();
  await _testLoginWebView();
  await _testDesktopMedia();

  _log('smoke: done');
  await _finish();
}

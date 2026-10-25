import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

/// 番茄官方登录桥（只读导入书架）。
///
/// Windows 使用 WebView2（webview_windows），macOS 使用 WKWebView
/// （flutter_inappwebview）。两侧都只允许在官方登录域名内跳转，并把
/// fanqienovel.com 的登录 cookie 交给桌面适配层。
class DesktopLogin {
  const DesktopLogin._();

  static Future<String?> open(BuildContext context) {
    if (Platform.isWindows) return _WindowsLogin.open(context);
    return _MacLogin.open(context);
  }

  static void cancel() {
    if (Platform.isWindows) {
      _WindowsLogin.cancel();
    } else {
      _MacLogin.cancel();
    }
  }

  static Future<void> clearSession() async {
    if (Platform.isWindows) {
      await _WindowsLogin.clearSession();
    } else {
      await _MacLogin.clearSession();
    }
  }
}

const _loginUrl = 'https://fanqienovel.com/main/writer/login';
const _allowedHosts = <String>[
  'fanqienovel.com',
  'snssdk.com',
  'bytedance.com',
  'zijieapi.com',
];
const _sessionCookieNames = <String>{'sessionid', 'sessionid_ss', 'sid_tt'};

bool _isAllowedUrl(String? url) {
  final uri = Uri.tryParse(url ?? '');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.host.isEmpty) {
    return false;
  }
  return _allowedHosts.any(
    (host) => uri.host == host || uri.host.endsWith('.$host'),
  );
}

// ---------------------------------------------------------------------------
// Windows (WebView2)
// ---------------------------------------------------------------------------

class _WindowsLogin {
  static final _controller = WebviewController();
  static Future<void>? _initializing;
  static VoidCallback? _cancel;

  static Future<void> _initialize() => _initializing ??=
      (() async {
        final root = await getApplicationSupportDirectory();
        final profile = await Directory(
          '${root.path}/webview',
        ).create(recursive: true);
        await WebviewController.initializeEnvironment(
          userDataPath: profile.path,
        );
        await _controller.initialize();
      })().catchError((Object e) {
        _initializing = null;
        throw e;
      });

  static Future<String?> open(BuildContext context) async {
    await _initialize();
    if (!context.mounted) return null;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _WindowsLoginDialog(),
    );
  }

  static void cancel() => _cancel?.call();

  static Future<void> clearSession() async {
    await _initialize();
    await _controller.clearCookies();
    await _controller.clearCache();
  }
}

class _WindowsLoginDialog extends StatefulWidget {
  const _WindowsLoginDialog();

  @override
  State<_WindowsLoginDialog> createState() => _WindowsLoginDialogState();
}

class _WindowsLoginDialogState extends State<_WindowsLoginDialog> {
  String _hint = _loginHint;
  bool _reading = false;
  StreamSubscription<String>? _navigation;

  @override
  void initState() {
    super.initState();
    _WindowsLogin._cancel = () {
      if (mounted) Navigator.pop(context);
    };
    _navigation = _WindowsLogin._controller.url.listen((url) {
      if (!_isAllowedUrl(url)) {
        unawaited(_WindowsLogin._controller.stop());
        if (mounted) setState(() => _hint = _blockedHint);
      }
    });
    unawaited(
      _WindowsLogin._controller.setPopupWindowPolicy(
        WebviewPopupWindowPolicy.deny,
      ),
    );
    unawaited(_WindowsLogin._controller.loadUrl(_loginUrl));
  }

  @override
  void dispose() {
    _WindowsLogin._cancel = null;
    _navigation?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    if (_reading) return;
    setState(() => _reading = true);
    try {
      final result = await _WindowsLogin._controller.getFanqieCookies();
      final cookies = (result['cookies'] as List? ?? []).whereType<Map>().where(
        (cookie) {
          final domain = (cookie['domain'] as String? ?? '').replaceFirst(
            RegExp(r'^.'),
            '',
          );
          return domain == 'fanqienovel.com' ||
              domain.endsWith('.fanqienovel.com');
        },
      ).toList();
      if (!_hasSessionCookie(
        cookies.map((c) => Map<String, dynamic>.from(c)),
      )) {
        if (mounted) setState(() => _hint = _noSessionHint);
        return;
      }
      final value = cookies.map((c) => '${c['name']}=${c['value']}').join('; ');
      if (value.length > 12 * 1024) throw StateError('cookie size');
      if (mounted) Navigator.pop(context, value);
    } catch (_) {
      if (mounted) setState(() => _hint = _readFailedHint);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) => _LoginDialogShell(
    title: _loginTitle,
    hint: _hint,
    reading: _reading,
    onRead: _read,
    onClose: () => Navigator.pop(context),
    child: Webview(
      _WindowsLogin._controller,
      permissionRequested: (_, _, _) async => WebviewPermissionDecision.deny,
    ),
  );
}

// ---------------------------------------------------------------------------
// macOS (WKWebView)
// ---------------------------------------------------------------------------

class _MacLogin {
  static VoidCallback? _cancel;

  static Future<String?> open(BuildContext context) => showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _MacLoginDialog(),
  );

  static void cancel() => _cancel?.call();

  static Future<void> clearSession() async {
    await CookieManager.instance().deleteAllCookies();
    try {
      await WebStorageManager.instance().deleteAllData();
    } catch (_) {
      // WKWebView data removal is unavailable on older macOS versions.
    }
    // InAppWebViewController.clearAllCache() is Android-only; WKWebView data
    // lives in WebStorageManager / the cookie store, both cleared above.
  }
}

class _MacLoginDialog extends StatefulWidget {
  const _MacLoginDialog();

  @override
  State<_MacLoginDialog> createState() => _MacLoginDialogState();
}

class _MacLoginDialogState extends State<_MacLoginDialog> {
  String _hint = _loginHint;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _MacLogin._cancel = () {
      if (mounted) Navigator.pop(context);
    };
  }

  @override
  void dispose() {
    _MacLogin._cancel = null;
    super.dispose();
  }

  void _block() {
    if (mounted) setState(() => _hint = _blockedHint);
  }

  Future<void> _read() async {
    if (_reading) return;
    setState(() => _reading = true);
    try {
      final cookies = <Cookie>[];
      final seen = <String>{};
      for (final url in <String>[
        'https://fanqienovel.com',
        'https://www.fanqienovel.com',
      ]) {
        try {
          cookies.addAll(
            await CookieManager.instance().getCookies(url: WebUri(url)),
          );
        } catch (_) {
          // A missing cookie store for one host must not abort the other.
        }
      }
      final parts = <String>[];
      var hasSession = false;
      for (final cookie in cookies) {
        final domain = (cookie.domain ?? '').replaceFirst(RegExp(r'^.'), '');
        if (domain != 'fanqienovel.com' &&
            !domain.endsWith('.fanqienovel.com')) {
          continue;
        }
        final value = cookie.value;
        if (value.isEmpty) continue;
        if (!seen.add('${cookie.name}@$domain')) continue;
        parts.add('${cookie.name}=$value');
        if (_sessionCookieNames.contains(cookie.name)) hasSession = true;
      }
      if (!hasSession) {
        if (mounted) setState(() => _hint = _noSessionHint);
        return;
      }
      final value = parts.join('; ');
      if (value.length > 12 * 1024) throw StateError('cookie size');
      if (mounted) Navigator.pop(context, value);
    } catch (_) {
      if (mounted) setState(() => _hint = _readFailedHint);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) => _LoginDialogShell(
    title: _loginTitle,
    hint: _hint,
    reading: _reading,
    onRead: _read,
    onClose: () => Navigator.pop(context),
    child: InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
      initialSettings: InAppWebViewSettings(
        isInspectable: false,
        supportMultipleWindows: false,
        useShouldOverrideUrlLoading: true,
      ),
      shouldOverrideUrlLoading: (controller, action) async {
        final url = action.request.url?.toString();
        if (_isAllowedUrl(url)) return NavigationActionPolicy.ALLOW;
        _block();
        return NavigationActionPolicy.CANCEL;
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// Shared UI
// ---------------------------------------------------------------------------

const _loginTitle = '番茄官方登录 · 只读导入';
const _loginHint = '请在番茄官方网页完成登录和验证，再点击“读取书架”。账号只用于读取。';
const _blockedHint = '已阻止离开官方登录域名。';
const _noSessionHint = '尚未取得有效登录态，请先完成官方登录。';
const _readFailedHint = '无法读取官方登录态，请重试。';

bool _hasSessionCookie(Iterable<Map<String, dynamic>> cookies) => cookies.any(
  (cookie) =>
      _sessionCookieNames.contains(cookie['name']) &&
      (cookie['value'] as String? ?? '').isNotEmpty,
);

class _LoginDialogShell extends StatelessWidget {
  const _LoginDialogShell({
    required this.title,
    required this.hint,
    required this.reading,
    required this.onRead,
    required this.onClose,
    required this.child,
  });

  final String title;
  final String hint;
  final bool reading;
  final VoidCallback onRead;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(24),
    child: SizedBox(
      width: math.min(1000, MediaQuery.sizeOf(context).width - 48),
      height: math.min(700, MediaQuery.sizeOf(context).height - 48),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
              ],
            ),
          ),
          Expanded(child: child),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(child: Text(hint)),
                const SizedBox(width: 16),
                FilledButton(
                  onPressed: reading ? null : onRead,
                  child: Text(reading ? '正在读取…' : '读取书架'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

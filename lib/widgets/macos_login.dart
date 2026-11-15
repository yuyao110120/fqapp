import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../services/app_log.dart';

/// 番茄官方登录（macOS / WKWebView）。
///
/// Windows 用 WebView2（`webview_windows`），macOS 没有对应的进程内 WebView
/// 插件，改用 flutter_inappwebview 的 WKWebView。两边对外契约一致：只允许在
/// 官方域名内跳转，读取 `fanqienovel.com` 的登录 cookie 并交给平台适配层；
/// 账号只用于读取书架，不做任何写入。
class MacLogin {
  const MacLogin._();

  static final _cookieStore = CookieManager.instance();
  static VoidCallback? _cancel;

  /// 允许停留的官方域名。
  static const _allowedHosts = <String>[
    'fanqienovel.com',
    'snssdk.com',
    'bytedance.com',
    'zijieapi.com',
  ];

  static bool allowsHost(String host) => _allowedHosts.any(
    (allowed) => host == allowed || host.endsWith('.$allowed'),
  );

  static Future<String?> open(BuildContext context) => showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const MacLoginDialog(),
  );

  static void cancel() => _cancel?.call();

  static Future<void> clearSession() async {
    try {
      await _cookieStore.deleteAllCookies();
    } catch (error, stack) {
      AppLog.w('login', '清除登录会话失败', error: error, stack: stack);
    }
  }
}

class MacLoginDialog extends StatefulWidget {
  const MacLoginDialog({super.key});

  @override
  State<MacLoginDialog> createState() => _MacLoginDialogState();
}

class _MacLoginDialogState extends State<MacLoginDialog> {
  static const _entryUrl = 'https://fanqienovel.com/';
  static const _cookieNames = ['sessionid', 'sessionid_ss', 'sid_tt'];

  InAppWebViewController? _web;
  String _hint = '请在番茄官方网页完成登录和验证，再点击「读取书架」。账号只用于读取。';
  bool _reading = false;
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    MacLogin._cancel = () {
      if (mounted) Navigator.pop(context);
    };
  }

  @override
  void dispose() {
    MacLogin._cancel = null;
    super.dispose();
  }

  Future<String?> _cookies() async {
    final seen = <String>{};
    final parts = <String>[];
    for (final host in const ['fanqienovel.com', 'www.fanqienovel.com']) {
      final url = WebUri('https://$host/');
      final cookies = await MacLogin._cookieStore.getCookies(url: url);
      for (final cookie in cookies) {
        final domain = (cookie.domain ?? '').replaceFirst(RegExp('^\\.'), '');
        if (!MacLogin.allowsHost(domain)) continue;
        final value = cookie.value;
        if (value == null || value.isEmpty) continue;
        if (!seen.add('${cookie.name}=$value')) continue;
        parts.add('${cookie.name}=$value');
      }
    }
    final joined = parts.join('; ');
    if (joined.length > 12 * 1024) throw StateError('cookie 过大');
    return joined;
  }

  Future<void> _read() async {
    setState(() {
      _reading = true;
      _hint = '正在读取登录状态…';
    });
    try {
      final value = await _cookies();
      final hasSession =
          value != null &&
          _cookieNames.any((name) => value.contains('$name='));
      if (!hasSession) {
        setState(() {
          _reading = false;
          _hint = '还没有读到登录凭证：请先在网页里完成登录，再点「读取书架」。';
        });
        return;
      }
      if (!mounted) return;
      Navigator.pop(context, value);
    } catch (error, stack) {
      AppLog.w('login', '读取登录 cookie 失败', error: error, stack: stack);
      if (!mounted) return;
      setState(() {
        _reading = false;
        _hint = '读取登录状态失败，请重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: media.width.clamp(320.0, 1000.0) - 48,
        height: media.height.clamp(320.0, 760.0) - 48,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '番茄官方登录',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _blocked
                  ? const Center(child: Text('只能在番茄官方域名内完成登录。'))
                  : InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri(_entryUrl),
                      ),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        thirdPartyCookiesEnabled: true,
                        isInspectable: false,
                      ),
                      onWebViewCreated: (controller) => _web = controller,
                      shouldOverrideUrlLoading: (controller, action) async {
                        final host = action.request.url?.host ?? '';
                        if (MacLogin.allowsHost(host)) {
                          return NavigationActionPolicy.ALLOW;
                        }
                        setState(() => _blocked = true);
                        return NavigationActionPolicy.CANCEL;
                      },
                      onLoadStop: (controller, url) {
                        if (_blocked && (url?.host.isNotEmpty ?? false)) {
                          setState(() => _blocked = false);
                        }
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _hint,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: _reading
                        ? null
                        : () async {
                            await _web?.reload();
                            setState(() => _blocked = false);
                          },
                    child: const Text('刷新'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _reading ? null : _read,
                    child: Text(_reading ? '读取中…' : '读取书架'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

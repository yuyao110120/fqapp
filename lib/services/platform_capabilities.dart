import 'package:flutter/foundation.dart';

import 'desktop_platform.dart';

/// 视频播放是否可用。
///
/// 视频依赖原生播放器：Android 走 ExoPlayer 平台通道（`fqapp/native_player`），
/// 桌面与 iOS 走进程内的 media_kit —— iOS 没有原生播放器通道，由
/// `IosPlatform` 把它接到 Dart 侧，能力等同桌面版(没有悬浮窗与画中画)。
bool get supportsVideoPlayback =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        isDesktopShell);
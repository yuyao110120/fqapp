import 'package:flutter/foundation.dart';

import 'desktop_platform.dart';

/// 视频播放是否可用。
///
/// 视频依赖原生播放器：Android 走 ExoPlayer 平台通道（`fqapp/native_player`），
/// 桌面走 media_kit。iOS 首版没有播放器实现，直接进入播放页会抛
/// `MissingPluginException`，所以入口整体降级为「暂不支持」。
///
/// macOS 和 Windows 共用同一个 media_kit 桌面适配器，因此必须用
/// [isDesktopPlatform] 而不是 Windows-only 的 isWindowsDesktop；否则 macOS 会
/// 被误判成没有播放器，短剧 tab 直接显示「短剧暂不支持」。
bool get supportsVideoPlayback =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android || isDesktopPlatform);

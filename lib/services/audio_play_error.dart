import 'dart:async';

import 'api_client.dart';
import 'backend_transport.dart';
import 'native_player.dart';

/// 听书播放失败时，明确超时与上游内容状态对应的提示。
///
/// 反编译取证：
/// * `ug` = 「本章该音色已下架」
/// * `uj` = 「本章正在审核中，请先看其他章节」
///
/// 上游只保证 `NO_THIS_TONE` 这个码；「审核中」的具体码没有取证到，因此这里
/// 按消息里的关键字识别，识别不到就返回 null，由调用方回落到通用文案——
/// 宁可给通用提示，也不要把裸错误码甩给用户。
String? audioPlayErrorMessage(Object error, {bool switchedTone = false}) {
  if (error is TimeoutException ||
      (error is BackendRequestAborted && error.timedOut) ||
      (error is ApiException && error.statusCode == 408) ||
      (error is NativePlaybackException && error.errorCode == 2002)) {
    return '加载超时，请检查网络后重试。';
  }
  final message = error is ApiException ? error.message : error.toString();
  if (message.contains('NO_THIS_TONE')) {
    return switchedTone ? '本章该音色已下架，已为你换用其它音色' : '本章该音色已下架';
  }
  const reviewMarkers = <String>['审核', 'UNDER_REVIEW', 'AUDITING', 'REVIEWING'];
  for (final marker in reviewMarkers) {
    if (message.contains(marker)) return '本章正在审核中，请先看其他章节';
  }
  return null;
}

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/platform_capabilities.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS uses the shared desktop video player', () {
    // The macOS port runs the same media_kit desktop adapter as Windows, so the
    // short-drama tab must not fall back to the "unsupported" placeholder.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(supportsVideoPlayback, isTrue);
  });

  test('Android keeps native playback', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(supportsVideoPlayback, isTrue);
  });

  test('iOS still degrades until it has a native player', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(supportsVideoPlayback, isFalse);
  });
}

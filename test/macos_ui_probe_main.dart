// ignore_for_file: avoid_print
//
// UI probe entrypoint for the macOS port (never shipped). Boots the real app,
// drives a few taps through the pointer pipeline, records provider state and
// writes PNG screenshots into the app sandbox container for inspection.
//
// Build/run:
//   flutter build macos --debug -t test/macos_ui_probe_main.dart
//   open -n -g build/macos/Build/Products/Debug/fqapp.app
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fqapp/main.dart' as app;
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/widgets/desktop_app_frame.dart';

final _lines = <String>[];
Directory? _out;

Future<void> _note(String line) async {
  print('PROBE $line');
  _lines.add(line);
  await _flush();
}

String _summary(HomeState s) =>
    'tab=${s.tabIndex} loading=${s.isLoading} items=${s.items.length} '
    'cells=${s.cells.length} cellsTab=${s.cellsTabIndex} '
    'kinds=${s.items.map((e) => e.kind).toSet()} error=${s.error}';

Future<void> _flush() async {
  final out = _out;
  if (out == null) return;
  try {
    await File(
      '${out.path}/macos_probe.txt',
    ).writeAsString(_lines.join('\n'), flush: true);
  } catch (_) {}
}

Element? _findType(Element element, String type) {
  if (element.widget.runtimeType.toString() == type) return element;
  Element? found;
  element.visitChildren((child) {
    found ??= _findType(child, type);
  });
  return found;
}

Element? _findKey(Element element, Key key) {
  if (element.widget.key == key) return element;
  Element? found;
  element.visitChildren((child) {
    found ??= _findKey(child, key);
  });
  return found;
}

Future<void> _shot(String name) async {
  final out = _out;
  if (out == null) return;
  try {
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    final view = WidgetsBinding.instance.renderViews.first;
    final layer = view.debugLayer;
    if (layer is! OffsetLayer) {
      await _note('shot $name: root layer is ${layer.runtimeType}');
      return;
    }
    final image = await layer.toImage(Offset.zero & view.size, pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) {
      await _note('shot $name: empty bytes');
      return;
    }
    final file = File('${out.path}/probe_$name.png');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    await _note('shot $name -> ${file.path}');
  } catch (error) {
    await _note('shot $name failed: $error');
  }
}

Future<void> _tapElement(Element element) async {
  final box = element.renderObject;
  if (box is! RenderBox || !box.hasSize) return;
  final center = box.localToGlobal(box.size.center(Offset.zero));
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(pointer: 9, position: center),
  );
  await Future<void>.delayed(const Duration(milliseconds: 40));
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(pointer: 9, position: center),
  );
}

Future<void> _tapKey(Key key) async {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return;
  final element = _findKey(root, key);
  if (element == null) {
    await _note('tap $key: not found');
    return;
  }
  final box = element.renderObject;
  if (box is! RenderBox || !box.hasSize) {
    await _note('tap $key: no render box');
    return;
  }
  final center = box.localToGlobal(box.size.center(Offset.zero));
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(pointer: 7, position: center),
  );
  await Future<void>.delayed(const Duration(milliseconds: 40));
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(pointer: 7, position: center),
  );
  await _note(
    'tap $key at ${center.dx.toStringAsFixed(0)},${center.dy.toStringAsFixed(0)}',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _out = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    for (final name in <String>[
      'home_feed_cache_v1.hive',
      'home_feed_cache_v1.lock',
    ]) {
      final file = File('${documents.path}/$name');
      if (await file.exists()) {
        await file.delete();
        print('PROBE cleared $name');
      }
    }
  } catch (_) {}
  app.main();
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final root = WidgetsBinding.instance.rootElement;
  if (root == null) {
    await _note('no root element');
    await _flush();
    exit(1);
  }

  for (var i = 0; i < 160; i++) {
    if (_findKey(root, const ValueKey('home_category_5')) != null) break;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  final tabElement = _findKey(root, const ValueKey('home_category_5'));
  if (tabElement == null) {
    await _note('home tab bar never appeared');
    await _shot('00_no_home');
    await _flush();
    exit(2);
  }
  final container = ProviderScope.containerOf(tabElement, listen: false);
  HomeState state() => container.read(homeProvider);

  // Let the first 推荐 feed finish so the home layout can be reviewed.
  for (var i = 0; i < 40 && state().isLoading; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  await _note('home loaded: ${_summary(state())}');
  final mq = MediaQuery.of(tabElement);
  _note(
    'media=${mq.size} dpr=${mq.devicePixelRatio} '
    'textScale=${(mq.textScaler.scale(14) / 14).toStringAsFixed(2)}',
  );
  for (final type in <String>[
    'HomeRankPreview',
    'HomeRankRow',
    'HomeRankCell',
  ]) {
    final element = _findType(root, type);
    final box = element?.renderObject;
    final size = box is RenderBox && box.hasSize ? box.size : null;
    _note('type=$type size=$size');
  }
  await _shot('00_home_loaded');

  // Category page: the chip grid must open a result surface when tapped.
  await _tapKey(const Key('home_category_button'));
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  _note('category page present=${_findType(root, 'CategoryPage') != null}');
  await _shot('C1_category');
  final chip = _findType(root, '_CategoryChip');
  _note('category chip found=${chip != null}');
  if (chip != null) {
    await _tapElement(chip);
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    _note('category list page=${_findType(root, 'CategoryBooksPage') != null}');
    await _shot('C2_category_search');
    DesktopPlatform.navigatorKey.currentState?.popUntil(
      (route) => route.isFirst,
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  // Scenario A: tap 听书 as soon as the tab bar appears (initial 推荐 load may
  // still be in flight).
  await _note('A before: ${_summary(state())}');
  await _shot('A0_early_before');
  await _tapKey(const ValueKey('home_category_5'));
  final timeline = <String>[];
  for (var i = 0; i < 32; i++) {
    final s = state();
    timeline.add('${s.tabIndex}/${s.isLoading}/${s.items.length}');
    if (i == 4) await _shot('A1_early_400ms');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await _note('A timeline tab/loading/items=${timeline.join(' ')}');
  await _note('A after 3.2s: ${_summary(state())}');
  await _shot('A2_early_3s');

  // Scenario B: manual recovery, then the same tap again.
  await _tapKey(const ValueKey('home_category_0'));
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await _note('B after 推荐: ${_summary(state())}');
  await _tapKey(const ValueKey('home_category_5'));
  await Future<void>.delayed(const Duration(milliseconds: 2500));
  await _note('B after 听书 again: ${_summary(state())}');
  await _shot('B1_second_tap');

  DesktopPlatform.navigatorKey.currentState?.push(
    MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
  );
  await Future<void>.delayed(const Duration(milliseconds: 900));
  await _shot('05_settings');
  await _note('settings pushed');

  DesktopPlatform.navigatorKey.currentState?.popUntil((route) => route.isFirst);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  desktopTab.value = 3;
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  await _shot('06_mine');
  desktopTab.value = 0;
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await _shot('07_home_shell');

  await _note('probe done');
  await _flush();
  exit(0);
}

typedef WidgetContainer = Object;
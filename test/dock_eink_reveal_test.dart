// RootShell 集成守卫:底栏已常驻,墨水屏切换仍要重建壳层,且不再有滚动自动
// 隐藏的包装层(旧实现的 _onEinkModeChanged 需要 reveal + setState)。
//
// 判断可见性用真实几何:底栏必须与可视区相交且位置在拖动/eink 切换前后不动,
// 光靠 findsOneWidget 抓不到滑出屏外的情况。
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/dock_auto_hide.dart';
import 'package:fqapp/widgets/shell_dock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaItem book(String id) => MediaItem(
    id: id,
    title: '$id 作品',
    cover: '',
    author: '作者',
    badge: '',
    ep: '',
    kind: 'book',
  );

  // 空 items 会让首页停在加载态(无限动画),pumpAndSettle 永远等不到静帧;
  // 每条 feed 给几张卡片,既让壳层进入稳态也保证首页可滚动。
  HomeNotifier notifier({int initialTabIndex = 0}) => HomeNotifier(
    initialTabIndex: initialTabIndex,
    homepageLoader:
        ({int tabType = 2, int offset = 0, String? sessionId}) async {
          return HomepagePage(
            items: [for (var i = 0; i < 6; i++) book('$tabType-$i')],
            nextOffset: null,
            sessionId: null,
          );
        },
    searchLoader: (query, {int page = 1}) async => const [],
  );

  testWidgets('eink toggle keeps the dock visible (no auto-hide wrapper)', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => einkModeNotifier.value = false);
    addTearDown(() => dramaLightPageNotifier.value = false);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(() => notifier()),
          dramaProvider.overrideWith(
            () => notifier(initialTabIndex: dramaTabIndex),
          ),
        ],
        child: MaterialApp(home: RootShell(backendStarter: () async {})),
      ),
    );
    await tester.pumpAndSettle();

    // 底栏已常驻:不再有滚动自动隐藏的包装层。
    expect(
      find.ancestor(
        of: find.byType(ShellDock),
        matching: find.byType(DockAutoHideSlide),
      ),
      findsNothing,
    );

    const surface = Rect.fromLTWH(0, 0, 400, 800);
    Rect dockRect() => tester.getRect(find.byType(ShellDock));
    void expectDockVisible(String when) {
      final rect = dockRect();
      expect(rect.height, greaterThan(0), reason: '$when:底栏必须有高度');
      expect(
        rect.intersect(surface).height,
        greaterThan(rect.height * 0.9),
        reason: '$when:底栏必须几乎整块落在可视区内',
      );
      expect(rect.top, lessThan(surface.bottom), reason: '$when:底栏不能滑出下边界');
      expect(rect.bottom, greaterThan(surface.top), reason: '$when:底栏不能滑出上边界');
    }

    expectDockVisible('初始');
    final resting = dockRect();

    // 首页 feed 上滚一把:底栏不会被收起,位置也不动。
    await tester.dragFrom(const Offset(200, 300), const Offset(0, -200));
    await tester.pumpAndSettle();
    expectDockVisible('滚动后');
    expect(dockRect().top, closeTo(resting.top, 0.5), reason: '滚动不应移动底栏');
    expect(dockRect().bottom, closeTo(resting.bottom, 0.5), reason: '滚动不应移动底栏');

    // 墨水屏开与关:监听仍收发重建,底栏始终可见且不位移,不能抛异常。
    einkModeNotifier.value = true;
    await tester.pump();
    expectDockVisible('eink 开');
    expect(dockRect().top, closeTo(resting.top, 0.5), reason: 'eink 下底栏不应移动');
    einkModeNotifier.value = false;
    await tester.pump();
    expectDockVisible('eink 关');
    expect(
      dockRect().bottom,
      closeTo(resting.bottom, 0.5),
      reason: '退出 eink 后底栏不应移动',
    );

    expect(tester.takeException(), isNull);
    // _verifyInvariants 先于 tearDown 检查 debug 变量,必须在这里复位。
    debugDefaultTargetPlatformOverride = null;
  });
}

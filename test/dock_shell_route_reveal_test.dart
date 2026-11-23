// RootShell 集成守卫:底栏已常驻,不再有滚动自动隐藏的包装层。
//
// 旧实现靠 DockAutoHideSlide/DockRouteReveal 收起与露出;现在两条路径都必须
// 让底栏留在可视区内且位置不动:首页 feed 上真滚一把,以及压一个覆盖路由再
// pop 回壳层。只断言 findsOneWidget 不够——滑出屏外的底栏照样能被找到。
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

  // 空 items 会让首页停在加载态(无限动画),pumpAndSettle 永远等不到静帧。
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

  testWidgets('shell dock stays visible across scroll and covering route', (
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

    // 底栏不再有自动隐藏的包装层。
    expect(
      find.ancestor(
        of: find.byType(ShellDock),
        matching: find.byType(DockAutoHideSlide),
      ),
      findsNothing,
    );

    const surface = Rect.fromLTWH(0, 0, 400, 800);
    Rect dockRect() => tester.getRect(find.byType(ShellDock));
    // 真实可见性:底栏必须几乎整块落在可视区内,而不是被滑到屏外。
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

    // 首页 feed 上滚一把:底栏必须留在原位,而不是被收起。
    await tester.dragFrom(const Offset(200, 300), const Offset(0, -200));
    await tester.pumpAndSettle();
    expectDockVisible('滚动后');
    expect(dockRect().top, closeTo(resting.top, 0.5), reason: '滚动不应移动底栏');
    expect(dockRect().bottom, closeTo(resting.bottom, 0.5), reason: '滚动不应移动底栏');

    // 压一个覆盖路由再 pop 回壳层:底栏也必须留在原位。
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('覆盖页')),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expectDockVisible('pop 后');
    expect(dockRect().top, closeTo(resting.top, 0.5), reason: 'pop 后底栏应回到原位');
    expect(
      dockRect().bottom,
      closeTo(resting.bottom, 0.5),
      reason: 'pop 后底栏应回到原位',
    );

    expect(tester.takeException(), isNull);
    // _verifyInvariants 先于 tearDown 检查 debug 变量,必须在这里复位。
    debugDefaultTargetPlatformOverride = null;
  });
}

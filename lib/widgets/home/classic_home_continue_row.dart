import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/desktop_platform.dart';
import 'home_design.dart';
import 'home_reading_row.dart' show ReadingNow;
import 'home_shelf.dart';

/// The text-only continue row from f329399. Reading history and dismissals
/// still belong to HomePage; this widget only restores their presentation.
class ClassicHomeContinueRow extends StatelessWidget {
  final ReadingNow now;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  const ClassicHomeContinueRow({
    super.key,
    required this.now,
    required this.onOpen,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final percent = (now.progress * 100).round();
    final compact = !isDesktopShell && MediaQuery.sizeOf(context).width < 600;
    final verb = Text(
      now.verb,
      maxLines: 1,
      style: TextStyle(
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w700,
        color: palette.accentText,
      ),
    );
    final progress = percent > 0 && !now.detailIsProgress
        ? Text(
            '$percent%',
            style: TextStyle(
              fontSize: 11,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: palette.muted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          )
        : null;
    return Row(
      children: [
        Expanded(
          child: HomePressable(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(10),
            semanticLabel: '${now.verb} ${now.item.title}',
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: compact ? 48 : 44),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(homeGutter, 4, 4, 4),
                child: compact
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              verb,
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  now.item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.3,
                                    fontWeight: FontWeight.w600,
                                    color: palette.ink,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  now.detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    height: 1.2,
                                    color: palette.muted,
                                  ),
                                ),
                              ),
                              if (progress != null) ...[
                                const SizedBox(width: 8),
                                progress,
                              ],
                            ],
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          verb,
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${now.item.title} · ${now.detail}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.3,
                                fontWeight: FontWeight.w600,
                                color: palette.ink,
                              ),
                            ),
                          ),
                          if (progress != null) ...[
                            const SizedBox(width: 8),
                            progress,
                          ],
                        ],
                      ),
              ),
            ),
          ),
        ),
        Semantics(
          button: true,
          label: '隐藏继续阅读',
          onTap: onDismiss,
          excludeSemantics: true,
          child: IconButton(
            tooltip: '隐藏继续阅读',
            onPressed: onDismiss,
            iconSize: 15,
            style: IconButton.styleFrom(
              foregroundColor: palette.muted,
              minimumSize: Size(48, compact ? 48 : 44),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(LucideIcons.x),
          ),
        ),
        const SizedBox(width: homeGutter - 10),
      ],
    );
  }
}

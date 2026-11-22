import 'package:material_ui/material_ui.dart';

import '../../models/media_item.dart';
import '../app_ui/content_anchor.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'detail_chapter_row.dart';
import 'detail_states.dart';
import 'detail_style.dart';

/// Classic `目录` preview of the pre-#291 detail page
/// (fqapp-backup@f329399 `widgets/detail/detail_directory_section.dart`).
///
/// Heading with its own catalogue entry, the creation-status / chapter-count
/// metadata line under it, the reader's progress line and bar, then a preview
/// of the current chapter ±1 (first three when there is no progress). The entry
/// opens the same searchable sheet as the 档案 catalogue.
///
/// The preview is a display slice only: rows carry the `Chapter` the page
/// picked from its own catalogue, so tapping one runs the same
/// `_openChapter`. It shows no ordinals, chevrons or opening excerpts.
class ClassicDetailDirectorySection extends StatelessWidget {
  /// `完结 共820章` — the only place the catalogue count appears; empty when the
  /// catalogue itself is missing.
  final String statusLabel;

  final bool catalogueComplete;

  /// The visible slice: current ±1, or chapters 1–3 without progress.
  final List<Chapter> preview;

  /// Index of the current chapter inside [preview]; null when unread.
  final int? currentIndex;

  /// Index of the saved chapter in the whole catalogue; null when unread.
  final int? resumeIndex;

  /// Whole-catalogue chapter count, used by the progress percentage.
  final int chapterCount;

  /// `3 天前` for the progress line; null hides the time part.
  final String? readTimeLabel;

  final String? error;
  final VoidCallback onOpenAll;
  final VoidCallback onRetry;
  final ValueChanged<Chapter> onOpenChapter;

  const ClassicDetailDirectorySection({
    super.key,
    required this.statusLabel,
    required this.catalogueComplete,
    required this.preview,
    required this.currentIndex,
    this.resumeIndex,
    this.chapterCount = 0,
    this.readTimeLabel,
    required this.onOpenAll,
    required this.onRetry,
    required this.onOpenChapter,
    this.error,
  });

  /// The distinct catalogue entry: its own 48dp target, never squeezed by the
  /// status/count line. Mounted in every state, disabled when there is nothing
  /// to open.
  Widget _action(HomePalette palette) {
    final enabled = preview.isNotEmpty;
    final labelText = catalogueComplete ? '全部目录' : '查看现有章节';
    final semanticLabel = catalogueComplete ? '查看全部章节' : labelText;
    final label = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Align(
        widthFactor: 1,
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, top: 2),
          child: Text(
            '$labelText ›',
            style: TextStyle(
              color: enabled
                  ? palette.muted
                  : palette.muted.withValues(alpha: 0.5),
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
    if (!enabled) {
      return Semantics(
        key: const Key('detail_directory_button'),
        label: semanticLabel,
        button: true,
        enabled: false,
        child: ExcludeSemantics(child: label),
      );
    }
    return HomePressable(
      key: const Key('detail_directory_button'),
      semanticLabel: semanticLabel,
      onTap: onOpenAll,
      borderRadius: BorderRadius.circular(8),
      child: label,
    );
  }

  /// `205 / 820` and `已读 25% · 3 天前`, or null when unread.
  ({int number, int total, int percent, String label})? _progress() {
    final index = resumeIndex;
    if (index == null || chapterCount <= 0) return null;
    final number = (index + 1).clamp(1, chapterCount);
    final percent = (number / chapterCount * 100).round();
    final time = readTimeLabel;
    final label = time == null || time.isEmpty
        ? '已读 $percent%'
        : '已读 $percent% · $time';
    return (
      number: number,
      total: chapterCount,
      percent: percent,
      label: label,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final progress = _progress();
    final action = _action(palette);
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '目录',
          style: TextStyle(
            fontSize: 15,
            height: 1.5,
            fontWeight: FontWeight.w700,
            color: palette.ink,
          ),
        ),
        if (statusLabel.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            statusLabel,
            style: TextStyle(color: palette.muted, fontSize: 12, height: 1.5),
          ),
        ],
      ],
    );
    final stackedHeader = MediaQuery.textScalerOf(context).scale(15) > 30;
    final rows = error != null
        ? DetailInlineError(message: error!, onRetry: onRetry)
        : preview.isEmpty
        ? Text('暂无目录', style: TextStyle(color: palette.muted, fontSize: 13))
        : Column(
            key: const Key('detail_preview_chapters'),
            children: [
              for (var i = 0; i < preview.length; i++)
                // The anchor id matches the inline catalogue row, so a layout
                // swap can return to the same chapter (or fall back to the
                // whole 目录 section when this preview does not show it).
                KeyedSubtree(
                  key: contentAnchorKey(
                    'directory/chapter:${preview[i].itemId}',
                  ),
                  child: DetailChapterRow(
                    key: ValueKey(
                      'detail_preview_chapter_${preview[i].itemId}',
                    ),
                    chapter: preview[i],
                    current: i == currentIndex,
                    read: currentIndex != null && i < currentIndex!,
                    divider: i < preview.length - 1,
                    onTap: () => onOpenChapter(preview[i]),
                  ),
                ),
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title pinned to the row top: the 48dp action makes the row taller
        // than the heading, and the classic/archive anchor measures the
        // section's leading edge, so the text keeps its homeSectionGap lead-in.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            homeGutter,
            homeSectionGap,
            homeGutter,
            0,
          ),
          child: stackedHeader
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    heading,
                    Align(alignment: Alignment.centerRight, child: action),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: heading),
                    const SizedBox(width: 12),
                    action,
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (progress != null) ...[
                _ProgressLine(palette: palette, progress: progress),
                const SizedBox(height: 6),
                _ProgressBar(palette: palette, percent: progress.percent),
                const SizedBox(height: 4),
              ],
              rows,
            ],
          ),
        ),
      ],
    );
  }
}

/// `已读 25% · 3 天前` on the left, `205 / 820` on the right.
class _ProgressLine extends StatelessWidget {
  final HomePalette palette;
  final ({int number, int total, int percent, String label}) progress;

  const _ProgressLine({required this.palette, required this.progress});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: palette.muted,
      fontSize: 12,
      height: 1.5,
      fontFeatures: detailNumericFeatures,
    );
    return Row(
      key: const Key('detail_progress_line'),
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            progress.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '${progress.number} / ${progress.total}',
          key: const Key('detail_progress_count'),
          style: style,
        ),
      ],
    );
  }
}

/// 4dp track (`--m-soft`) with an accent fill; e-ink is a 5dp black bar in a
/// black hairline.
class _ProgressBar extends StatelessWidget {
  final HomePalette palette;
  final int percent;

  const _ProgressBar({required this.palette, required this.percent});

  @override
  Widget build(BuildContext context) {
    final eink = palette.eink;
    final radius = BorderRadius.circular(99);
    return Container(
      key: const Key('detail_progress_bar'),
      height: eink ? 5 : 4,
      decoration: BoxDecoration(
        color: detailProgressTrack(palette),
        borderRadius: radius,
        border: eink ? Border.all(color: palette.line) : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: (percent / 100).clamp(0.0, 1.0),
            heightFactor: 1,
            child: ColoredBox(
              key: const Key('detail_progress_fill'),
              color: detailProgressFill(palette),
            ),
          ),
        ),
      ),
    );
  }
}

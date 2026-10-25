import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import 'detail_page.dart';

/// Book list for one category tag (the page behind a tag chip).
///
/// Data comes from the Rust backend route /api/v1/category/books; the page
/// pages in batches of 10 while the list is scrolled.
class CategoryBooksPage extends StatefulWidget {
  const CategoryBooksPage({
    super.key,
    required this.name,
    this.tab = 1,
    this.loader,
  });

  final String name;
  final int tab;
  final Future<List<MediaItem>> Function(
    String name, {
    int tab,
    int offset,
    int count,
  })?
  loader;

  @override
  State<CategoryBooksPage> createState() => _CategoryBooksPageState();
}

class _CategoryBooksPageState extends State<CategoryBooksPage> {
  static const _pageSize = 10;

  final _scroll = ScrollController();
  final _items = <MediaItem>[];
  final _seen = <String>{};
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  Future<List<MediaItem>> _fetch(int offset) =>
      widget.loader?.call(
        widget.name,
        tab: widget.tab,
        offset: offset,
        count: _pageSize,
      ) ??
      ApiClient.instance.categoryBooks(
        widget.name,
        tab: widget.tab,
        offset: offset,
        count: _pageSize,
      );

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fetched = await _fetch(_items.length);
      if (!mounted) return;
      for (final item in fetched) {
        if (item.id.isNotEmpty && _seen.add('${item.kind}:${item.id}')) {
          _items.add(item);
        }
      }
      setState(() {
        _loading = false;
        _hasMore = fetched.length >= _pageSize && fetched.isNotEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '分类内容加载失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: Text(widget.name),
        centerTitle: true,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: _items.isEmpty
          ? _empty(palette)
          : ListView.separated(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
              itemCount: _items.length + 1,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: palette.line.withValues(alpha: 0.6),
              ),
              itemBuilder: (context, index) {
                if (index == _items.length) return _footer(palette);
                final item = _items[index];
                return _row(context, palette, item);
              },
            ),
    );
  }

  Widget _row(BuildContext context, HomePalette palette, MediaItem item) {
    return InkWell(
      onTap: () => openBookDetail(context, item),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              height: 102,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: StoryCover(item: item, cacheWidth: 152),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      item.author,
                      item.badge,
                      item.ep,
                    ].where((part) => part.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ],
              ),
            ),
            Icon(LucideIcons.chevron_right, size: 18, color: palette.muted),
          ],
        ),
      ),
    );
  }

  Widget _empty(HomePalette palette) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: HomePalette.accent),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.cloud_off, size: 40, color: palette.muted),
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(fontSize: 14, color: palette.muted)),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return Center(
      child: Text('暂无分类内容', style: TextStyle(color: palette.muted)),
    );
  }

  Widget _footer(HomePalette palette) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: HomePalette.accent,
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: TextButton(onPressed: _load, child: Text(_error!)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          _hasMore ? '' : '已显示全部',
          style: TextStyle(fontSize: 12, color: palette.muted),
        ),
      ),
    );
  }
}

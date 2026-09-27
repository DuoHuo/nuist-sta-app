import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'announcement_controller.dart';
import 'announcement_detail_page.dart';
import 'announcement_models.dart';

/// 学校公告浏览与订阅管理页。
class AnnouncementPage extends StatefulWidget {
  /// 创建公告阅读与订阅设置页面。
  const AnnouncementPage({super.key});

  @override
  State<AnnouncementPage> createState() => _AnnouncementPageState();
}

class _AnnouncementPageState extends State<AnnouncementPage> {
  final _controller = AnnouncementController.instance;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _controller.ensureStarted();
    if (mounted) {
      await Future.wait([
        _controller.refreshCurrentCategory(),
        if (_controller.subscription.enabled) _controller.refreshFeed(),
      ]);
    }
  }

  Future<void> _refresh() async {
    await Future.wait([
      _controller.refreshCurrentCategory(),
      if (_controller.subscription.enabled) _controller.refreshFeed(),
    ]);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openSubscriptionSettings() async {
    final current = _controller.subscription;
    var enabled = current.enabled;
    final selected = current.topics.toSet();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.pageBg,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              4,
              20,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.72,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '公告订阅',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.titleText,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '选择感兴趣的主题，匹配的新公告会显示在首页。',
                    style: TextStyle(fontSize: 13, color: AppColors.hint),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: _cardDecoration,
                    child: SwitchListTile.adaptive(
                      value: enabled,
                      activeTrackColor: AppColors.accent,
                      title: const Text(
                        '开启首页公告动态',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        enabled ? '只展示所选主题的新公告' : '目前不会显示订阅动态',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onChanged: (value) =>
                          setSheetState(() => enabled = value),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '感兴趣的主题',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.titleText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final topic in AnnouncementTopic.values)
                            FilterChip(
                              label: Text(topic.label),
                              selected: selected.contains(topic),
                              showCheckmark: false,
                              selectedColor: AppColors.accent.withValues(
                                alpha: 0.12,
                              ),
                              side: BorderSide(
                                color: selected.contains(topic)
                                    ? AppColors.accent.withValues(alpha: 0.55)
                                    : AppColors.divider,
                              ),
                              labelStyle: TextStyle(
                                color: selected.contains(topic)
                                    ? AppColors.accent
                                    : AppColors.labelText,
                                fontSize: 12,
                              ),
                              onSelected: (value) => setSheetState(() {
                                if (value) {
                                  selected.add(topic);
                                } else {
                                  selected.remove(topic);
                                }
                              }),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: enabled && selected.isEmpty
                          ? null
                          : () async {
                              await _controller.configureSubscription(
                                enabled: enabled,
                                topics: selected,
                              );
                              if (sheetContext.mounted) {
                                Navigator.pop(sheetContext);
                              }
                            },
                      child: Text(
                        enabled && selected.isEmpty ? '至少选择一个主题' : '保存设置',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(
        title: const Text('信息公告'),
        actions: [
          IconButton(
            tooltip: '订阅设置',
            onPressed: _openSubscriptionSettings,
            icon: const Icon(Icons.notifications_active_outlined),
          ),
          IconButton(
            tooltip: '刷新公告',
            onPressed: _controller.isLoadingCategory ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final items = _controller.items
              .where(
                (item) =>
                    _query.isEmpty ||
                    item.title.toLowerCase().contains(_query.toLowerCase()) ||
                    item.publisher.toLowerCase().contains(_query.toLowerCase()),
              )
              .toList();
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _IntroCard(
                  enabled: _controller.subscription.enabled,
                  onManage: _openSubscriptionSettings,
                ),
                const SizedBox(height: 12),
                _SearchBox(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value.trim()),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 38,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: AnnouncementCategory.all.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final category = AnnouncementCategory.all[index];
                      final selected =
                          category.path == _controller.category.path;
                      return ChoiceChip(
                        label: Text(category.name),
                        selected: selected,
                        showCheckmark: false,
                        selectedColor: AppColors.accent,
                        backgroundColor: Colors.white,
                        labelStyle: TextStyle(
                          color: selected ? Colors.white : AppColors.labelText,
                          fontSize: 12,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                        side: BorderSide(
                          color: selected
                              ? AppColors.accent
                              : AppColors.divider,
                        ),
                        onSelected: (_) => _controller.selectCategory(category),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                if (_controller.categoryError != null)
                  _ErrorCard(
                    message: _controller.categoryError!,
                    onRetry: () => _controller.loadCategory(
                      _controller.category,
                      forceRefresh: true,
                    ),
                  ),
                if (items.isEmpty && _controller.isLoadingCategory)
                  const _LoadingCard()
                else if (items.isEmpty && _query.isNotEmpty)
                  const _EmptyCard(
                    icon: Icons.search_off,
                    title: '没有找到匹配公告',
                    subtitle: '试试更短的标题或发布单位关键词。',
                  )
                else if (items.isEmpty && _controller.categoryError == null)
                  const _EmptyCard(
                    icon: Icons.campaign_outlined,
                    title: '暂时没有公告',
                    subtitle: '下拉刷新，稍后再来看看吧。',
                  )
                else
                  for (final item in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _AnnouncementTile(
                        announcement: item,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                AnnouncementDetailPage(announcement: item),
                          ),
                        ),
                      ),
                    ),
                if (_controller.isLoadingCategory && items.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (_controller.hasMore && _query.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: OutlinedButton.icon(
                      onPressed: _controller.loadMore,
                      icon: const Icon(Icons.expand_more),
                      label: const Text('加载更多公告'),
                    ),
                  )
                else if (items.isNotEmpty && !_controller.hasMore)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: Text(
                        '已经看到当前分类的全部公告',
                        style: TextStyle(fontSize: 12, color: AppColors.hint),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.enabled, required this.onManage});

  final bool enabled;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF087DE1), Color(0xFF45B5ED)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.campaign_outlined, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '校园公告，一站阅读',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  enabled ? '订阅已开启 · 首页会整理感兴趣的新公告' : '浏览全部公告，也可按主题开启订阅',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '订阅设置',
            onPressed: onManage,
            icon: const Icon(Icons.tune, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '搜索公告标题或发布单位',
        prefixIcon: const Icon(Icons.search, color: AppColors.hint),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清空搜索',
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
                icon: const Icon(Icons.close),
              ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _AnnouncementTile extends StatelessWidget {
  const _AnnouncementTile({required this.announcement, required this.onTap});

  final Announcement announcement;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final topics = announcement.topics.take(3).toList();
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 14, 12, 13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      announcement.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.titleText,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: AppColors.hint,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (announcement.officialCategory.isNotEmpty)
                    _Tag(announcement.officialCategory, highlighted: false),
                  for (final topic in topics)
                    _Tag(topic.label, highlighted: true),
                  for (final action in announcement.actions.take(1))
                    _Tag(action, highlighted: false),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.account_balance_outlined,
                    size: 13,
                    color: AppColors.hint,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      announcement.publisher.isEmpty
                          ? '学校信息公告栏'
                          : announcement.publisher,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.hint,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Text(
                    announcement.publishedAt,
                    style: const TextStyle(color: AppColors.hint, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {required this.highlighted});

  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final color = highlighted ? AppColors.accent : AppColors.labelText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted ? const Color(0xFFEAF5FF) : AppColors.pageBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, height: 1.2),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
    decoration: _cardDecoration,
    child: Row(
      children: [
        const Icon(Icons.wifi_off, color: AppColors.warning, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppColors.labelText),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) => Container(
    height: 150,
    decoration: _cardDecoration,
    alignment: Alignment.center,
    child: const CircularProgressIndicator(strokeWidth: 2),
  );
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
    decoration: _cardDecoration,
    child: Column(
      children: [
        Icon(icon, size: 32, color: AppColors.hint),
        const SizedBox(height: 10),
        Text(
          title,
          style: const TextStyle(
            color: AppColors.titleText,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.hint, fontSize: 12),
        ),
      ],
    ),
  );
}

final _cardDecoration = BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.circular(14),
);

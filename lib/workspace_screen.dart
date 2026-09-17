import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_store.dart';
import 'logs_sheet.dart';
import 'models.dart';
import 'settings_sheet.dart';
import 'survey_controller.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, required this.store});

  final AppStore store;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  final Map<String, SurveyController> _controllers = {};
  Timer? _scheduleTimer;

  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _reconcileControllers();
    _scheduleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final target = store.scheduledRefresh;
      if (target == null || DateTime.now().isBefore(target)) {
        if (mounted && target != null) setState(() {});
        return;
      }
      store.scheduleRefresh(null);
      _reloadAll();
    });
  }

  @override
  void dispose() {
    _scheduleTimer?.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _reconcileControllers() {
    final activeIds = store.pages.map((page) => page.id).toSet();
    final removed =
        _controllers.keys.where((id) => !activeIds.contains(id)).toList();
    for (final id in removed) {
      _controllers.remove(id)?.dispose();
    }
    for (final page in store.pages) {
      _controllers.putIfAbsent(
        page.id,
        () => SurveyController(
          store: store,
          page: page,
          onSubmitted: () {
            if (store.selectedPageId == page.id) store.selectNextPage();
          },
        ),
      );
    }
  }

  Future<void> _reloadAll() async {
    _reconcileControllers();
    final busy = _controllers.values.where((controller) => controller.isBusy);
    if (busy.isNotEmpty) {
      _message('请先结束正在填写或提交的页面。');
      return;
    }
    var count = 0;
    for (final page in store.pages) {
      if (store.validatedSurveyUri(page.surveyUrl) == null) continue;
      count += 1;
      await _controllers[page.id]!.reload();
    }
    if (count == 0) _message('请先为页面设置有效的问卷地址。');
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        _reconcileControllers();
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 700;
            final sidebarWidth = compact
                ? (constraints.maxWidth * .22).clamp(84.0, 104.0)
                : 210.0;
            return Scaffold(
              body: SafeArea(
                child: Row(
                  children: [
                    SizedBox(
                      key: const ValueKey('page-sidebar'),
                      width: sidebarWidth,
                      child: _PageSidebar(
                        store: store,
                        controllers: _controllers,
                        compact: compact,
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: IndexedStack(
                        index: store.pages.indexWhere(
                          (page) => page.id == store.selectedPageId,
                        ),
                        children: [
                          for (final page in store.pages)
                            SurveyPagePane(
                              key: ValueKey(page.id),
                              store: store,
                              page: page,
                              controller: _controllers[page.id]!,
                              onReloadAll: _reloadAll,
                              onSchedule: _showScheduleSheet,
                              onAddPage: store.addPage,
                              onSettingsChanged: _reloadAll,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showScheduleSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _ScheduleSheet(store: store),
    );
  }
}

class _PageSidebar extends StatelessWidget {
  const _PageSidebar({
    required this.store,
    required this.controllers,
    required this.compact,
  });

  final AppStore store;
  final Map<String, SurveyController> controllers;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF2F2F7),
      child: Column(
        children: [
          if (!compact) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  const Text(
                    '页面',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    '${store.pages.length}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 4 : 9,
                vertical: 4,
              ),
              itemCount: store.pages.length,
              itemBuilder: (context, index) {
                final page = store.pages[index];
                return Dismissible(
                  key: ValueKey('sidebar-${page.id}'),
                  direction: store.pages.length > 1
                      ? DismissDirection.endToStart
                      : DismissDirection.none,
                  background: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.only(right: 12),
                    alignment: Alignment.centerRight,
                    color: Colors.red,
                    child:
                        const Icon(Icons.delete_outline, color: Colors.white),
                  ),
                  onDismissed: (_) => store.removePage(page.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _SidebarRow(
                      page: page,
                      controller: controllers[page.id]!,
                      preset: store.presetFor(page),
                      compact: compact,
                      selected: page.id == store.selectedPageId,
                      onTap: () => store.selectPage(page.id),
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 4 : 12,
              vertical: 8,
            ),
            child: Row(
              mainAxisAlignment:
                  compact ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                const Icon(Icons.layers_outlined,
                    size: 17, color: Colors.black45),
                const SizedBox(width: 6),
                Text(
                  '${store.pages.length} 个',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.page,
    required this.controller,
    required this.preset,
    required this.compact,
    required this.selected,
    required this.onTap,
  });

  final SurveyPageSession page;
  final SurveyController controller;
  final SubmissionPreset preset;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final statusColor = _statusColor(controller);
        return Material(
          color: selected ? const Color(0x22007AFF) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color:
                  selected ? const Color(0x88007AFF) : const Color(0x12000000),
              width: selected ? 1.2 : .6,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: compact ? 54 : 58,
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: compact ? 2 : 3,
                    height: selected ? (compact ? 28 : 34) : 0,
                    decoration: BoxDecoration(
                      color: const Color(0xFF007AFF),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  SizedBox(width: compact ? 3 : 8),
                  Container(
                    width: compact ? 12 : 17,
                    height: compact ? 12 : 17,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: statusColor.withOpacity(.18),
                    ),
                    alignment: Alignment.center,
                    child: Container(
                      width: compact ? 5 : 8,
                      height: compact ? 5 : 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: statusColor,
                      ),
                    ),
                  ),
                  SizedBox(width: compact ? 4 : 9),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          compact ? '页 ${page.pageNumber}' : page.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: compact ? 13 : 14,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? const Color(0xFF007AFF)
                                : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          compact
                              ? preset.name
                              : '${preset.name} · ${Uri.tryParse(page.surveyUrl)?.host ?? '地址未设置'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: compact ? 9.5 : 12,
                            color: selected
                                ? const Color(0xBB007AFF)
                                : Colors.black45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!compact && selected)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: Color(0xFF007AFF),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class SurveyPagePane extends StatefulWidget {
  const SurveyPagePane({
    super.key,
    required this.store,
    required this.page,
    required this.controller,
    required this.onReloadAll,
    required this.onSchedule,
    required this.onAddPage,
    required this.onSettingsChanged,
  });

  final AppStore store;
  final SurveyPageSession page;
  final SurveyController controller;
  final Future<void> Function() onReloadAll;
  final VoidCallback onSchedule;
  final VoidCallback onAddPage;
  final Future<void> Function() onSettingsChanged;

  @override
  State<SurveyPagePane> createState() => _SurveyPagePaneState();
}

class _SurveyPagePaneState extends State<SurveyPagePane> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.controller.initialize());
  }

  @override
  Widget build(BuildContext context) {
    final validUri = widget.store.validatedSurveyUri(widget.page.surveyUrl);
    final pageIndex =
        widget.store.pages.indexWhere((item) => item.id == widget.page.id);
    final hasNext = pageIndex >= 0 && pageIndex < widget.store.pages.length - 1;
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          leadingWidth: widget.controller.canGoBack ? 40 : 0,
          leading: widget.controller.canGoBack
              ? IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.chevron_left),
                  onPressed: widget.controller.isBusy
                      ? null
                      : widget.controller.goBack,
                  tooltip: '返回',
                )
              : null,
          title: Text(widget.page.title, overflow: TextOverflow.ellipsis),
          actions: [
            _CompactIconButton(
              icon: Icons.refresh,
              tooltip: '刷新所有页面',
              onPressed: widget.onReloadAll,
            ),
            _CompactIconButton(
              icon: widget.store.scheduledRefresh == null
                  ? Icons.schedule_outlined
                  : Icons.schedule,
              color:
                  widget.store.scheduledRefresh == null ? null : Colors.orange,
              tooltip: '定时刷新',
              onPressed: widget.onSchedule,
            ),
            _CompactIconButton(
              icon: Icons.add,
              tooltip: '新增页面',
              onPressed: widget.onAddPage,
            ),
          ],
        ),
        body: validUri == null
            ? _InvalidUrlView(onOpenSettings: _showSettings)
            : Column(
                children: [
                  _StatusHeader(
                    controller: widget.controller,
                    onLogs: _showLogs,
                    onSettings: _showSettings,
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: WebViewWidget(
                      controller: widget.controller.webViewController,
                    ),
                  ),
                ],
              ),
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            color: Color(0xF5FFFFFF),
            border: Border(top: BorderSide(color: Color(0xFFD1D1D6))),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: SafeArea(
            top: false,
            child: Center(
              child: SizedBox(
                width: 280,
                height: 46,
                child: FilledButton.icon(
                  onPressed: hasNext ? widget.store.selectNextPage : null,
                  iconAlignment: IconAlignment.end,
                  icon: const Icon(Icons.chevron_right, size: 20),
                  label: const Text(
                    '下一页',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .96,
        child: SettingsSheet(store: widget.store, page: widget.page),
      ),
    );
    await widget.onSettingsChanged();
  }

  void _showLogs() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .75,
        child: LogsSheet(controller: widget.controller),
      ),
    );
  }
}

class _CompactIconButton extends StatelessWidget {
  const _CompactIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
        constraints: const BoxConstraints.tightFor(width: 36, height: 44),
        padding: EdgeInsets.zero,
        iconSize: 21,
        color: color,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
      );
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({
    required this.controller,
    required this.onLogs,
    required this.onSettings,
  });

  final SurveyController controller;
  final VoidCallback onLogs;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(controller);
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(.14),
                ),
                child: Icon(_statusIcon(controller), color: color, size: 17),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.statusTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      controller.statusDetail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                  ],
                ),
              ),
              if (controller.isBusy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (controller.state.kind == SurveyStateKind.ready)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '${controller.state.questionCount} 题',
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ),
              PopupMenuButton<String>(
                constraints: const BoxConstraints(minWidth: 160),
                iconSize: 20,
                padding: EdgeInsets.zero,
                tooltip: '运行日志与问卷设置',
                onSelected: (value) =>
                    value == 'logs' ? onLogs() : onSettings(),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'logs',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.list_alt_outlined),
                      title: Text('运行日志'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'settings',
                    enabled: !controller.isBusy,
                    child: const ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.tune),
                      title: Text('问卷与预设'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (controller.state.kind == SurveyStateKind.captcha) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.person_pin_circle,
                      color: Colors.orange, size: 16),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '请在页面上完成智能验证，完成后自动继续提交',
                      style: TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                  ),
                  TextButton(
                    onPressed: controller.resumeAfterCaptcha,
                    child: const Text('已完成'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InvalidUrlView extends StatelessWidget {
  const _InvalidUrlView({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add_link, size: 38, color: Colors.black38),
              const SizedBox(height: 14),
              const Text(
                '问卷地址无效',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              const Text(
                '请输入 wjx.cn 的 HTTPS 问卷地址',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onOpenSettings,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('打开设置'),
              ),
            ],
          ),
        ),
      );
}

class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet({required this.store});

  final AppStore store;

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  late DateTime selected;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    selected = widget.store.scheduledRefresh ??
        DateTime(now.year, now.month, now.day, now.hour + 1);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.store.scheduledRefresh;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '定时刷新',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            if (active != null) ...[
              const SizedBox(height: 16),
              _InfoRow(label: '执行时间', value: _dateText(active)),
              const SizedBox(height: 8),
              _InfoRow(
                label: '剩余时间',
                value: _durationText(active.difference(DateTime.now())),
              ),
            ],
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _pickDateTime,
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(_dateText(selected)),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: () {
                if (!selected
                    .isAfter(DateTime.now().add(const Duration(seconds: 1)))) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请选择晚于当前时间的日期和时间。')),
                  );
                  return;
                }
                widget.store.scheduleRefresh(selected);
                Navigator.pop(context);
              },
              child: Text(active == null ? '启动定时刷新' : '更新定时刷新'),
            ),
            if (active != null) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: () {
                  widget.store.scheduleRefresh(null);
                  Navigator.pop(context);
                },
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('取消定时刷新'),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              '到点后刷新全部已打开页面，每个页面使用各自保存的网址。请保持 App 在前台。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: selected,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(selected),
    );
    if (time == null) return;
    setState(() {
      selected =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Text(label),
          const Spacer(),
          Text(value, style: const TextStyle(color: Colors.black54)),
        ],
      );
}

Color _statusColor(SurveyController controller) {
  if (controller.isBusy) return const Color(0xFF007AFF);
  return switch (controller.state.kind) {
    SurveyStateKind.loading => Colors.grey,
    SurveyStateKind.ready || SurveyStateKind.submitted => Colors.green,
    SurveyStateKind.captcha => Colors.orange,
    SurveyStateKind.closed || SurveyStateKind.failed => Colors.red,
  };
}

IconData _statusIcon(SurveyController controller) {
  if (controller.isFilling) return Icons.auto_awesome;
  if (controller.isWaitingToSubmit) return Icons.timer_outlined;
  if (controller.isSubmitting) return Icons.send;
  return switch (controller.state.kind) {
    SurveyStateKind.loading => Icons.hourglass_bottom,
    SurveyStateKind.ready => Icons.check_circle,
    SurveyStateKind.submitted => Icons.verified,
    SurveyStateKind.captcha => Icons.person_pin_circle,
    SurveyStateKind.closed => Icons.cancel,
    SurveyStateKind.failed => Icons.wifi_off,
  };
}

String _dateText(DateTime date) =>
    '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} '
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

String _durationText(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 999999999).toInt();
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainder = seconds % 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${remainder.toString().padLeft(2, '0')}';
}

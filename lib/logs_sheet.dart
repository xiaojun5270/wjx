import 'package:flutter/material.dart';

import 'models.dart';
import 'survey_controller.dart';

enum _LogFilter { all, success, warning, error }

class LogsSheet extends StatefulWidget {
  const LogsSheet({super.key, required this.controller});

  final SurveyController controller;

  @override
  State<LogsSheet> createState() => _LogsSheetState();
}

class _LogsSheetState extends State<LogsSheet> {
  _LogFilter filter = _LogFilter.all;
  String query = '';

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final logs =
            _filteredLogs(widget.controller.logs).toList().reversed.toList();
        return Column(
          children: [
            SizedBox(
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Text(
                    '运行日志',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  Positioned(
                    right: 6,
                    child: IconButton(
                      tooltip: '清空日志',
                      onPressed: widget.controller.logs.isEmpty
                          ? null
                          : widget.controller.clearLogs,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
                ],
              ),
            ),
            _Summary(logs: widget.controller.logs),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: SegmentedButton<_LogFilter>(
                segments: const [
                  ButtonSegment(value: _LogFilter.all, label: Text('全部')),
                  ButtonSegment(value: _LogFilter.success, label: Text('成功')),
                  ButtonSegment(value: _LogFilter.warning, label: Text('警告')),
                  ButtonSegment(value: _LogFilter.error, label: Text('失败')),
                ],
                selected: {filter},
                showSelectedIcon: false,
                onSelectionChanged: (value) =>
                    setState(() => filter = value.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '搜索日志',
                  prefixIcon: Icon(Icons.search, size: 20),
                ),
                onChanged: (value) => setState(() => query = value),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: logs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            query.trim().isEmpty
                                ? Icons.description_outlined
                                : Icons.search,
                            size: 32,
                            color: Colors.black38,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            query.trim().isEmpty ? '暂无日志' : '没有匹配的日志',
                            style: const TextStyle(
                                color: Colors.black54,
                                fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                      itemCount: logs.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, indent: 32),
                      itemBuilder: (context, index) =>
                          _LogRow(entry: logs[index]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Iterable<AutomationLogEntry> _filteredLogs(List<AutomationLogEntry> logs) {
    return logs.where((entry) {
      final levelMatches = switch (filter) {
        _LogFilter.all => true,
        _LogFilter.success => entry.level == LogLevel.success,
        _LogFilter.warning => entry.level == LogLevel.warning,
        _LogFilter.error => entry.level == LogLevel.error,
      };
      final normalizedQuery = query.trim().toLowerCase();
      return levelMatches &&
          (normalizedQuery.isEmpty ||
              entry.category.toLowerCase().contains(normalizedQuery) ||
              entry.message.toLowerCase().contains(normalizedQuery));
    });
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.logs});

  final List<AutomationLogEntry> logs;

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFFF7F7F8),
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            _Metric('总计', logs.length, Colors.black87),
            _Metric('成功', _count(LogLevel.success), Colors.green),
            _Metric('警告', _count(LogLevel.warning), Colors.orange),
            _Metric('失败', _count(LogLevel.error), Colors.red),
          ],
        ),
      );

  int _count(LogLevel level) =>
      logs.where((entry) => entry.level == level).length;
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.count, this.color);

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600, color: color),
            ),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ],
        ),
      );
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final AutomationLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.level) {
      LogLevel.info => const Color(0xFF007AFF),
      LogLevel.success => Colors.green,
      LogLevel.warning => Colors.orange,
      LogLevel.error => Colors.red,
    };
    final icon = switch (entry.level) {
      LogLevel.info => Icons.info,
      LogLevel.success => Icons.check_circle,
      LogLevel.warning => Icons.warning_rounded,
      LogLevel.error => Icons.cancel,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      entry.category,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: color),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      _time(entry.timestamp),
                      style:
                          const TextStyle(fontSize: 11, color: Colors.black45),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                SelectableText(entry.message,
                    style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _time(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}

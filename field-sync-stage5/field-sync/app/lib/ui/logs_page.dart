// path: app/lib/ui/logs_page.dart
// 감사 로그: 누가·언제·어디서·무엇을. 범위는 RLS(본인/팀/전체). 키셋 페이지네이션(더 보기).
// 위치 플래그: 행위 시 단말 위치가 현장에서 200m 이상 떨어져 있으면 ⚠ 표시(원격 허위 완료 탐지).
import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../core/util.dart';
import '../data/models.dart';
import 'widgets.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  static const _farM = 200.0;
  final List<LogEntry> _rows = [];
  int _days = 1; // 1=오늘, 7, 0=전체
  bool _loading = false, _end = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    final st = AppScope.read(context);
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _rows.clear();
        _end = false;
      }
    });
    try {
      final now = DateTime.now();
      final from = _days == 0 ? null : DateTime(now.year, now.month, now.day).subtract(Duration(days: _days - 1));
      final page = await st.api.logs(beforeId: _rows.isEmpty ? null : _rows.last.id, from: from);
      _rows.addAll(page);
      _end = page.length < 50;
    } catch (e) {
      _error = st.errorText(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('logs.title'))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 1, label: Text(tr('period.today'))),
              ButtonSegment(value: 7, label: Text(tr('period.7d'))),
              ButtonSegment(value: 0, label: Text(tr('period.all'))),
            ],
            selected: {_days},
            onSelectionChanged: (s) {
              _days = s.first;
              _load(reset: true);
            },
          ),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: ListView.builder(
              itemCount: _rows.length + 1,
              itemBuilder: (c, i) {
                if (i == _rows.length) {
                  if (_loading) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                  if (_rows.isEmpty) return Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr('logs.empty'))));
                  return _end ? const SizedBox(height: 24) : TextButton(onPressed: _load, child: Text(tr('logs.more')));
                }
                return _tile(_rows[i]);
              },
            ),
          ),
        ),
      ]),
    );
  }

  Widget _tile(LogEntry l) {
    final far = l.lat != null && l.siteLat != null ? distanceM(l.lat!, l.lng!, l.siteLat!, l.siteLng!) : null;
    final details = <String>[
      if (l.meta['reason'] != null) '${tr('logs.reason')}: ${l.meta['reason']}',
      if (l.meta['memo'] != null) '${l.meta['memo']}',
      if (!l.ok) '${tr('logs.rejected')}: ${tr('code.${l.meta['result']?['code'] ?? 'UNKNOWN'}')}',
      if (l.clientAt != null && l.clientAt!.difference(l.at).inMinutes.abs() >= 2) tr('logs.offline_at', {'time': fmtDateTime(l.clientAt!)}),
      if (far != null && far > _farM) '⚠ ${tr('logs.far', {'d': fmtDistance(far)})}',
    ];
    return ListTile(
      dense: true,
      leading: Text(fmtTime(l.at)),
      title: Text('${l.actorName ?? tr('logs.system')} · ${l.siteBunji ?? ''}  ${tr('log.${l.action}')}',
          style: TextStyle(color: l.ok ? null : Colors.red, fontWeight: FontWeight.w500)),
      subtitle: details.isEmpty ? Text(fmtDateTime(l.at)) : Text('${fmtDateTime(l.at)}\n${details.join('\n')}'),
      isThreeLine: details.isNotEmpty,
    );
  }
}

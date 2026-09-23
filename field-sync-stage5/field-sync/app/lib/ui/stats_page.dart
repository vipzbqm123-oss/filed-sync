// path: app/lib/ui/stats_page.dart
// 통계(팀장: 자기 팀, 관리자: 전체): 완료율·평균 소요·차단된 중복 시도·장기 미완료. 차트 라이브러리 없이 막대 위젯.
import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../data/models.dart';
import 'widgets.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  int _days = 1;
  String _by = 'team';
  Future<List<StatsRow>>? _f;

  void _reload() {
    final now = DateTime.now();
    final to = DateTime(now.year, now.month, now.day);
    final f = AppScope.read(context).api.stats(to.subtract(Duration(days: _days - 1)), to, _by);
    setState(() {
      _f = f;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_f == null) WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('stats.title'))),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 1, label: Text(tr('period.today'))),
              ButtonSegment(value: 7, label: Text(tr('period.7d'))),
              ButtonSegment(value: 30, label: Text(tr('period.30d'))),
            ],
            selected: {_days},
            onSelectionChanged: (s) {
              _days = s.first;
              _reload();
            },
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [ButtonSegment(value: 'team', label: Text(tr('stats.by_team'))), ButtonSegment(value: 'user', label: Text(tr('stats.by_user')))],
            selected: {_by},
            onSelectionChanged: (s) {
              _by = s.first;
              _reload();
            },
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<StatsRow>>(
            future: _f,
            builder: (c, snap) {
              if (snap.hasError) return Text(AppScope.read(c).errorText(snap.error!));
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final rows = snap.data!;
              if (rows.isEmpty) return Center(child: Text(tr('stats.empty')));
              final dup = rows.fold<int>(0, (a, r) => a + r.rejectedDuplicates);
              final long = rows.fold<int>(0, (a, r) => a + r.longRunning);
              return Column(children: [
                for (final r in rows) _Bar(r),
                const Divider(),
                ListTile(leading: const Icon(Icons.block), title: Text(tr('stats.duplicates', {'n': dup}))),
                ListTile(leading: const Icon(Icons.hourglass_bottom), title: Text(tr('stats.long_running', {'n': long}))),
              ]);
            },
          ),
        ]),
      );
}

class _Bar extends StatelessWidget {
  const _Bar(this.r);
  final StatsRow r;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.name, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: r.completionRate.clamp(0, 1).toDouble(), minHeight: 14, color: const Color(0xFF2E7D32)),
          ),
          const SizedBox(height: 2),
          Text(tr('stats.row', {
            'done': r.completed,
            'claimed': r.claimed,
            'rate': (r.completionRate * 100).round(),
            'avg': r.avgWorkMin?.round() ?? '-',
            'released': r.released,
          })),
        ]),
      );
}

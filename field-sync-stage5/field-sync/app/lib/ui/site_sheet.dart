// path: app/lib/ui/site_sheet.dart
// 현장 상세 시트: 주소 복사 · 상태/점유자 · 체크 항목 · 길찾기 · 상태별 버튼(주 1 + 보조 1) · 최근 기록.
import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../core/theme.dart';
import '../core/util.dart';
import '../data/models.dart';
import 'actions.dart';
import 'widgets.dart';

Future<void> showSiteSheet(BuildContext context, String siteId) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (c, scroll) => _SiteSheet(siteId: siteId, scroll: scroll),
      ),
    );

class _SiteSheet extends StatelessWidget {
  const _SiteSheet({required this.siteId, required this.scroll});
  final String siteId;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final s = st.sites[siteId];
    if (s == null) return Center(child: Text(tr('site.not_found')));
    final mine = st.isMine(s);
    final ses = st.mySessions[s.id];
    final tpl = st.template;
    final dist = st.myLat == null ? null : distanceM(st.myLat!, st.myLng!, s.lat, s.lng);
    final t = Theme.of(context).textTheme;

    return ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
      CopyText(s.bunji, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
      if (s.road != null) CopyText(s.road!, style: t.bodyLarge),
      if (s.label != null || s.unit.isNotEmpty || s.note != null)
        Text([if (s.label != null) '[${s.label}]', if (s.unit.isNotEmpty) s.unit, if (s.note != null) s.note!].join(' · ')),
      if (dist != null) Text(tr('site.distance', {'d': fmtDistance(dist)}), style: t.bodySmall),
      const SizedBox(height: 12),
      _StatusCard(site: s, blink: !st.batterySaver),
      if (s.urgent) Padding(padding: const EdgeInsets.only(top: 8), child: Banner2(icon: Icons.warning_amber, text: tr('site.urgent'), color: const Color(0xFFB71C1C))),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: OutlinedButton.icon(onPressed: () => openRoute(context, s), icon: const Icon(Icons.directions), label: Text(tr('site.route')))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton.icon(onPressed: () => openKakaoView(s), icon: const Icon(Icons.map), label: Text(tr('site.kakao')))),
      ]),
      const SizedBox(height: 12),
      ..._actions(context, s, mine),
      if (tpl != null && tpl.items.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(tr('site.checks'), style: t.titleMedium),
        for (final it in tpl.items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(it.valid(ses?.checks[it.key]) && ses?.checks[it.key] != null ? Icons.check_box : Icons.check_box_outline_blank),
            title: Text('${it.section.isNotEmpty ? '${it.section} · ' : ''}${it.label}${it.required ? ' *' : ''}'),
            trailing: ses?.checks[it.key] == null ? null : Text(_fmtValue(ses!.checks[it.key])),
          ),
      ],
      const SizedBox(height: 16),
      Text(tr('site.recent'), style: t.titleMedium),
      _RecentLogs(siteId: s.id),
    ]);
  }

  String _fmtValue(Object? v) => v is bool ? (v ? tr('common.yes') : tr('common.no')) : '$v';

  /// 상태 × 점유자 여부별 버튼 (1단계 설계 표와 동일)
  List<Widget> _actions(BuildContext c, Site s, bool mine) {
    final st = AppScope.read(c);
    Widget primary(String label, VoidCallback? on, {IconData? icon}) =>
        FilledButton.icon(onPressed: on, icon: Icon(icon ?? Icons.play_arrow), label: Text(label));
    Widget secondary(String label, VoidCallback on) => OutlinedButton(onPressed: on, child: Text(label));

    final out = <Widget>[];
    if (s.status == SiteStatus.pending) {
      // 시트는 열어 둔 채 실시간으로 상태·버튼이 바뀜
      out.add(primary(tr('action.claim_long'), () => doClaim(c, s), icon: Icons.flag));
      out.add(secondary(tr('action.start_direct'), () => doStart(c, s)));
    } else if (mine && s.status == SiteStatus.enRoute) {
      out.add(primary(tr('action.start'), () => doStart(c, s)));
      out.add(secondary(tr('action.release'), () => doRelease(c, s)));
    } else if (mine && s.status == SiteStatus.working) {
      out.add(primary(tr('action.complete'), () => doComplete(c, s), icon: Icons.check));
      out.add(secondary(tr('action.pause'), () => doPause(c, s)));
      out.add(TextButton.icon(onPressed: () => doSnooze(c, s), icon: const Icon(Icons.snooze), label: Text(tr('action.snooze'))));
    } else if (mine && s.status == SiteStatus.paused) {
      out.add(primary(tr('action.resume'), () => doResume(c, s)));
      out.add(secondary(tr('action.release'), () => doRelease(c, s)));
    } else if (s.status.occupied) {
      out.add(primary(tr('site.occupied_by', {'name': s.occupantName ?? '-', 'status': StatusStyle.of(s.status).label}), null, icon: Icons.lock));
      if (st.can('work.force_release')) out.add(secondary(tr('action.force_release'), () => doForceRelease(c, s)));
    } else if (s.status == SiteStatus.done) {
      final undoable = mine && s.statusAt != null && DateTime.now().difference(s.statusAt!).inMinutes < st.settings.undoWindowMin;
      if (undoable) out.add(secondary(tr('action.undo_complete'), () => st.undoComplete(s)));
      if (st.can('work.reopen')) out.add(secondary(tr('action.reopen'), () => doReopen(c, s)));
    }
    if (st.can('urgent.send')) {
      out.add(TextButton.icon(onPressed: () => doUrgent(c, site: s), icon: const Icon(Icons.campaign, color: Colors.red), label: Text(tr('urgent.send'))));
    }
    return [
      for (final w in out) Padding(padding: const EdgeInsets.only(bottom: 8), child: SizedBox(width: double.infinity, child: w)),
    ];
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.site, required this.blink});
  final Site site;
  final bool blink;

  @override
  Widget build(BuildContext context) {
    final st = AppScope.read(context);
    final s = site;
    final since = s.status == SiteStatus.done ? s.statusAt : (s.startedAt ?? s.statusAt);
    final who = [s.occupantName, s.occupantTeam].whereType<String>().join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          StatusChip(s.status, big: true, blink: blink, pending: s.pendingSync),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              [
                if (who.isNotEmpty) who,
                if (since != null && s.status.occupied) '${fmtTime(since)}~ (${fmtElapsed(DateTime.now().difference(since), st.lang)})',
                if (since != null && s.status == SiteStatus.done) tr('site.done_at', {'time': fmtTime(since)}),
                if (s.pendingSync) tr('site.pending_sync'),
              ].join('\n'),
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 최근 기록(로그 조회 권한 범위만 — RLS). 오프라인이면 안내. 시트가 다시 그려져도 한 번만 조회
class _RecentLogs extends StatefulWidget {
  const _RecentLogs({required this.siteId});
  final String siteId;

  @override
  State<_RecentLogs> createState() => _RecentLogsState();
}

class _RecentLogsState extends State<_RecentLogs> {
  late final Future<List<LogEntry>> _f = AppScope.read(context).api.logs(siteId: widget.siteId, limit: 10);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<LogEntry>>(
      future: _f,
      builder: (c, snap) {
        if (snap.hasError) return Padding(padding: const EdgeInsets.all(8), child: Text(tr('err.network')));
        if (!snap.hasData) return const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator());
        final logs = snap.data!;
        if (logs.isEmpty) return Padding(padding: const EdgeInsets.all(8), child: Text(tr('logs.empty')));
        return Column(children: [
          for (final l in logs)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${fmtTime(l.at)}  ${l.actorName ?? tr('logs.system')}  ${tr('log.${l.action}')}${l.ok ? '' : ' (${tr('logs.rejected')})'}'),
            ),
        ]);
      },
    );
  }
}

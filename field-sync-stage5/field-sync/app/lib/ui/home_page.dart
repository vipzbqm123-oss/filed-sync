// path: app/lib/ui/home_page.dart
// 홈: 동선 선택 · 경고/긴급 배너 · 상태 필터 칩(실시간 개수) · 지도/목록 · 하단 고정 "현재 작업" 바.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../core/theme.dart';
import '../core/util.dart';
import '../data/models.dart';
import 'actions.dart';
import 'admin/admin_home.dart';
import 'inbox_page.dart';
import 'logs_page.dart';
import 'map_view.dart';
import 'settings_page.dart';
import 'site_sheet.dart';
import 'stats_page.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool? _map; // null = 기본(절약 모드면 목록)
  ValueNotifier<String?>? _signal;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_signal == null) {
      _signal = AppScope.read(context).openSite;
      _signal!.addListener(_openFromSignal);
      WidgetsBinding.instance.addPostFrameCallback((_) => _openFromSignal()); // 알림으로 실행된 경우
    }
  }

  @override
  void dispose() {
    _signal?.removeListener(_openFromSignal);
    super.dispose();
  }

  void _openFromSignal() {
    final id = _signal?.value;
    if (id == null || !mounted) return;
    _signal!.value = null;
    showSiteSheet(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final map = _map ?? !st.batterySaver;
    final counts = st.counts;
    final g = st.group;
    return Scaffold(
      appBar: AppBar(
        title: st.groups.isEmpty
            ? Text(tr('home.no_group'))
            : PopupMenuButton<String>(
                onSelected: st.selectGroup,
                itemBuilder: (_) => [for (final x in st.groups) PopupMenuItem(value: x.id, child: Text(x.name))],
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(child: Text(g?.name ?? '-', overflow: TextOverflow.ellipsis)),
                  const Icon(Icons.arrow_drop_down),
                ]),
              ),
        actions: [
          IconButton(
            tooltip: tr('inbox.title'),
            icon: Badge(isLabelVisible: st.unread > 0, label: Text('${st.unread}'), child: const Icon(Icons.notifications)),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const InboxPage())),
          ),
          IconButton(
            tooltip: map ? tr('home.list') : tr('home.map'),
            icon: Icon(map ? Icons.list : Icons.map),
            onPressed: () => setState(() => _map = !map),
          ),
        ],
      ),
      drawer: const _Menu(),
      body: Column(children: [
        if (st.updateRequired) Banner2(icon: Icons.system_update, text: tr('home.update_required'), color: Colors.deepPurple),
        if (!st.online || st.outbox.length > 0)
          Banner2(
            icon: st.online ? Icons.cloud_upload : Icons.cloud_off,
            text: st.online ? tr('home.sending', {'n': st.outbox.length}) : tr('home.offline', {'n': st.outbox.length}),
            color: Colors.orange.shade800,
            onTap: st.outbox.flush,
          ),
        for (final u in st.urgent.take(2))
          Banner2(
            icon: Icons.warning_amber,
            text: '${tr('urgent.label')}: ${u.siteId != null ? '${st.sites[u.siteId]?.bunji ?? ''} · ' : ''}${u.message}',
            color: const Color(0xFFB71C1C),
            onTap: u.siteId == null && !st.can('urgent.send') ? null : () => doUrgentTap(context, u, (id) => showSiteSheet(context, id)),
          ),
        SizedBox(
          height: 52,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), children: [
            _chip(st.filter == null, '${tr('filter.all')} ${st.groupSites.length}', () => st.setFilter(null)),
            for (final s in SiteStatus.values)
              _chip(st.filter == s.db, '${StatusStyle.of(s).label} ${counts[s.db] ?? 0}', () => st.setFilter(s.db), color: StatusStyle.of(s).bg),
            _chip(st.filter == 'mine', '${tr('filter.mine')} ${counts['mine'] ?? 0}', () => st.setFilter('mine')),
          ]),
        ),
        Expanded(child: st.groups.isEmpty ? Center(child: Text(tr('home.empty'))) : (map ? const MapView() : const SiteList())),
      ]),
      bottomNavigationBar: st.currentWork == null ? null : CurrentWorkBar(site: st.currentWork!),
    );
  }

  Widget _chip(bool on, String label, VoidCallback tap, {Color? color}) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          selected: on,
          onSelected: (_) => tap(),
          label: Text(label),
          avatar: color == null ? null : CircleAvatar(backgroundColor: color, radius: 6),
        ),
      );
}

class SiteList extends StatelessWidget {
  const SiteList({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final list = st.listSites;
    if (list.isEmpty) return Center(child: Text(tr('home.empty_filter')));
    return RefreshIndicator(
      onRefresh: st.refreshAll,
      child: ListView.separated(
        itemCount: list.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (c, i) {
          final s = list[i];
          final mine = st.isMine(s);
          final dist = st.myLat == null ? null : distanceM(st.myLat!, st.myLng!, s.lat, s.lng);
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            leading: StatusChip(s.status, blink: !st.batterySaver, pending: s.pendingSync),
            title: Text('${s.label != null ? '[${s.label}] ' : ''}${s.bunji}${s.unit.isNotEmpty ? ' · ${s.unit}' : ''}',
                style: TextStyle(fontWeight: mine ? FontWeight.bold : FontWeight.w500, fontSize: 16)),
            subtitle: Text(_sub(s, dist, st.lang)),
            trailing: s.status == SiteStatus.pending
                ? FilledButton.tonal(onPressed: () => doClaim(c, s), child: Text(tr('action.claim')))
                : (s.urgent ? const Icon(Icons.warning_amber, color: Colors.red) : null),
            shape: mine ? Border(left: BorderSide(color: Theme.of(c).colorScheme.primary, width: 6)) : null,
            onTap: () => showSiteSheet(c, s.id),
          );
        },
      ),
    );
  }

  String _sub(Site s, double? dist, String lang) {
    final parts = <String>[];
    if (s.status.occupied || s.status == SiteStatus.done) {
      final who = [s.occupantName, s.occupantTeam].whereType<String>().join('·');
      final since = s.status == SiteStatus.done ? s.statusAt : (s.startedAt ?? s.statusAt);
      if (who.isNotEmpty) parts.add(who);
      if (since != null) {
        parts.add(s.status == SiteStatus.done ? tr('site.done_at', {'time': fmtTime(since)}) : '${fmtTime(since)}~ (${fmtElapsed(DateTime.now().difference(since), lang)})');
      }
    }
    if (dist != null) parts.add(fmtDistance(dist));
    return parts.join('  ');
  }
}

/// 하단 고정 작업 바: 작업중이면 경과 시간 + [일시중단][작업완료] — 완료 체크 누락 방지
class CurrentWorkBar extends StatefulWidget {
  const CurrentWorkBar({super.key, required this.site});
  final Site site;

  @override
  State<CurrentWorkBar> createState() => _CurrentWorkBarState();
}

class _CurrentWorkBarState extends State<CurrentWorkBar> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.site;
    final since = s.startedAt ?? s.statusAt;
    final buttons = switch (s.status) {
      SiteStatus.working => [
          OutlinedButton(onPressed: () => doPause(context, s), child: Text(tr('action.pause'))),
          FilledButton.icon(onPressed: () => doComplete(context, s), icon: const Icon(Icons.check), label: Text(tr('action.complete'))),
        ],
      SiteStatus.paused => [
          OutlinedButton(onPressed: () => doRelease(context, s), child: Text(tr('action.release'))),
          FilledButton(onPressed: () => doResume(context, s), child: Text(tr('action.resume'))),
        ],
      _ => [
          OutlinedButton(onPressed: () => doRelease(context, s), child: Text(tr('action.release'))),
          FilledButton(onPressed: () => doStart(context, s), child: Text(tr('action.start'))),
        ],
    };
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            InkWell(
              onTap: () => showSiteSheet(context, s.id),
              child: Row(children: [
                StatusChip(s.status, blink: !AppScope.of(context).batterySaver),
                const SizedBox(width: 8),
                Expanded(child: Text(s.bunji, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                if (since != null && s.status == SiteStatus.working)
                  Text(fmtClock(DateTime.now().difference(since)), style: const TextStyle(fontSize: 17, fontFeatures: [FontFeature.tabularFigures()])),
              ]),
            ),
            const SizedBox(height: 8),
            Row(children: [
              for (final b in buttons) ...[Expanded(child: b), const SizedBox(width: 8)],
            ]..removeLast()),
          ]),
        ),
      ),
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu();

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final me = st.me;
    void go(Widget page) {
      Navigator.pop(context);
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
    }

    return Drawer(
      child: ListView(children: [
        DrawerHeader(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
            Text(me?.name ?? '', style: Theme.of(context).textTheme.titleLarge),
            Text('${tr('role.${me?.role.name ?? 'worker'}')} · ${me?.loginId ?? ''}'),
          ]),
        ),
        ListTile(leading: const Icon(Icons.history), title: Text(tr('logs.title')), onTap: () => go(const LogsPage())),
        if (st.isAdmin || st.can('stats.view_team'))
          ListTile(leading: const Icon(Icons.bar_chart), title: Text(tr('stats.title')), onTap: () => go(const StatsPage())),
        if (st.can('urgent.send'))
          ListTile(
              leading: const Icon(Icons.campaign, color: Colors.red),
              title: Text(tr('urgent.title')),
              onTap: () {
                Navigator.pop(context);
                doUrgent(context);
              }),
        if (st.group?.kakaoFolderUrl != null)
          ListTile(leading: const Icon(Icons.star), title: Text(tr('home.kakao_folder')), onTap: () => openUrl(st.group!.kakaoFolderUrl!)),
        if (st.canManage) ListTile(leading: const Icon(Icons.admin_panel_settings), title: Text(tr('admin.title')), onTap: () => go(const AdminHome())),
        ListTile(leading: const Icon(Icons.settings), title: Text(tr('settings.title')), onTap: () => go(const SettingsPage())),
      ]),
    );
  }
}

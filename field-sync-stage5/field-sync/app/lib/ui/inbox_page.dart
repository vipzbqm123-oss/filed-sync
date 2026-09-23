// path: app/lib/ui/inbox_page.dart
// 알림함: 서버 알림(긴급·에스컬레이션·강제 해제·배포·재오픈). 열면 모두 읽음 처리.
import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../core/util.dart';
import '../data/models.dart';
import 'widgets.dart';

class InboxPage extends StatefulWidget {
  const InboxPage({super.key});

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  late final Future<List<AppNotif>> _f = _load();

  Future<List<AppNotif>> _load() async {
    final st = AppScope.read(context);
    final list = await st.api.notifications();
    final unread = list.where((n) => n.readAt == null).map((n) => n.id).toList();
    if (unread.isNotEmpty) {
      await st.api.markRead(unread);
      st.clearUnread();
    }
    return list;
  }

  static const _icons = {
    'urgent': Icons.warning_amber,
    'escalate': Icons.alarm,
    'force_release': Icons.lock_open,
    'publish': Icons.route,
    'reopen': Icons.replay,
    'remind': Icons.notifications,
  };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('inbox.title'))),
        body: FutureBuilder<List<AppNotif>>(
          future: _f,
          builder: (c, snap) {
            if (snap.hasError) return Center(child: Text(AppScope.read(c).errorText(snap.error!)));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            if (list.isEmpty) return Center(child: Text(tr('inbox.empty')));
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (c, i) {
                final n = list[i];
                final siteId = n.data['site_id'] as String?;
                return ListTile(
                  leading: Icon(_icons[n.kind] ?? Icons.notifications, color: n.kind == 'urgent' ? Colors.red : null),
                  title: Text(n.title, style: TextStyle(fontWeight: n.readAt == null ? FontWeight.bold : FontWeight.normal)),
                  subtitle: Text('${n.body}\n${fmtDateTime(n.createdAt)}'),
                  isThreeLine: true,
                  onTap: siteId == null
                      ? null
                      : () {
                          Navigator.pop(c);
                          AppScope.read(c).openSite.value = siteId;
                        },
                );
              },
            );
          },
        ),
      );
}

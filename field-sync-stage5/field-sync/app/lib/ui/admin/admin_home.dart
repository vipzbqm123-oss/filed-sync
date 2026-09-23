// path: app/lib/ui/admin/admin_home.dart
// 관리 메뉴: 권한에 따라 노출(서버 RLS·RPC가 최종 판정). 배포·등급·권한·정책은 관리자 고정.
import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../widgets.dart';
import 'groups_page.dart';
import 'perms_page.dart';
import 'policy_page.dart';
import 'templates_page.dart';
import 'users_page.dart';

class AdminHome extends StatelessWidget {
  const AdminHome({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    void go(Widget p) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => p));
    return Scaffold(
      appBar: AppBar(title: Text(tr('admin.title'))),
      body: ListView(children: [
        if (st.can('site.create') || st.can('site.edit'))
          ListTile(leading: const Icon(Icons.route), title: Text(tr('admin.groups')), subtitle: Text(tr('admin.groups_desc')), onTap: () => go(const GroupsPage())),
        if (st.isAdmin) ListTile(leading: const Icon(Icons.people), title: Text(tr('admin.users')), onTap: () => go(const UsersPage())),
        if (st.isAdmin) ListTile(leading: const Icon(Icons.security), title: Text(tr('admin.perms')), onTap: () => go(const PermsPage())),
        if (st.can('template.edit')) ListTile(leading: const Icon(Icons.checklist), title: Text(tr('admin.templates')), onTap: () => go(const TemplatesPage())),
        if (st.isAdmin) ListTile(leading: const Icon(Icons.timer), title: Text(tr('admin.policy')), onTap: () => go(const PolicyPage())),
      ]),
    );
  }
}

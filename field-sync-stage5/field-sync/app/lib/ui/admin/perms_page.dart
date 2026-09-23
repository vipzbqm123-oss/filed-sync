// path: app/lib/ui/admin/perms_page.dart
// 권한 매트릭스(관리자 전용): 등급(팀장·작업자) × 위임 가능 권한. 배포·등급·권한·정책은 위임 불가(고정 표시).
import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/util.dart';
import '../widgets.dart';

class PermsPage extends StatefulWidget {
  const PermsPage({super.key});

  @override
  State<PermsPage> createState() => _PermsPageState();
}

class _PermsPageState extends State<PermsPage> {
  // 서버 private.delegable_perms()와 동일 목록
  static const perms = ['site.create', 'site.edit', 'work.force_release', 'work.reopen', 'urgent.send', 'log.view_team', 'stats.view_team', 'template.edit'];
  static const fixed = ['site.publish', 'role.grant', 'user.manage', 'settings.edit'];
  Map<String, Set<String>>? _m;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final st = AppScope.read(context);
    try {
      final m = await st.api.rolePerms();
      if (mounted) setState(() => _m = m);
    } catch (e) {
      st.toast(st.errorText(e));
    }
  }

  Future<void> _toggle(String role, String perm, bool on) async {
    final st = AppScope.read(context);
    try {
      final r = await st.api.rpc('set_role_permission', {'p_role': role, 'p_perm': perm, 'p_granted': on, 'p_op_id': uuidV4()});
      if (!r.ok) st.toast(st.rejectText(r));
    } catch (e) {
      st.toast(st.errorText(e));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    return Scaffold(
      appBar: AppBar(title: Text(tr('admin.perms'))),
      body: m == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(tr('perms.perm'))),
                  DataColumn(label: Text(tr('role.admin'))),
                  DataColumn(label: Text(tr('role.leader'))),
                  DataColumn(label: Text(tr('role.worker'))),
                ],
                rows: [
                  for (final p in perms)
                    DataRow(cells: [
                      DataCell(Text(tr('perm.$p'))),
                      DataCell(Text(tr('perms.fixed'))),
                      for (final role in ['leader', 'worker'])
                        DataCell(Switch(value: m[role]?.contains(p) ?? false, onChanged: (v) => _toggle(role, p, v))),
                    ]),
                  for (final p in fixed)
                    DataRow(cells: [
                      DataCell(Text(tr('perm.$p'))),
                      DataCell(Text(tr('perms.fixed'))),
                      const DataCell(Text('✖')),
                      const DataCell(Text('✖')),
                    ]),
                ],
              ),
            ),
    );
  }
}

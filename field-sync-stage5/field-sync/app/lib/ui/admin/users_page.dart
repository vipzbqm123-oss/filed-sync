// path: app/lib/ui/admin/users_page.dart
// 사용자·등급·팀 관리(관리자 전용). 계정 발급·비밀번호·활성은 Edge Function(admin-users), 등급·팀은 RPC.
import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/util.dart';
import '../../data/models.dart';
import '../widgets.dart';

class UsersPage extends StatefulWidget {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  List<Profile> _users = [];
  List<Team> _teams = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final st = AppScope.read(context);
    try {
      final u = await st.api.profiles();
      final t = await st.api.teams();
      if (mounted) {
        setState(() {
          _users = u;
          _teams = t;
          _loading = false;
        });
      }
    } catch (e) {
      st.toast(st.errorText(e));
    }
  }

  String _team(String? id) => _teams.where((t) => t.id == id).firstOrNull?.name ?? tr('group.all_teams');

  Future<void> _call(Future<void> Function() f) async {
    final st = AppScope.read(context);
    try {
      await f();
      await _load();
    } catch (e) {
      st.toast(st.errorText(e));
    }
  }

  void _show(Map<String, dynamic> r) {
    final st = AppScope.read(context);
    final code = r['code'] as String?;
    // ok:true + AUTH_BAN_PENDING(DB 차단은 적용, 로그인 차단 재시도 필요)처럼 성공이어도 코드가 있으면 안내
    st.toast(r['ok'] == true && (code == null || code == 'OK') ? tr('common.saved') : tr('code.${code ?? 'UNKNOWN'}'));
  }

  /// 계정 발급: 로그인 ID·이름·초기 비밀번호·등급·팀
  Future<void> _create() async {
    final st = AppScope.read(context);
    final id = TextEditingController(), name = TextEditingController(), pw = TextEditingController();
    var role = Role.worker;
    String? team;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(tr('users.new')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: id, decoration: InputDecoration(labelText: tr('login.id'), helperText: tr('users.id_rule'))),
              TextField(controller: name, decoration: InputDecoration(labelText: tr('users.name'))),
              TextField(controller: pw, decoration: InputDecoration(labelText: tr('users.password'), helperText: tr('users.pw_rule'))),
              DropdownButtonFormField<Role>(
                initialValue: role,
                decoration: InputDecoration(labelText: tr('users.role')),
                items: [for (final r in Role.values) DropdownMenuItem(value: r, child: Text(tr('role.${r.name}')))],
                onChanged: (v) => set(() => role = v ?? Role.worker),
              ),
              DropdownButtonFormField<String?>(
                initialValue: team,
                decoration: InputDecoration(labelText: tr('group.team')),
                items: [DropdownMenuItem(value: null, child: Text(tr('users.no_team'))), for (final t in _teams) DropdownMenuItem(value: t.id, child: Text(t.name))],
                onChanged: (v) => set(() => team = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('common.ok'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _call(() async => _show(await st.api.invoke('admin-users', {
          'action': 'create',
          'login_id': id.text.trim(),
          'name': name.text.trim(),
          'password': pw.text,
          'role': role.name,
          'team_id': team,
          'lang': st.lang,
        })));
  }

  Future<void> _editRole(Profile u) async {
    final st = AppScope.read(context);
    final role = await askChoice<Role>(context, tr('users.role'), {for (final r in Role.values) r: tr('role.${r.name}')});
    if (role == null || !mounted) return;
    final team = await askChoice<String>(context, tr('group.team'), {'': tr('users.no_team'), for (final t in _teams) t.id: t.name});
    if (team == null) return;
    await _call(() async {
      final r = await st.api.rpc('set_user_role', {'p_user_id': u.id, 'p_role': role.name, 'p_team_id': team.isEmpty ? null : team, 'p_op_id': uuidV4()});
      st.toast(r.ok ? tr('common.saved') : st.rejectText(r));
    });
  }

  Future<void> _resetPw(Profile u) async {
    final st = AppScope.read(context);
    final pw = await askText(context, tr('users.reset_pw', {'name': u.name}), hint: tr('users.pw_rule'));
    if (pw == null) return;
    await _call(() async => _show(await st.api.invoke('admin-users', {'action': 'reset_password', 'user_id': u.id, 'password': pw})));
  }

  Future<void> _toggleActive(Profile u) async {
    final st = AppScope.read(context);
    if (!await confirm(context, u.active ? tr('users.deactivate') : tr('users.activate'), u.name)) return;
    await _call(() async => _show(await st.api.invoke('admin-users', {'action': u.active ? 'deactivate' : 'activate', 'user_id': u.id})));
  }

  Future<void> _addTeam() async {
    final st = AppScope.read(context);
    final name = await askText(context, tr('users.add_team'));
    if (name != null) await _call(() => st.api.addTeam(name));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('admin.users')), actions: [
          IconButton(onPressed: _addTeam, icon: const Icon(Icons.group_add), tooltip: tr('users.add_team')),
        ]),
        floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.person_add), label: Text(tr('users.new'))),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(children: [
                for (final u in _users)
                  ListTile(
                    leading: Icon(u.active ? Icons.person : Icons.person_off, color: u.active ? null : Colors.grey),
                    title: Text('${u.name} (${u.loginId})', style: TextStyle(color: u.active ? null : Colors.grey)),
                    subtitle: Text('${tr('role.${u.role.name}')} · ${_team(u.teamId)}${u.active ? '' : ' · ${tr('users.inactive')}'}'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (a) => switch (a) {
                        'role' => _editRole(u),
                        'pw' => _resetPw(u),
                        _ => _toggleActive(u),
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'role', child: Text(tr('users.change_role'))),
                        PopupMenuItem(value: 'pw', child: Text(tr('users.reset_pw_menu'))),
                        PopupMenuItem(value: 'active', child: Text(u.active ? tr('users.deactivate') : tr('users.activate'))),
                      ],
                    ),
                  ),
              ]),
      );
}

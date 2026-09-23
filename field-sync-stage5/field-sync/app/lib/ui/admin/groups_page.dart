// path: app/lib/ui/admin/groups_page.dart
// 동선(현장 묶음) 목록·생성 + 편집 화면(주소 검색 등록 · CSV 일괄 등록 · 즐겨찾기 링크 · 순서 · 팀·템플릿 · 배포).
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/util.dart';
import '../../data/models.dart';
import '../actions.dart';
import '../widgets.dart';

class GroupsPage extends StatefulWidget {
  const GroupsPage({super.key});

  @override
  State<GroupsPage> createState() => _GroupsPageState();
}

class _GroupsPageState extends State<GroupsPage> {
  Future<List<SiteGroup>>? _f;

  void _reload() {
    final f = AppScope.read(context).api.allGroups();
    setState(() {
      _f = f;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _f ??= AppScope.read(context).api.allGroups();
  }

  Future<void> _open(SiteGroup? g) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => GroupEditPage(group: g)));
    _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('admin.groups'))),
        floatingActionButton: AppScope.of(context).can('site.create')
            ? FloatingActionButton.extended(onPressed: () => _open(null), icon: const Icon(Icons.add), label: Text(tr('group.new')))
            : null,
        body: FutureBuilder<List<SiteGroup>>(
          future: _f,
          builder: (c, snap) {
            if (snap.hasError) return Center(child: Text(AppScope.read(c).errorText(snap.error!)));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return ListView(children: [
              for (final g in snap.data!.where((g) => !g.archived))
                ListTile(
                  title: Text(g.name),
                  subtitle: Text([g.workDate ?? '', g.published ? tr('group.published') : tr('group.draft')].where((e) => e.isNotEmpty).join(' · ')),
                  leading: Icon(g.published ? Icons.public : Icons.edit_note, color: g.published ? Colors.green : null),
                  onTap: () => _open(g),
                ),
            ]);
          },
        ),
      );
}

class GroupEditPage extends StatefulWidget {
  const GroupEditPage({super.key, this.group});
  final SiteGroup? group;

  @override
  State<GroupEditPage> createState() => _GroupEditPageState();
}

class _GroupEditPageState extends State<GroupEditPage> {
  SiteGroup? _g;
  final _name = TextEditingController(), _date = TextEditingController(), _link = TextEditingController();
  String? _teamId, _templateId;
  List<Team> _teams = [];
  List<Template> _templates = [];
  List<Site> _sites = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _g = widget.group;
    _name.text = _g?.name ?? '';
    _date.text = _g?.workDate ?? '';
    _link.text = _g?.kakaoFolderUrl ?? '';
    _teamId = _g?.teamId;
    _templateId = _g?.templateId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final st = AppScope.read(context);
    try {
      final teams = await st.api.teams();
      final tpls = await st.api.templates();
      final sites = _g == null ? <Site>[] : await st.api.sites(_g!.id);
      if (!mounted) return;
      setState(() {
        _teams = teams;
        _templates = tpls;
        _sites = sites.where((s) => !s.archived).toList();
      });
    } catch (e) {
      st.toast(st.errorText(e));
    }
  }

  Future<void> _run(Future<void> Function() f) async {
    final st = AppScope.read(context);
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      st.toast(st.errorText(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() => _run(() async {
        final st = AppScope.read(context);
        final date = _date.text.trim();
        if (_name.text.trim().isEmpty || (date.isNotEmpty && DateTime.tryParse(date) == null)) {
          st.toast(tr('group.invalid'));
          return;
        }
        final g = await st.api.saveGroup({
          'name': _name.text.trim(),
          'work_date': date.isEmpty ? null : date,
          'team_id': _teamId,
          'template_id': _templateId,
          'kakao_folder_url': _link.text.trim().isEmpty ? null : _link.text.trim(),
        }, id: _g?.id);
        setState(() => _g = g);
        st.toast(tr('common.saved'));
      });

  Future<void> _publish(bool on) => _run(() async {
        final st = AppScope.read(context);
        final r = await st.api.rpc('publish_group', {'p_group_id': _g!.id, 'p_published': on, 'p_op_id': uuidV4()});
        if (r.ok) {
          final g = r.raw['group'];
          if (g is Map) setState(() => _g = SiteGroup.fromJson(Map<String, dynamic>.from(g)));
          st.toast(on ? tr('group.published_msg', {'n': r.raw['site_count'] ?? 0}) : tr('group.unpublished_msg'));
          await st.refreshAll();
        } else {
          st.toast(st.rejectText(r));
        }
      });

  /// 주소 검색 → 후보 선택 → 세부·라벨·메모 입력 → 등록
  Future<void> _addBySearch() async {
    final st = AppScope.read(context);
    final q = await askText(context, tr('group.search'), hint: tr('group.search_hint'));
    if (q == null || !mounted) return;
    List<dynamic> cands;
    try {
      cands = (await st.api.invoke('geocode', {'mode': 'search', 'query': q}))['candidates'] as List<dynamic>? ?? [];
    } catch (e) {
      st.toast(st.errorText(e));
      return;
    }
    if (!mounted) return;
    if (cands.isEmpty) {
      st.toast(tr('group.no_result'));
      return;
    }
    final pick = await askChoice<int>(context, tr('group.pick'), {
      for (var i = 0; i < cands.length; i++) i: '${cands[i]['bunji']}\n${cands[i]['road'] ?? cands[i]['jibun']}',
    });
    if (pick == null || !mounted) return;
    final c = Map<String, dynamic>.from(cands[pick] as Map);
    final unit = await askText(context, tr('group.unit'), hint: tr('group.unit_hint'), required: false);
    if (unit == null) return;
    await _run(() async {
      await st.api.insertSite({
        'group_id': _g!.id,
        'seq': (_sites.isEmpty ? 0 : _sites.map((s) => s.seq).reduce((a, b) => a > b ? a : b)) + 1,
        'bunji': c['bunji'],
        'jibun': c['jibun'],
        'road': c['road'],
        'unit': unit,
        'lat': c['lat'],
        'lng': c['lng'],
        'b_code': c['b_code'],
        'jibun_key': c['jibun_key'],
      });
      await _load();
    });
  }

  /// CSV(UTF-8) 일괄 등록 → 결과(등록·중복·실패 행) 표시
  Future<void> _importCsv() async {
    final st = AppScope.read(context);
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['csv']);
    if (f == null) return;
    final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
    if (text.contains('�')) {
      st.toast(tr('csv.not_utf8')); // 엑셀 기본 CSV(CP949) → "CSV UTF-8"로 저장 안내
      return;
    }
    await _run(() async {
      final r = await st.api.invoke('geocode', {'mode': 'import', 'group_id': _g!.id, 'csv': text});
      await _load();
      if (!mounted) return;
      String rows(Object? v) => (v as List? ?? []).map((e) => '${e['row']}${tr('csv.row')}: ${e['reason']}').join('\n');
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('csv.result', {'n': r['inserted'] ?? 0})),
          content: SingleChildScrollView(
            child: Text([
              if ((r['duplicates'] as List? ?? []).isNotEmpty) '${tr('csv.duplicates')}\n${rows(r['duplicates'])}',
              if ((r['failed'] as List? ?? []).isNotEmpty) '${tr('csv.failed')}\n${rows(r['failed'])}',
            ].join('\n\n')),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok')))],
        ),
      );
    });
  }

  /// 드래그로 동선 순서 변경 → 바뀐 행만 seq 갱신. O(n) 요청
  Future<void> _reorder(int from, int to) async {
    final st = AppScope.read(context);
    if (to > from) to--;
    setState(() => _sites.insert(to, _sites.removeAt(from)));
    await _run(() async {
      for (var i = 0; i < _sites.length; i++) {
        if (_sites[i].seq != i + 1) await st.api.updateSite(_sites[i].id, {'seq': i + 1});
      }
      await _load();
    });
  }

  Future<void> _archive(Site s) async {
    final st = AppScope.read(context);
    if (!await confirm(context, tr('group.archive'), s.bunji)) return;
    await _run(() async {
      await st.api.updateSite(s.id, {'archived': true});
      await _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final g = _g;
    final ro = g != null && g.published && !st.isAdmin; // 배포된 동선 = 전달 완료 → 관리자만 수정(서버 RLS와 동일)
    return Scaffold(
      appBar: AppBar(title: Text(g?.name ?? tr('group.new')), actions: [
        IconButton(onPressed: _busy || ro ? null : _save, icon: const Icon(Icons.save), tooltip: tr('common.save')),
      ]),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(padding: const EdgeInsets.all(12), children: [
          if (_busy) const LinearProgressIndicator(),
          if (g != null && st.isAdmin)
            SwitchListTile(
              value: g.published,
              onChanged: _publish,
              title: Text(tr('group.publish')),
              subtitle: Text(tr('group.publish_desc')),
            ),
          if (g != null && !st.isAdmin) ListTile(leading: const Icon(Icons.info_outline), title: Text(tr('group.publish_admin_only'))),
          TextField(controller: _name, enabled: !ro, decoration: InputDecoration(labelText: tr('group.name'))),
          TextField(controller: _date, enabled: !ro, decoration: InputDecoration(labelText: tr('group.date'), hintText: '2026-09-23')),
          DropdownButtonFormField<String?>(
            key: ValueKey('team${_teams.length}'),
            initialValue: _teams.any((t) => t.id == _teamId) ? _teamId : null,
            decoration: InputDecoration(labelText: tr('group.team')),
            items: [DropdownMenuItem(value: null, child: Text(tr('group.all_teams'))), for (final t in _teams) DropdownMenuItem(value: t.id, child: Text(t.name))],
            onChanged: ro ? null : (v) => setState(() => _teamId = v),
          ),
          DropdownButtonFormField<String?>(
            key: ValueKey('tpl${_templates.length}'),
            initialValue: _templates.any((t) => t.id == _templateId) ? _templateId : null,
            decoration: InputDecoration(labelText: tr('group.template')),
            items: [DropdownMenuItem(value: null, child: Text(tr('group.no_template'))), for (final t in _templates) DropdownMenuItem(value: t.id, child: Text(t.name))],
            onChanged: ro ? null : (v) => setState(() => _templateId = v),
          ),
          Row(children: [
            Expanded(child: TextField(controller: _link, enabled: !ro, decoration: InputDecoration(labelText: tr('group.kakao_link'), hintText: 'https://kko.to/...'))),
            IconButton(onPressed: _link.text.startsWith('https://') ? () => openUrl(_link.text) : null, icon: const Icon(Icons.open_in_new)),
          ]),
          const SizedBox(height: 12),
          if (g == null) Text(tr('group.save_first'))
          else ...[
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: ro ? null : _addBySearch, icon: const Icon(Icons.search), label: Text(tr('group.add_search')))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: ro ? null : _importCsv, icon: const Icon(Icons.upload_file), label: Text(tr('group.add_csv')))),
            ]),
            const SizedBox(height: 8),
            Text(tr('group.sites', {'n': _sites.length}), style: Theme.of(context).textTheme.titleMedium),
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: !ro,
              onReorder: ro ? (_, __) {} : _reorder,
              children: [
                for (var i = 0; i < _sites.length; i++)
                  ListTile(
                    key: ValueKey(_sites[i].id),
                    leading: Text('${i + 1}'),
                    title: Text(_sites[i].bunji),
                    subtitle: Text([_sites[i].unit, _sites[i].status.db].where((e) => e.isNotEmpty).join(' · ')),
                    trailing: IconButton(icon: const Icon(Icons.archive_outlined), onPressed: ro ? null : () => _archive(_sites[i])),
                  ),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}

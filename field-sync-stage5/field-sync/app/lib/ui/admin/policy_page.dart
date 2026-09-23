// path: app/lib/ui/admin/policy_page.dart
// 알림·점유 정책(관리자 전용). 분 단위로 저장되며 화면은 "시간·분"으로 입력. 서버 CHECK가 범위 검증.
import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/util.dart';
import '../widgets.dart';

class PolicyPage extends StatefulWidget {
  const PolicyPage({super.key});

  @override
  State<PolicyPage> createState() => _PolicyPageState();
}

class _PolicyPageState extends State<PolicyPage> {
  // 키 → (라벨 키, 시간 입력 여부)
  static const _fields = {
    'remind_working_first_min': ('policy.first', true),
    'remind_working_repeat_min': ('policy.repeat', true),
    'remind_max': ('policy.max', false),
    'escalate_at': ('policy.escalate', false),
    'remind_en_route_after_min': ('policy.en_route', true),
    'remind_paused_after_min': ('policy.paused', true),
    'max_claims_per_user': ('policy.claims', false),
    'arrive_radius_m': ('policy.radius', false),
    'undo_complete_window_min': ('policy.undo', false),
  };
  final Map<String, TextEditingController> _h = {}, _m = {};
  final _minVer = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_m.isNotEmpty) return;
    final j = AppScope.read(context).settings.j;
    for (final e in _fields.entries) {
      final v = (j[e.key] as num?)?.toInt() ?? 0;
      if (e.value.$2) {
        _h[e.key] = TextEditingController(text: '${v ~/ 60}');
        _m[e.key] = TextEditingController(text: '${v % 60}');
      } else {
        _m[e.key] = TextEditingController(text: '$v');
      }
    }
    _minVer.text = '${j['min_app_version'] ?? '1.0.0'}';
  }

  Future<void> _save() async {
    final st = AppScope.read(context);
    final body = <String, dynamic>{'min_app_version': _minVer.text.trim()};
    for (final k in _fields.keys) {
      final h = int.tryParse(_h[k]?.text ?? '0') ?? 0;
      final m = int.tryParse(_m[k]!.text) ?? 0;
      body[k] = h * 60 + m;
    }
    try {
      final r = await st.api.rpc('update_settings', {'p_settings': body, 'p_op_id': uuidV4()});
      st.toast(r.ok ? tr('common.saved') : st.rejectText(r));
      if (r.ok) await st.refreshAll();
    } catch (e) {
      st.toast(st.errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('admin.policy')), actions: [IconButton(onPressed: _save, icon: const Icon(Icons.save))]),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          for (final e in _fields.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Expanded(flex: 3, child: Text(tr(e.value.$1))),
                if (e.value.$2) ...[
                  SizedBox(width: 64, child: TextField(controller: _h[e.key], keyboardType: TextInputType.number, decoration: InputDecoration(suffixText: tr('unit.hour')))),
                  const SizedBox(width: 8),
                ],
                SizedBox(
                  width: 72,
                  child: TextField(controller: _m[e.key], keyboardType: TextInputType.number, decoration: InputDecoration(suffixText: e.value.$2 ? tr('unit.min') : null)),
                ),
              ]),
            ),
          TextField(controller: _minVer, decoration: InputDecoration(labelText: tr('policy.min_version'))),
          const SizedBox(height: 12),
          Text(tr('policy.note'), style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

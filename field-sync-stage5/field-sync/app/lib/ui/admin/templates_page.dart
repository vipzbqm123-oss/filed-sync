// path: app/lib/ui/admin/templates_page.dart
// 체크 템플릿(상하수도 항목) 목록·편집. 형식은 서버 CHECK(valid_template_items)와 동일 규칙.
import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../data/models.dart';
import '../widgets.dart';

class TemplatesPage extends StatefulWidget {
  const TemplatesPage({super.key});

  @override
  State<TemplatesPage> createState() => _TemplatesPageState();
}

class _TemplatesPageState extends State<TemplatesPage> {
  Future<List<Template>>? _f;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _f ??= AppScope.read(context).api.templates();
  }

  Future<void> _open(Template? t) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => TemplateEditPage(template: t)));
    if (!mounted) return;
    final f = AppScope.read(context).api.templates();
    setState(() {
      _f = f;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('admin.templates'))),
        floatingActionButton: FloatingActionButton(onPressed: () => _open(null), child: const Icon(Icons.add)),
        body: FutureBuilder<List<Template>>(
          future: _f,
          builder: (c, snap) {
            if (snap.hasError) return Center(child: Text(AppScope.read(c).errorText(snap.error!)));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return ListView(children: [
              for (final t in snap.data!)
                ListTile(title: Text(t.name), subtitle: Text(tr('tpl.summary', {'n': t.items.length, 'photo': t.requirePhoto})), onTap: () => _open(t)),
            ]);
          },
        ),
      );
}

class _Row {
  _Row(this.key, CheckItem? it)
      : section = TextEditingController(text: it?.section ?? ''),
        label = TextEditingController(text: it?.label ?? ''),
        options = TextEditingController(text: it?.options.join(', ') ?? ''),
        unit = TextEditingController(text: it?.unit ?? ''),
        min = TextEditingController(text: it?.min?.toString() ?? ''),
        max = TextEditingController(text: it?.max?.toString() ?? ''),
        type = it?.type ?? 'bool',
        required = it?.required ?? true;

  final String key;
  final TextEditingController section, label, options, unit, min, max;
  String type;
  bool required;

  Map<String, dynamic> toJson() => CheckItem(
        key: key,
        label: label.text.trim(),
        type: type,
        section: section.text.trim(),
        required: required,
        options: type == 'select' ? options.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList() : const [],
        unit: unit.text.trim().isEmpty ? null : unit.text.trim(),
        min: type == 'number' ? num.tryParse(min.text.trim()) : null,
        max: type == 'number' ? num.tryParse(max.text.trim()) : null,
      ).toJson();
}

class TemplateEditPage extends StatefulWidget {
  const TemplateEditPage({super.key, this.template});
  final Template? template;

  @override
  State<TemplateEditPage> createState() => _TemplateEditPageState();
}

class _TemplateEditPageState extends State<TemplateEditPage> {
  late final _name = TextEditingController(text: widget.template?.name ?? '');
  late int _photo = widget.template?.requirePhoto ?? 1;
  late bool _sig = widget.template?.requireSignature ?? false;
  late final List<_Row> _rows = [for (final it in widget.template?.items ?? const <CheckItem>[]) _Row(it.key, it)];

  /// 새 항목 key: 서버 규칙 ^[a-z][a-z0-9_]{0,31}$, 기존 key와 중복 없이
  String _newKey() {
    var n = _rows.length + 1;
    while (_rows.any((r) => r.key == 'item_$n')) {
      n++;
    }
    return 'item_$n';
  }

  Future<void> _save() async {
    final st = AppScope.read(context);
    if (_name.text.trim().isEmpty || _rows.any((r) => r.label.text.trim().isEmpty)) {
      st.toast(tr('tpl.invalid'));
      return;
    }
    try {
      await st.api.saveTemplate({
        'name': _name.text.trim(),
        'require_photo': _photo,
        'require_signature': _sig,
        'items': [for (final r in _rows) r.toJson()],
      }, id: widget.template?.id);
      st.toast(tr('common.saved'));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      st.toast(st.errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.template?.name ?? tr('tpl.new')), actions: [IconButton(onPressed: _save, icon: const Icon(Icons.save))]),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => setState(() => _rows.add(_Row(_newKey(), null))),
          icon: const Icon(Icons.add),
          label: Text(tr('tpl.add_item')),
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
          TextField(controller: _name, decoration: InputDecoration(labelText: tr('tpl.name'))),
          Row(children: [
            Expanded(child: Text(tr('tpl.photo', {'n': _photo}))),
            IconButton(onPressed: _photo > 0 ? () => setState(() => _photo--) : null, icon: const Icon(Icons.remove)),
            IconButton(onPressed: _photo < 10 ? () => setState(() => _photo++) : null, icon: const Icon(Icons.add)),
          ]),
          SwitchListTile(value: _sig, onChanged: (v) => setState(() => _sig = v), title: Text(tr('tpl.signature'))),
          for (final r in _rows)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(children: [
                  Row(children: [
                    Expanded(child: TextField(controller: r.section, decoration: InputDecoration(labelText: tr('tpl.section')))),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: r.type,
                      items: [for (final t in ['bool', 'select', 'number', 'text']) DropdownMenuItem(value: t, child: Text(tr('tpl.type.$t')))],
                      onChanged: (v) => setState(() => r.type = v ?? 'bool'),
                    ),
                    IconButton(onPressed: () => setState(() => _rows.remove(r)), icon: const Icon(Icons.delete_outline)),
                  ]),
                  TextField(controller: r.label, decoration: InputDecoration(labelText: tr('tpl.label'))),
                  if (r.type == 'select') TextField(controller: r.options, decoration: InputDecoration(labelText: tr('tpl.options'))),
                  if (r.type == 'number')
                    Row(children: [
                      Expanded(child: TextField(controller: r.unit, decoration: InputDecoration(labelText: tr('tpl.unit')))),
                      Expanded(child: TextField(controller: r.min, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr('tpl.min')))),
                      Expanded(child: TextField(controller: r.max, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr('tpl.max')))),
                    ]),
                  SwitchListTile(dense: true, value: r.required, onChanged: (v) => setState(() => r.required = v), title: Text(tr('tpl.required'))),
                ]),
              ),
            ),
        ]),
      );
}

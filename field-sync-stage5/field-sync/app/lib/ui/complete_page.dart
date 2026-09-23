// path: app/lib/ui/complete_page.dart
// 작업완료: 템플릿 체크 항목(상하수도) · 메모 · 사진(최소 n장) · 서명 → 누락 항목을 보여주고 모두 채워야 제출.
// 사진·서명은 앱 전용 폴더에 먼저 저장 후 업로드 대기열에 넣으므로 오프라인에서도 유실되지 않음.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/i18n.dart';
import '../data/models.dart';
import 'signature_pad.dart';
import 'widgets.dart';

class CompletePage extends StatefulWidget {
  const CompletePage({super.key, required this.siteId});
  final String siteId;

  @override
  State<CompletePage> createState() => _CompletePageState();
}

class _CompletePageState extends State<CompletePage> {
  final Map<String, dynamic> _values = {};
  final _note = TextEditingController();
  final _sig = SignatureController();
  final List<Uint8List> _photos = [];
  int _serverPhotos = 0;
  bool _serverSig = false, _sigSaved = false, _busy = false, _loaded = false;
  double _padWidth = 320;
  bool _sigEmpty = true;

  @override
  void initState() {
    super.initState();
    _sig.addListener(() {
      if (_sig.isEmpty != _sigEmpty && mounted) setState(() => _sigEmpty = _sig.isEmpty); // 비었는지 바뀔 때만 다시 그림
    });
  }

  @override
  void dispose() {
    _sig.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final st = AppScope.read(context);
    final ses = st.mySessions[widget.siteId];
    _values.addAll(ses?.checks ?? const {});
    if (ses != null && st.online) _loadServerProof(st.api.attachments(ses.id));
  }

  /// 이미 업로드된 증빙 수(온라인일 때). 실패해도 화면 사용에 지장 없음
  Future<void> _loadServerProof(Future<List<Map<String, dynamic>>> f) async {
    try {
      final rows = await f;
      if (!mounted) return;
      setState(() {
        _serverPhotos = rows.where((r) => r['kind'] == 'photo').length;
        _serverSig = rows.any((r) => r['kind'] == 'signature');
      });
    } catch (_) {}
  }

  Future<void> _addPhoto(Site s) async {
    final src = await askChoice<ImageSource>(context, tr('complete.photo_add'), {ImageSource.camera: tr('complete.camera'), ImageSource.gallery: tr('complete.gallery')});
    if (src == null) return;
    final x = await ImagePicker().pickImage(source: src, maxWidth: 1600, imageQuality: 75); // 약 200~400KB(추정)
    if (x == null || !mounted) return;
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    await AppScope.read(context).addEvidence(s, 'photo', bytes, ext: 'jpg');
    setState(() => _photos.add(bytes));
  }

  Future<void> _saveSignature(Site s) async {
    if (_sig.isEmpty) return;
    final st = AppScope.read(context);
    final png = await _sig.toPng(Size(_padWidth, 180));
    if (png == null) return;
    await st.addEvidence(s, 'signature', png, ext: 'png');
    if (mounted) setState(() => _sigSaved = true);
  }

  Future<void> _submit(Site s) async {
    final st = AppScope.read(context);
    setState(() => _busy = true);
    if (!_sigSaved && !_sig.isEmpty) await _saveSignature(s); // 그린 서명은 자동 저장
    await st.complete(s, Map.of(_values), _note.text.trim());
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final s = st.sites[widget.siteId];
    if (s == null || !st.isMine(s) || s.status != SiteStatus.working) {
      return Scaffold(appBar: AppBar(), body: Center(child: Text(tr('complete.not_working'))));
    }
    final tpl = st.template;
    final needPhoto = tpl?.requirePhoto ?? 0;
    final havePhoto = _serverPhotos + _photos.length;
    final needSig = tpl?.requireSignature ?? false;
    final missing = <String>[
      for (final k in tpl?.missing(_values) ?? const <String>[]) tpl!.items.firstWhere((i) => i.key == k).label,
      if (havePhoto < needPhoto) tr('complete.need_photo', {'n': needPhoto - havePhoto}),
      if (needSig && !_serverSig && !_sigSaved && _sigEmpty) tr('proof.signature'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('${tr('action.complete')} · ${s.bunji}'),
        actions: [
          TextButton(
            onPressed: () {
              st.saveChecks(s, Map.of(_values));
              st.toast(tr('complete.draft_saved'));
            },
            child: Text(tr('complete.draft')),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (tpl == null) Text(tr('complete.no_template')),
        ..._items(tpl),
        const SizedBox(height: 12),
        TextField(controller: _note, maxLength: 2000, maxLines: 3, decoration: InputDecoration(labelText: tr('complete.note'), border: const OutlineInputBorder())),
        const SizedBox(height: 12),
        Text('${tr('proof.photo')} ${needPhoto > 0 ? '(${tr('complete.min', {'n': needPhoto})})' : ''} · $havePhoto', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in _photos) ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(p, width: 88, height: 88, fit: BoxFit.cover)),
          SizedBox(
            width: 88,
            height: 88,
            child: OutlinedButton(onPressed: () => _addPhoto(s), child: const Icon(Icons.add_a_photo, size: 32)),
          ),
        ]),
        Text(tr('complete.photo_meta'), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        Text('${tr('proof.signature')}${needSig ? ' *' : ''}${_serverSig || _sigSaved ? ' ✓' : ''}', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (c, box) {
          _padWidth = box.maxWidth;
          return SignaturePad(controller: _sig);
        }),
        Row(children: [
          TextButton(onPressed: _sig.clear, child: Text(tr('complete.sig_clear'))),
          TextButton(onPressed: _sigSaved ? null : () => _saveSignature(s), child: Text(tr('complete.sig_save'))),
        ]),
        const SizedBox(height: 8),
        if (missing.isNotEmpty)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(padding: const EdgeInsets.all(12), child: Text('${tr('complete.missing')}: ${missing.join(', ')}')),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: missing.isEmpty && !_busy ? () => _submit(s) : null,
          icon: const Icon(Icons.check),
          label: Text(tr('complete.submit')),
        ),
      ]),
    );
  }

  List<Widget> _items(Template? tpl) {
    if (tpl == null) return const [];
    final out = <Widget>[];
    String? section;
    for (final it in tpl.items) {
      if (it.section != section) {
        section = it.section;
        if (section.isNotEmpty) {
          out.add(Padding(padding: const EdgeInsets.only(top: 12, bottom: 4), child: Text(section, style: Theme.of(context).textTheme.titleMedium)));
        }
      }
      out.add(_Item(
        item: it,
        value: _values[it.key],
        onChanged: (v) => setState(() {
          if (v == null) {
            _values.remove(it.key);
          } else {
            _values[it.key] = v;
          }
        }),
      ));
    }
    return out;
  }
}

/// 항목 타입별 입력 위젯 (bool=예/아니오, select=선택 칩, number=숫자, text=글)
class _Item extends StatelessWidget {
  const _Item({required this.item, required this.value, required this.onChanged});
  final CheckItem item;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = '${item.label}${item.required ? ' *' : ''}${item.unit != null ? ' (${item.unit})' : ''}';
    final invalid = value != null && !item.valid(value);
    Widget input;
    switch (item.type) {
      case 'bool':
        input = SegmentedButton<bool>(
          segments: [ButtonSegment(value: true, label: Text(tr('common.yes'))), ButtonSegment(value: false, label: Text(tr('common.no')))],
          selected: value is bool ? {value as bool} : <bool>{},
          emptySelectionAllowed: true,
          onSelectionChanged: (s) => onChanged(s.isEmpty ? null : s.first),
        );
      case 'select':
        input = Wrap(spacing: 8, children: [
          for (final o in item.options) ChoiceChip(label: Text(o), selected: value == o, onSelected: (on) => onChanged(on ? o : null)),
        ]);
      case 'number':
        input = TextFormField(
          initialValue: value?.toString() ?? '',
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            errorText: invalid ? tr('complete.range', {'min': item.min ?? '-', 'max': item.max ?? '-'}) : null,
          ),
          onChanged: (t) {
            final n = num.tryParse(t.trim());
            onChanged(n == null ? null : (n == n.roundToDouble() && !t.contains('.') ? n.toInt() : n));
          },
        );
      default:
        input = TextFormField(initialValue: value?.toString() ?? '', maxLength: 500, onChanged: (t) => onChanged(t.trim().isEmpty ? null : t.trim()));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 6),
        input,
      ]),
    );
  }
}

// path: app/lib/ui/widgets.dart
// 공용 위젯: 상태 칩(깜빡임) · 복사 텍스트 · 입력 대화상자 · 전역 상태 접근(AppScope).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/i18n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';

/// 전역 상태 주입(InheritedNotifier): of = 변경 시 재빌드, read = 읽기만
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppState read(BuildContext c) => c.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

/// 1Hz 페이드 깜빡임(초당 3회 미만: WCAG 2.3.1). 절약 모드·동작 줄이기 설정 시 정지
class Blink extends StatefulWidget {
  const Blink({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  State<Blink> createState() => _BlinkState();
}

class _BlinkState extends State<Blink> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));

  @override
  Widget build(BuildContext context) {
    final on = widget.enabled && !MediaQuery.of(context).disableAnimations;
    if (on && !_c.isAnimating) _c.repeat(reverse: true);
    if (!on && _c.isAnimating) _c.stop();
    return on ? FadeTransition(opacity: Tween(begin: 1.0, end: 0.35).animate(_c), child: widget.child) : widget.child;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }
}

/// 상태 표기: 색 + 아이콘 + 텍스트 (+ 작업중 깜빡임)
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.big = false, this.blink = true, this.pending = false});
  final SiteStatus status;
  final bool big, blink, pending;

  @override
  Widget build(BuildContext context) {
    final st = StatusStyle.of(status);
    final chip = Container(
      padding: EdgeInsets.symmetric(horizontal: big ? 14 : 8, vertical: big ? 8 : 4),
      decoration: BoxDecoration(
        color: st.bg,
        borderRadius: BorderRadius.circular(8),
        border: pending ? Border.all(color: Colors.black54, width: 2, strokeAlign: BorderSide.strokeAlignOutside) : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(st.icon, color: st.fg, size: big ? 22 : 16),
        const SizedBox(width: 4),
        Text(st.label, style: TextStyle(color: st.fg, fontWeight: FontWeight.bold, fontSize: big ? 18 : 13)),
        if (pending) ...[const SizedBox(width: 4), Icon(Icons.cloud_upload_outlined, color: st.fg, size: big ? 18 : 14)],
      ]),
    );
    return Semantics(label: st.label, child: Blink(enabled: blink && status == SiteStatus.working, child: chip));
  }
}

/// 한 번 탭 = 클립보드 복사 + 진동 + "복사됨"
class CopyText extends StatelessWidget {
  const CopyText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: text));
          await HapticFeedback.mediumImpact();
          if (context.mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(tr('msg.copied', {'text': text})), duration: const Duration(seconds: 2)));
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(text, style: style)),
            const Icon(Icons.copy, size: 20),
          ]),
        ),
      );
}

/// 텍스트 입력 대화상자 (사유 등). 빈 값이면 확인 비활성
Future<String?> askText(BuildContext context, String title, {String hint = '', bool required = true, String initial = ''}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctl, autofocus: true, maxLength: 500, decoration: InputDecoration(hintText: hint), onChanged: (_) => set(() {})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.cancel'))),
          FilledButton(
              onPressed: required && ctl.text.trim().isEmpty ? null : () => Navigator.pop(c, ctl.text.trim()),
              child: Text(tr('common.ok'))),
        ],
      ),
    ),
  );
}

/// 선택지 대화상자
Future<T?> askChoice<T>(BuildContext context, String title, Map<T, String> options) => showDialog<T>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(title),
        children: [
          for (final e in options.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, e.key),
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(e.value, style: const TextStyle(fontSize: 17))),
            ),
        ],
      ),
    );

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('common.ok'))),
        ],
      ),
    ) ==
    true;

class Banner2 extends StatelessWidget {
  const Banner2({super.key, required this.icon, required this.text, required this.color, this.onTap, this.fg = Colors.white});
  final IconData icon;
  final String text;
  final Color color, fg;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(icon, color: fg),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w600))),
              if (onTap != null) Icon(Icons.chevron_right, color: fg),
            ]),
          ),
        ),
      );
}

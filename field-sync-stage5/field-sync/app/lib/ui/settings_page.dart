// path: app/lib/ui/settings_page.dart
// 설정: 테마(다크·야외 고대비) · 언어 · 배터리 절약 · 큰 글씨 · 거리순 정렬 · 알림 테스트 · 로그아웃.
import 'package:flutter/material.dart';

import '../config.dart';
import '../core/i18n.dart';
import '../core/theme.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('settings.title'))),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Text(tr('settings.theme'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        SegmentedButton<ThemeChoice>(
          segments: [for (final t in ThemeChoice.values) ButtonSegment(value: t, label: Text(tr('theme.${t.name}')))],
          selected: {st.theme},
          onSelectionChanged: (s) => st.setTheme(s.first),
        ),
        const SizedBox(height: 16),
        Text(tr('settings.lang'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: [for (final l in I18n.supported) ButtonSegment(value: l, label: Text(I18n.names[l]!))],
          selected: {st.lang},
          onSelectionChanged: (s) => st.setLang(s.first),
        ),
        const SizedBox(height: 16),
        Text(tr('settings.font'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        SegmentedButton<double>(
          segments: [
            ButtonSegment(value: 1.0, label: Text(tr('font.normal'))),
            ButtonSegment(value: 1.2, label: Text(tr('font.large'))),
            ButtonSegment(value: 1.4, label: Text(tr('font.xlarge'))),
          ],
          selected: {st.fontScale},
          onSelectionChanged: (s) => st.setFontScale(s.first),
        ),
        const Divider(height: 32),
        SwitchListTile(
          value: st.batterySaver,
          onChanged: st.setBatterySaver,
          title: Text(tr('settings.battery')),
          subtitle: Text(tr('settings.battery_desc')),
        ),
        SwitchListTile(
          value: st.sortNearest,
          onChanged: st.setSortNearest,
          title: Text(tr('settings.nearest')),
          subtitle: Text(tr('settings.nearest_desc')),
        ),
        ListTile(
          leading: const Icon(Icons.notifications_active),
          title: Text(tr('settings.notif_test')),
          onTap: () => st.reminders?.test(),
        ),
        ListTile(leading: const Icon(Icons.info_outline), title: Text(tr('settings.version')), trailing: Text(Config.appVersion)),
        const Divider(height: 32),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.logout),
          label: Text(tr('settings.logout')),
          onPressed: () async {
            final pending = st.outbox.length;
            final ok = await confirm(context, tr('settings.logout'), pending > 0 ? tr('settings.logout_pending', {'n': pending}) : tr('settings.logout_confirm'));
            if (!ok) return;
            await st.logout();
            if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
          },
        ),
      ]),
    );
  }
}

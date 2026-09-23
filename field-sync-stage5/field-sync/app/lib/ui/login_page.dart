// path: app/lib/ui/login_page.dart
import 'package:flutter/material.dart';

import '../core/i18n.dart';
import 'widgets.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _id = TextEditingController();
  final _pw = TextEditingController();
  bool _busy = false, _hide = true;
  String? _error;

  Future<void> _submit() async {
    if (_id.text.trim().isEmpty || _pw.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AppScope.read(context).login(_id.text, _pw.text);
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Icon(Icons.location_on, size: 64),
                Text('FieldSync', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(tr('login.subtitle'), textAlign: TextAlign.center),
                const SizedBox(height: 24),
                SegmentedButton<String>(
                  segments: [for (final l in I18n.supported) ButtonSegment(value: l, label: Text(I18n.names[l]!))],
                  selected: {state.lang},
                  onSelectionChanged: (s) => state.setLang(s.first),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _id,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(labelText: tr('login.id'), prefixIcon: const Icon(Icons.person)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pw,
                  obscureText: _hide,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: tr('login.password'),
                    prefixIcon: const Icon(Icons.lock),
                    suffixIcon: IconButton(icon: Icon(_hide ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _hide = !_hide)),
                  ),
                ),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                const SizedBox(height: 20),
                FilledButton(onPressed: _busy ? null : _submit, child: _busy ? const CircularProgressIndicator() : Text(tr('login.submit'))),
                const SizedBox(height: 12),
                Text(tr('login.help'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

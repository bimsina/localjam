/// Settings: appearance and identity.
///
/// Deliberately short. Room behaviour (who may do what, sync nudge) belongs
/// where you can see its effect — in the room — not in a global settings list.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/app_settings.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/section.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _identity = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final name = await JamIdentity.displayName();
    if (mounted) setState(() => _identity = name);
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _identity);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your name in the room'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await JamIdentity.setDisplayName(name);
    if (mounted) setState(() => _identity = name);
  }

  @override
  Widget build(BuildContext context) {
    final settings = JamSettings.of(context);
    final colors = context.jamColors;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.page,
            JamSpace.sm,
            JamSpace.page,
            JamSpace.huge,
          ),
          children: [
            JamSection(
              title: 'You',
              child: ListTile(
                onTap: () => unawaited(_rename()),
                leading: _identity.isEmpty
                    ? null
                    : PeerAvatar(name: _identity, size: 44),
                title: Text(
                  _identity.isEmpty ? 'Loading…' : _identity,
                  style: context.jamRowTitle,
                ),
                subtitle: const Text('How you appear in rooms'),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  color: colors.textTertiary,
                ),
              ),
            ),
            const SizedBox(height: JamSpace.section),
            JamSection(
              title: 'Appearance',
              child: RadioGroup<ThemeMode>(
                groupValue: settings.themeMode,
                onChanged: (value) =>
                    unawaited(settings.setThemeMode(value ?? ThemeMode.system)),
                child: Column(
                  children: [
                    for (final mode in ThemeMode.values)
                      RadioListTile<ThemeMode>(
                        value: mode,
                        title: Text(_label(mode), style: context.jamBody),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'Match my device',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };
}

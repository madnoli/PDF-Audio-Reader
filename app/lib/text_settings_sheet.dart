import 'package:flutter/material.dart';

import 'text_settings.dart';

/// Bottom sheet for adjusting how book text looks. Changes apply live to the page behind it.
class TextSettingsSheet extends StatelessWidget {
  const TextSettingsSheet({super.key, required this.settings});
  final TextSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Text', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              _row(
                context,
                label: 'Size',
                value: '${settings.fontSize.round()}',
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Smaller',
                      icon: const Icon(Icons.text_decrease),
                      onPressed: () => settings.update(fontSize: settings.fontSize - 1),
                    ),
                    Expanded(
                      child: Slider(
                        value: settings.fontSize,
                        min: TextSettings.minFontSize,
                        max: TextSettings.maxFontSize,
                        divisions: (TextSettings.maxFontSize - TextSettings.minFontSize).round(),
                        onChanged: (v) => settings.update(fontSize: v),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Larger',
                      icon: const Icon(Icons.text_increase),
                      onPressed: () => settings.update(fontSize: settings.fontSize + 1),
                    ),
                  ],
                ),
              ),
              _row(
                context,
                label: 'Line spacing',
                value: settings.lineHeight.toStringAsFixed(1),
                child: Slider(
                  value: settings.lineHeight,
                  min: 1.1,
                  max: 2.4,
                  divisions: 13,
                  onChanged: (v) => settings.update(lineHeight: v),
                ),
              ),
              _row(
                context,
                label: 'Margins',
                value: '${settings.margin.round()}',
                child: Slider(
                  value: settings.margin,
                  min: 4,
                  max: 80,
                  divisions: 19,
                  onChanged: (v) => settings.update(margin: v),
                ),
              ),
              const SizedBox(height: 8),
              _label(context, 'Font'),
              SegmentedButton<ReadingFont>(
                segments: const [
                  ButtonSegment(value: ReadingFont.sans, label: Text('Sans')),
                  ButtonSegment(
                    value: ReadingFont.serif,
                    label: Text('Serif', style: TextStyle(fontFamily: 'serif', fontFamilyFallback: ['Georgia'])),
                  ),
                ],
                selected: {settings.font},
                onSelectionChanged: (s) => settings.update(font: s.first),
              ),
              const SizedBox(height: 12),
              _label(context, 'Alignment'),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, icon: Icon(Icons.format_align_justify), label: Text('Justified')),
                  ButtonSegment(value: false, icon: Icon(Icons.format_align_left), label: Text('Left')),
                ],
                selected: {settings.justify},
                onSelectionChanged: (s) => settings.update(justify: s.first),
              ),
              const SizedBox(height: 12),
              _label(context, 'Theme'),
              SegmentedButton<ReadingTheme>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ReadingTheme.system, label: Text('Auto')),
                  ButtonSegment(value: ReadingTheme.light, label: Text('Light')),
                  ButtonSegment(value: ReadingTheme.sepia, label: Text('Sepia')),
                  ButtonSegment(value: ReadingTheme.dark, label: Text('Dark')),
                ],
                selected: {settings.theme},
                onSelectionChanged: (s) => settings.update(theme: s.first),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: settings.reset, child: const Text('Reset to defaults')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );

  Widget _row(BuildContext context, {required String label, required String value, required Widget child}) {
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text('$label  $value', style: Theme.of(context).textTheme.labelLarge),
        ),
        Expanded(child: child),
      ],
    );
  }
}

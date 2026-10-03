import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReadingTheme { system, light, dark, sepia }

enum ReadingFont { sans, serif }

/// How book text looks: size, spacing, font, margins and colours. Saved between launches.
class TextSettings extends ChangeNotifier {
  SharedPreferences? _prefs;

  double fontSize = 19;
  double lineHeight = 1.6;
  double margin = 20;
  bool justify = true;
  ReadingFont font = ReadingFont.sans;
  ReadingTheme theme = ReadingTheme.system;

  static const minFontSize = 12.0;
  static const maxFontSize = 40.0;

  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    final p = _prefs!;
    fontSize = (p.getDouble('text.size') ?? fontSize).clamp(minFontSize, maxFontSize).toDouble();
    lineHeight = (p.getDouble('text.lineHeight') ?? lineHeight).clamp(1.1, 2.4).toDouble();
    margin = (p.getDouble('text.margin') ?? margin).clamp(4, 80).toDouble();
    justify = p.getBool('text.justify') ?? justify;
    font = ReadingFont.values.asNameMap()[p.getString('text.font')] ?? font;
    theme = ReadingTheme.values.asNameMap()[p.getString('text.theme')] ?? theme;
    notifyListeners();
  }

  void update({
    double? fontSize,
    double? lineHeight,
    double? margin,
    bool? justify,
    ReadingFont? font,
    ReadingTheme? theme,
  }) {
    if (fontSize != null) {
      this.fontSize = fontSize.clamp(minFontSize, maxFontSize).toDouble();
      _prefs?.setDouble('text.size', this.fontSize);
    }
    if (lineHeight != null) {
      this.lineHeight = lineHeight;
      _prefs?.setDouble('text.lineHeight', lineHeight);
    }
    if (margin != null) {
      this.margin = margin;
      _prefs?.setDouble('text.margin', margin);
    }
    if (justify != null) {
      this.justify = justify;
      _prefs?.setBool('text.justify', justify);
    }
    if (font != null) {
      this.font = font;
      _prefs?.setString('text.font', font.name);
    }
    if (theme != null) {
      this.theme = theme;
      _prefs?.setString('text.theme', theme.name);
    }
    notifyListeners();
  }

  void reset() => update(
        fontSize: 19,
        lineHeight: 1.6,
        margin: 20,
        justify: true,
        font: ReadingFont.sans,
        theme: ReadingTheme.system,
      );

  ThemeMode get themeMode => switch (theme) {
        ReadingTheme.light || ReadingTheme.sepia => ThemeMode.light,
        ReadingTheme.dark => ThemeMode.dark,
        ReadingTheme.system => ThemeMode.system,
      };

  /// Background and text colours for the page; null means "use the app theme".
  (Color, Color)? get pageColors =>
      theme == ReadingTheme.sepia ? (const Color(0xFFF4ECD8), const Color(0xFF4A3B2A)) : null;

  String? get fontFamily => switch (font) {
        ReadingFont.sans => null, // platform default: Roboto on Android, Segoe UI on Windows
        ReadingFont.serif => Platform.isWindows ? 'Georgia' : 'serif',
      };

  List<String> get fontFallback =>
      font == ReadingFont.serif ? const ['Noto Serif', 'Cambria', 'Times New Roman'] : const [];
}

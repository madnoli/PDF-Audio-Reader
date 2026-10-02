import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book.dart';

const languageNames = {'en': 'English', 'hi': 'Hindi', 'mr': 'Marathi'};

class TtsVoice {
  TtsVoice(this.name, this.locale);
  final String name;
  final String locale;

  String get _normalizedLocale => locale.replaceAll('_', '-');

  /// Language code such as 'en', 'hi' or 'mr'.
  String get code => _normalizedLocale.split('-').first.toLowerCase();

  bool get isIndian {
    final l = _normalizedLocale.toUpperCase();
    return l.endsWith('-IN') || l.contains('-IN-') || name.toLowerCase().contains('india');
  }

  String get language => _languageNames[code] ?? locale;

  /// Friendly label: Android voice names look like "en-in-x-ahp-local".
  String get label {
    final region = isIndian ? ' (India)' : ' ($locale)';
    final cleanName = name.replaceFirst('Microsoft ', '').replaceAll(RegExp(r' - .*$'), '');
    return '$language$region · $cleanName';
  }

  Map<String, String> get asMap => {'name': name, 'locale': locale};

  static const _languageNames = {
    'en': 'English', 'hi': 'Hindi', 'bn': 'Bengali', 'ta': 'Tamil', 'te': 'Telugu',
    'mr': 'Marathi', 'gu': 'Gujarati', 'kn': 'Kannada', 'ml': 'Malayalam', 'pa': 'Punjabi',
    'ur': 'Urdu', 'or': 'Odia', 'as': 'Assamese', 'ne': 'Nepali', 'sa': 'Sanskrit',
  };
}

/// Owns the open book, the reading position and the text-to-speech engine.
///
/// Sentences are spoken one at a time; the completion callback advances to the
/// next. (flutter_tts's awaitSpeakCompletion mode can crash on Windows when
/// stop() is called after a sentence has already finished, so it isn't used.)
/// English and Devanagari sentences each use the voice chosen for their language.
class ReaderController extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  SharedPreferences? _prefs;

  Book? book;
  String? bookKey;
  int index = 0;
  bool playing = false;
  double rate = 1.0;
  bool indianOnly = true;
  List<TtsVoice> allVoices = [];
  String? message;

  bool _awaitingEnd = false;
  String? _activeVoice; // name of the voice last sent to the engine
  Timer? _saveTimer;

  static const minRate = 0.5;
  static const maxRate = 3.0;

  List<TtsVoice> get indianVoices => allVoices.where((v) => v.isIndian).toList();

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    rate = (_prefs?.getDouble('rate') ?? 1.0).clamp(minRate, maxRate).toDouble();
    indianOnly = _prefs?.getBool('indianOnly') ?? true;

    _tts.setCompletionHandler(_onSentenceDone);
    _tts.setErrorHandler((msg) {
      if (!playing) return;
      _awaitingEnd = false;
      playing = false;
      message = 'Speech stopped: $msg. Try another voice.';
      notifyListeners();
    });
    if (Platform.isAndroid) {
      // Don't queue: each speak replaces whatever is still playing.
      await _tts.setQueueMode(0);
    }
    await _loadVoices();
  }

  Future<void> _loadVoices() async {
    // The Android engine may need a moment after startup before it lists voices.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        final raw = await _tts.getVoices;
        if (raw is List && raw.isNotEmpty) {
          allVoices = [
            for (final v in raw)
              if (v is Map && v['name'] != null)
                TtsVoice('${v['name']}', '${v['locale'] ?? ''}'),
          ];
          break;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    allVoices.sort((a, b) {
      int rank(TtsVoice v) =>
          (v.isIndian ? 0 : 10) + (v.code == 'en' ? 0 : v.code == 'hi' ? 1 : v.code == 'mr' ? 2 : 3);
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.label.compareTo(b.label);
    });
    notifyListeners();
  }

  /* ----------------------------------------------------------- Voices */

  /// The voice used for sentences in [lang]: the user's choice, or the best installed match.
  TtsVoice? voiceFor(String lang) {
    final saved = _prefs?.getString('voice:$lang') ?? (lang == 'en' ? _prefs?.getString('voice') : null);
    return allVoices.where((v) => v.name == saved).firstOrNull ?? _defaultVoiceFor(lang);
  }

  TtsVoice? _defaultVoiceFor(String lang) {
    final same = allVoices.where((v) => v.code == lang);
    return same.where((v) => v.isIndian).firstOrNull ??
        same.firstOrNull ??
        (lang == 'mr' ? _defaultVoiceFor('hi') : null) ?? // Hindi voices read Marathi script passably
        (lang == 'en' ? allVoices.firstOrNull : null);
  }

  /// Whether a voice that actually speaks [lang] is installed.
  bool hasVoiceFor(String lang) => allVoices.any((v) => v.code == lang);

  /// Voices to offer for [lang]: matching ones first; with the Indian filter on, only Indian ones.
  List<TtsVoice> voiceChoices(String lang) {
    final pool = indianOnly ? indianVoices : allVoices;
    final same = pool.where((v) => v.code == lang).toList();
    if (indianOnly) return same;
    return [...same, ...pool.where((v) => v.code != lang)];
  }

  Future<void> setVoiceFor(String lang, TtsVoice v) async {
    await _prefs?.setString('voice:$lang', v.name);
    _activeVoice = null;
    notifyListeners();
    if (playing && current?.lang == lang) await _restart();
  }

  void setIndianOnly(bool value) {
    indianOnly = value;
    _prefs?.setBool('indianOnly', value);
    notifyListeners();
  }

  String installHint(String lang) {
    final name = languageNames[lang] ?? lang;
    if (Platform.isAndroid) {
      return 'To add a $name voice: Settings › Text-to-speech output › Google › Install voice data › $name (India).';
    }
    if (lang == 'mr') {
      return 'Windows has no Marathi voice; Marathi text is read with the Hindi voice. '
          'To add it: Windows Settings › Time & language › Speech › Add voices › Hindi (India), then restart this app.';
    }
    return 'To add a $name voice: Windows Settings › Time & language › Speech › Add voices › $name (India), then restart this app.';
  }

  // flutter_tts scales the rate differently per platform; this maps a plain
  // multiplier (1.0 = normal) to what each platform expects.
  double get _engineRate {
    if (Platform.isAndroid) return rate / 2; // plugin doubles it
    if (Platform.isWindows) return rate - 0.5; // plugin adds 0.5
    return rate;
  }

  /* ------------------------------------------------------------- Book */

  void openBook(Book b, String key) {
    stop();
    book = b;
    bookKey = key;
    index = (_prefs?.getInt('progress:$key') ?? 0).clamp(0, b.sentences.length - 1).toInt();

    // Marathi can fall back to a Hindi voice; anything else without a voice gets a hint.
    final missing = b.languages
        .where((l) => l != 'en' && !hasVoiceFor(l) && !(l == 'mr' && hasVoiceFor('hi')))
        .firstOrNull;
    if (missing != null) {
      final name = languageNames[missing];
      message = 'This book has $name text but no $name voice is installed. ${installHint(missing)}';
    } else {
      message = index > 0
          ? 'Resuming where you left off. Press play to listen.'
          : '${b.sentences.length} sentences ready. Press play to listen.';
    }
    notifyListeners();
  }

  Sentence? get current => book?.sentences.elementAtOrNull(index);

  /* ---------------------------------------------------------- Playback */

  Future<void> play() async {
    if (book == null || book!.sentences.isEmpty) return;
    playing = true;
    message = null;
    notifyListeners();
    await _restart();
  }

  Future<void> stop() async {
    playing = false;
    _awaitingEnd = false;
    notifyListeners();
    try {
      await _tts.stop();
    } catch (_) {}
  }

  void toggle() => playing ? stop() : play();

  Future<void> goTo(int i) async {
    final b = book;
    if (b == null || b.sentences.isEmpty) return;
    index = i.clamp(0, b.sentences.length - 1).toInt();
    _saveProgress();
    notifyListeners();
    if (playing) await _restart();
  }

  Future<void> setRate(double r) async {
    rate = r.clamp(minRate, maxRate).toDouble();
    _prefs?.setDouble('rate', rate);
    notifyListeners();
    if (playing) await _restart();
  }

  Future<void> _restart() async {
    _awaitingEnd = false;
    try {
      await _tts.stop();
    } catch (_) {}
    if (playing) await _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    final s = current;
    if (s == null) return;
    try {
      final voice = voiceFor(s.lang);
      if (voice != null && voice.name != _activeVoice) {
        await _tts.setVoice(voice.asMap);
        _activeVoice = voice.name;
      }
      await _tts.setSpeechRate(_engineRate);
      _awaitingEnd = true;
      await _tts.speak(s.text);
    } catch (e) {
      _awaitingEnd = false;
      playing = false;
      message = 'Could not speak: $e';
      notifyListeners();
    }
  }

  void _onSentenceDone() {
    if (!_awaitingEnd || !playing) return;
    _awaitingEnd = false;
    final b = book;
    if (b == null || index >= b.sentences.length - 1) {
      playing = false;
      message = 'Finished reading.';
      notifyListeners();
      return;
    }
    index++;
    _saveProgress();
    notifyListeners();
    _speakCurrent();
  }

  void _saveProgress() {
    final key = bookKey;
    if (key == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () => _prefs?.setInt('progress:$key', index));
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _tts.stop();
    super.dispose();
  }
}

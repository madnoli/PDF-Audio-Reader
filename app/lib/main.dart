import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'background.dart';
import 'book.dart';
import 'library.dart';
import 'library_page.dart';
import 'reader.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AudioReaderApp());
}

class AudioReaderApp extends StatelessWidget {
  const AudioReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFC2410C);
    return MaterialApp(
      title: 'Audio Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
      home: const ReaderPage(),
    );
  }
}

/// One row of the reading list: either a section heading or a paragraph.
class _Item {
  const _Item.heading(this.section) : paragraph = null;
  const _Item.paragraph(this.paragraph, this.section);
  final int? paragraph;
  final int section;
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final reader = ReaderController();
  final library = LibraryController();
  final _scroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();

  List<_Item> _items = [];
  List<int> _paragraphItem = []; // paragraph index -> list item index
  List<int> _sectionItem = []; // section index -> list item index
  int _lastParagraph = -1;
  String? _loading;

  @override
  void initState() {
    super.initState();
    reader.addListener(_followReading);
    reader.init();
    library.load();
    if (Platform.isAndroid) startBackgroundAudio(reader);
  }

  @override
  void dispose() {
    reader.removeListener(_followReading);
    reader.dispose();
    library.dispose();
    super.dispose();
  }

  Future<void> _openFile() async {
    final PlatformFile? file;
    try {
      file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['pdf', 'epub']);
    } catch (e) {
      _showError('Could not open the file picker: $e');
      return;
    }
    if (file != null) await _openBook(file.name, file.readAsBytes);
  }

  Future<void> _openLibrary() async {
    final picked = await Navigator.of(context).push<BookFile>(
      MaterialPageRoute(builder: (_) => LibraryPage(library: library)),
    );
    if (picked == null) return;
    if (!File(picked.path).existsSync()) {
      library.forget(picked);
      _showError('${picked.name} no longer exists. It has been removed from the library.');
      return;
    }
    await _openBook(picked.name, () => File(picked.path).readAsBytes());
  }

  Future<void> _openBook(String name, Future<Uint8List> Function() readBytes) async {
    await reader.stop();
    setState(() => _loading = 'Reading $name…');
    try {
      final bytes = await readBytes();
      final raw = await compute(parseBook, (name, bytes));
      final title = raw.title.isNotEmpty ? raw.title : name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final book = Book.fromRaw(RawBook(title, raw.sections));
      if (book.sentences.isEmpty) throw BookFormatException('No readable text found in this file.');

      _buildItems(book);
      _lastParagraph = -1;
      reader.openBook(book, '$name:${bytes.length}');
      setState(() => _loading = null);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent(jump: true));
    } on BookFormatException catch (e) {
      setState(() => _loading = null);
      _showError(e.message);
    } catch (e) {
      setState(() => _loading = null);
      _showError('Could not open $name: $e');
    }
  }

  void _buildItems(Book book) {
    final items = <_Item>[];
    final paragraphItem = List<int>.filled(book.paragraphs.length, 0);
    final sectionItem = List<int>.filled(book.sections.length, 0);
    for (var si = 0; si < book.sections.length; si++) {
      sectionItem[si] = items.length;
      items.add(_Item.heading(si));
      final end = si + 1 < book.sections.length ? book.sections[si + 1].firstParagraph : book.paragraphs.length;
      for (var pi = book.sections[si].firstParagraph; pi < end; pi++) {
        paragraphItem[pi] = items.length;
        items.add(_Item.paragraph(pi, si));
      }
    }
    _items = items;
    _paragraphItem = paragraphItem;
    _sectionItem = sectionItem;
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // Keep the sentence being read on screen as playback moves between paragraphs.
  void _followReading() {
    final s = reader.current;
    if (s == null || s.paragraph == _lastParagraph) return;
    _lastParagraph = s.paragraph;
    _scrollToCurrent();
  }

  void _scrollToCurrent({bool jump = false}) {
    final s = reader.current;
    if (s == null || !_scroll.isAttached) return;
    final item = _paragraphItem[s.paragraph];
    final visible = _positions.itemPositions.value
        .any((p) => p.index == item && p.itemLeadingEdge >= 0 && p.itemTrailingEdge <= 1);
    if (visible && !jump) return;
    if (jump) {
      _scroll.jumpTo(index: item, alignment: 0.15);
    } else {
      _scroll.scrollTo(index: item, alignment: 0.15, duration: const Duration(milliseconds: 350));
    }
  }

  void _goToSection(int si) {
    final book = reader.book!;
    Navigator.of(context).maybePop();
    // Jump to the heading ourselves rather than letting _followReading scroll to the paragraph.
    _lastParagraph = book.sections[si].firstParagraph;
    reader.goTo(book.sections[si].firstSentence);
    _scroll.jumpTo(index: _sectionItem[si]);
  }

  void _step(int delta) {
    _lastParagraph = -1; // makes _followReading bring the sentence back on screen
    reader.goTo(reader.index + delta);
  }

  void _showVoices() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (context, controller) => VoiceSheet(
          reader: reader,
          scrollController: controller,
          initialLanguage: reader.current?.lang ?? 'en',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): reader.toggle,
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _openFile,
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): _openLibrary,
      },
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: reader,
          builder: (context, _) {
            final book = reader.book;
            return Scaffold(
              appBar: AppBar(
                title: Text(book?.title ?? 'Audio Reader', overflow: TextOverflow.ellipsis),
                actions: [
                  IconButton(
                    tooltip: 'Library (Ctrl+L)',
                    icon: const Icon(Icons.local_library),
                    onPressed: _loading == null ? _openLibrary : null,
                  ),
                  IconButton(
                    tooltip: 'Open PDF / EPUB (Ctrl+O)',
                    icon: const Icon(Icons.folder_open),
                    onPressed: _loading == null ? _openFile : null,
                  ),
                ],
              ),
              drawer: book == null ? null : _buildContents(book),
              body: _loading != null
                  ? _CenteredStatus(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(_loading!),
                    ]))
                  : book == null
                      ? _Welcome(onOpen: _openFile, onLibrary: _openLibrary)
                      : _buildBook(book),
              bottomNavigationBar: book == null ? null : _PlayerBar(
                reader: reader,
                onPrev: () => _step(-1),
                onNext: () => _step(1),
                onVoices: _showVoices,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildContents(Book book) {
    final currentSection = reader.current?.section;
    return Drawer(
      child: SafeArea(
        child: ListView.builder(
          itemCount: book.sections.length,
          itemBuilder: (context, i) => ListTile(
            dense: true,
            selected: i == currentSection,
            title: Text(book.sections[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _goToSection(i),
          ),
        ),
      ),
    );
  }

  Widget _buildBook(Book book) {
    final theme = Theme.of(context);
    return ScrollablePositionedList.builder(
      itemScrollController: _scroll,
      itemPositionsListener: _positions,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 48),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final item = _items[i];
        final Widget child;
        if (item.paragraph == null) {
          child = Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 24, bottom: 12),
            child: Text(
              book.sections[item.section].title.toUpperCase(),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 1.2,
              ),
            ),
          );
        } else {
          child = ParagraphView(
            book: book,
            paragraph: item.paragraph!,
            current: reader.index,
            onTapSentence: (s) {
              reader.goTo(s);
              if (!reader.playing) reader.play();
            },
          );
        }
        return Center(
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: child),
        );
      },
    );
  }
}

/// Picks a voice for each language; Hindi/Marathi text automatically uses its own voice.
class VoiceSheet extends StatefulWidget {
  const VoiceSheet({
    super.key,
    required this.reader,
    required this.scrollController,
    required this.initialLanguage,
  });

  final ReaderController reader;
  final ScrollController scrollController;
  final String initialLanguage;

  @override
  State<VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<VoiceSheet> {
  late String _lang = widget.initialLanguage;

  @override
  Widget build(BuildContext context) {
    final reader = widget.reader;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: reader,
      builder: (context, _) {
        final voices = reader.voiceChoices(_lang);
        final selected = reader.voiceFor(_lang);
        final name = languageNames[_lang]!;
        return ListView(
          controller: widget.scrollController,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Voice for each language in the book', style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<String>(
                segments: [
                  for (final e in languageNames.entries) ButtonSegment(value: e.key, label: Text(e.value)),
                ],
                selected: {_lang},
                onSelectionChanged: (s) => setState(() => _lang = s.first),
              ),
            ),
            SwitchListTile(
              title: const Text('Indian voices only'),
              subtitle: Text('${reader.indianVoices.length} Indian voices on this device'),
              value: reader.indianOnly,
              onChanged: reader.setIndianOnly,
            ),
            const Divider(height: 1),
            if (!reader.hasVoiceFor(_lang))
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(selected == null
                    ? 'No $name voice installed.'
                    : 'No $name voice installed. $name text will use ${selected.label}.'),
                subtitle: Text(reader.installHint(_lang)),
              ),
            for (final v in voices)
              ListTile(
                title: Text(v.label),
                trailing: v.name == selected?.name ? const Icon(Icons.check) : null,
                onTap: () => reader.setVoiceFor(_lang, v),
              ),
            if (reader.hasVoiceFor(_lang))
              ListTile(
                dense: true,
                leading: const Icon(Icons.add),
                title: const Text('More voices'),
                subtitle: Text(reader.installHint(_lang)),
              ),
          ],
        );
      },
    );
  }
}

/// A paragraph whose sentences can be tapped and the current one highlighted.
class ParagraphView extends StatefulWidget {
  const ParagraphView({
    super.key,
    required this.book,
    required this.paragraph,
    required this.current,
    required this.onTapSentence,
  });

  final Book book;
  final int paragraph;
  final int current;
  final ValueChanged<int> onTapSentence;

  @override
  State<ParagraphView> createState() => _ParagraphViewState();
}

class _ParagraphViewState extends State<ParagraphView> {
  List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _createRecognizers();
  }

  @override
  void didUpdateWidget(ParagraphView old) {
    super.didUpdateWidget(old);
    if (old.paragraph != widget.paragraph || old.book != widget.book) {
      _disposeRecognizers();
      _createRecognizers();
    }
  }

  void _createRecognizers() {
    final p = widget.book.paragraphs[widget.paragraph];
    _recognizers = [
      for (var s = p.firstSentence; s < p.endSentence; s++)
        TapGestureRecognizer()..onTap = () => widget.onTapSentence(s),
    ];
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.book.paragraphs[widget.paragraph];
    final highlight = TextStyle(
      backgroundColor: theme.colorScheme.tertiaryContainer,
      color: theme.colorScheme.onTertiaryContainer,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text.rich(
        TextSpan(children: [
          for (var s = p.firstSentence; s < p.endSentence; s++)
            TextSpan(
              text: '${widget.book.sentences[s].text} ',
              style: s == widget.current ? highlight : null,
              recognizer: _recognizers[s - p.firstSentence],
              mouseCursor: SystemMouseCursors.click,
            ),
        ]),
        style: theme.textTheme.bodyLarge?.copyWith(fontSize: 19, height: 1.6),
      ),
    );
  }
}

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    required this.reader,
    required this.onPrev,
    required this.onNext,
    required this.onVoices,
  });

  final ReaderController reader;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onVoices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (reader.message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    reader.message!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ),
              Row(
                children: [
                  IconButton(tooltip: 'Previous sentence (←)', icon: const Icon(Icons.skip_previous), onPressed: onPrev),
                  IconButton.filled(
                    tooltip: reader.playing ? 'Pause (Space)' : 'Play (Space)',
                    iconSize: 32,
                    icon: Icon(reader.playing ? Icons.pause : Icons.play_arrow),
                    onPressed: reader.toggle,
                  ),
                  IconButton(tooltip: 'Next sentence (→)', icon: const Icon(Icons.skip_next), onPressed: onNext),
                  const SizedBox(width: 4),
                  const Icon(Icons.speed, size: 20),
                  Expanded(child: _SpeedSlider(reader: reader)),
                  SizedBox(
                    width: 44,
                    child: Text('${reader.rate.toStringAsFixed(1)}×',
                        style: theme.textTheme.titleSmall, textAlign: TextAlign.end),
                  ),
                  IconButton(
                    tooltip: 'Voices',
                    icon: const Icon(Icons.record_voice_over),
                    onPressed: onVoices,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the new speed while dragging, and only restarts speech when released.
class _SpeedSlider extends StatefulWidget {
  const _SpeedSlider({required this.reader});
  final ReaderController reader;

  @override
  State<_SpeedSlider> createState() => _SpeedSliderState();
}

class _SpeedSliderState extends State<_SpeedSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final value = _dragging ?? widget.reader.rate;
    return Slider(
      value: value,
      min: ReaderController.minRate,
      max: ReaderController.maxRate,
      divisions: 25,
      label: '${value.toStringAsFixed(1)}×',
      onChanged: (v) => setState(() => _dragging = v),
      onChangeEnd: (v) {
        setState(() => _dragging = null);
        widget.reader.setRate(v);
      },
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onOpen, required this.onLibrary});
  final VoidCallback onOpen;
  final VoidCallback onLibrary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _CenteredStatus(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.headphones, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('Listen to your books', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Open a PDF or EPUB and it will be read aloud in an Indian voice. '
            'Tap any sentence to start reading from there.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onLibrary,
            icon: const Icon(Icons.manage_search),
            label: const Text('Find books on this device'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.folder_open),
            label: const Text('Open a file'),
          ),
        ],
      ),
    );
  }
}

class _CenteredStatus extends StatelessWidget {
  const _CenteredStatus({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: child),
        ),
      );
}

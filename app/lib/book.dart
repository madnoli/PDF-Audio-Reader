import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

/// A book flattened into what the reader needs: sections (pages or chapters),
/// paragraphs for display, and sentences for speech.
class Book {
  Book(this.title, this.sections, this.paragraphs, this.sentences);

  final String title;
  final List<Section> sections;
  final List<Paragraph> paragraphs;
  final List<Sentence> sentences;

  /// Builds the display/speech structure from parsed raw text.
  factory Book.fromRaw(RawBook raw) {
    final sections = <Section>[];
    final paragraphs = <Paragraph>[];
    final sentences = <Sentence>[];
    for (final rs in raw.sections) {
      final si = sections.length;
      sections.add(Section(rs.title, paragraphs.length, sentences.length));
      for (final text in rs.paragraphs) {
        final pi = paragraphs.length;
        final first = sentences.length;
        for (final part in splitSentences(text)) {
          sentences.add(Sentence(part, pi, si));
        }
        if (sentences.length > first) {
          paragraphs.add(Paragraph(si, first, sentences.length));
        }
      }
    }
    return Book(raw.title, sections, paragraphs, sentences);
  }
}

class Section {
  Section(this.title, this.firstParagraph, this.firstSentence);
  final String title;
  final int firstParagraph;
  final int firstSentence;
}

class Paragraph {
  Paragraph(this.section, this.firstSentence, this.endSentence);
  final int section;
  final int firstSentence;
  final int endSentence; // exclusive
}

class Sentence {
  Sentence(this.text, this.paragraph, this.section);
  final String text;
  final int paragraph;
  final int section;
}

/// Plain parse result; simple enough to pass back from a background isolate.
class RawBook {
  RawBook(this.title, this.sections);
  final String title;
  final List<RawSection> sections;
}

class RawSection {
  RawSection(this.title, this.paragraphs);
  final String title;
  final List<String> paragraphs;
}

class BookFormatException implements Exception {
  BookFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Entry point for `compute`: parses a PDF or EPUB from its bytes.
RawBook parseBook((String, Uint8List) input) {
  final (name, bytes) = input;
  final lower = name.toLowerCase();
  if (lower.endsWith('.pdf')) return parsePdf(bytes);
  if (lower.endsWith('.epub')) return parseEpub(bytes);
  throw BookFormatException('Please choose a .pdf or .epub file.');
}

/* ------------------------------------------------------------------ PDF */

RawBook parsePdf(Uint8List bytes) {
  final PdfDocument doc;
  try {
    doc = PdfDocument(inputBytes: bytes);
  } catch (_) {
    throw BookFormatException('This PDF could not be opened. It may be damaged or password-protected.');
  }
  try {
    var title = '';
    try {
      title = doc.documentInformation.title.trim();
    } catch (_) {}
    final extractor = PdfTextExtractor(doc);
    final sections = <RawSection>[];
    for (var i = 0; i < doc.pages.count; i++) {
      String text;
      try {
        text = extractor.extractText(startPageIndex: i, endPageIndex: i);
      } catch (_) {
        text = '';
      }
      sections.add(RawSection('Page ${i + 1}', _pdfParagraphs(text)));
    }
    if (sections.every((s) => s.paragraphs.isEmpty)) {
      throw BookFormatException(
          'No text found. This PDF looks like scanned images, which need OCR first.');
    }
    return RawBook(title, sections);
  } finally {
    doc.dispose();
  }
}

/// Joins wrapped lines back into paragraphs. A line that ends a sentence and is
/// noticeably shorter than the page's typical line closes the paragraph.
List<String> _pdfParagraphs(String pageText) {
  final lines = pageText
      .split(RegExp(r'\r\n|\r|\n'))
      .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
      .toList();
  final lengths = lines.where((l) => l.isNotEmpty).map((l) => l.length).toList()..sort();
  final typical = lengths.isEmpty ? 0 : lengths[(lengths.length * 0.8).floor().clamp(0, lengths.length - 1).toInt()];

  final paragraphs = <String>[];
  var buf = '';
  void flush() {
    if (buf.trim().isNotEmpty) paragraphs.add(buf.trim());
    buf = '';
  }

  for (final line in lines) {
    if (line.isEmpty) {
      flush();
      continue;
    }
    if (RegExp(r'[a-z]-$').hasMatch(buf) && RegExp(r'^[a-z]').hasMatch(line)) {
      buf = buf.substring(0, buf.length - 1) + line; // re-join hyphenated word
    } else {
      buf = buf.isEmpty ? line : '$buf $line';
    }
    final endsSentence = RegExp(r'''[.!?:।]["'”’)\]]*$''').hasMatch(line);
    if (endsSentence && line.length < typical * 0.75) flush();
  }
  flush();
  return paragraphs;
}

/* ----------------------------------------------------------------- EPUB */

RawBook parseEpub(Uint8List bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw BookFormatException('This EPUB could not be opened. It may be damaged.');
  }

  String read(String path) {
    final f = zip.findFile(path);
    if (f == null) throw BookFormatException('The EPUB is missing $path.');
    return utf8.decode(f.content, allowMalformed: true);
  }

  String dirOf(String p) => p.substring(0, p.lastIndexOf('/') + 1);
  String resolve(String base, String href) =>
      Uri.decodeComponent(Uri.parse('http://epub/$base').resolve(href).path.substring(1));
  Iterable<XmlElement> byTag(XmlNode node, String tag) =>
      node.descendantElements.where((e) => e.name.local == tag);
  String? attr(XmlElement e, String name) => e.getAttribute(name);

  final XmlDocument container;
  final XmlDocument opf;
  final String opfPath;
  try {
    container = XmlDocument.parse(read('META-INF/container.xml'));
    final p = byTag(container, 'rootfile').firstOrNull;
    if (p == null || attr(p, 'full-path') == null) throw BookFormatException('This EPUB has no package file.');
    opfPath = attr(p, 'full-path')!;
    opf = XmlDocument.parse(read(opfPath));
  } on XmlException {
    throw BookFormatException('This EPUB has an invalid package file.');
  }
  final opfDir = dirOf(opfPath);

  final title = byTag(opf, 'title').firstOrNull?.innerText.trim() ?? '';
  final manifest = {for (final item in byTag(opf, 'item')) attr(item, 'id'): item};
  final spine = byTag(opf, 'spine').firstOrNull;

  // Chapter names from the table of contents (EPUB 3 nav, or EPUB 2 NCX).
  final tocTitles = <String, String>{};
  void addTitle(String path, String label) {
    final key = path.split('#').first;
    final clean = label.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isNotEmpty) tocTitles.putIfAbsent(key, () => clean);
  }

  try {
    final nav = manifest.values
        .where((i) => (attr(i, 'properties') ?? '').split(RegExp(r'\s+')).contains('nav'))
        .firstOrNull;
    final ncx = manifest[spine == null ? null : attr(spine, 'toc')] ??
        manifest.values.where((i) => attr(i, 'media-type') == 'application/x-dtbncx+xml').firstOrNull;
    if (nav != null) {
      final navPath = resolve(opfDir, attr(nav, 'href')!);
      final doc = html_parser.parse(read(navPath));
      for (final a in doc.querySelectorAll('a[href]')) {
        addTitle(resolve(dirOf(navPath), a.attributes['href']!), a.text);
      }
    } else if (ncx != null) {
      final ncxPath = resolve(opfDir, attr(ncx, 'href')!);
      final doc = XmlDocument.parse(read(ncxPath));
      for (final point in byTag(doc, 'navPoint')) {
        final src = byTag(point, 'content').firstOrNull?.getAttribute('src');
        final label = byTag(point, 'text').firstOrNull?.innerText ?? '';
        if (src != null) addTitle(resolve(dirOf(ncxPath), src), label);
      }
    }
  } catch (_) {
    // A broken table of contents only costs us chapter names.
  }

  final sections = <RawSection>[];
  for (final ref in spine == null ? const <XmlElement>[] : byTag(spine, 'itemref')) {
    final item = manifest[attr(ref, 'idref')];
    if (item == null || !RegExp('html|xml').hasMatch(attr(item, 'media-type') ?? '')) continue;
    final path = resolve(opfDir, attr(item, 'href') ?? '');
    final dom.Document doc;
    try {
      doc = html_parser.parse(read(path));
    } catch (_) {
      continue;
    }
    final body = doc.body;
    if (body == null) continue;
    final paragraphs = htmlParagraphs(body);
    if (paragraphs.isEmpty) continue;
    final heading = body.querySelector('h1') ?? body.querySelector('h2');
    sections.add(RawSection(
      tocTitles[path] ?? (heading?.text.trim().isNotEmpty == true ? heading!.text.trim() : 'Section ${sections.length + 1}'),
      paragraphs,
    ));
  }
  if (sections.isEmpty) throw BookFormatException('No readable text found in this EPUB.');
  return RawBook(title, sections);
}

const _blockTags = {
  'address', 'article', 'aside', 'blockquote', 'br', 'dd', 'div', 'dl', 'dt', 'figcaption',
  'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr', 'li', 'ol', 'p',
  'pre', 'section', 'table', 'td', 'th', 'tr', 'ul',
};
const _skipTags = {'script', 'style', 'head', 'title', 'rt', 'rp', 'svg', 'math'};

List<String> htmlParagraphs(dom.Element root) {
  final out = <String>[];
  final buf = StringBuffer();
  void flush() {
    final t = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isNotEmpty) out.add(t);
    buf.clear();
  }

  void walk(dom.Node node) {
    for (final child in node.nodes) {
      if (child is dom.Text) {
        buf.write(child.text);
      } else if (child is dom.Element) {
        final tag = (child.localName ?? '').toLowerCase();
        if (_skipTags.contains(tag)) continue;
        // Footnote reference markers like ¹ or [3] just interrupt the reading.
        if (tag == 'sup' && child.querySelector('a') != null) continue;
        final block = _blockTags.contains(tag);
        if (block) flush();
        walk(child);
        if (block) flush();
      }
    }
  }

  walk(root);
  flush();
  return out;
}

/* ------------------------------------------------------------ Sentences */

const _maxChunk = 240; // long sentences are split so the speech engine never stalls
const _abbreviations = {
  'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'vs', 'etc', 'eg', 'ie', 'no', 'fig',
  'vol', 'pp', 'ch', 'inc', 'ltd', 'co', 'rs', 'smt', 'shri', 'mt', 'jan', 'feb', 'mar',
  'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
};

List<String> splitSentences(String text) {
  final parts = <String>[];
  var start = 0;
  for (final m in RegExp(r'''[.!?।]+["'”’)\]]*\s+''').allMatches(text)) {
    final next = m.end < text.length ? text[m.end] : '';
    if (RegExp('[a-z]').hasMatch(next)) continue; // "e.g. this" – not a sentence end
    final before = text.substring(start, m.start);
    final lastWord = RegExp(r'([A-Za-z.]+)$').firstMatch(before)?.group(1)?.replaceAll('.', '').toLowerCase();
    if (lastWord != null && (_abbreviations.contains(lastWord) || lastWord.length == 1)) continue;
    parts.add(text.substring(start, m.end).trim());
    start = m.end;
  }
  if (start < text.length) parts.add(text.substring(start).trim());

  final out = <String>[];
  for (var rest in parts) {
    while (rest.length > _maxChunk) {
      var cut = rest.lastIndexOf(', ', _maxChunk);
      if (cut < _maxChunk ~/ 2) cut = rest.lastIndexOf(' ', _maxChunk);
      if (cut <= 0) cut = _maxChunk;
      out.add(rest.substring(0, cut + 1).trim());
      rest = rest.substring(cut + 1).trim();
    }
    if (rest.isNotEmpty) out.add(rest);
  }
  return out;
}

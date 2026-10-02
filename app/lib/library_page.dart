import 'package:flutter/material.dart';

import 'library.dart';

/// Lists the books found on the device; returns the chosen [BookFile] when one is tapped.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.library});
  final LibraryController library;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _query = '';
  String _type = 'all'; // all | pdf | epub

  @override
  void initState() {
    super.initState();
    // First visit: start looking straight away.
    if (widget.library.books.isEmpty && widget.library.lastScan == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.library.scan());
    }
  }

  List<BookFile> _filtered(List<BookFile> books) {
    final q = _query.trim().toLowerCase();
    return books.where((b) {
      if (_type == 'pdf' && !b.isPdf) return false;
      if (_type == 'epub' && b.isPdf) return false;
      return q.isEmpty || b.name.toLowerCase().contains(q) || b.folder.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final books = _filtered(library.books);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Library'),
            actions: [
              if (library.scanning)
                TextButton(onPressed: library.cancelScan, child: const Text('Stop'))
              else
                IconButton(
                  tooltip: 'Scan this device for books',
                  icon: const Icon(Icons.manage_search),
                  onPressed: library.scan,
                ),
            ],
            bottom: library.scanning
                ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
                : null,
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search by name or folder',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    for (final (value, label) in [('all', 'All'), ('pdf', 'PDF'), ('epub', 'EPUB')])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(label),
                          selected: _type == value,
                          onSelected: (_) => setState(() => _type = value),
                        ),
                      ),
                    const Spacer(),
                    Flexible(
                      child: Text(
                        _summary(library, books.length),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (library.message != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(library.message!, style: theme.textTheme.bodyMedium),
                ),
              const Divider(height: 1),
              Expanded(
                child: books.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            library.scanning
                                ? 'Looking for PDF and EPUB files…'
                                : library.books.isEmpty
                                    ? 'Tap the scan button to find books on this device.'
                                    : 'No books match your search.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: books.length,
                        itemBuilder: (context, i) {
                          final b = books[i];
                          return ListTile(
                            leading: Icon(b.isPdf ? Icons.picture_as_pdf : Icons.menu_book,
                                color: theme.colorScheme.primary),
                            title: Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${_size(b.size)} · ${b.folder}',
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () => Navigator.of(context).pop(b),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _summary(LibraryController library, int shown) {
    if (library.scanning) {
      return '${library.books.length} found · ${library.foldersScanned} folders';
    }
    final total = library.books.length;
    return shown == total ? '$total books' : '$shown of $total books';
  }

  static String _size(int bytes) {
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).ceil()} KB';
  }
}

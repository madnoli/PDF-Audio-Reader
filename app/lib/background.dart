import 'package:audio_service/audio_service.dart';

import 'reader.dart';

/// Connects the reader to Android's media session, so reading continues in a
/// foreground service after the app is closed and can be controlled from the
/// notification, lock screen and headset buttons.
class ReaderAudioHandler extends BaseAudioHandler {
  ReaderAudioHandler(this.reader) {
    reader.addListener(_sync);
    _sync();
  }

  final ReaderController reader;
  String? _lastTitle;
  int? _lastSection;
  bool? _lastPlaying;

  void _sync() {
    final book = reader.book;
    if (book == null) return;
    final section = reader.current?.section;
    if (book.title != _lastTitle || section != _lastSection) {
      _lastTitle = book.title;
      _lastSection = section;
      mediaItem.add(MediaItem(
        id: reader.bookKey ?? book.title,
        title: book.title,
        album: section == null ? null : book.sections[section].title,
        artist: 'Audio Reader',
      ));
    }
    if (reader.playing != _lastPlaying) {
      _lastPlaying = reader.playing;
      playbackState.add(playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          reader.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop, // lets the notification be dismissed
        ],
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: reader.playing,
      ));
    }
  }

  @override
  Future<void> play() => reader.play();

  @override
  Future<void> pause() => reader.stop();

  @override
  Future<void> stop() async {
    await reader.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => reader.goTo(reader.index + 1);

  @override
  Future<void> skipToPrevious() => reader.goTo(reader.index - 1);
}

/// Starts the media session on Android; other platforms don't need it.
Future<void> startBackgroundAudio(ReaderController reader) async {
  try {
    await AudioService.init(
      builder: () => ReaderAudioHandler(reader),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.madnoli.audio_reader.reading',
        androidNotificationChannelName: 'Reading aloud',
        // Stay in the foreground while paused so play from the notification keeps working.
        androidStopForegroundOnPause: false,
      ),
    );
  } catch (_) {
    // Reading still works in the foreground without the media session.
  }
}

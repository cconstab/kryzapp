import 'package:at_client/at_client.dart';
import 'package:kryz_shared/kryz_shared.dart';
import 'package:logging/logging.dart';

final _logger = Logger('AtCollectionService');

/// Writes each [TransmitterStats] reading to an [AtCollection] shared with all
/// [receivers].  Every item is end-to-end encrypted by the SDK and persisted for
/// [retentionDays] days on the atServer, after which it expires automatically.
///
/// This replaces the old notify()-based stats path.  Alert notifications are
/// still sent via [AtNotificationService] so the mobile app can pop up an
/// immediate modal without waiting for a sync round-trip.
class AtCollectionService {
  final AtClient atClient;

  /// Receiver atsigns — items will be shared with each of these.
  final Set<Atsign> receivers;

  /// How long each reading is kept on the atServer before automatic expiry.
  final int retentionDays;

  late AtCollection<TransmitterStats> _collection;

  AtCollectionService({
    required this.atClient,
    required this.receivers,
    this.retentionDays = 7,
  });

  /// Open (or create) the collection namespace.  Must be called once after
  /// the [AtClient] is authenticated.
  Future<void> initialize() async {
    _logger.info('Initialising AtCollection<TransmitterStats> '
        '(namespace: stats.kryz, TTL: ${retentionDays}d, '
        'receivers: ${receivers.map((a) => a.toString()).join(", ")})');

    atClient.notificationService.startListening();

    _collection = await atClient.collection<TransmitterStats>(
      'stats.kryz',
      Duration(days: retentionDays),
      fromJson: TransmitterStats.fromJson,
      typeTag: 'TransmitterStats',
      eventSource: EventSource.data,
    );

    _logger.info('AtCollection initialised successfully');
  }

  /// Persist [stats] as a new collection item and share it with all receivers.
  ///
  /// The SDK handles key generation, encryption, and sync automatically.
  /// Each call produces one persisted record; the atServer expires records
  /// older than [retentionDays] automatically.
  Future<void> appendReading(TransmitterStats stats) async {
    try {
      await _collection.create(
        obj: stats,
        sharedWith: receivers,
      );
      _logger.fine(
          'Appended reading: ${stats.transmitterId} @ ${stats.timestamp.toIso8601String()}');
    } catch (e, st) {
      _logger.severe('Failed to append reading to collection', e, st);
      rethrow;
    }
  }
}

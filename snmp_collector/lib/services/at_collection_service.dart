import 'package:at_client/at_client.dart';
import 'package:kryz_shared/kryz_shared.dart';
import 'package:logging/logging.dart';

final _logger = Logger('AtCollectionService');

/// Writes transmitter readings using MRTG-style tiered storage to keep the
/// total key count bounded regardless of how long the collector runs.
///
/// Three resolution tiers, modelled on the MRTG/RRD consolidation approach:
///
/// | Tier      | Namespace     | TTL   | Resolution  | Max keys (approx) |
/// |-----------|---------------|-------|-------------|-------------------|
/// | Raw       | stats.kryz    | 2 h   | every poll  | ~1 440            |
/// | 1-minute  | stats1m.kryz  | 36 h  | 1-min avg   | ~2 160            |
/// | 30-minute | stats30m.kryz | 10 d  | 30-min avg  | ~480              |
/// | **Total** |               |       |             | **~4 080**        |
///
/// Compare with the naïve approach (7-day TTL, raw every 5 s): ~120 960 keys.
///
/// The raw tier feeds the live gauges and the 1-hour chart.
/// The 1-minute tier feeds the 6-hour and 24-hour charts.
/// The 30-minute tier feeds the 7-day chart.
///
/// Alert notifications are still sent via [AtNotificationService] for
/// immediate delivery — this service handles only the stats collection.
class AtCollectionService {
  final AtClient atClient;

  /// Receiver atsigns — items will be shared with each of these.
  final Set<Atsign> receivers;

  late AtCollection<TransmitterStats> _rawCollection;
  late AtCollection<TransmitterStats> _oneMinCollection;
  late AtCollection<TransmitterStats> _thirtyMinCollection;

  // Rolling accumulator for the 1-minute consolidation bucket.
  final List<TransmitterStats> _oneMinBuffer = [];
  DateTime? _oneMinBucketStart;

  // Rolling accumulator for the 30-minute consolidation bucket.
  final List<TransmitterStats> _thirtyMinBuffer = [];
  DateTime? _thirtyMinBucketStart;

  AtCollectionService({
    required this.atClient,
    required this.receivers,
  });

  /// Open all three collection namespaces.  Must be called once after the
  /// [AtClient] is authenticated.
  Future<void> initialize() async {
    _logger.info('Initialising tiered AtCollection storage '
        '(receivers: ${receivers.map((a) => a.toString()).join(", ")})');

    atClient.notificationService.startListening();

    // Raw — live feed + 1-hour chart.  Short TTL keeps key count bounded.
    _rawCollection = await atClient.collection<TransmitterStats>(
      'stats.kryz',
      const Duration(hours: 2),
      fromJson: TransmitterStats.fromJson,
      typeTag: 'TransmitterStats',
      eventSource: EventSource.data,
    );

    // 1-minute averages — 6-hour and 24-hour charts.
    _oneMinCollection = await atClient.collection<TransmitterStats>(
      'stats1m.kryz',
      const Duration(hours: 36),
      fromJson: TransmitterStats.fromJson,
      typeTag: 'TransmitterStats',
      eventSource: EventSource.data,
    );

    // 30-minute averages — 7-day chart.
    _thirtyMinCollection = await atClient.collection<TransmitterStats>(
      'stats30m.kryz',
      const Duration(days: 10),
      fromJson: TransmitterStats.fromJson,
      typeTag: 'TransmitterStats',
      eventSource: EventSource.data,
    );

    _logger.info('Tiered AtCollection storage initialised '
        '(raw 2 h / 1-min 36 h / 30-min 10 d)');
  }

  /// Persist [stats] to the appropriate resolution tiers.
  ///
  /// Every reading goes into the raw tier immediately.  When a 1-minute or
  /// 30-minute bucket closes, an averaged record is written to the
  /// corresponding higher tier.
  Future<void> appendReading(TransmitterStats stats) async {
    try {
      // ── Raw tier ─────────────────────────────────────────────────────────
      await _rawCollection.create(obj: stats, sharedWith: receivers);
      _logger.fine(
          'Appended reading: ${stats.transmitterId} @ ${stats.timestamp.toIso8601String()}');

      // ── Accumulate into consolidation buckets ─────────────────────────────
      _oneMinBucketStart ??= stats.timestamp;
      _thirtyMinBucketStart ??= stats.timestamp;
      _oneMinBuffer.add(stats);
      _thirtyMinBuffer.add(stats);

      // ── Flush 1-minute bucket ─────────────────────────────────────────────
      if (stats.timestamp.difference(_oneMinBucketStart!) >=
          const Duration(minutes: 1)) {
        final avg = _consolidate(_oneMinBuffer);
        await _oneMinCollection.create(obj: avg, sharedWith: receivers);
        _logger.fine('1-min avg written @ ${avg.timestamp.toIso8601String()} '
            '(${_oneMinBuffer.length} readings)');
        _oneMinBuffer.clear();
        _oneMinBucketStart = null;
      }

      // ── Flush 30-minute bucket ────────────────────────────────────────────
      if (stats.timestamp.difference(_thirtyMinBucketStart!) >=
          const Duration(minutes: 30)) {
        final avg = _consolidate(_thirtyMinBuffer);
        await _thirtyMinCollection.create(obj: avg, sharedWith: receivers);
        _logger.fine('30-min avg written @ ${avg.timestamp.toIso8601String()} '
            '(${_thirtyMinBuffer.length} readings)');
        _thirtyMinBuffer.clear();
        _thirtyMinBucketStart = null;
      }
    } catch (e, st) {
      _logger.severe('Failed to append reading', e, st);
      rethrow;
    }
  }

  /// Average a non-empty list of readings into a single consolidated record.
  ///
  /// Numeric fields are mean-averaged.  [status] and [alertLevel] come from
  /// the most-severe reading in the bucket: critical > warning > null.  The
  /// timestamp is the midpoint of the bucket so chart tooltips show the right
  /// time.
  TransmitterStats _consolidate(List<TransmitterStats> readings) {
    assert(readings.isNotEmpty);
    final n = readings.length;
    double avg(double Function(TransmitterStats) f) =>
        readings.map(f).reduce((a, b) => a + b) / n;

    // Worst alert level in the bucket.
    final alertLevel = readings.any((r) => r.alertLevel == 'critical')
        ? 'critical'
        : readings.any((r) => r.alertLevel == 'warning')
            ? 'warning'
            : null;

    return TransmitterStats(
      transmitterId: readings.last.transmitterId,
      timestamp: readings[n ~/ 2].timestamp, // midpoint of bucket
      modulation: avg((r) => r.modulation),
      swr: avg((r) => r.swr),
      powerOut: avg((r) => r.powerOut),
      powerRef: avg((r) => r.powerRef),
      heatTemp: avg((r) => r.heatTemp),
      fanSpeed: avg((r) => r.fanSpeed),
      status: readings.last.status,
      alertLevel: alertLevel,
    );
  }
}

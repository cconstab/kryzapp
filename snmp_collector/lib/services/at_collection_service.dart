import 'package:at_client/at_client.dart';
import 'package:kryz_shared/kryz_shared.dart';
import 'package:logging/logging.dart';

final _logger = Logger('AtCollectionService');

/// Writes transmitter readings using MRTG-style tiered storage to keep the
/// total key count bounded regardless of how long the collector runs.
///
/// Three resolution tiers, modelled on the MRTG/RRD consolidation approach:
///
/// | Tier     | Namespace    | TTL    | Resolution  | Max keys (approx) |
/// |----------|--------------|--------|-------------|-------------------|
/// | Raw      | stats.kryz   | 10 min | every 2 s   | ~300              |
/// | 5-minute | stats5m.kryz | 26 h   | 5-min avg   | ~312              |
/// | 1-hour   | stats1h.kryz | 8 d    | 1-hour avg  | ~192              |
/// | **Total**|              |        |             | **~804**          |
///
/// Compare with the naïve approach (7-day TTL, raw every 2 s): ~302 400 keys.
///
/// The raw tier feeds the live gauges and the recent end of the 1-hour chart
/// (last 10 min at 2 s resolution).
/// The 5-minute tier feeds the 6-hour and 24-hour charts.
/// The 1-hour tier feeds the 7-day chart.
///
/// Alert notifications are still sent via [AtNotificationService] for
/// immediate delivery — this service handles only the stats collection.
class AtCollectionService {
  final AtClient atClient;

  /// Receiver atsigns — items will be shared with each of these.
  final Set<Atsign> receivers;

  late AtCollection<TransmitterStats> _rawCollection;
  late AtCollection<TransmitterStats> _fiveMinCollection;
  late AtCollection<TransmitterStats> _oneHourCollection;

  // Rolling accumulator for the 5-minute consolidation bucket.
  final List<TransmitterStats> _fiveMinBuffer = [];
  DateTime? _fiveMinBucketStart;

  // Rolling accumulator for the 1-hour consolidation bucket.
  final List<TransmitterStats> _oneHourBuffer = [];
  DateTime? _oneHourBucketStart;

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

    // Raw — live gauges + recent tail of the 1-hour chart.  Very short TTL
    // keeps the key count tiny (~300 keys at 2 s poll rate).
    _rawCollection = await atClient.collection<TransmitterStats>(
      'stats.kryz',
      const Duration(minutes: 10),
      fromJson: TransmitterStats.fromJson,
      typeTag: 'TransmitterStats',
      eventSource: EventSource.data,
    );

    // 5-minute averages — 6-hour and 24-hour charts.
    _fiveMinCollection = await atClient.collection<TransmitterStats>(
      'stats5m.kryz',
      const Duration(hours: 26),
      fromJson: TransmitterStats.fromJson,
      typeTag: 'TransmitterStats',
      eventSource: EventSource.data,
    );

    // 1-hour averages — 7-day chart.
    _oneHourCollection = await atClient.collection<TransmitterStats>(
      'stats1h.kryz',
      const Duration(days: 8),
      fromJson: TransmitterStats.fromJson,
      typeTag: 'TransmitterStats',
      eventSource: EventSource.data,
    );

    _logger.info('Tiered AtCollection storage initialised '
        '(raw 10 min / 5-min 26 h / 1-hour 8 d)');
  }

  /// Persist [stats] to the appropriate resolution tiers.
  ///
  /// Every reading goes into the raw tier immediately.  When a 5-minute or
  /// 1-hour bucket closes, an averaged record is written to the corresponding
  /// higher tier.
  Future<void> appendReading(TransmitterStats stats) async {
    try {
      // ── Raw tier ─────────────────────────────────────────────────────────
      await _rawCollection.create(obj: stats, sharedWith: receivers);
      _logger.fine(
          'Appended reading: ${stats.transmitterId} @ ${stats.timestamp.toIso8601String()}');

      // ── Accumulate into consolidation buckets ─────────────────────────────
      _fiveMinBucketStart ??= stats.timestamp;
      _oneHourBucketStart ??= stats.timestamp;
      _fiveMinBuffer.add(stats);
      _oneHourBuffer.add(stats);

      // ── Flush 5-minute bucket ─────────────────────────────────────────────
      if (stats.timestamp.difference(_fiveMinBucketStart!) >=
          const Duration(minutes: 5)) {
        final avg = _consolidate(_fiveMinBuffer);
        await _fiveMinCollection.create(obj: avg, sharedWith: receivers);
        _logger.fine('5-min avg written @ ${avg.timestamp.toIso8601String()} '
            '(${_fiveMinBuffer.length} readings)');
        _fiveMinBuffer.clear();
        _fiveMinBucketStart = null;
      }

      // ── Flush 1-hour bucket ───────────────────────────────────────────────
      if (stats.timestamp.difference(_oneHourBucketStart!) >=
          const Duration(hours: 1)) {
        final avg = _consolidate(_oneHourBuffer);
        await _oneHourCollection.create(obj: avg, sharedWith: receivers);
        _logger.fine('1-hour avg written @ ${avg.timestamp.toIso8601String()} '
            '(${_oneHourBuffer.length} readings)');
        _oneHourBuffer.clear();
        _oneHourBucketStart = null;
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

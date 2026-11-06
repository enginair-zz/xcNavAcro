import 'dart:math';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';
import 'package:xcnav/models/glide_range.dart';
import 'package:xcnav/models/waypoint.dart';
import 'package:xcnav/models/wind_table.dart';

/// Meters per degree of latitude. (Same earth radius as latlong2's `Distance`)
const double _metersPerDegLat = pi * 6371009 / 180;

/// Name of the waypoint that marks the center of the acro box. Case and surrounding spaces don't matter.
const String acroWaypointName = "Acro";

/// First single-point waypoint named [acroWaypointName].
Waypoint? findAcroWaypoint(Iterable<Waypoint> waypoints) {
  for (final wp in waypoints) {
    if (!wp.isPath && wp.latlng.isNotEmpty && wp.name.trim().toLowerCase() == acroWaypointName.toLowerCase()) {
      return wp;
    }
  }
  return null;
}

/// [latlng] moved [east] and [north] meters. Flat earth: fine over the few miles of an acro box.
LatLng offsetMeters(LatLng latlng, double east, double north) => LatLng(latlng.latitude + north / _metersPerDegLat,
    latlng.longitude + east / (_metersPerDegLat * cos(latlng.latitude * pi / 180)));

/// Meters east and north from [from] to [to].
WindVector metersBetween(LatLng from, LatLng to) => (
      east: (to.longitude - from.longitude) * _metersPerDegLat * cos(from.latitude * pi / 180),
      north: (to.latitude - from.latitude) * _metersPerDegLat,
    );

// ============================================================================================
//
// Acro runs and the learned descent rate
//
// ============================================================================================

class AcroRun {
  /// Milliseconds since epoch
  final int start;
  final int end;

  /// Meters
  final double startAlt;
  final double endAlt;

  /// Ended by passing the hard deck (otherwise the pilot stopped maneuvering)
  final bool endedAtHardDeck;

  /// Long and deep enough to learn the descent rate from
  final bool accepted;

  const AcroRun(
      {required this.start,
      required this.end,
      required this.startAlt,
      required this.endAlt,
      required this.endedAtHardDeck,
      required this.accepted});

  Duration get duration => Duration(milliseconds: end - start);

  /// m/s, positive down
  double get descentRate => end > start ? (startAlt - endAlt) / (end - start) * 1000 : 0;
}

/// Finds acro runs from g-load and measures how fast they came down.
///
/// A run starts once g holds at [startG] or more for [holdMs] (backdated to the first high-g sample), so the straight
/// engine-off setup glide doesn't count. It ends at the hard deck, or once g stays under [quietG] for [quietMs].
class AcroRunDetector {
  static const double startG = 1.5;
  static const int holdMs = 1000;
  static const double quietG = 1.3;
  static const int quietMs = 20000;

  /// Shortest run worth learning from
  static const int minDurationMs = 15000;

  /// Smallest altitude loss worth learning from (meters). 150 ft.
  static const double minDrop = 45.72;

  /// Plausible descent rates (m/s). About 200 to 8,000 ft/min.
  static const double minRate = 1;
  static const double maxRate = 40;

  /// Altitude history (time ms, meters), so a backdated start can look up its altitude.
  final List<(int, double)> _alts = [];
  static const int _altHistoryMs = 180000;

  int? _highSince;
  int? _lastHigh;

  /// Start of the run in progress (ms)
  int? runStart;

  bool get running => runStart != null;

  void reset() {
    _alts.clear();
    _highSince = null;
    _lastHigh = null;
    runStart = null;
  }

  void addAlt(int time, double alt) {
    if (_alts.isNotEmpty && time <= _alts.last.$1) return;
    _alts.add((time, alt));
    while (_alts.length > 2 && time - _alts.first.$1 > _altHistoryMs && (runStart == null || _alts[1].$1 < runStart!)) {
      _alts.removeAt(0);
    }
  }

  /// Altitude at [time], interpolated between samples.
  double? altAt(int time) {
    if (_alts.isEmpty) return null;
    if (time <= _alts.first.$1) return _alts.first.$2;
    for (int i = 1; i < _alts.length; i++) {
      if (_alts[i].$1 >= time) {
        final (t0, a0) = _alts[i - 1];
        final (t1, a1) = _alts[i];
        return a0 + (a1 - a0) * (time - t0) / (t1 - t0);
      }
    }
    return _alts.last.$2;
  }

  void addG(int time, double g) {
    if (g >= startG) {
      _highSince ??= time;
      if (!running && time - _highSince! >= holdMs) runStart = _highSince;
    } else {
      _highSince = null;
    }
    if (g >= quietG) _lastHigh = time;
  }

  /// Check whether the run in progress has ended. [height] and [hardDeck] are meters above the ground.
  AcroRun? update(int now, {required double? height, required double hardDeck}) {
    final start = runStart;
    if (start == null) return null;
    int? end;
    bool atHardDeck = false;
    if (height != null && height <= hardDeck && now > start) {
      end = now;
      atHardDeck = true;
    } else if (now - (_lastHigh ?? start) >= quietMs) {
      end = _lastHigh ?? start;
    }
    if (end == null) return null;

    runStart = null;
    _highSince = null;
    final startAlt = altAt(start);
    final endAlt = altAt(end);
    if (startAlt == null || endAlt == null) return null;
    final rate = (startAlt - endAlt) / (end - start) * 1000;
    final ok = end - start >= minDurationMs && startAlt - endAlt >= minDrop && rate >= minRate && rate <= maxRate;
    return AcroRun(
        start: start, end: end, startAlt: startAlt, endAlt: endAlt, endedAtHardDeck: atHardDeck, accepted: ok);
  }
}

/// Runs the learned descent rate averages over. Older runs fade out past this, so the rate follows the pilot.
const int acroRateMemory = 10;

/// New average descent rate and run count after adding [rate].
(double, int) learnDescentRate(double average, int runs, double rate) {
  if (runs <= 0) return (rate, 1);
  final n = min(runs, acroRateMemory - 1);
  return ((average * n + rate) / (n + 1), runs + 1);
}

// ============================================================================================
//
// Reserve landing predictions
//
// ============================================================================================

/// Size of the landing spot right under a throw (meters): the box the pilot maneuvers in.
const double reserveSpotBase = 30;

/// Landing spots spread by this fraction of the drift distance, for wind error.
const double reserveSpotGrowth = 0.2;

/// Throw heights checked between the hard deck and the current height
const int reserveThrowSteps = 30;

class ReserveLanding {
  /// Meters above the ground
  final double throwHeight;

  /// Reserve descent rate (m/s)
  final double rate;

  final LatLng throwAt;
  final LatLng landAt;

  /// Meters
  final double radius;

  /// In the lowest third of the run, where landing near the acro waypoint matters most
  final bool lowerThird;

  const ReserveLanding(
      {required this.throwHeight,
      required this.rate,
      required this.throwAt,
      required this.landAt,
      required this.radius,
      required this.lowerThird});
}

class ReservePrediction {
  /// Throws from the current height down to the hard deck, for each reserve, highest first.
  final List<ReserveLanding> landings;

  /// Where to start the run, at the current height, so lower third throws land on the acro waypoint.
  final LatLng? startAt;

  /// Mean landing spot of the lower third throws
  final LatLng lowerThirdCenter;

  const ReservePrediction({required this.landings, required this.startAt, required this.lowerThirdCenter});

  List<ReserveLanding> get lowerThird => landings.where((l) => l.lowerThird).toList();

  /// Throw right now, for each reserve
  List<ReserveLanding> get throwNow => landings.where((l) => l.throwHeight == landings.first.throwHeight).toList();

  /// Throw at the hard deck, for each reserve
  List<ReserveLanding> get throwAtHardDeck =>
      landings.where((l) => l.throwHeight == landings.last.throwHeight).toList();
}

/// Where the reserve would land if thrown anywhere from now down to the hard deck.
///
/// The pilot drifts with the wind during the run at [acroRate], throws at some height, then drifts under the reserve
/// at its rate. Pure drift: no forward flight under the reserve. [height] and [hardDeck] are meters above the ground,
/// [windAt] takes meters above the ground. Null when the wind isn't known.
ReservePrediction? predictReserveLandings(
    {required LatLng from,
    required double height,
    required double hardDeck,
    required double acroRate,
    required List<double> reserveRates,
    required WindAt windAt,
    LatLng? target}) {
  final rates = reserveRates.where((r) => r > 0).toList();
  if (rates.isEmpty || acroRate <= 0 || height <= 0) return null;

  final bottom = max(0.0, min(height, hardDeck));
  final steps = height > bottom ? reserveThrowSteps : 0;
  final lowerThirdTop = bottom + (height - bottom) / 3;

  final landings = <ReserveLanding>[];
  double sumEast = 0, sumNorth = 0;
  int count = 0;
  for (int i = 0; i <= steps; i++) {
    final throwHeight = steps == 0 ? height : height - (height - bottom) * i / steps;
    final run = drift(windAt, from: height, to: throwHeight, rate: acroRate);
    if (run == null) return null;
    final throwAt = offsetMeters(from, run.east, run.north);
    final lowerThird = steps == 0 || throwHeight <= lowerThirdTop + 1e-6;
    for (final rate in rates) {
      final under = drift(windAt, from: throwHeight, to: 0, rate: rate);
      if (under == null) return null;
      final east = run.east + under.east;
      final north = run.north + under.north;
      final driftDist =
          sqrt(run.east * run.east + run.north * run.north) + sqrt(under.east * under.east + under.north * under.north);
      landings.add(ReserveLanding(
          throwHeight: throwHeight,
          rate: rate,
          throwAt: throwAt,
          landAt: offsetMeters(from, east, north),
          radius: reserveSpotBase + reserveSpotGrowth * driftDist,
          lowerThird: lowerThird));
      if (lowerThird) {
        sumEast += east;
        sumNorth += north;
        count++;
      }
    }
  }

  final meanEast = sumEast / count;
  final meanNorth = sumNorth / count;
  LatLng? startAt;
  if (target != null) startAt = offsetMeters(target, -meanEast, -meanNorth);
  return ReservePrediction(
      landings: landings, startAt: startAt, lowerThirdCenter: offsetMeters(from, meanEast, meanNorth));
}

/// Cell size limits for the landing zone raster (meters)
const double _zoneMinCell = 5;
const int _zoneCellsPerRadius = 40;

/// Landing zone as a grid, drawn with the glide range's look.
///
/// Each landing spot is a disc. Consecutive spots of the same reserve are joined, so the zone is a continuous band.
GlideRange reserveZoneRange(List<ReserveLanding> landings) {
  assert(landings.isNotEmpty);
  // Center and reach of the zone
  double minLat = double.infinity, maxLat = -double.infinity, minLng = double.infinity, maxLng = -double.infinity;
  double maxRadius = 0;
  for (final l in landings) {
    minLat = min(minLat, l.landAt.latitude);
    maxLat = max(maxLat, l.landAt.latitude);
    minLng = min(minLng, l.landAt.longitude);
    maxLng = max(maxLng, l.landAt.longitude);
    maxRadius = max(maxRadius, l.radius);
  }
  final origin = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
  double reach = 0;
  for (final l in landings) {
    final m = metersBetween(origin, l.landAt);
    reach = max(reach, sqrt(m.east * m.east + m.north * m.north) + l.radius);
  }
  reach = max(reach, maxRadius) * 1.05;
  final cellSize = max(_zoneMinCell, reach / _zoneCellsPerRadius);
  final halfSize = max(1, (reach / cellSize).ceil());
  final n = 2 * halfSize + 1;
  final grid = GlideGrid(origin: origin, cellSize: cellSize, halfSize: halfSize, ground: Float32List(n * n));

  final inside = Uint8List(n * n);

  /// Mark cells within the capsule from a to b (cell units), radius growing from ra to rb.
  void capsule(double ax, double ay, double ra, double bx, double by, double rb) {
    final r = max(ra, rb);
    final c0 = max(0, (min(ax, bx) - r).floor());
    final c1 = min(n - 1, (max(ax, bx) + r).ceil());
    final r0 = max(0, (min(ay, by) - r).floor());
    final r1 = min(n - 1, (max(ay, by) + r).ceil());
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    for (int row = r0; row <= r1; row++) {
      for (int col = c0; col <= c1; col++) {
        final t = len2 == 0 ? 0.0 : (((col - ax) * dx + (row - ay) * dy) / len2).clamp(0.0, 1.0);
        final px = ax + dx * t - col, py = ay + dy * t - row;
        final rr = ra + (rb - ra) * t;
        if (px * px + py * py <= rr * rr) inside[row * n + col] = 1;
      }
    }
  }

  (double, double) toCell(LatLng latlng) {
    final m = metersBetween(origin, latlng);
    return (halfSize + m.east / cellSize, halfSize - m.north / cellSize);
  }

  final byRate = <double, List<ReserveLanding>>{};
  for (final l in landings) {
    byRate.putIfAbsent(l.rate, () => []).add(l);
  }
  for (final spots in byRate.values) {
    for (int i = 0; i < spots.length; i++) {
      final (ax, ay) = toCell(spots[i].landAt);
      final ra = spots[i].radius / cellSize;
      if (i + 1 < spots.length) {
        final (bx, by) = toCell(spots[i + 1].landAt);
        capsule(ax, ay, ra, bx, by, spots[i + 1].radius / cellSize);
      } else {
        capsule(ax, ay, ra, ax, ay, ra);
      }
    }
  }

  final excess = Float32List(n * n);
  for (int i = 0; i < n * n; i++) {
    excess[i] = inside[i] == 1 ? 0 : double.nan;
  }
  return GlideRange(
      grid: grid,
      params: const GlideRangeParams(alt: 0, glideRatio: 1, margin: 0),
      excess: excess,
      unknown: Uint8List(n * n),
      touchesEdge: false,
      hasUnknown: false);
}

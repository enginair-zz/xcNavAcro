import 'dart:math';

/// Wind at one altitude. Components are the direction the wind blows toward.
typedef WindVector = ({double east, double north});

/// Wind at an altitude (meters), or null when nothing is known.
typedef WindAt = WindVector? Function(double alt);

/// Height of each wind table band (meters). 500 ft, counted up from 0 ft MSL.
const double windBandHeight = 152.4;

/// Wind table entries older than this are dropped.
const Duration windTableMaxAge = Duration(hours: 3);

class CircleFit {
  final double cx;
  final double cy;
  final double r;

  /// RMS distance of the points from the circle
  final double rms;

  const CircleFit(this.cx, this.cy, this.r, this.rms);
}

/// Algebraic circle fit (Taubin, solved with Newton's method). Null when the points don't define a circle.
///
/// Reference: Chernov, "Circular and Linear Regression", and https://people.cas.uab.edu/~mosya/cl/
CircleFit? fitCircleTaubin(List<double> xs, List<double> ys) {
  final n = xs.length;
  if (n < 3 || ys.length != n) return null;
  final xMean = xs.reduce((a, b) => a + b) / n;
  final yMean = ys.reduce((a, b) => a + b) / n;

  double mXX = 0, mYY = 0, mXY = 0, mXZ = 0, mYZ = 0, mZZ = 0;
  for (int i = 0; i < n; i++) {
    final x = xs[i] - xMean;
    final y = ys[i] - yMean;
    final z = x * x + y * y;
    mXX += x * x;
    mYY += y * y;
    mXY += x * y;
    mXZ += x * z;
    mYZ += y * z;
    mZZ += z * z;
  }
  mXX /= n;
  mYY /= n;
  mXY /= n;
  mXZ /= n;
  mYZ /= n;
  mZZ /= n;

  final mZ = mXX + mYY;
  final covXY = mXX * mYY - mXY * mXY;
  final varZ = mZZ - mZ * mZ;
  final a3 = 4 * mZ;
  final a2 = -3 * mZ * mZ - mZZ;
  final a1 = varZ * mZ + 4 * covXY * mZ - mXZ * mXZ - mYZ * mYZ;
  final a0 = mXZ * (mXZ * mYY - mYZ * mXY) + mYZ * (mYZ * mXX - mXZ * mXY) - varZ * covXY;

  double x = 0;
  double y = a0;
  for (int iter = 0; iter < 99; iter++) {
    final dy = a1 + x * (2 * a2 + x * 3 * a3);
    final xNew = x - y / dy;
    if (!xNew.isFinite || xNew == x) break;
    final yNew = a0 + xNew * (a1 + xNew * (a2 + xNew * a3));
    if (yNew.abs() >= y.abs()) break;
    x = xNew;
    y = yNew;
  }

  final det = x * x - x * mZ + covXY;
  if (!det.isFinite || det.abs() < 1e-12) return null;
  final cx = (mXZ * (mYY - x) - mYZ * mXY) / det / 2;
  final cy = (mYZ * (mXX - x) - mXZ * mXY) / det / 2;
  final r = sqrt(cx * cx + cy * cy + mZ);
  if (!r.isFinite) return null;

  double sumSq = 0;
  for (int i = 0; i < n; i++) {
    final d = sqrt(pow(xs[i] - xMean - cx, 2) + pow(ys[i] - yMean - cy, 2)) - r;
    sumSq += d * d;
  }
  return CircleFit(cx + xMean, cy + yMean, r, sqrt(sumSq / n));
}

/// Circle of known radius [r] through the points: only the center is fitted (Gauss-Newton from each of [starts]).
/// Far steadier than a free fit over a short arc, where center and radius trade off against each other.
CircleFit? fitCircleFixedRadius(List<double> xs, List<double> ys, double r, List<(double, double)> starts) {
  final n = xs.length;
  if (n < 2 || ys.length != n) return null;
  CircleFit? best;
  for (var (cx, cy) in starts) {
    for (int iter = 0; iter < 30; iter++) {
      double a = 0, b = 0, c = 0, bx = 0, by = 0;
      for (int i = 0; i < n; i++) {
        final dx = xs[i] - cx, dy = ys[i] - cy;
        final d = max(sqrt(dx * dx + dy * dy), 1e-9);
        final ux = dx / d, uy = dy / d;
        a += ux * ux;
        b += ux * uy;
        c += uy * uy;
        bx += ux * (d - r);
        by += uy * (d - r);
      }
      final det = a * c - b * b;
      if (det.abs() < 1e-12) break;
      final sx = (c * bx - b * by) / det, sy = (a * by - b * bx) / det;
      cx += sx;
      cy += sy;
      if (sqrt(sx * sx + sy * sy) < 1e-4) break;
    }
    double sumSq = 0;
    for (int i = 0; i < n; i++) {
      final d = sqrt(pow(xs[i] - cx, 2) + pow(ys[i] - cy, 2)) - r;
      sumSq += d * d;
    }
    final fit = CircleFit(cx, cy, r, sqrt(sumSq / n));
    if (fit.rms.isFinite && (best == null || fit.rms < best.rms)) best = fit;
  }
  return best;
}

/// Air density relative to sea level (standard atmosphere) at [alt] meters MSL.
double densityRatio(double alt) => pow(1 - 2.25577e-5 * alt, 4.2559).toDouble();

/// Smallest arc (radians) that holds all [headings]. Handles the wrap at north.
double headingSpan(Iterable<double> headings) {
  final angles = headings.map((h) => h % (2 * pi)).toList()..sort();
  if (angles.length < 2) return 0;
  double maxGap = angles.first + 2 * pi - angles.last;
  for (int i = 1; i < angles.length; i++) {
    maxGap = max(maxGap, angles[i] - angles[i - 1]);
  }
  return 2 * pi - maxGap;
}

class WindEstimate {
  /// m/s, toward
  final double east;
  final double north;

  /// m/s
  final double airspeed;

  /// Meters MSL: middle of the turn
  final double alt;

  /// Meters MSL: lowest and highest points of the turn. Default to [alt].
  final double minAlt;
  final double maxAlt;

  /// Milliseconds since epoch
  final int time;

  const WindEstimate(
      {required this.east,
      required this.north,
      required this.airspeed,
      required this.alt,
      double? minAlt,
      double? maxAlt,
      required this.time})
      : minAlt = minAlt ?? alt,
        maxAlt = maxAlt ?? alt;

  double get speed => sqrt(east * east + north * north);
}

/// GPS sample used for the wind fit.
class _TurnSample {
  final int time;
  final double alt;

  /// Radians
  final double hdg;

  /// m/s
  final double spd;

  const _TurnSample(this.time, this.alt, this.hdg, this.spd);
}

/// Fits the wind over each quarter turn (or more) of a climb.
///
/// Ground speed vectors around a turn lie on a circle: the center is the wind, the radius the airspeed. Samples are
/// used once: after a fit the next one starts fresh, so each band gets independent estimates.
///
/// The turn is measured through the air (around the fitted wind), not by ground track: downwind the ground track
/// swings slower than the wing turns, upwind faster.
///
/// On full power with hands off the brakes the airspeed hardly changes, so once [minAirspeedFits] fits agree on it,
/// it's held ([airspeed]) and later turns only fit the wind. The held airspeed is kept at sea level and scaled for
/// thinner air higher up. It follows fits within [airspeedTolerance] of it, and moves to a new value once
/// [minAirspeedFits] fits in a row agree on one (other wing or trim).
class QuarterTurnWindFitter {
  /// Turn through the air needed for a fit
  static const double minSpan = pi / 2;

  /// Ground track swing before trying a fit. Downwind, a quarter turn through the air swings the ground track less.
  static const double minGroundSpan = pi / 3;
  static const int minSamples = 5;

  /// A quarter turn shorter than this is a snap turn, not a steady one.
  static const int minDurationMs = 6000;
  static const int maxAgeMs = 60000;

  /// Strongest paramotor climb (m/s): 1000 ft/min.
  static const double maxClimb = 1000 / 196.85;

  /// Slowest quarter turn to allow for (ms).
  static const int slowQuarterTurnMs = 20000;

  /// Samples more than this far below the newest one are dropped (meters): a slow quarter turn at the strongest
  /// climb still fits. About 330 ft.
  static const double maxAltSpan = maxClimb * slowQuarterTurnMs / 1000;

  static const double minAirspeed = 3;
  static const double maxAirspeed = 30;

  /// Max RMS fit error, as a fraction of airspeed
  static const double maxRelRms = 0.15;

  static const int minAirspeedFits = 3;
  static const double airspeedTolerance = 0.15;

  final List<_TurnSample> _samples = [];

  /// Sea-level airspeeds (m/s) of recent free fits that agreed with the held airspeed, and of ones that didn't
  final List<double> _airspeeds = [];
  final List<double> _outliers = [];

  int get sampleCount => _samples.length;

  /// Ground track swing covered by the current samples (radians)
  double get span => headingSpan(_samples.map((s) => s.hdg));

  /// Held airspeed (m/s at sea level), once [minAirspeedFits] fits agree
  double? get airspeed => _airspeeds.length < minAirspeedFits ? null : _median(_airspeeds);

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// Start the next turn fresh. The held airspeed stays.
  void reset() => _samples.clear();

  /// Forget the held airspeed too
  void clear() {
    _samples.clear();
    _airspeeds.clear();
    _outliers.clear();
  }

  /// Track the held airspeed from a free fit's (sea-level) airspeed
  void _learnAirspeed(double seaLevel) {
    final held = airspeed;
    if (held == null || (seaLevel / held - 1).abs() <= airspeedTolerance) {
      _airspeeds.add(seaLevel);
      if (_airspeeds.length > 9) _airspeeds.removeAt(0);
      _outliers.clear();
      return;
    }
    _outliers.add(seaLevel);
    if (_outliers.length < minAirspeedFits) return;
    final median = _median(_outliers);
    if (_outliers.every((a) => (a / median - 1).abs() <= airspeedTolerance)) {
      _airspeeds
        ..clear()
        ..addAll(_outliers);
      _outliers.clear();
    } else {
      _outliers.removeAt(0);
    }
  }

  /// Add a GPS sample taken during a steady climb. Returns an estimate when the samples cover enough of a turn.
  WindEstimate? add({required int time, required double alt, required double hdg, required double spd}) {
    if (!spd.isFinite || !hdg.isFinite || spd <= 0) return null;
    _samples.add(_TurnSample(time, alt, hdg, spd));
    _samples.removeWhere((s) => time - s.time > maxAgeMs || alt - s.alt > maxAltSpan);

    if (_samples.length < minSamples) return null;
    if (time - _samples.first.time < minDurationMs) return null;
    if (span < minGroundSpan) return null;

    final xs = _samples.map((s) => s.spd * sin(s.hdg)).toList();
    final ys = _samples.map((s) => s.spd * cos(s.hdg)).toList();
    final fit = fitCircleTaubin(xs, ys);
    // Keep collecting until the wing has turned a quarter turn through the air
    if (fit != null &&
        headingSpan([for (int i = 0; i < xs.length; i++) atan2(xs[i] - fit.cx, ys[i] - fit.cy)]) < minSpan) {
      return null;
    }
    final count = _samples.length;
    final meanAlt = _samples.map((s) => s.alt).reduce((a, b) => a + b) / count;
    final minAlt = _samples.map((s) => s.alt).reduce(min);
    final maxAlt = _samples.map((s) => s.alt).reduce(max);

    // Start the next fit from here either way. A bad fit means the samples weren't a steady turn.
    final last = _samples.last;
    _samples
      ..clear()
      ..add(last);

    final freeOk = fit != null &&
        fit.r >= minAirspeed &&
        fit.r <= maxAirspeed &&
        sqrt(fit.cx * fit.cx + fit.cy * fit.cy) < fit.r * 0.9 &&
        fit.rms <= fit.r * maxRelRms;
    final held = airspeed;
    if (freeOk) _learnAirspeed(fit.r * sqrt(densityRatio(meanAlt)));
    if (held == null) {
      return freeOk
          ? WindEstimate(
              east: fit.cx, north: fit.cy, airspeed: fit.r, alt: meanAlt, minAlt: minAlt, maxAlt: maxAlt, time: time)
          : null;
    }

    // Airspeed known: fit only the wind
    final r = held / sqrt(densityRatio(meanAlt));
    final meanX = xs.reduce((a, b) => a + b) / count, meanY = ys.reduce((a, b) => a + b) / count;
    final fixed = fitCircleFixedRadius(xs, ys, r, [if (fit != null) (fit.cx, fit.cy), (meanX, meanY)]);
    if (fixed == null) return null;
    if (sqrt(fixed.cx * fixed.cx + fixed.cy * fixed.cy) >= r * 0.9) return null;
    if (fixed.rms > r * maxRelRms) return null;
    return WindEstimate(
        east: fixed.cx, north: fixed.cy, airspeed: r, alt: meanAlt, minAlt: minAlt, maxAlt: maxAlt, time: time);
  }
}

/// Wind estimates in one altitude band.
class WindBand {
  double east;
  double north;
  double airspeed;
  int count;

  /// Milliseconds since epoch of the newest estimate
  int updated;

  WindBand({required this.east, required this.north, required this.airspeed, this.count = 1, required this.updated});

  double get speed => sqrt(east * east + north * north);

  /// Radians. Direction the wind blows from.
  double get fromHdg => (atan2(-east, -north) + 2 * pi) % (2 * pi);

  /// Blend in a new estimate. Newer estimates count more, so the band follows the wind as it changes.
  void add(WindEstimate est) {
    final weight = max(0.3, 1 / (count + 1));
    east += (est.east - east) * weight;
    north += (est.north - north) * weight;
    airspeed += (est.airspeed - airspeed) * weight;
    count++;
    updated = max(updated, est.time);
  }

  Map<String, dynamic> toJson() => {"e": east, "n": north, "a": airspeed, "c": count, "t": updated};

  factory WindBand.fromJson(Map<String, dynamic> json) => WindBand(
      east: (json["e"] as num).toDouble(),
      north: (json["n"] as num).toDouble(),
      airspeed: (json["a"] as num).toDouble(),
      count: json["c"] as int,
      updated: json["t"] as int);
}

/// Wind by altitude, built from observed wind only.
class WindTable {
  /// Keyed by band index: floor(alt / [windBandHeight]). Altitudes are meters MSL.
  final Map<int, WindBand> bands = {};

  WindTable();

  bool get isEmpty => bands.isEmpty;

  static int bandFor(double alt) => (alt / windBandHeight).floor();

  /// Bottom of a band (meters MSL)
  static double bandBottom(int band) => band * windBandHeight;

  /// Middle of a band (meters MSL)
  static double bandCenter(int band) => (band + 0.5) * windBandHeight;

  /// Add to every band the turn passed through.
  void add(WindEstimate est) {
    for (int band = bandFor(est.minAlt); band <= bandFor(est.maxAlt); band++) {
      final existing = bands[band];
      if (existing == null) {
        bands[band] = WindBand(east: est.east, north: est.north, airspeed: est.airspeed, updated: est.time);
      } else {
        existing.add(est);
      }
    }
  }

  /// Drop bands with nothing newer than [maxAge]. Returns true if any were dropped.
  bool expire(int nowMs, {Duration maxAge = windTableMaxAge}) {
    final before = bands.length;
    bands.removeWhere((_, b) => nowMs - b.updated > maxAge.inMilliseconds);
    return bands.length != before;
  }

  void clear() => bands.clear();

  /// Wind at [alt] (meters MSL). Interpolated between bands, and held constant above the top band and below the
  /// bottom one.
  WindVector? windAt(double alt) {
    if (bands.isEmpty) return null;
    final keys = bands.keys.toList()..sort();
    final x = alt / windBandHeight - 0.5;
    if (x <= keys.first) return (east: bands[keys.first]!.east, north: bands[keys.first]!.north);
    if (x >= keys.last) return (east: bands[keys.last]!.east, north: bands[keys.last]!.north);
    for (int i = 1; i < keys.length; i++) {
      if (x <= keys[i]) {
        final lo = bands[keys[i - 1]]!;
        final hi = bands[keys[i]]!;
        final t = (x - keys[i - 1]) / (keys[i] - keys[i - 1]);
        return (east: lo.east + (hi.east - lo.east) * t, north: lo.north + (hi.north - lo.north) * t);
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => bands.map((k, v) => MapEntry(k.toString(), v.toJson()));

  factory WindTable.fromJson(Map<String, dynamic> json) {
    final table = WindTable();
    json.forEach((k, v) => table.bands[int.parse(k)] = WindBand.fromJson(v as Map<String, dynamic>));
    return table;
  }
}

/// Altitude step used when integrating drift (meters)
const double _driftStep = 10;

/// How far the wind carries something descending from [from] to [to] (meters, [to] < [from]) at [rate] m/s.
///
/// Meters east and north. Null when the wind isn't known.
WindVector? drift(WindAt windAt, {required double from, required double to, required double rate}) {
  if (rate <= 0) return null;
  if (from <= to) return (east: 0, north: 0);
  final steps = max(1, ((from - to) / _driftStep).ceil());
  final dz = (from - to) / steps;
  double east = 0, north = 0;
  for (int i = 0; i < steps; i++) {
    final w = windAt(from - (i + 0.5) * dz);
    if (w == null) return null;
    east += w.east * dz / rate;
    north += w.north * dz / rate;
  }
  return (east: east, north: north);
}

/// Why the wind table isn't recording right now, or null when it is.
///
/// Any normal flight is used (climb, level, glide); acro and taxiing are left out. Turns that aren't steady circles
/// are dropped by the fit itself. [height] is meters above the ground. [minG], [maxG] and [maxRotation] (degrees per
/// second) are the extremes over the last couple seconds.
String? windTableGate(
    {required double? height, required bool acroRun, double? minG, double? maxG, double? maxRotation}) {
  if (height == null) return "No ground elevation";
  if (height < 30.48) return "Below 100 ft";
  if (acroRun) return "Acro run";
  if ((maxG != null && maxG >= 1.3) || (minG != null && minG < 0.7)) return "Pulling or unloading g";
  if (maxRotation != null && maxRotation >= 60) return "Rotating fast";
  return null;
}

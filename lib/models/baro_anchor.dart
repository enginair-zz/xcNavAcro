import 'dart:math';

import 'package:xcnav/models/geo.dart';

/// Ties the barometer's reference (sea level) pressure to GPS altitude.
///
/// The barometer tracks altitude changes instantly, but its reference drifts with the weather, and its altitude scale
/// is off by a few percent when the air isn't a standard day. GPS altitude is right on average, but noisy, and can lag
/// several seconds behind in hard maneuvers. So the barometer gives the altitude and GPS corrects the reference:
/// - On the ground, the reference is the median of what each GPS fix in the last [groundWindow] implies. One bad fix
///   can't set it, and walking or driving uphill doesn't skew it.
/// - In flight it follows GPS with a [timeConstant] of about 10 s (10% per 1 s fix). That keeps up with the barometer's
///   scale error through climbs and changing air masses.
/// - It doesn't follow at all while maneuvering (the caller decides, see [onFlight]), so a lagging GPS altitude in a
///   spiral or acro can't pull the barometer with it.
class BaroAnchor {
  final Duration timeConstant;
  final Duration groundWindow;

  /// Reference (ambient) pressure, hPa. Null until the first fix.
  double? ambient;

  int? _lastTime;

  /// (time ms, implied ambient hPa) of recent fixes on the ground
  final List<(int, double)> _ground = [];

  BaroAnchor({
    this.timeConstant = const Duration(milliseconds: 9500),
    this.groundWindow = const Duration(seconds: 60),
  });

  /// Reference pressure that would make the barometer read [gpsAlt] (meters) at [pressure] (hPa).
  static double impliedAmbient(double gpsAlt, double pressure) => ambientFromAlt(gpsAlt, pressure);

  /// A GPS fix while on the ground.
  void onGround(int time, double gpsAlt, double pressure) {
    final implied = impliedAmbient(gpsAlt, pressure);
    if (!implied.isFinite) return;
    _ground.add((time, implied));
    _ground.removeWhere((e) => time - e.$1 > groundWindow.inMilliseconds || e.$1 > time);
    final values = _ground.map((e) => e.$2).toList()..sort();
    ambient = values[values.length ~/ 2];
    _lastTime = time;
  }

  /// A GPS fix in flight. While [maneuvering], GPS altitude is least trustworthy, so the reference stays where it is.
  void onFlight(int time, double gpsAlt, double pressure, {required bool maneuvering}) {
    final implied = impliedAmbient(gpsAlt, pressure);
    final last = _lastTime;
    _lastTime = time;
    _ground.clear();
    if (!implied.isFinite) return;
    if (ambient == null) {
      ambient = implied;
      return;
    }
    if (maneuvering) return;
    final dt = last == null ? 0 : (time - last).clamp(0, 10000);
    final k = 1 - exp(-dt / timeConstant.inMilliseconds);
    ambient = ambient! + (implied - ambient!) * k;
  }

  /// Set the reference so the barometer reads [altitude] (meters) at [pressure] (hPa). Used when switching between
  /// barometers, so the altitude carries on smoothly.
  void setAltitude(double altitude, double pressure) {
    final next = ambientFromAlt(altitude, pressure);
    if (next.isFinite) ambient = next;
  }

  void reset() {
    ambient = null;
    _lastTime = null;
    _ground.clear();
  }
}

/// Learns the altitude difference between the phone's barometer and an external one while both report, so a switch
/// between them (an external sensor dropping out or coming back) doesn't make the altitude jump.
class BaroSourceOffset {
  /// Readings further apart than this aren't compared (the altitude may have changed between them).
  static const int maxSkewMs = 150;

  /// Meters, phone minus external, as read with the same reference pressure. Null until both have reported together.
  double? offset;

  (int, double)? _phone;
  (int, double)? _external;

  /// A phone barometer reading: time ms, pressure hPa, current reference pressure hPa.
  void addPhone(int time, double pressure, double? ambient) {
    _phone = (time, pressure);
    _update(ambient);
  }

  /// An external barometer reading: time ms, pressure hPa, current reference pressure hPa.
  void addExternal(int time, double pressure, double? ambient) {
    _external = (time, pressure);
    _update(ambient);
  }

  void _update(double? ambient) {
    final phone = _phone, external = _external;
    if (ambient == null || phone == null || external == null || (phone.$1 - external.$1).abs() > maxSkewMs) return;
    final diff = altFromBaro(phone.$2, ambient) - altFromBaro(external.$2, ambient);
    if (!diff.isFinite) return;
    offset = offset == null ? diff : offset! + (diff - offset!) * 0.02;
  }

  /// Altitude (meters) the new barometer should continue from, so it matches the old one.
  /// [toExternal]: switching from the phone to the external barometer. Null if the offset isn't known yet.
  double? continueFrom({required bool toExternal, required double newPressure, required double ambient}) {
    final o = offset;
    if (o == null) return null;
    return altFromBaro(newPressure, ambient) + (toExternal ? o : -o);
  }
}

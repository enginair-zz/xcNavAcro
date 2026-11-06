import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xcnav/audio_cue_service.dart';
import 'package:xcnav/dem_service.dart';
import 'package:xcnav/models/acro.dart';
import 'package:xcnav/models/geo.dart';
import 'package:xcnav/models/waypoint.dart';
import 'package:xcnav/models/wind_table.dart';
import 'package:xcnav/providers/active_plan.dart';
import 'package:xcnav/providers/wind.dart';
import 'package:xcnav/settings_service.dart';
import 'package:xcnav/tts_service.dart';
import 'package:xcnav/units.dart';
import 'package:xcnav/util.dart';
import 'package:xcnav/widgets/waypoint_marker.dart' show colorOptions;

typedef GroundAt = double? Function(LatLng latlng);

double? _sampleGround(LatLng latlng) => sampleDem(latlng, true);

/// What the acro heights are measured from.
enum AcroGroundRef {
  /// Ground under the "Acro" waypoint
  waypoint,

  /// Launch altitude
  launch,

  /// Ground under the pilot
  here,
}

/// Acro mode: wind table, acro runs and the learned descent rate, and reserve landing predictions.
///
/// Fed every GPS fix while acro mode is on.
class AcroService with ChangeNotifier {
  WindTable table = WindTable();
  final QuarterTurnWindFitter fitter = QuarterTurnWindFitter();
  final AcroRunDetector runDetector = AcroRunDetector();

  /// Why the wind table isn't recording right now. Null while recording.
  String? tableGate = "No GPS yet";
  WindEstimate? lastEstimate;
  AcroRun? lastRun;
  ReservePrediction? prediction;
  Waypoint? acroWaypoint;

  /// Ground the heights are measured from (meters MSL)
  double? groundRef;
  AcroGroundRef? groundRefSource;

  /// Pilot's height above [groundRef] (meters)
  double? height;

  final GroundAt groundAt;
  AcroService({this.groundAt = _sampleGround});

  int _lastGTime = 0;
  int _lastRotationTime = 0;
  bool _loaded = false;

  /// Rotation rate (degrees per second, any axis), averaged every 100 ms. Only the last few seconds are kept.
  final List<TimestampValue<double>> rotationRecord = [];
  StreamSubscription<GyroscopeEvent>? _gyro;
  int _gyroWindowStart = 0;
  double _gyroX = 0, _gyroY = 0, _gyroZ = 0;
  int _gyroCount = 0;

  /// The gyroscope only runs in flight with acro mode on, to save battery.
  void startGyro() {
    if (_gyro != null) return;
    _gyroWindowStart = DateTime.now().millisecondsSinceEpoch;
    _gyro = gyroscopeEventStream(samplingPeriod: const Duration(milliseconds: 10)).listen((event) {
      _gyroX += event.x;
      _gyroY += event.y;
      _gyroZ += event.z;
      _gyroCount++;
      final time = event.timestamp.millisecondsSinceEpoch;
      if (time > _gyroWindowStart + 100) {
        final radPerSec = sqrt(pow(_gyroX / _gyroCount, 2) + pow(_gyroY / _gyroCount, 2) + pow(_gyroZ / _gyroCount, 2));
        rotationRecord.add(TimestampValue<double>(time, radPerSec * 180 / pi));
        rotationRecord.removeWhere((r) => time - r.time > 10000);
        _gyroWindowStart = time;
        _gyroX = _gyroY = _gyroZ = 0;
        _gyroCount = 0;
      }
    }, onError: (err) => debugPrint("Gyroscope unavailable: $err"));
  }

  void stopGyro() {
    _gyro?.cancel();
    _gyro = null;
    _gyroCount = 0;
    _gyroX = _gyroY = _gyroZ = 0;
  }

  Timer? _saveTimer;
  static const _prefsKey = "acro.windTable";

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final loaded = WindTable.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        // Keep anything recorded before the load finished
        loaded.bands.addAll(table.bands);
        table = loaded;
        table.expire(DateTime.now().millisecondsSinceEpoch);
        notifyListeners();
      }
    } catch (err, trace) {
      debugPrint("Failed to load wind table: $err\n$trace");
    }
  }

  void _scheduleSave() {
    _saveTimer ??= Timer(const Duration(seconds: 10), () async {
      _saveTimer = null;
      final prefs = await SharedPreferences.getInstance();
      prefs.setString(_prefsKey, jsonEncode(table.toJson()));
    });
  }

  bool _hadAcroWaypoint = false;

  /// Acro waypoints are always purple, and adding one turns acro mode on.
  void onPlanChanged(ActivePlan plan) {
    final purple = colorOptions["purple"]!.toARGB32();
    final toRecolor = plan.waypoints.values.where((wp) => isAcroWaypoint(wp) && wp.color != purple).toList();
    final hasAcro = findAcroWaypoint(plan.waypoints.values) != null;
    if (hasAcro && !_hadAcroWaypoint) settingsMgr.acroMode.value = true;
    _hadAcroWaypoint = hasAcro;
    // Not while the plan is still notifying
    if (toRecolor.isNotEmpty) {
      scheduleMicrotask(() {
        for (final wp in toRecolor) {
          wp.color = purple;
          plan.updateWaypoint(wp);
        }
      });
    }
  }

  void clearTable() {
    table.clear();
    fitter.reset();
    lastEstimate = null;
    _scheduleSave();
    notifyListeners();
  }

  /// Read the app state and settings, then [update]. Learns from finished runs and calls out the hard deck.
  void handleGeo(BuildContext context, Geo geo,
      {required List<TimestampValue<double>> gForce, double? launchAlt, required bool inFlight}) {
    load();
    inFlight ? startGyro() : stopGyro();
    final plan = Provider.of<ActivePlan>(context, listen: false);
    final wind = Provider.of<Wind>(context, listen: false).result;
    final hardDeck = settingsMgr.acroHardDeck.value;
    final run = update(geo,
        gForce: gForce,
        rotation: rotationRecord,
        launchAlt: launchAlt,
        waypoints: plan.waypoints.values,
        currentWind:
            wind == null ? null : (east: wind.windSpd * sin(wind.windHdg), north: wind.windSpd * cos(wind.windHdg)),
        hardDeck: hardDeck,
        acroRate: settingsMgr.acroDescentRate.value,
        reserveRates: [settingsMgr.acroReserve1Rate.value, settingsMgr.acroReserve2Rate.value]);

    if (run != null) {
      if (run.accepted) {
        final (rate, runs) =
            learnDescentRate(settingsMgr.acroDescentRate.value, settingsMgr.acroDescentRuns.value, run.descentRate);
        settingsMgr.acroDescentRate.value = rate;
        settingsMgr.acroDescentRuns.value = runs;
      }
      if (run.endedAtHardDeck) {
        audioCueService.ttsService.speak(AudioMessage(
            "Hard deck reached, ${unitConverters[UnitType.distFine]!(hardDeck).round()}",
            priority: 0,
            expires: DateTime.now().add(const Duration(seconds: 5))));
      }
    }
  }

  /// Process a GPS fix. Returns a run when one just finished.
  ///
  /// [currentWind] is the live wind solution, used while the wind table is empty. [rotation] is degrees per second.
  AcroRun? update(Geo geo,
      {required List<TimestampValue<double>> gForce,
      List<TimestampValue<double>> rotation = const [],
      double? launchAlt,
      required Iterable<Waypoint> waypoints,
      WindVector? currentWind,
      required double hardDeck,
      required double acroRate,
      required List<double> reserveRates}) {
    final now = geo.time;

    // --- Height reference
    acroWaypoint = findAcroWaypoint(waypoints);
    final wpGround = acroWaypoint == null ? null : groundAt(acroWaypoint!.latlng.first);
    if (wpGround != null) {
      groundRef = wpGround;
      groundRefSource = AcroGroundRef.waypoint;
    } else if (launchAlt != null) {
      groundRef = launchAlt;
      groundRefSource = AcroGroundRef.launch;
    } else {
      groundRef = geo.ground;
      groundRefSource = geo.ground == null ? null : AcroGroundRef.here;
    }
    height = groundRef == null ? null : geo.alt - groundRef!;

    // --- G-load and rotation, new samples in time order
    double? maxG, minG, maxRotation;
    for (int i = gForce.length - 1; i >= 0 && gForce[i].time > now - 2000; i--) {
      maxG = max(maxG ?? 0, gForce[i].value);
      minG = min(minG ?? double.infinity, gForce[i].value);
    }
    for (int i = rotation.length - 1; i >= 0 && rotation[i].time > now - 2000; i--) {
      maxRotation = max(maxRotation ?? 0, rotation[i].value);
    }
    runDetector.armed = height == null || height! > hardDeck;
    final newG = gForce.where((g) => g.time > _lastGTime).toList();
    final newRotation = rotation.where((r) => r.time > _lastRotationTime).toList();
    if (newG.isNotEmpty) _lastGTime = newG.last.time;
    if (newRotation.isNotEmpty) _lastRotationTime = newRotation.last.time;
    int gi = 0, ri = 0;
    while (gi < newG.length || ri < newRotation.length) {
      if (ri >= newRotation.length || (gi < newG.length && newG[gi].time <= newRotation[ri].time)) {
        runDetector.addG(newG[gi].time, newG[gi].value);
        gi++;
      } else {
        runDetector.addRotation(newRotation[ri].time, newRotation[ri].value);
        ri++;
      }
    }

    // --- Wind table
    tableGate =
        windTableGate(height: height, acroRun: runDetector.running, minG: minG, maxG: maxG, maxRotation: maxRotation);
    if (tableGate == null) {
      final est = fitter.add(time: now, alt: geo.alt, hdg: geo.hdg, spd: geo.spd);
      if (est != null) {
        table.add(est);
        lastEstimate = est;
        _scheduleSave();
      }
    } else {
      fitter.reset();
    }
    if (table.expire(now)) _scheduleSave();

    // --- Acro runs
    runDetector.addAlt(now, geo.alt);
    final run = runDetector.update(now, height: height, hardDeck: hardDeck);
    if (run != null) lastRun = run;

    // --- Reserve landings
    prediction = null;
    final ref = groundRef;
    if (ref != null && height != null && height! > 0) {
      WindVector? windAt(double h) => table.windAt(ref + h) ?? currentWind;
      prediction = predictReserveLandings(
          from: geo.latlng,
          height: height!,
          hardDeck: hardDeck,
          acroRate: acroRate,
          reserveRates: reserveRates,
          windAt: windAt,
          target: acroWaypoint?.latlng.first);
    }

    notifyListeners();
    return run;
  }
}

final acroService = AcroService();

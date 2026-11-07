import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:xcnav/fake_path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xcnav/models/acro.dart';
import 'package:xcnav/models/geo.dart';
import 'package:xcnav/models/glide_range.dart';
import 'package:xcnav/models/waypoint.dart';
import 'package:xcnav/models/wind_table.dart';
import 'package:xcnav/providers/active_plan.dart';
import 'package:xcnav/services/acro_service.dart';
import 'package:xcnav/settings_service.dart';
import 'package:xcnav/util.dart';
import 'package:xcnav/widgets/waypoint_marker.dart' show colorOptions;

const origin = LatLng(40, -105);

/// Wind toward the east at [speed] m/s, at every altitude
WindAt eastWind(double speed) => (alt) => (east: speed, north: 0.0);

double meters(LatLng a, LatLng b) {
  final m = metersBetween(a, b);
  return sqrt(m.east * m.east + m.north * m.north);
}

/// GPS fixes around a steady climbing turn: [airspeed] m/s through the air, wind blowing toward the east.
List<({int time, double alt, double hdg, double spd})> climbingTurn(
    {double airspeed = 12,
    double wind = 4,
    double degPerSec = 10,
    double climb = 1.5,
    int seconds = 72,
    double startAlt = 1600,
    int start = 0}) {
  final fixes = <({int time, double alt, double hdg, double spd})>[];
  for (int t = 0; t <= seconds; t++) {
    final heading = t * degPerSec * pi / 180;
    final east = airspeed * sin(heading) + wind;
    final north = airspeed * cos(heading);
    fixes.add((
      time: start + t * 1000,
      alt: startAlt + climb * t,
      hdg: (atan2(east, north) + 2 * pi) % (2 * pi),
      spd: sqrt(east * east + north * north)
    ));
  }
  return fixes;
}

void main() {
  group("circle fit", () {
    test("points on a circle", () {
      final xs = <double>[], ys = <double>[];
      for (int i = 0; i < 6; i++) {
        final a = i * 0.3;
        xs.add(3 + 10 * cos(a));
        ys.add(-2 + 10 * sin(a));
      }
      final fit = fitCircleTaubin(xs, ys)!;
      expect(fit.cx, closeTo(3, 1e-6));
      expect(fit.cy, closeTo(-2, 1e-6));
      expect(fit.r, closeTo(10, 1e-6));
      expect(fit.rms, closeTo(0, 1e-6));
    });

    test("too few points", () {
      expect(fitCircleTaubin([1, 2], [1, 2]), isNull);
    });

    test("heading span wraps through north", () {
      expect(headingSpan([350 * pi / 180, 10 * pi / 180]), closeTo(20 * pi / 180, 1e-9));
      expect(headingSpan([0, pi / 2, pi]), closeTo(pi, 1e-9));
    });
  });

  group("quarter turn wind", () {
    test("finds the wind on each quarter of a steady turn", () {
      final fitter = QuarterTurnWindFitter();
      final estimates = <WindEstimate>[];
      for (final f in climbingTurn()) {
        final est = fitter.add(time: f.time, alt: f.alt, hdg: f.hdg, spd: f.spd);
        if (est != null) estimates.add(est);
      }
      // 720° of turn, one estimate each 90° or so
      expect(estimates.length, greaterThanOrEqualTo(6));
      for (final est in estimates) {
        expect(est.east, closeTo(4, 0.1));
        expect(est.north, closeTo(0, 0.1));
        expect(est.airspeed, closeTo(12, 0.1));
      }
    });

    test("a slow turn in a 1000 ft/min climb still fits", () {
      final fitter = QuarterTurnWindFitter();
      int fits = 0;
      // 90° every 20 s, climbing 1000 ft/min
      for (final f in climbingTurn(degPerSec: 4.5, climb: 1000 / 196.85, seconds: 120)) {
        if (fitter.add(time: f.time, alt: f.alt, hdg: f.hdg, spd: f.spd) != null) fits++;
      }
      expect(fits, greaterThanOrEqualTo(4));
    });

    test("snap turns don't count", () {
      final fitter = QuarterTurnWindFitter();
      // 90° in 3 s
      for (final f in climbingTurn(degPerSec: 30, seconds: 4)) {
        expect(fitter.add(time: f.time, alt: f.alt, hdg: f.hdg, spd: f.spd), isNull);
      }
    });

    test("straight flight never fits", () {
      final fitter = QuarterTurnWindFitter();
      for (final f in climbingTurn(degPerSec: 0)) {
        expect(fitter.add(time: f.time, alt: f.alt, hdg: f.hdg, spd: f.spd), isNull);
      }
    });

    test("records in any normal flight, never in acro", () {
      // Climbing, level or gliding: all fine
      expect(windTableGate(height: 200, acroRun: false, minG: 0.9, maxG: 1.2, maxRotation: 25), isNull);
      expect(windTableGate(height: 200, acroRun: false), isNull);
      expect(windTableGate(height: null, acroRun: false), isNotNull);
      expect(windTableGate(height: 20, acroRun: false), isNotNull);
      expect(windTableGate(height: 200, acroRun: true), isNotNull);
      expect(windTableGate(height: 200, acroRun: false, maxG: 1.4), isNotNull);
      expect(windTableGate(height: 200, acroRun: false, minG: 0.5), isNotNull);
      expect(windTableGate(height: 200, acroRun: false, maxRotation: 70), isNotNull);
    });
  });

  group("wind table", () {
    WindEstimate est(double alt, double east, {int time = 0}) =>
        WindEstimate(east: east, north: 0, airspeed: 12, alt: alt, time: time);

    test("interpolates between bands and holds past the ends", () {
      final table = WindTable()
        ..add(est(WindTable.bandCenter(10), 2))
        ..add(est(WindTable.bandCenter(20), 12));
      expect(table.windAt(WindTable.bandCenter(15))!.east, closeTo(7, 1e-9));
      expect(table.windAt(0)!.east, 2);
      expect(table.windAt(10000)!.east, 12);
      expect(WindTable().windAt(100), isNull);
    });

    test("a turn fills every band it passed through", () {
      final table = WindTable()
        ..add(const WindEstimate(east: 3, north: 0, airspeed: 12, alt: 280, minAlt: 100, maxAlt: 470, time: 0));
      expect(table.bands.keys.toList()..sort(), [0, 1, 2, 3]);
    });

    test("newer estimates count more", () {
      final band = WindBand(east: 0, north: 0, airspeed: 12, updated: 0);
      for (int i = 1; i <= 10; i++) {
        band.add(est(0, 10, time: i));
      }
      expect(band.east, greaterThan(9.5));
      expect(band.count, 11);
    });

    test("old bands expire", () {
      final table = WindTable()
        ..add(est(100, 2, time: 0))
        ..add(est(500, 2, time: windTableMaxAge.inMilliseconds));
      expect(table.expire(windTableMaxAge.inMilliseconds + 1), isTrue);
      expect(table.bands.length, 1);
    });

    test("saves and loads", () {
      final table = WindTable()..add(est(300, 3, time: 1234));
      final loaded = WindTable.fromJson(table.toJson());
      expect(loaded.bands.keys, table.bands.keys);
      expect(loaded.windAt(300)!.east, 3);
      expect(loaded.bands.values.first.updated, 1234);
    });

    test("wind direction is where it blows from", () {
      // Blowing toward the east is a west wind
      expect(WindBand(east: 5, north: 0, airspeed: 12, updated: 0).fromHdg, closeTo(3 * pi / 2, 1e-9));
    });
  });

  group("drift", () {
    test("uniform wind", () {
      final d = drift(eastWind(5), from: 300, to: 0, rate: 3)!;
      expect(d.east, closeTo(500, 1e-6));
      expect(d.north, closeTo(0, 1e-9));
    });

    test("unknown wind", () {
      expect(drift((alt) => null, from: 300, to: 0, rate: 3), isNull);
    });
  });

  group("acro runs", () {
    /// Acro from 1000 m down at 5 m/s, pulling 2 g, with g samples at 10 Hz.
    AcroRun? fly(AcroRunDetector detector, {required double hardDeck, int seconds = 200, double ground = 0}) {
      for (int t = 0; t <= seconds * 10; t++) {
        final time = 10000 + t * 100;
        detector.addG(time, t < 5 ? 1.0 : 2.0);
        if (t % 10 == 0) {
          final alt = 1000 - max(0, t - 5) * 0.5;
          detector.addAlt(time, alt);
          final run = detector.update(time, height: alt - ground, hardDeck: hardDeck);
          if (run != null) return run;
        }
      }
      return null;
    }

    test("ends at the hard deck and measures the descent rate", () {
      final detector = AcroRunDetector();
      final run = fly(detector, hardDeck: 300)!;
      expect(run.endedAtHardDeck, isTrue);
      expect(run.accepted, isTrue);
      expect(run.descentRate, closeTo(5, 0.1));
      // Backdated to the first high-g sample
      expect(run.start, 10500);
      expect(run.entry, AcroEntry.gLoad);
    });

    test("ends once the pilot stops maneuvering", () {
      final detector = AcroRunDetector();
      for (int t = 0; t <= 600; t++) {
        final time = t * 100;
        detector.addG(time, t < 300 ? 2.0 : 1.0);
        if (t % 10 == 0) detector.addAlt(time, 1000 - t * 0.5);
      }
      expect(detector.running, isTrue);
      final run = detector.update(300 * 100 + AcroRunDetector.quietMs, height: 500, hardDeck: 300)!;
      expect(run.endedAtHardDeck, isFalse);
      expect(run.duration.inMilliseconds, 29900);
      expect(run.descentRate, closeTo(5, 0.1));
    });

    test("a short burst of g isn't a run", () {
      final detector = AcroRunDetector();
      for (int t = 0; t < 8; t++) {
        detector.addG(t * 100, 2.0);
      }
      detector.addG(800, 1.0);
      expect(detector.running, isFalse);
    });

    test("stall entry starts a run where the drop began", () {
      final detector = AcroRunDetector();
      for (int t = 0; t < 20; t++) {
        detector.addG(t * 100, 1.0);
      }
      for (int t = 20; t < 26; t++) {
        detector.addG(t * 100, 0.3);
      }
      expect(detector.running, isTrue);
      expect(detector.runEntry, AcroEntry.stall);
      expect(detector.runStart, 2000);
    });

    test("a brief low-g bump isn't a stall", () {
      final detector = AcroRunDetector();
      detector.addG(0, 0.3);
      detector.addG(100, 0.3);
      detector.addG(200, 1.0);
      expect(detector.running, isFalse);
    });

    test("sharp turn starts a run where the rotation began", () {
      final detector = AcroRunDetector();
      for (int t = 0; t <= 12; t++) {
        detector.addRotation(5000 + t * 100, 90);
      }
      expect(detector.running, isTrue);
      expect(detector.runEntry, AcroEntry.sharpTurn);
      expect(detector.runStart, 5000);
    });

    test("normal turns don't start a run", () {
      final detector = AcroRunDetector();
      for (int t = 0; t <= 300; t++) {
        detector.addRotation(t * 100, 25);
        detector.addG(t * 100, 1.2);
      }
      expect(detector.running, isFalse);
    });

    test("nothing starts below the hard deck", () {
      final detector = AcroRunDetector()..armed = false;
      for (int t = 0; t <= 20; t++) {
        detector.addRotation(t * 100, 90);
        detector.addG(t * 100, 0.2);
      }
      expect(detector.running, isFalse);
    });

    test("rotating keeps the run going without g", () {
      final detector = AcroRunDetector();
      detector.addAlt(0, 1000);
      for (int t = 0; t <= 300; t++) {
        detector.addRotation(t * 100, t < 20 ? 90 : 40);
        detector.addG(t * 100, 1.0);
      }
      detector.addAlt(30000, 850);
      expect(detector.update(30000, height: 550, hardDeck: 300), isNull);
      expect(detector.running, isTrue);
    });

    test("short runs aren't learned from", () {
      final detector = AcroRunDetector();
      final run = fly(detector, hardDeck: 960)!;
      expect(run.endedAtHardDeck, isTrue);
      expect(run.accepted, isFalse);
    });

    test("learned rate follows recent runs", () {
      var (rate, runs) = learnDescentRate(5, 0, 6);
      expect((rate, runs), (6, 1));
      (rate, runs) = learnDescentRate(rate, runs, 8);
      expect(rate, closeTo(7, 1e-9));
      for (int i = 0; i < 50; i++) {
        (rate, runs) = learnDescentRate(rate, runs, 4);
      }
      expect(rate, closeTo(4, 0.01));
    });
  });

  group("reserve landings", () {
    test("throw now vs. at the hard deck", () {
      final p = predictReserveLandings(
          from: origin, height: 900, hardDeck: 300, acroRate: 5, reserveRates: [3], windAt: eastWind(5))!;
      // Now: 300 s under reserve at 5 m/s
      final now = metersBetween(origin, p.throwNow.single.landAt);
      expect(now.east, closeTo(1500, 1));
      expect(now.north, closeTo(0, 1));
      // Hard deck: 120 s of acro then 100 s under reserve
      final hd = p.throwAtHardDeck.single;
      expect(metersBetween(origin, hd.throwAt).east, closeTo(600, 1));
      expect(metersBetween(origin, hd.landAt).east, closeTo(1100, 1));
      expect(hd.radius, greaterThan(reserveSpotBase));
      expect(p.landings.length, reserveThrowSteps + 1);
    });

    test("every enabled reserve", () {
      final p = predictReserveLandings(
          from: origin, height: 900, hardDeck: 300, acroRate: 5, reserveRates: [3, 4.5, 0], windAt: eastWind(5))!;
      expect(p.throwNow.length, 2);
      expect(p.landings.length, 2 * (reserveThrowSteps + 1));
      expect(p.landings.map((l) => l.reserve).toSet(), {0, 1});
      // Only reserve 2 set: still tagged as reserve 2
      final second = predictReserveLandings(
          from: origin, height: 900, hardDeck: 300, acroRate: 5, reserveRates: [0, 4.5], windAt: eastWind(5))!;
      expect(second.landings.map((l) => l.reserve).toSet(), {1});
    });

    test("below the hard deck it's just throw now", () {
      final p = predictReserveLandings(
          from: origin, height: 200, hardDeck: 300, acroRate: 5, reserveRates: [3], windAt: eastWind(5))!;
      expect(p.landings.length, 1);
      expect(p.landings.single.lowerThird, isTrue);
    });

    test("start point puts the lower third on the waypoint", () {
      const target = LatLng(40.01, -105);
      final p = predictReserveLandings(
          from: origin,
          height: 900,
          hardDeck: 300,
          acroRate: 5,
          reserveRates: [3],
          windAt: eastWind(5),
          target: target)!;
      // Flying the same run from the start point
      final fromStart = predictReserveLandings(
          from: p.startAt!, height: 900, hardDeck: 300, acroRate: 5, reserveRates: [3], windAt: eastWind(5))!;
      expect(meters(fromStart.lowerThirdCenter, target), lessThan(1));
      // Upwind of the target
      expect(metersBetween(target, p.startAt!).east, lessThan(-1000));
      // The low throws land closer to the target than the high ones
      final lowest = meters(fromStart.throwAtHardDeck.single.landAt, target);
      final highest = meters(fromStart.throwNow.single.landAt, target);
      expect(lowest, lessThan(highest));
    });

    test("needs wind", () {
      expect(
          predictReserveLandings(
              from: origin, height: 900, hardDeck: 300, acroRate: 5, reserveRates: [3], windAt: (alt) => null),
          isNull);
      expect(
          predictReserveLandings(
              from: origin, height: 900, hardDeck: 300, acroRate: 5, reserveRates: [0], windAt: eastWind(5)),
          isNull);
    });

    test("zone covers the landing spots and nothing far off", () {
      final p = predictReserveLandings(
          from: origin, height: 900, hardDeck: 300, acroRate: 5, reserveRates: [3], windAt: eastWind(5))!;
      final zone = reserveZoneRange(p.landings);
      final grid = zone.grid;
      bool insideAt(LatLng latlng) {
        final m = metersBetween(grid.origin, latlng);
        final row = grid.halfSize - (m.north / grid.cellSize).round();
        final col = grid.halfSize + (m.east / grid.cellSize).round();
        if (row < 0 || col < 0 || row >= grid.size || col >= grid.size) return false;
        return zone.isReachable(row, col);
      }

      for (final l in p.landings) {
        expect(insideAt(l.landAt), isTrue);
      }
      // Between two spots
      expect(insideAt(offsetMeters(origin, 1300, 0)), isTrue);
      // Well north of the band
      expect(insideAt(offsetMeters(origin, 1300, 400)), isFalse);
    });
  });

  group("zone cutout", () {
    test("reserve 1 is cut where it overlaps reserve 2", () {
      final p = predictReserveLandings(
          from: origin, height: 900, hardDeck: 300, acroRate: 5, reserveRates: [3, 3.6], windAt: eastWind(5))!;
      final first = reserveZoneRange(p.landings.where((l) => l.reserve == 0).toList());
      final second = reserveZoneRange(p.landings.where((l) => l.reserve == 1).toList());
      final cut = subtractZone(first, second);

      bool inside(GlideRange zone, LatLng latlng) {
        final g = zone.grid;
        final m = metersBetween(g.origin, latlng);
        final row = g.halfSize - (m.north / g.cellSize).round();
        final col = g.halfSize + (m.east / g.cellSize).round();
        return row >= 0 && col >= 0 && row < g.size && col < g.size && zone.isReachable(row, col);
      }

      int kept = 0, removed = 0;
      final n = first.grid.size;
      for (int row = 0; row < n; row++) {
        for (int col = 0; col < n; col++) {
          if (!first.isReachable(row, col)) continue;
          final center = first.grid.cellCenter(row, col);
          if (cut.isReachable(row, col)) {
            kept++;
            expect(inside(second, center), isFalse);
          } else {
            removed++;
          }
        }
      }
      expect(kept, greaterThan(0));
      expect(removed, greaterThan(0));
    });
  });

  group("acro waypoint", () {
    test("found by name, any case", () {
      final wps = [
        Waypoint(name: "LZ", latlngs: [origin]),
        Waypoint(name: " acro ", latlngs: [origin]),
      ];
      expect(findAcroWaypoint(wps)?.name, " acro ");
    });

    test("paths and other names aren't used", () {
      final wps = [
        Waypoint(name: "Acro", latlngs: [origin, const LatLng(40.1, -105)]),
        Waypoint(name: "Acro box", latlngs: [origin]),
      ];
      expect(findAcroWaypoint(wps), isNull);
    });
  });

  group("acro service", () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test("an Acro waypoint turns purple and turns acro mode on", () async {
      settingsMgr = SettingsMgr(await SharedPreferences.getInstance());
      final plan = ActivePlan();
      final service = AcroService(groundAt: (latlng) => null);
      final other = Waypoint(name: "LZ", latlngs: [origin]);
      plan.waypoints[other.id] = other;
      service.onPlanChanged(plan);
      await Future.delayed(Duration.zero);
      expect(settingsMgr.acroMode.value, isFalse);

      final acro = Waypoint(name: "acro", latlngs: [origin]);
      plan.waypoints[acro.id] = acro;
      service.onPlanChanged(plan);
      await Future.delayed(Duration.zero);
      expect(settingsMgr.acroMode.value, isTrue);
      expect(acro.color, colorOptions["purple"]!.toARGB32());
      expect(other.color, isNull);

      // Turning it off sticks until another Acro waypoint shows up
      settingsMgr.acroMode.value = false;
      service.onPlanChanged(plan);
      expect(settingsMgr.acroMode.value, isFalse);
    });

    test("climbing turns fill the wind table, then predict landings", () {
      final service = AcroService(groundAt: (latlng) => 1000);
      final acroWp = Waypoint(name: "Acro", latlngs: [origin]);
      for (final f in climbingTurn(seconds: 120, startAlt: 1100)) {
        final geo =
            Geo(lat: origin.latitude, lng: origin.longitude, alt: f.alt, timestamp: f.time, hdg: f.hdg, spd: f.spd);
        service.update(geo,
            gForce: <TimestampValue<double>>[], waypoints: [acroWp], hardDeck: 300, acroRate: 5, reserveRates: [3]);
      }
      expect(service.groundRefSource, AcroGroundRef.waypoint);
      expect(service.height, closeTo(280, 1));
      expect(service.table.bands.length, greaterThanOrEqualTo(2));
      for (final band in service.table.bands.values) {
        expect(band.east, closeTo(4, 0.2));
      }
      // Below the hard deck: throw now only, drifting east
      final p = service.prediction!;
      expect(p.landings.length, 1);
      expect(metersBetween(origin, p.landings.single.landAt).east, greaterThan(300));
    });

    test("the spoofed test flight circling a selected waypoint fills the wind table", () {
      final service = AcroService(groundAt: (latlng) => null);
      final fake = FakeFlight()..initFakeFlight(Geo(lat: origin.latitude, lng: origin.longitude, alt: 300));
      // Waypoint just ahead; climbing toward a high target altitude the whole time
      final target = offsetMeters(origin, 0, 300);
      // Fixes 3 s apart, like the app's spoofing timer
      Geo prev = Geo(lat: origin.latitude, lng: origin.longitude, alt: 300, timestamp: 0);
      for (int step = 1; step <= 200; step++) {
        final pos = fake.genFakeLocationFlight(target, prev, targetAlt: 5000);
        final here = LatLng(pos.latitude, pos.longitude);
        final geo = Geo(
            lat: pos.latitude,
            lng: pos.longitude,
            alt: pos.altitude,
            timestamp: step * 3000,
            hdg: latlngCalc.bearing(prev.latlng, here) * pi / 180,
            spd: latlngCalc.distance(prev.latlng, here) / 3)
          ..ground = 0;
        service.update(geo,
            gForce: <TimestampValue<double>>[], waypoints: const [], hardDeck: 300, acroRate: 5, reserveRates: [3]);
        prev = geo;
      }
      expect(service.table.bands.length, greaterThanOrEqualTo(3));
    });

    test("level circles count too", () {
      final service = AcroService(groundAt: (latlng) => null);
      for (final f in climbingTurn(climb: 0)) {
        final geo =
            Geo(lat: origin.latitude, lng: origin.longitude, alt: f.alt, timestamp: f.time, hdg: f.hdg, spd: f.spd)
              ..ground = 1000;
        service.update(geo,
            gForce: <TimestampValue<double>>[], waypoints: const [], hardDeck: 300, acroRate: 5, reserveRates: [3]);
      }
      expect(service.groundRefSource, AcroGroundRef.here);
      expect(service.tableGate, isNull);
      expect(service.table.bands.length, 1);
      expect(service.table.bands.values.single.east, closeTo(4, 0.2));
      expect(service.prediction, isNotNull);
    });

    test("acro is left out of the wind table", () {
      final service = AcroService(groundAt: (latlng) => null);
      final gForce = <TimestampValue<double>>[];
      for (final f in climbingTurn(climb: -3)) {
        // Pulling 2.5 g the whole time
        for (int ms = 0; ms < 1000; ms += 100) {
          gForce.add(TimestampValue(f.time - 1000 + ms, 2.5));
        }
        final geo =
            Geo(lat: origin.latitude, lng: origin.longitude, alt: f.alt, timestamp: f.time, hdg: f.hdg, spd: f.spd)
              ..ground = 1000;
        service.update(geo, gForce: gForce, waypoints: const [], hardDeck: 300, acroRate: 5, reserveRates: [3]);
      }
      expect(service.runDetector.running, isTrue);
      expect(service.tableGate, isNotNull);
      expect(service.table.isEmpty, isTrue);
    });
  });
}

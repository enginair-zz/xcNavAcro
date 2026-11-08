import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:xcnav/models/baro_anchor.dart';
import 'package:xcnav/models/geo.dart';

const double pressure = 950; // hPa, roughly 540 m on a standard day

/// Altitude the barometer shows at [p] with the anchor's reference
double baroAlt(BaroAnchor anchor, double p) => altFromBaro(p, anchor.ambient);

void main() {
  group("BaroAnchor on the ground", () {
    test("follows the median GPS altitude, so one bad fix can't set it", () {
      final anchor = BaroAnchor();
      for (int i = 0; i < 20; i++) {
        anchor.onGround(i * 1000, 100, pressure);
      }
      anchor.onGround(20000, 400, pressure); // a bad fix
      expect(baroAlt(anchor, pressure), closeTo(100, 0.01));
    });

    test("forgets fixes older than the window", () {
      final anchor = BaroAnchor(groundWindow: const Duration(seconds: 10));
      for (int i = 0; i < 20; i++) {
        anchor.onGround(i * 1000, 100, pressure);
      }
      for (int i = 20; i < 40; i++) {
        anchor.onGround(i * 1000, 150, pressure);
      }
      expect(baroAlt(anchor, pressure), closeTo(150, 0.01));
    });

    test("isn't skewed by moving uphill", () {
      final anchor = BaroAnchor();
      // Climb 2 m/s: GPS and pressure change together, so every fix implies the same reference.
      for (int i = 0; i < 30; i++) {
        final alt = 100.0 + 2 * i;
        anchor.onGround(i * 1000, alt, ambientToPressure(alt));
      }
      expect(baroAlt(anchor, ambientToPressure(158)), closeTo(158, 0.05));
    });
  });

  group("BaroAnchor in flight", () {
    BaroAnchor calibrated() {
      final anchor = BaroAnchor();
      for (int i = 0; i < 60; i++) {
        anchor.onGround(i * 1000, 100, pressure);
      }
      return anchor;
    }

    test("follows GPS with about a 10 s time constant (10% per 1 s fix)", () {
      final anchor = calibrated();
      anchor.onFlight(60000, 200, pressure, maneuvering: false);
      expect(baroAlt(anchor, pressure), closeTo(110, 0.5));
      for (int i = 61; i < 90; i++) {
        anchor.onFlight(i * 1000, 200, pressure, maneuvering: false);
      }
      expect(baroAlt(anchor, pressure), greaterThan(190));
    });

    test("keeps up with a barometer scale error through a climb", () {
      final anchor = calibrated();
      final rng = Random(1);
      // Climb 5 m/s for 10 min; the barometer reads 3% short of GPS (warm air), GPS has a few meters of noise
      double worst = 0;
      for (int i = 1; i <= 600; i++) {
        final gps = 100.0 + 5 * i;
        final baroTrueAlt = 100.0 + 5 * i * 0.97;
        final p = ambientToPressure(baroTrueAlt);
        anchor.onFlight(60000 + i * 1000, gps + (rng.nextDouble() - 0.5) * 6, p, maneuvering: false);
        if (i > 60) worst = max(worst, (baroAlt(anchor, p) - gps).abs());
      }
      expect(worst, lessThan(8));
    });

    test("doesn't follow GPS while maneuvering", () {
      final anchor = calibrated();
      for (int i = 60; i < 100; i++) {
        anchor.onFlight(i * 1000, 400, pressure, maneuvering: true);
      }
      expect(baroAlt(anchor, pressure), closeTo(100, 0.01));
    });

    test("first fix in the air sets it even while maneuvering", () {
      final anchor = BaroAnchor();
      anchor.onFlight(0, 800, pressure, maneuvering: true);
      expect(baroAlt(anchor, pressure), closeTo(800, 0.01));
    });

    test("setAltitude keeps the altitude where it was on a new sensor", () {
      final anchor = calibrated();
      final before = baroAlt(anchor, pressure);
      anchor.setAltitude(before, pressure + 1.5); // new sensor reads 1.5 hPa higher
      expect(baroAlt(anchor, pressure + 1.5), closeTo(before, 0.01));
    });
  });

  group("BaroSourceOffset", () {
    test("learns the difference between barometers and continues across a switch", () {
      final offset = BaroSourceOffset();
      const ambient = 1013.25;
      // The phone reads 0.5 hPa lower than the external sensor (it thinks it's ~4.5 m higher)
      for (int i = 0; i < 200; i++) {
        offset.addExternal(i * 100, pressure, ambient);
        offset.addPhone(i * 100 + 20, pressure - 0.5, ambient);
      }
      final phoneAlt = altFromBaro(pressure - 0.5, ambient);
      final externalAlt = altFromBaro(pressure, ambient);
      expect(offset.offset, closeTo(phoneAlt - externalAlt, 0.01));

      // Was on the external sensor, switching to the phone: carry on at the external altitude
      expect(offset.continueFrom(toExternal: false, newPressure: pressure - 0.5, ambient: ambient),
          closeTo(externalAlt, 0.01));
      // And back
      expect(offset.continueFrom(toExternal: true, newPressure: pressure, ambient: ambient), closeTo(phoneAlt, 0.01));
    });

    test("ignores readings too far apart in time", () {
      final offset = BaroSourceOffset();
      offset.addExternal(0, pressure, 1013.25);
      offset.addPhone(1000, pressure - 3, 1013.25);
      expect(offset.offset, isNull);
      expect(offset.continueFrom(toExternal: true, newPressure: pressure, ambient: 1013.25), isNull);
    });
  });

  group("Geo", () {
    Position fix({double heading = 0}) => Position(
          latitude: 37,
          longitude: -122,
          timestamp: DateTime(2026, 11, 7, 10),
          accuracy: 3,
          altitude: 500,
          altitudeAccuracy: 0,
          heading: heading,
          headingAccuracy: 0,
          speed: 12,
          speedAccuracy: 0,
        );

    test("heading from the GPS is wrapped to -pi..pi", () {
      final geo = Geo.fromPosition(fix(heading: 342), null, null, null);
      expect(geo.hdg, closeTo(-18 * pi / 180, 0.001));
      expect(wrapPi(5.97), closeTo(5.97 - 2 * pi, 1e-9));
      expect(wrapPi(-3.5), closeTo(-3.5 + 2 * pi, 1e-9));
    });

    test("logs GPS altitude, pressure and sources, and reads them back", () {
      final geo = Geo.fromPosition(
          fix(), null, BarometerEvent(950.1234, DateTime(2026, 11, 7)), BarometerEvent(1013.25, DateTime(2026, 11, 7)))
        ..pressure = 950.1234
        ..baroExternal = true
        ..gpsExternal = false;
      final json = geo.toJson();
      expect(json["altGps"], 500);
      expect(json["baro"], 950.123);
      expect(json["baroExt"], 1);
      expect(json["gpsExt"], 0);

      final back = Geo.fromJson(json);
      expect(back.altGps, 500);
      expect(back.pressure, 950.123);
      expect(back.baroExternal, true);
      expect(back.gpsExternal, false);
    });

    test("older logs without the new fields still load", () {
      final back = Geo.fromJson({"lat": 37, "lng": -122, "alt": 321.5, "time": 1, "hdg": 0, "spd": 0});
      expect(back.altGps, 321.5);
      expect(back.pressure, isNull);
      expect(back.baroExternal, isNull);
    });
  });
}

/// Pressure (hPa) at [alt] meters with a standard-day reference
double ambientToPressure(double alt) => 1013.25 * pow(1 - alt * meters2FeetLocal / 145366.45, 1 / 0.190284);

const double meters2FeetLocal = 3.28084;

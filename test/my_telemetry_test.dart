import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xcnav/providers/my_telemetry.dart';
import 'package:xcnav/settings_service.dart';
import 'package:xcnav/util.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // MyTelemetry starts the IMU on takeoff; stub the sensors plugin.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      "dev.fluttercommunity.plus/sensors/method",
      "dev.fluttercommunity.plus/sensors/accelerometer",
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
    SharedPreferences.setMockInitialValues({
      "profile.name": "Mr Test",
      "profile.id": "1234",
      "profile.secretID": "1234abcd",
    });
    settingsMgr = SettingsMgr(await SharedPreferences.getInstance());
    settingsMgr.forceGpsAltitude.value = true;
  });

  test("smokes", () {
    final telemetry = MyTelemetry();
    final position = Position(
      longitude: 0,
      latitude: 0,
      timestamp: DateTime.now(),
      accuracy: 1,
      altitude: 1000,
      altitudeAccuracy: 1,
      headingAccuracy: 1,
      heading: 0,
      speed: 0,
      speedAccuracy: 0,
    );
    telemetry.updateGeo(position);
  });

  test("gps fix strength", () {
    final now = DateTime(2026, 1, 1, 12);
    withClock(Clock.fixed(now), () {
      expect(GpsFixQuality(accuracy: 4, time: now).strength, GpsStrength.good);
      expect(GpsFixQuality(accuracy: 20, time: now).strength, GpsStrength.fair);
      expect(GpsFixQuality(accuracy: 80, time: now).strength, GpsStrength.poor);
      expect(GpsFixQuality(accuracy: 4, time: now.subtract(const Duration(seconds: 11))).strength, GpsStrength.none);
    });
  });

  test("updateGeo records gps fix", () {
    final telemetry = MyTelemetry();
    expect(telemetry.gpsFix.value, isNull);
    telemetry.updateGeo(Position(
      longitude: 0,
      latitude: 0,
      timestamp: DateTime.now(),
      accuracy: 7,
      altitude: 1000,
      altitudeAccuracy: 1,
      headingAccuracy: 1,
      heading: 0,
      speed: 0,
      speedAccuracy: 0,
    ));
    expect(telemetry.gpsFix.value?.accuracy, 7);
    expect(telemetry.gpsFix.value?.strength, GpsStrength.good);
  });

  test("IMU only runs in flight", () {
    final telemetry = MyTelemetry();
    expect(telemetry.listenIMU, isNull);
    telemetry.updateGeo(Position(
      longitude: 0,
      latitude: 0,
      timestamp: DateTime.now(),
      accuracy: 1,
      altitude: 1000,
      altitudeAccuracy: 1,
      headingAccuracy: 1,
      heading: 0,
      speed: 0,
      speedAccuracy: 0,
    ));
    expect(telemetry.listenIMU, isNull);

    telemetry.startFlight();
    expect(telemetry.listenIMU, isNotNull);

    telemetry.stopFlight(bypassRecording: true);
    expect(telemetry.listenIMU, isNull);
  });

  test("external vario is used without smoothing", () {
    final telemetry = MyTelemetry();
    settingsMgr.forceGpsAltitude.value = false;
    addTearDown(() => settingsMgr.forceGpsAltitude.value = true);

    telemetry.handleExternalBaro(1013.25, vario: 1.5);
    expect(telemetry.varioSmooth.value, 1.5);
    expect(telemetry.externalBaroActive, true);
    telemetry.handleExternalBaro(1013.20, vario: -0.4);
    expect(telemetry.varioSmooth.value, -0.4);
  });

  test("external baro falls back to the phone after a second", () {
    final start = DateTime(2026, 11, 7, 10);
    final telemetry = MyTelemetry();
    settingsMgr.forceGpsAltitude.value = false;
    addTearDown(() => settingsMgr.forceGpsAltitude.value = true);
    withClock(Clock.fixed(start), () => telemetry.handleExternalBaro(1013.25, vario: 0));
    withClock(Clock.fixed(start.add(const Duration(milliseconds: 900))), () {
      expect(telemetry.externalBaroActive, true);
    });
    withClock(Clock.fixed(start.add(const Duration(milliseconds: 1100))), () {
      expect(telemetry.externalBaroActive, false);
    });
  });

  test("barometer anchor pauses at 1.5 g until 10 s below it", () {
    final now = DateTime(2026, 11, 7, 10);
    final telemetry = MyTelemetry();
    withClock(Clock.fixed(now), () {
      telemetry.gForceRecord.add(TimestampValue(now.subtract(const Duration(seconds: 20)).millisecondsSinceEpoch, 1.1));
      expect(telemetry.anchorPaused, false);
      telemetry.gForceRecord.add(TimestampValue(now.subtract(const Duration(seconds: 9)).millisecondsSinceEpoch, 1.6));
      telemetry.gForceRecord.add(TimestampValue(now.subtract(const Duration(seconds: 2)).millisecondsSinceEpoch, 1.0));
      expect(telemetry.anchorPaused, true);
    });
    withClock(Clock.fixed(now.add(const Duration(seconds: 2))), () {
      expect(telemetry.anchorPaused, false);
    });
  });

  test("speed and heading aren't derived across a GPS source switch", () {
    final telemetry = MyTelemetry();
    final t0 = DateTime(2026, 11, 7, 10);
    Position fix(double lat, DateTime time, {double speed = 12, double heading = 90}) => Position(
          longitude: -122,
          latitude: lat,
          timestamp: time,
          accuracy: 3,
          altitude: 500,
          altitudeAccuracy: 1,
          headingAccuracy: 1,
          heading: heading,
          speed: speed,
          speedAccuracy: 0,
        );
    telemetry.updateGeo(fix(37, t0));
    telemetry.updateGeo(fix(37.0001, t0.add(const Duration(seconds: 1))));
    expect(telemetry.geo!.spd, closeTo(11.1, 0.2));
    expect(telemetry.geo!.gpsExternal, false);

    // External fix a few meters off the phone's track: reported speed and heading are used, not derived from the step
    telemetry.updateGeo(fix(37.00025, t0.add(const Duration(seconds: 2)), speed: 12.5, heading: 342), external: true);
    expect(telemetry.geo!.spd, 12.5);
    expect(telemetry.geo!.hdg, closeTo(-18 * 3.14159265 / 180, 0.001));
    expect(telemetry.geo!.gpsExternal, true);
  });
}

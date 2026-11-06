import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xcnav/models/acro.dart';
import 'package:xcnav/providers/active_plan.dart';
import 'package:xcnav/screens/settings_editor.dart' show pickColor;
import 'package:xcnav/settings_service.dart';
import 'package:xcnav/units.dart';

void showAcroModeDialog(BuildContext context) {
  showDialog(context: context, builder: (context) => const AcroModeDialog());
}

/// Acro mode options: hard deck, reserve descent rates, and the learned acro descent rate.
class AcroModeDialog extends StatefulWidget {
  const AcroModeDialog({super.key});

  @override
  State<AcroModeDialog> createState() => _AcroModeDialogState();
}

class _AcroModeDialogState extends State<AcroModeDialog> {
  /// Bumped to rebuild the descent rate field after the learned rate is reset.
  int descentFieldKey = 0;

  Widget _header(IconData icon, String title, String help) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: Colors.amber),
            const SizedBox(width: 8),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
          ]),
          const SizedBox(height: 4),
          Text(help, style: const TextStyle(color: Colors.grey, fontSize: 13)),
        ],
      ),
    );
  }

  /// Number field for a value stored in SI units, but typed in the user's display units.
  Widget _unitField(SettingConfig<double> setting, UnitType type, {required String label, Key? key, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Expanded(child: Text(label)),
        SizedBox(
          width: 110,
          child: TextFormField(
              key: key,
              textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(suffixText: getUnitStr(type)),
              initialValue: printValue(type, setting.value, decimals: 0),
              onChanged: (value) {
                final parsed = parseDoubleValue(type, value);
                if (parsed != null) setting.value = parsed;
              }),
        ),
        if (trailing != null) trailing,
      ]),
    );
  }

  /// Map color swatch. Same color picker as the glide range colors in settings.
  Widget _colorButton(SettingConfig<Color> setting) {
    return IconButton(
        tooltip: "Map color",
        icon: Icon(Icons.circle, color: setting.value, size: 32),
        onPressed: () => pickColor(context, setting.value).then((newColor) {
              if (newColor != null) setState(() => setting.value = newColor);
            }));
  }

  @override
  Widget build(BuildContext context) {
    final acroWp = findAcroWaypoint(Provider.of<ActivePlan>(context).waypoints.values);
    final runs = settingsMgr.acroDescentRuns.value;
    return Dialog(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
                title: Text("Acro Mode", style: Theme.of(context).textTheme.titleLarge),
                subtitle: const Text("Adds the Wind page and the reserve landing zone on the map."),
                value: settingsMgr.acroMode.value,
                onChanged: (value) => setState(() => settingsMgr.acroMode.value = value)),

            // --- Acro box
            _header(Icons.place, "Acro Box",
                "Name a waypoint \"$acroWaypointName\" to make it the center of your acro box: where you want to land under reserve. It turns purple and turns acro mode on."),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Icon(acroWp == null ? Icons.close : Icons.check, color: acroWp == null ? Colors.grey : Colors.green),
                const SizedBox(width: 8),
                Text(acroWp == null ? "No \"$acroWaypointName\" waypoint" : "Using waypoint \"${acroWp.name}\""),
              ]),
            ),
            _unitField(settingsMgr.acroHardDeck, UnitType.distFine, label: "Hard deck"),

            // --- Reserves
            _header(Icons.paragliding, "Reserves",
                "Descent rate and map color for each reserve. Set reserve 2 to 0 if you only fly one."),
            _unitField(settingsMgr.acroReserve1Rate, UnitType.vario,
                label: "Reserve 1 (primary)", trailing: _colorButton(settingsMgr.acroReserve1Color)),
            _unitField(settingsMgr.acroReserve2Rate, UnitType.vario,
                label: "Reserve 2", trailing: _colorButton(settingsMgr.acroReserve2Color)),

            // --- Acro descent rate
            _header(
                Icons.trending_down,
                "Acro Descent Rate",
                runs == 0
                    ? "Your guess, until an acro run is measured. Runs start on their own when you stall the wing or turn sharply into a maneuver, above your hard deck."
                    : "Learned from $runs ${runs == 1 ? "run" : "runs"}, and updated after every run."),
            _unitField(settingsMgr.acroDescentRate, UnitType.vario,
                label: "Average", key: ValueKey("acroDescentRate$descentFieldKey")),
            if (runs > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextButton.icon(
                    icon: const Icon(Icons.restart_alt),
                    label: const Text("Forget learned rate"),
                    onPressed: () => setState(() {
                          settingsMgr.acroDescentRuns.value = 0;
                          settingsMgr.acroDescentRate.reset();
                          descentFieldKey++;
                        })),
              ),

            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(onPressed: () => Navigator.pop(context), child: const Text("Done")),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

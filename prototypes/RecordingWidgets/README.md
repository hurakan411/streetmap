# Recording control widgets

Small: persistent / while running (including background) / off.
Medium: the same controls, plus walking / walking + cycling / all travel.
These are capture settings, not visibility filters for saved routes.

The main app is the sole writer of the real recording preferences. App
Intents run in its process and call the existing AppStore/LocationRecorder.
The extension reads one Codable display snapshot from App Group
`group.jp.michi.walkmap`; no coordinates or route history are shared.

## Execution and permissions

- With Always permission, eligible controls run in the app's background
  process without showing its UI. Off and capture policy changes do not
  require location permission.
- Starting a new When-In-Use recording session opens the app first.
- Selecting a mode without its required permission opens the app's existing
  settings/permission explanation. The current mode is not changed until
  permission is sufficient. Cancellation leaves it unchanged.
- No onboarding completion: open onboarding rather than start recording.
- Explicit values are used, not next-mode cycles based on stale timelines.
- The real recorder publishes updates to both widget sizes. Identical
  snapshots do not repeatedly request timeline reloads. WidgetKit schedules
  refreshes; it is not a continuously running service.
- OS restrictions on force-quit and background location remain unchanged.

## Build and signing

Run `xcodegen generate` after editing `project.yml`. Both `Michi` and
`StreetPrintWidgets` need App Groups enabled for `group.jp.michi.walkmap`.
The extension identifier is `jp.michi.walkmap.widgets` and is embedded in
the app. Both require compatible provisioning profiles for device/archive
builds; a wildcard profile without App Groups is insufficient. No profile
or entitlement may be stripped to work around device signing.

Use a normal signed simulator build too: `CODE_SIGNING_ALLOWED=NO` omits
the simulated entitlements section and prevents App Group registration.
Adding an ad-hoc signature afterwards is not equivalent.

## Tests

From the project root:

```
xcrun swiftc Shared/RecordingSettings.swift prototypes/RecordingWidgets/main.swift -o /private/tmp/streetprint_widget_tests
/private/tmp/streetprint_widget_tests
```

Verified on iOS 18.4 Simulator:

- Small widget setup and live preference display.
- Starting an authorized When-In-Use session via foreground app intent;
  the widget updates to the selected mode.
- Off stops collection without opening the app.
- Medium widget walking / cycling / all buttons change capture policy in
  the real app without opening it, and do not resume recording while off.
- Persistent without Always opens the existing permission alert. Cancel
  keeps Off selected. App settings show the same capture policy.
- Small and medium render without clipped controls.
- Capture switching also works after terminating the simulator app; the
  app starts in the background and Off remains selected.

Both simulator Release and unsigned physical-device Release compile.
Device installation is pending an App-Groups-enabled provisioning profile:
the CLI currently reports No Accounts, although Xcode's account/team UI is
valid. The physical phone's installed build and history were not modified.

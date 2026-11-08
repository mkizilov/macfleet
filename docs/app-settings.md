# Settings, navigation, and polish

This page covers the settings window, how preferences are kept, the keyboard commands, the empty and error states, how
the app's sampling and windows were reviewed for energy and responsiveness, and what the automated tests cover.

## Settings

Open **Settings** from the app menu (⌘,) or from **Windows** in the popover. It has two panes.

### General

- **Menu bar.** Choose any of CPU, Memory, Network, and Disk. The label keeps them in that fixed order. With none chosen,
  the menu bar shows the icon alone, and the values stay in the popover.
- **Refresh rates.** Each kind of sampling has its own list, so no setting can spin the CPU or wait for hours:

  | Kind | Applies | Choices | Default |
  | --- | --- | --- | --- |
  | Background | Menu bar and alerts while the popover is closed | 5, 10, 30, 60 seconds | 10 seconds |
  | Popover | Values while the popover is open | 1, 2, 5 seconds | 2 seconds |
  | Process list | Processes, while its window is open | 2, 5, 10 seconds | 2 seconds |
  | Registered Macs | Each registered Mac reports | 5, 10, 30 seconds | 10 seconds |

  A change to the background rate restarts the menu bar's sampling. A change to the popover rate applies at once if the
  popover is open. A change to the registered-Mac rate reopens each open session at the new rate.
- **Startup.** **Open MacFleet at Login** uses `SMAppService.mainApp`, the supported login item API. The status line says
  which of four things is true: on, off, waiting for approval, or not available in this build. When approval is needed,
  a button opens Login Items in System Settings.
- **Restore Defaults** returns every setting above to its default.

### Notifications

The alert thresholds from the earlier notifications work, unchanged: each metric's switch, threshold, sustained period,
and cooldown, plus the permission request. The separate Alert Settings window was merged into this pane, so there is one
place for thresholds.

## Persistence

- Settings are stored as one encoded value under the user defaults key `MacFleet.preferences`.
- Every value is validated on load. A rate outside its kind's list becomes the default, an unknown metric name is
  dropped, and a missing field takes its default. An older or edited file still loads.
- A value that cannot be decoded is moved aside under `MacFleet.preferences.damaged.<time>`, never deleted, and the app
  starts from the defaults. A notice says where the data went.
- A save that fails keeps the new value for the rest of the session, and the pane says so.
- The login item is not stored by the app. The system is asked each time the pane opens, so the toggle shows what is real.

## Keyboard

The **Navigate** menu lists every command, with its shortcut:

| Command | Shortcut | Opens or does |
| --- | --- | --- |
| Refresh Now | ⌘R | Samples this Mac now |
| Fleet | ⌘1 | The Fleet window |
| History | ⌘2 | The History window |
| Processes | ⌘3 | The process list |
| Notification Settings | ⌘4 | Settings, on the Notifications pane |
| Settings | ⌘, | Settings, on the General pane (the system command) |

The shortcut table lives in one place (`AppCommand`), and a test checks that the keys are unique and that none of them
takes ⌘,. Within the Fleet window, the confirm button of the pairing form is the default action (Return) and Cancel is
the cancel action (Escape). Settings tabs, pickers, toggles, and steppers take the standard keyboard focus.

## Empty and error states

- **Fleet with no Macs.** The window says how to add one, with its Tailscale name or private IP address.
- **Menu bar with no metrics.** The label is the icon alone, and the General pane says so.
- **Launch at login.** Off, on, waiting for approval (with a link), not available in a build that is not an installed
  app, or unknown. Each state has a sentence; the toggle is disabled when the system has nothing to change.
- **A refused login item.** The system's reason is shown, and the toggle keeps the state the system reports.
- **Unreadable settings.** The app starts from the defaults, and the Settings window explains where the damaged data went.
- **A settings save that failed.** The new value applies for the session, and the pane says it is not yet stored.
- **A group name over 32 characters.** The pairing form refuses it before probing the Mac, with the limit stated.
- **History, processes, and the popover.** Each already shows its own reason when data is missing or unavailable. The
  popover's first-run line reads "Waiting for the first sample."

## Groups

Registered Macs can be grouped. Each card has a **Group** menu that lists the groups in use and a **No Group** choice,
and the pairing form has an optional group field. The dashboard shows **This Mac** first, then each named group in
name order, then the ungrouped Macs as **Other Macs** (or **Remote Macs** when no group exists). Group names are matched
exactly, so "Lab" and "lab" are separate groups. Records saved before groups existed load as ungrouped.

## Accessibility

- Every chart has a title and a spoken summary. The upload line is dashed as well as a different color, so the two
  network lines are told apart without color.
- Usage levels carry their words (Normal, Elevated, Critical), and unavailable readings show a dash with the reason spoken.
- Every control has a label, and each explanation is a hint. The menu bar label reads in full to VoiceOver, with the
  startup disk included when it is shown.

## Energy and responsiveness review

The review looked for work that runs when nobody is looking. Its findings and changes:

- **Remote Macs** were polled every 5 seconds. The default is now 10 seconds, which halves their wakeups on both
  Macs. The 5-second rate is still available for anyone who wants it.
- **The background rate** remains 10 seconds by default, and the user can make it 60 seconds to reduce wakeups further.
- **The popover** samples only while it is open, as before, and at 2 seconds by default.
- **The process list** samples only while its window is open, as before.
- **The History window** reloads every 30 seconds only while it is open. Closing it cancels the loop.
- **Sampling stops** when the Mac sleeps and resumes on wake, as before.
- **The menu bar label** is rebuilt once per sample, from values already computed for the popover. A metric that is not
  shown costs nothing beyond that.
- **The Alert Settings window** was merged into Settings, so there is one fewer window to keep open.

The policy is also checked in code: the background rate is never faster than 5 seconds, and the popover rate is never
slower than 5 seconds (`theRateLimitsKeepBackgroundWorkLowAndTheOpenPopoverFresh`).

## Windows

- **Settings** is the standard Settings scene, so it appears in the app menu with ⌘,.
- **Fleet**, **History**, and **Processes** open at sizes that suit their content, and the system restores their position.
- **Notification Settings** and **Settings** open the same window on different panes.

## Automated tests

- **Kit (22 tests).** Defaults and rate lists, the energy limits, refused and invalid rates, metric order, JSON encoding
  and loading with missing or unknown fields, storage with damaged data moved aside, the launch-at-login states, and
  group decoding for records saved before groups.
- **State (40 tests).** Settings flows: changing the menu bar and rates, saving and reloading, failed saves, damaged
  settings at launch, launch-at-login states and refusals, the navigation table and panes, and the wording and
  accessibility of every pane. Fleet groups: sections, moving a Mac, group names on pairing, the empty state, and a rate
  change reaching the open sessions. The menu bar label: the default, a changed choice, an empty choice, and the spoken
  label. Accessibility of the charts and readings.

These are flow tests at the model level. Each one drives the same actions the view sends and checks the presentation
the view shows.

## Not created

No XCUITest target was added. Driving the app's windows needs the Xcode test runner, and neither Xcode nor `xcodebuild`
is available in this environment, so a UI test target could not be built or run here. The views were typechecked as part
of the app target instead.

## Not verified

- Launch at login was not registered. A test run must not change the user's login items, so the `SMAppService` path
  compiles and is covered through its state mapping only. It was not tried from an installed bundle.
- The Settings window, the Navigate commands, and the activation of the app when a window opens were typechecked, not run.
- Energy was not measured with Instruments, and wakeups were not counted. The policy is covered by the tests above.
- VoiceOver, Dynamic Type, Increase Contrast, and dark mode were not checked in a running app.
- A registered-Mac rate change was not seen on a real tailnet.

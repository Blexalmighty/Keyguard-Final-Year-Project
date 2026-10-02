# CHAPTER FIVE

# SUMMARY, CONCLUSION AND RECOMMENDATIONS

---

## 5.1 Introduction

This chapter summarises the work undertaken, states the conclusions drawn from
it, sets out the contributions made, and recommends further work. It closes with
a short account of what the project established beyond its own artefacts — the
findings that would be useful to someone building a comparable system from
scratch.

---

## 5.2 Summary of the work

### 5.2.1 Aim

The aim was to design and implement a Bluetooth Low Energy key-finding system
comprising a battery-powered keyholder and an Android application, such that an
owner can locate misplaced keys, be warned before leaving them behind, and find
a misplaced phone using the keyholder — without an account, a subscription, or a
third party holding a record of where the owner has been.

### 5.2.2 Objectives and their disposition

| Objective | Outcome |
|---|---|
| Design a compact, battery-powered BLE keyholder | Achieved on the ESP32-C3 Super Mini with an on-board 72 × 40 OLED |
| Implement two-way alerting — find the keys, find the phone | Achieved; the phone's ringing continues until stopped in the application |
| Estimate distance from signal strength | Achieved, as a calibrated estimate with its limits stated in the interface |
| Warn the owner before the keys are left behind | Achieved, with a notifying threshold and a sounding maximum allowance as separate settings |
| Bind a keyholder to exactly one owner | Achieved via HMAC-SHA256 challenge–response, rooted in physical possession of a button |
| Keep working in the background, across swipe-away and reboot | Achieved on Android |
| Display position on the keyholder's own screen | Achieved — by pushing the *phone's* position to the device, after the original design was reversed |
| Conserve battery without dropping the connection | Achieved with light sleep at a reduced clock |
| Avoid becoming usable as a tracking device | Achieved within the limits stated in §5.5 |

### 5.2.3 What was built

| | |
|---|---|
| Application | 15,306 lines of Dart, 42 files, Flutter, Android API 26+ |
| Firmware | ESP32-C3, Arduino framework, no GPS, no Wi-Fi |
| Tests | 128 automated, all passing; `flutter analyze` clean |
| Protocol | One GATT service, 11 commands, 14 responses, two supported dialects |
| Documentation | Architecture reference, security model, and this report |

---

## 5.3 Conclusions

### 5.3.1 The system meets its aim

All seventeen functional requirements and all five privacy requirements were met;
seven of eight non-functional requirements were met, with multi-day battery life
only partly verified for want of a long-run measurement. Field testing confirmed
the awkward cases as well as the easy ones: the application continues to monitor
after being swiped out of Recents, reconnects after a phone reboot without being
opened, and correctly declines to reconnect after a disconnection the owner
performed deliberately.

### 5.3.2 A tracker's hardest constraint is not technical

The most restrictive requirements in this project were the privacy requirements,
and they were derived from the documented failures of commercial products rather
than from anything in a specification.

The decision that follows from them is small and absolute: **a keyholder
advertises no per-unit identifier.** Every unit announces the same generic name.
Nicknames exist and are useful, and the obvious place to put one is in the
advertisement, where it would make the device identifiable in a crowded scan
list. That convenience *is* the attack. A passer-by with a scanner sees a number
of indistinguishable radios and cannot follow one of them through a building, and
therefore cannot follow its owner.

The cost is accepted and real: an owner with two keyholders cannot tell them
apart in the scan list except by signal strength. A project with more units to
sell would feel pressure to reverse that trade. It should not be reversed.

### 5.3.3 Removing features improved the system

Four substantial features were designed, built and then deleted. In every case
the system was better afterwards.

| Removed | What the removal bought |
|---|---|
| GPS receiver in the keyholder | The receiver could only be read over a live BLE link, which is precisely what is absent the instant the keys are lost. The phone's receiver is available then. Removing it also removed cost, size and current draw. |
| Wi-Fi provisioning | A frequently-lost object with USB-readable flash is the worst place to keep a home network password. Removing the feature removed the asset. Wi-Fi and BLE also share one antenna on this chip, roughly doubling average current. |
| Cloud event reporting | It created the one thing this design otherwise does not have: an operator holding a movement history, who could be breached or compelled. |
| Four of six alert patterns | They were not distinguishable on a single-tone active buzzer. The setting implied a precision the hardware did not have. |

Deleting the Wi-Fi subsystem also removed three permissions from the manifest.
That matters more than the line count: a permission an application no longer
exercises is still printed on the store listing and in the system permission
screen, and "this key finder wants to see the networks around you" is a question
an owner should not have to answer for a feature that does not exist.

The general conclusion is that in an embedded product each feature carries a
recurring cost in current draw, in attack surface, and in the owner's trust — and
that a feature justifying itself at design time may not justify itself once it is
measurable.

### 5.3.4 Transport-layer faults are the expensive ones

The fault that prevented the phone's position from reaching the keyholder's
screen was reported three times and attacked three times from the wrong side.
Both endpoints were correct throughout: the application pushed on every fix, and
the firmware's handler parsed the frame properly. The fault was in the transport
between them — a 27-byte frame against the 20-byte payload that a default
23-byte ATT MTU permits.

Three properties made it expensive:

1. **It was silent.** The write appeared to succeed. Nothing raised an error at
   either end.
2. **It was invisible from either side in isolation.** Reading the application
   showed correct code. Reading the firmware showed correct code.
3. **It required both sides to fix.** Raising the MTU on the client alone
   achieves nothing, because the negotiated value is the smaller of the two.

It was diagnosed by counting bytes, not by instrumentation. The conclusion
generalises: when both endpoints of a protocol are demonstrably correct and the
behaviour is still wrong, the fault is in the assumptions the two endpoints share
— and for BLE specifically, the default MTU is the assumption most worth checking
first.

### 5.3.5 A reassembly buffer without a timeout is a latent total failure

The fault found while fixing the previous one was worse than it. The keyholder's
buffer held an incomplete frame indefinitely, with no timeout and no length
limit. One truncated frame therefore left a fragment in the buffer for ever; every
subsequent command was appended to it, matched nothing, and the device obeyed
**nothing at all** until it was reconnected.

A buffer that waits for more data must be able to give up, and must be bounded.
Those are not defensive luxuries: without them, a single malformed write is a
denial of service against the whole device.

The second-order lesson is subtler and is recorded in the source. The instinct
when reassembling is to wait for certainty, but waiting is itself dangerous:
holding `LOCATION_NAME:Amphitheatre` back to see whether more arrives is how
`SET_DIST:50` gets glued onto the end of it and a place name is persisted as
`AmphitheatreSET_DIST:50`. The implementation therefore errs towards acting
immediately, and withholds only the single frame whose truncation is *detectable*
— a coordinate pair, which must contain a comma.

### 5.3.6 Background execution on Android rewards being specific

"Keep working in the background" is six distinct problems, each with its own
mechanism, and solving five leaves a system that fails in the sixth case:

| Threat to the process | Mechanism |
|---|---|
| Minimised | A foreground service — a cached process is reclaimed first |
| Swiped from Recents | `stopWithTask: false` |
| Android 15's six-hour cap | `connectedDevice`, not `dataSync` |
| Manufacturer battery managers | `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` |
| Reboot | A boot receiver *and* a headless reconnection |
| App update | `autoRunOnMyPackageReplaced` |

The service type deserves emphasis because the correct choice is also the honest
one. `dataSync` is the type an application of this kind might reach for by
default, and from Android 15 the system stops such a service after roughly six
hours in any twenty-four. A key finder that quietly gives up after six hours
would be worse than one that never claimed to watch. This application genuinely
interacts with a connected Bluetooth device, so the accurate declaration is also
the one without the cap.

The reboot case also produced the project's one deliberate architectural
exception. The application's rule is that no Bluetooth work happens in the
background isolate, because isolates share no memory and a second service object
would fight the first over the adapter. After a reboot there is no Activity and
therefore no main isolate at all, so the rule's premise is absent and the
reasoning inverts. Gating the exception on the platform's own `TaskStarter.system`
value makes it precise rather than a loophole: the handler touches Bluetooth only
in the one case where nothing else can.

### 5.3.7 Testing across the hardware boundary caught what unit tests could not

The most valuable test in the suite reads the **firmware source file from disk**,
parses its alert-cadence table, and asserts that the tokens match the
application's definitions.

It is the only mechanism in the project capable of detecting the two halves of the
wire contract drifting apart — a fault class that no amount of Dart-only testing
would find, because each side remains individually self-consistent while
disagreeing with the other. In a system split across two languages, two
toolchains and two repositories-worth of concerns, a test that spans the boundary
is worth more than many that do not.

It is also deliberately brittle: adding a field to the firmware struct breaks it.
That is correct. A change to a shared contract should require a decision, not pass
silently.

---

## 5.4 Contributions

1. **A complete, working two-way BLE key-finding system** with no account, no
   server and no subscription, documented to the level needed to rebuild it.
2. **A privacy-first identification scheme for consumer trackers** — one generic
   advertised name for all units, with human-readable names held only on the
   owner's phone — together with an explicit account of what it costs and what it
   does not defend against.
3. **An inverted location architecture.** Position travels phone → keyholder
   rather than the reverse, which removes the GPS receiver, its cost, its size and
   its current draw, and answers a question the usual arrangement cannot: where
   was my phone last, read from a screen I still have.
4. **A documented account of the ATT MTU failure mode**, including why it is
   silent, why it is invisible from either endpoint alone, and the arithmetic that
   identifies it. This is the project's most transferable finding.
5. **Reassembly rules for a constrained GATT peer** that are safe in both
   directions — bounded, timed out, and biased towards acting rather than waiting,
   with the reason for that bias recorded.
6. **A specific Android background-execution recipe** for a device-companion
   application, including the service-type choice that Android 15 made
   consequential.
7. **A cross-boundary test pattern**: an application test that parses firmware
   source to hold a shared protocol constant.

---

## 5.5 Limitations

Restated here so that the recommendations in §5.6 are read against them.

**Distance is an estimate.** RSSI varies by several decibels with orientation,
obstruction and the owner's own body. The model is calibrated for one environment
and is wrong in others. It supports relative judgement — warmer, colder — which
is what finding an object in a room requires, and not more.

**Physical possession defeats much of the security model.** ESP32-C3 flash is
readable over USB; neither flash encryption nor secure boot is enabled. Anyone
holding the device can read the stored key, the last position and the place name.

**An intimate adversary is not defeated.** Someone who can hold the keyholder for
thirty seconds can unclaim and reclaim it; someone with the owner's unlocked
phone has the application. No tracker design solves this, and the industry's
answer — cross-vendor unwanted-tracking alerts, where every phone warns about an
unfamiliar tracker travelling with it — requires participation in Apple's and
Google's detection networks, which a project of this size cannot join.

The partial mitigation is real but cuts both ways, and the second edge should be
named: because this device advertises nothing unique, it cannot be *followed* by a
third party — but neither can it be *detected* as a planted tracker by the
scanning applications people use for that purpose, which look for identifiers
that persist.

**iOS background operation is not implemented.**

**Battery life was not measured over a full discharge.** The low-power mode
demonstrably reduces current draw; no long-run figure was obtained.

**The keyholder cannot be sent an IP address.** It has no network stack, and no
frame for an address exists in either dialect of the protocol. The place name
covers the actual need and is more useful on a 72 × 40 display than an address
would be.

**Calibration is manual.** The owner holds the phone at one metre and taps a
button.

**The firmware is not compiled in continuous integration.**

**`applicationId` is still `com.example.keyguard`**, which Google Play will not
accept. It was left unchanged because changing it breaks the upgrade path for
every installed build — a release-time decision rather than a development one.

---

## 5.6 Recommendations

### 5.6.1 Immediate, before any release

| | Recommendation | Why |
|---|---|---|
| 1 | Change `applicationId` from `com.example.keyguard` | `com.example.*` is reserved for samples; Play will reject it. Do it before the first install base exists, because afterwards it breaks upgrades. |
| 2 | Enable ESP32 flash encryption and secure boot | Closes the largest gap in the security model: the key, the last position and the place name are currently readable over USB by anyone holding the device. Supported by this chip. |
| 3 | Add a firmware compile step to continuous integration | A test parses the sketch, which catches protocol drift but not a build break. |
| 4 | Measure a full discharge | The only missing figure behind a battery-life claim. |

### 5.6.2 Automatic calibration

The manual one-metre calibration asks the owner to hold the phone at a measured
distance, which few will do accurately.

The intuitive automatic approach — have the phone's own sensors measure one metre
as the owner walks it — **should not be pursued**, and the reason is worth
recording so the idea is not revisited hopefully. A pedometer quantises to a step
of roughly 0.7 m, so one metre is between one and two steps and cannot be
resolved; GPS is accurate to about 5 m, which is five times the distance being
measured; and accelerometer dead-reckoning integrates error quadratically, so a
displacement estimate over one metre is dominated by drift. Each sensor's error
exceeds the quantity it would be measuring.

**The defensible automatic scheme is statistical rather than kinematic.** Ask the
owner to hold the phone near the keyholder, collect RSSI samples for several
seconds, and take the median. The median suppresses the multipath outliers that
make any single reading unreliable, and the result is a `TxPower` figure for *this*
board in *this* enclosure — which is what the constant actually describes. It does
not require the distance to be measured by the phone at all; it requires only that
the owner holds a roughly known distance for a few seconds, which people can do.

A further refinement: sample at two distances and solve for the path-loss exponent
as well. That would adapt the model to the environment rather than only to the
board, which is where the larger error currently sits.

### 5.6.3 Technical improvements

| | Recommendation | Benefit |
|---|---|---|
| 1 | Kalman or exponentially-weighted filtering of RSSI | Noticeably steadier distance readout; the single largest perceived-quality improvement available |
| 2 | BLE connection-interval tuning | Longer intervals when idle, shorter during an active search; further battery saving without losing responsiveness |
| 3 | Buffer events while disconnected, and flush on reconnection | The log currently loses what happened out of range |
| 4 | Support several keyholders in one application | The protocol and the storage schema already accommodate it; only the interface assumes one |
| 5 | A second alert channel — a vibration motor | Useful where a buzzer is socially impossible |
| 6 | Over-the-air firmware update | Removes the need to recover a board physically to fix a protocol bug, which the MTU fault made concrete |
| 7 | Reduce `ble_service.dart` from 2,924 lines | It has accreted scanning, connection, GATT I/O, ownership, logging and pushing. Extracting a connection manager and a push coordinator would leave the single-instance guarantee intact while making each part testable |

### 5.6.4 Feature recommendations

| | Recommendation |
|---|---|
| 1 | Geofence-based reminders — alert on *leaving a place*, not merely on exceeding a distance, which is closer to how keys are actually forgotten |
| 2 | A "last seen here" map pin showing the position at the moment of disconnection, which is the single most useful datum when something is genuinely lost |
| 3 | Export the event log, so an owner can retain it outside the application |
| 4 | Localisation, beginning with the languages of the deployment region |
| 5 | A one-time privacy explanation at first run, stating that nothing leaves the phone. The property is unusual enough to be worth asserting |

### 5.6.5 Research directions

| | Direction |
|---|---|
| 1 | **Multilateration from several keyholders.** Three units with known relative positions could locate a phone far better than one can, turning a proximity device into a positioning system |
| 2 | **Bluetooth 5.1 direction finding (AoA/AoD).** Bearing rather than distance; the correct long-term answer to "which way do I walk", and a direction the ESP32-C3 cannot take but a successor part could |
| 3 | **Environment classification.** Infer indoors/outdoors from RSSI variance and select a path-loss exponent automatically, addressing the single largest source of distance error |
| 4 | **Open unwanted-tracking detection.** The cross-vendor alerting that protects people from planted trackers is currently the property of two companies' device fleets. What a privacy-preserving, openly specified equivalent would look like — and whether a device that advertises no identifier can participate in one at all — is an open and socially consequential question. This project sits squarely inside it: the design choice that makes the keyholder unfollowable also makes it undetectable |

---

## 5.7 Concluding remarks

The system works, and it works in the cases that are easy to overlook: with the
application swiped away, after the phone has been rebooted, out of range and back,
and with no internet connection at all.

The most useful outcome of the project, though, is not the artefact. It is the
record of four substantial features designed, built and then deliberately
deleted, with the reasons preserved — and of two faults that were invisible from
either endpoint and were found by counting bytes rather than by reading code. A
report that presented the final design as though it had arrived whole would have
discarded the information most valuable to whoever builds on it.

Two conclusions are worth restating last.

The first is that in a constrained embedded product, every feature is a recurring
cost — in current, in attack surface, and in the owner's trust — and a feature
that justified itself at design time may not justify itself once it can be
measured. The GPS receiver was the clearest case: it was the most obvious
component in the original design, and removing it made the product better in every
dimension including the one it was there to serve.

The second concerns the category. A key finder and a stalking device are the same
object with different intent, and the distinguishing engineering decision is a
small one — whether the radio announces anything unique about itself. This system
answers no. That choice costs the owner a convenience, limits the device's ability
to be detected as well as its ability to be followed, and is the right choice. It
should survive any future revision of this work.

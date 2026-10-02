# FindX / FindMe — security model

Referenced from `README.md`, `firmware/README.md` and `lib/services/ble_protocol.dart:45`.

A key finder is an unusual thing to secure. Most of the obvious threats to it
are not the interesting ones: nobody is going to mount a sophisticated attack to
make somebody else's keyring beep. The threat that matters is the one the device
category is notorious for — **a small radio, attached to a person, that reports
where they are.** Everything below follows from taking that seriously.

---

## 1. What is being protected

| Asset | Where it lives | Why it matters |
|---|---|---|
| The owner's movements | Phone positions, pushed to the keyholder and stored in its NVS | The whole stalking risk |
| The owner's identity, as seen from outside | What the keyholder puts on the air | Links a radio to a person |
| Control of the keyholder | Whether a stranger can make it sound, or claim it | Nuisance, and denial of a safety feature |
| The 32-byte device key | Phone's `flutter_secure_storage`, device's NVS | Proves ownership |
| The event log | Phone preferences | A record of where the owner has been |

Note what is *not* on this list: there is no server, no account, no password and
no cloud copy of anything. That is not an omission — it is the single largest
security decision in the project. There is nothing to breach, nothing to
subpoena, and no operator who could be compelled to hand over a movement
history, because no operator has one.

---

## 2. Adversaries

**A1 — The passer-by with a scanner.** Walks through a crowd running a BLE
sniffer, looking for trackers to follow. Needs no equipment beyond a phone.
The realistic, common adversary.

**A2 — The opportunistic finder.** Has physical possession of a dropped
keyholder. Wants to silence it, or make it theirs.

**A3 — The nearby nuisance.** In range, not in possession. Wants to make the
keyholder sound, or to stop it sounding when it should.

**A4 — The intimate adversary.** Has had access to the owner's phone or the
keyholder, perhaps for minutes. This is the adversary the tracker industry
actually has a problem with, and the hardest to defend against.

**A5 — The network observer.** Sees the app's HTTPS traffic to tile and
geocoding servers.

---

## 3. Design decisions, and the threat each answers

### 3.1 One advertised name for every unit — A1

A claimed keyholder advertises `FindMe`. So does an unclaimed one. So does every
other unit ever built. There is no serial number, no owner id, no nickname and no
counter on the air.

Nicknames exist, and they are the obvious thing to put in the advertisement —
the device would then be identifiable in a crowded scan list, which is
convenient. That convenience is precisely the attack. **Nicknames are stored in
phone preferences keyed by BLE id and are never written to the radio.** A
passer-by scanning a street sees a number of indistinguishable `FindMe` radios
and cannot tell which belongs to whom, or follow one of them through a building.

The cost is real and accepted: an owner with two keyholders cannot tell them
apart in the scan list except by signal strength. That is the correct trade.

Claim state *is* advertised, as one byte of service data in the scan response.
One bit distinguishing "owned" from "not owned" does not identify anybody, and
without it the app would have to offer pairing on devices that will refuse it.

### 3.2 Claiming requires the physical button — A2, A3, A4

`CLAIM:` is accepted only while the button is held down. There is no passphrase,
no PIN and no out-of-band code.

This is stronger than it sounds. A PIN on a device with no keypad has to be
printed on the enclosure or shipped in the box, which means anyone holding the
device has it; and anyone holding the device can press the button anyway. The
button is therefore not a weaker proof of possession than a printed secret — it
is the *same* proof, without a secret to leak.

What it buys: **ownership cannot be taken remotely.** An attacker in range, with
a full implementation of the protocol, cannot claim an unclaimed keyholder.
Against A4 the button is no defence at all, which is stated plainly in §5.

### 3.3 Challenge–response rather than a stored password — A3

Every connection to a claimed keyholder begins with a fresh 16-byte nonce. The
app answers with HMAC-SHA256(key, nonce), truncated to 128 bits.

| Property | Consequence |
|---|---|
| The key is sent exactly once, in `CLAIM_OK:`, at the moment of claiming | Nothing to intercept on later connections |
| The nonce is new every connection | A recorded exchange cannot be replayed |
| HMAC rather than encryption | The device needs no secret *at rest* beyond the key, and no cipher implementation |
| 128-bit truncation | Beyond brute force, and short enough to survive a low negotiated MTU |

The key is generated **on the device**, by its hardware RNG, not derived from
anything the phone knows. Two keyholders claimed by the same phone have
unrelated keys.

### 3.4 Lockout — A3

Three failed authentications and the keyholder refuses connections for 30
seconds. Against a 128-bit HMAC this is not what stops a brute force — the
arithmetic does that. What it stops is a nearby attacker burning the battery by
forcing an endless sequence of connect-and-fail cycles, which is the actual
denial-of-service available against a coin-cell-class device.

### 3.5 `neverForLocation` on the scan permission — the owner's own privacy

Android lets an app derive a position from the pattern of nearby Bluetooth
radios. `BLUETOOTH_SCAN` is declared with `android:usesPermissionFlags="neverForLocation"`,
which is a promise to the system and the user that this app does not do that.

It is a kept promise rather than a label: `BleService.startScan` passes
`androidUsesFineLocation: false`. The flag would be a lie if it did not.

### 3.6 No Wi-Fi credentials, anywhere — A2, A4

Wi-Fi provisioning existed. The keyholder accepted an SSID and a password over
BLE and stored them in NVS.

It is gone from both sides, and the third characteristic that carried it
(`…b26aa`) is deliberately *not* reused — the UUID is named in a comment in
`ble_protocol.dart` and nowhere else, so a phone still running the old firmware
cannot write a password to whatever gets created next.

The reasoning: a small object that is frequently lost, has no secure element,
and whose flash can be read over USB by anyone holding it, is the worst possible
place to keep a home network password. Removing the feature removed the asset.

### 3.7 The event log stays on the phone — A5

Every event — connections, alerts, breaches, positions, place names — is written
to `SharedPreferences` and goes nowhere else. The retention window is the
owner's choice and defaults to a bounded period rather than forever.

There was a "cloud reporting" setting. It is gone. A key finder that uploads a
movement history is a different product with a different risk profile, and it
was not what anyone had asked for.

### 3.8 HTTPS only, and a minimal footprint — A5

`android:usesCleartextTraffic="false"`, so the platform itself blocks any
accidental plaintext request.

Two services are contacted, both read-only and both optional:

| Service | Sees | Does not see |
|---|---|---|
| Map tiles (Esri, OpenStreetMap) | Which map tiles, hence roughly where | Who, or that a tracker is involved |
| Nominatim | A coordinate pair to name | Device identity, owner id, any key |

Neither is sent a device identifier, an owner id, or any key material. Both
fail soft: no internet means no tiles and no place names, and every alert,
alarm and log entry still works. An owner who never grants network access loses
cosmetics only.

### 3.9 Key storage

| Secret | Store |
|---|---|
| Owner id, 16 bytes | `flutter_secure_storage` — Android Keystore |
| Device key, 32 bytes | `flutter_secure_storage` — Android Keystore |
| Everything else | `SharedPreferences` |

The split is the point: nothing in `SharedPreferences` can be used to
impersonate the owner to a keyholder. A backup or a debug dump of preferences
leaks history, which is bad, but not control.

---

## 4. Threat matrix

| Attack | Adversary | Outcome |
|---|---|---|
| Scan a crowd and single out this keyholder | A1 | **Blocked.** Every unit advertises the same name; no identifier on the air. |
| Follow one keyholder through a building by its advertisement | A1 | **Blocked**, same reason. |
| Claim a keyholder found on the ground | A2 | **Works, and is intended.** See §5. |
| Claim an unclaimed keyholder from across the room | A3 | **Blocked.** The button must be held. |
| Make a claimed keyholder sound | A3 | **Blocked.** `FIND_KEY` requires an authenticated session. |
| Replay a recorded authentication | A3 | **Blocked.** Fresh nonce per connection. |
| Brute-force the key over the air | A3 | **Blocked.** 2¹²⁸, plus a 30 s lockout after three tries. |
| Read the owner's position out of a keyholder in hand | A2, A4 | **Possible.** See §5. |
| Extract the key from the flash of a device in hand | A2, A4 | **Possible.** See §5. |
| Plant a keyholder on someone to track them | A4 | **Partly mitigated.** See §5. |
| Learn the owner's home Wi-Fi password | A2, A4 | **Nothing to learn.** The feature is gone. |
| Pull a movement history from the vendor | — | **No vendor, no server, no history.** |
| Intercept tile or geocoding traffic | A5 | Reveals approximate position. HTTPS; no identifiers sent. |

---

## 5. What this design does not defend against

Stated plainly, because a security document that only lists wins is marketing.

**Physical possession of the keyholder defeats most of this.** ESP32-C3 flash
can be read over USB. Anyone holding the device can read the stored key, the
last position and the stored place name, and can press the button to claim it
after an unclaim. There is no secure element and no flash encryption enabled.
Mitigating this properly means enabling ESP32 flash encryption and secure boot —
possible on this chip, not done here, and worth doing before anything like a
product.

**The last known position is readable from the device's own screen.** Press the
button, read the place name. That is the feature: it is how an owner who has
lost their *phone* finds it. It is also how someone holding the keyholder learns
where its owner was. The two cannot be separated without removing the feature.

**An intimate adversary (A4) is not defeated.** Someone who can hold the
keyholder for thirty seconds can unclaim and reclaim it; someone with the
owner's unlocked phone has the app. No tracker design solves this, and the
industry's answer — cross-vendor unwanted-tracking alerts, where every phone
warns about any unfamiliar tracker travelling with it — requires participation
in Apple's and Google's detection networks, which a project of this size cannot
join. Being clear about it is the only honest option.

The partial mitigation is real but limited: this device advertises nothing
unique, so it cannot be *followed* by a third party — but neither can it be
*detected* as a planted tracker by the usual scanning apps, which look for
identifiers that persist. That cuts both ways, and the second edge is the one
worth naming.

**The distance estimate is not a security boundary.** RSSI is trivially
manipulated by anyone with an amplifier or a shield. "Out of range" means "the
radio stopped hearing it", which is not the same as "it has gone".

**`applicationId` is still `com.example.keyguard`.** Not a vulnerability, but it
must be changed before any public release — `com.example.*` is reserved for
samples and Play will not accept it. It is flagged rather than changed because
changing it breaks the upgrade path for every already-installed APK.

**The firmware is not compile-checked in CI.** A test parses the reference
sketch, which catches protocol drift but not a build break.

---

## 6. Guidance for anyone changing this code

1. **Never write a nickname, serial number, owner id or counter into an
   advertisement or scan response.** That single change would turn this into a
   followable tracker. §3.1 is the most important paragraph in this document.
2. **Keep the advertised name at 8 characters or fewer.** `test/auth_test.dart`
   enforces it; the reason is the 31-byte legacy advertisement budget, and
   exceeding it makes the device appear nameless in scan lists.
3. **Do not add a secret the owner has to type.** It would end up printed on the
   enclosure, and anyone who can read it can press the button anyway.
4. **Do not re-create the provisioning characteristic** (`…b26aa`), and do not
   reuse that UUID for anything.
5. **Both sides of any protocol change, in the same commit.** `ble_protocol.dart`
   and the firmware `#define`s are one contract with two copies.
6. **Watch the MTU when adding a frame.** The default 23-byte MTU leaves 20
   bytes of payload. A frame longer than that will not arrive whole unless both
   sides have raised the MTU, and nothing reports an error when it does not —
   which is exactly how the phone's position came to be undeliverable for as
   long as it was.
7. **Anything that leaves the phone is a new asset to defend.** The reason this
   document is short is that there is almost nothing on the network. Keep it
   that way.

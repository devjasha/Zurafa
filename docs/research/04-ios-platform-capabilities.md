# 04 — Apple platform capabilities for Zurafa iOS

*Researched 2026-11-08. Shipping platform: iOS/iPadOS 27 and macOS 27 (WWDC26, June 2026). iOS 26 APIs count as the floor. Scope: iPhone, iPad, Mac. Every platform claim links to Apple documentation or a WWDC session. Where Apple doesn't document something, or where a claim comes from a third party, the text says so.*

---

## 0. TL;DR

Zurafa iOS's job is to **know when an agent on the Mac needs you, let you answer in seconds, and let you take over the terminal when an answer isn't enough.** The app already covers most of the basics: alert pushes through a relay, an Approve/Deny category, a push-started Live Activity with `LiveActivityIntent` buttons, Liquid Glass chrome, and a SwiftTerm view over a raw Tailscale socket. The upgrades that matter most, ordered by how much they help per hour of work:

1. **Answer without Tailscale on the phone.** Today every lock-screen Approve has to bring up a TCP+TLS connection to the Mac over the phone's Tailscale VPN, inside a few seconds of background time. Send answers back **through the relay instead, signed with a Secure Enclave key** that the Mac verifies. This one change makes approvals reliable, and it turns Face ID into a check the Mac enforces rather than a UI courtesy. (§3.6, §9.3)
2. **Encrypt pushes end to end and add a Notification Service Extension.** Today the relay, which has no auth, sees every prompt in plain text. An NSE can decrypt with a key set up at pairing, attach the agent's icon, and enrich the notification. (§3.3)
3. **Expand the notification vocabulary:** time-sensitive for "needs you", passive for "done", a text-reply action ("tell the agent…"), `relevanceScore`, and a grouping/summary scheme for each agent. (§3.4–3.5)
4. **Fix the Live Activity lifetime gaps:** the 8-hour cap, `input-push-token`, the stale date, relevance, and landscape compact layouts on iOS 27. (§4)
5. **Add App Intents and entities** (agents and panes as `AppEntity`), which give you Shortcuts, Siri, Spotlight, Controls, Focus filters and Action-button support from one model. (§5)
6. **Make the terminal a proper hardware-keyboard citizen on iPad:** `UIPress`/`UIKeyCommand` priority, a menu bar via `UIMainMenuSystem`, multiwindow, pointer. Add a dictation-first **prompt composer** on iPhone. (§8)
7. **Pairing v2:** the QR code carries a public key and a one-time secret, and an iCloud Keychain item gives zero-tap pairing for users signed in to the same Apple Account. (§9)

The phased plan with effort and risk is at the end (§12).

---

## 1. What exists today (as of `55f4c02`)

| Area | Implementation | Files |
|---|---|---|
| Transport | `NWConnection` to `<mac>-zurafa.<tailnet>.ts.net:443` (TLS), then `GET /zurafa` with `Upgrade: zurafa`, then length-prefixed JSON frames, protocol 2. The Mac side is Zurafa's own embedded Tailscale node (tsnet), which admits only the owner's tailnet identities. | `apps/ios/ZurafaMobile/MacClient.swift`, `rust/crates/zurafa-daemon/src/listen.rs`, `remote.rs` |
| Resume | `resume()` on scene activation: a "connected" socket must answer `hosts.list` within 2 s or it gets rebuilt. A 10 s handshake timeout. | `MacClient.swift` |
| Alert push | Mac → `PhonePush.send` → `POST https://zurafa-website.vercel.app/api/push` (Vercel holds the `.p8`) → APNs `alert`, `thread-id`, `category: permission`. 410 removes the token. The Mac skips the push while the user is at the Mac (`userAtMac`, under 2 min idle). | `apps/macos/Sources/Zurafa/PhonePush.swift`, `website/api/push.js` |
| Actions | Category `permission`: Approve / Deny (`.authenticationRequired`, Deny `.destructive`). The handler calls `beginBackgroundTask`, reconnects (up to 10 s of 250 ms polls), checks the pane is still blocked on a permission, then sends `\r` or `ESC` into the pane. | `apps/ios/ZurafaMobile/Notifications.swift`, `MacClient.answerPermission` |
| Live Activity | `ZurafaAgentsAttributes`: up to 6 agents, working/blocked counts. Push-to-start (17.2+), with update and end via push. Updates are throttled to one per 5 s and sent immediately when an agent becomes blocked; priority 5 unless there's an alert. Approve/Deny through `AnswerPermissionIntent: LiveActivityIntent` with `requiresAuthentication`. | `apps/ios/ZurafaAgents/*`, `PhonePush.activity` |
| Pairing | QR → `zurafa://connect?address=NAME.ts.net` scanned with `DataScannerViewController`. The QR carries only an address; trust comes entirely from Tailscale identity. | `ZurafaMobileApp.swift`, `Info.plist` |
| Look | Mac theme mirrored through `ui.appearance`. Liquid Glass via `glassEffect(.regular.interactive())` and `GlassEffectContainer`, with a material fallback below iOS 26. | `Look.swift`, `TerminalScreen.swift` |
| Build | `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, `SWIFT_VERSION = 5.0`, `aps-environment = development` in the checked-in entitlements. | `ZurafaMobile.xcodeproj`, `ZurafaMobile.entitlements` |

Known debt, called out in the code itself: the relay has *"no auth or rate limit; anyone holding a phone's token could push to it"* (`website/api/push.js`).

---

## 2. Platform baseline (November 2026)

- **iOS 26** (2025) introduced Liquid Glass, `NetworkConnection` (an async Network.framework API), `BGContinuedProcessingTask`, `SnippetIntent` (interactive snippets), WidgetKit push updates (`WidgetPushHandler`), `SpeechAnalyzer`, and Controls on macOS. Availability of each: [NetworkConnection](https://developer.apple.com/documentation/network/networkconnection), [BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask), [SnippetIntent](https://developer.apple.com/documentation/appintents/snippetintent), [WidgetPushHandler](https://developer.apple.com/documentation/widgetkit/widgetpushhandler), [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [ControlWidget](https://developer.apple.com/documentation/swiftui/controlwidget).
- **iOS 27** (WWDC26) is mostly a Siri / App Intents / Foundation Models release:
  - App Intents adds entity and intent *schemas*, a View Annotations API, an `AppIntentsTesting` framework ([WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)), plus `LongRunningIntent`, `CancellableIntent`, `EntityCollection`, `SyncableEntity`, `RelevantEntities` and `allowedExecutionTargets` ([WWDC26-345](https://developer.apple.com/videos/play/wwdc2026/345/)).
  - Live Activities now show in the Dynamic Island in landscape ([WWDC26-223](https://developer.apple.com/videos/play/wwdc2026/223/)).
  - SwiftUI adds toolbar `visibilityPriority`, `ToolbarOverflowMenu`, `Tab(role: .prominent)`, and resizable iPhone apps for iPhone Mirroring ([WWDC26-269](https://developer.apple.com/videos/play/wwdc2026/269/)).
  - Foundation Models can now front third-party LLM providers ([WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)).
- **Late-2026 signal:** Apple's docs now list **ActivityKit on macOS 27.3** ([ActivityKit](https://developer.apple.com/documentation/activitykit), [`Activity`](https://developer.apple.com/documentation/activitykit/activity), [`pushToStartTokenUpdates`](https://developer.apple.com/documentation/activitykit/activity/pushtostarttokenupdates)). Before this, Macs only showed the *iPhone's* Live Activities in the menu bar ([ActivityKit updates, June 2025](https://developer.apple.com/documentation/updates/activitykit)). macOS 27.3 was not released when this was written and Apple hasn't published guidance. Watch this: a native Mac Live Activity could replace part of Zurafa's own menu-bar UI.
- **Bottom line for deployment target:** moving the iOS target from 17.0 to **26.0** removes every `#available` branch in the glass helpers and unlocks `NetworkConnection`, `SnippetIntent`, widget push and `SpeechAnalyzer`. For a developer-tool companion app with a technical audience, that's a reasonable trade. Moving to 27 adds landscape-island polish and the newer App Intents APIs.

---

## 3. Push notifications

### 3.1 APNs basics that constrain the design

- **Token-based auth:** the provider signs an ES256 JWT with the team's `.p8` key. Refresh it at most every 20 minutes and no less often than every 60 ([Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)). `push.js` caches for 50 minutes, which is correct.
- **Request headers** ([Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)):
  - `apns-push-type` (`alert`, `background`, `liveactivity`, `widgets`…)
  - `apns-topic`
  - `apns-priority` (10 = immediate, 5 = power-friendly, 1 = lowest)
  - `apns-expiration`
  - `apns-collapse-id`: up to 64 bytes. A newer notification with the same id *replaces* the older one in Notification Center.
- **Payload cap:** 4 KB for normal pushes. HTTP 410 means the token is no longer valid, which `PhonePush` already handles ([Handling notification responses from APNs](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)).
- **Background (silent) pushes** use `content-available: 1`, type `background` and priority 5. They are throttled, and Apple says not to send more than two or three an hour ([Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)). **Silent pushes can't drive the product.** Use them, if at all, to prefetch.

### 3.2 Direct APNs vs. relay

The `.p8` signing key covers **every app on the team**, so it can never ship inside the Mac app. That leaves three architectures:

| Option | How | Pros | Cons |
|---|---|---|---|
| **A. Stateless relay (today)** | The Mac posts plaintext to a Vercel function that signs and forwards. | Simple; no database. | No auth: anyone holding a token can spam the phone. The relay sees prompt contents. One vendor is a single point of failure. |
| **B. Authenticated relay** | The Mac proves it may push to a given token. | Closes the spam hole. | Needs per-pairing state or signed capabilities. |
| **C. Push-to-self via iCloud** | No server; CloudKit subscriptions push on record change. | No server to run. | CloudKit pushes are silent or opportunistic, with no Live Activity and no categories you control. Not suitable. |

**Recommendation: B, done statelessly.** At pairing, the phone gives the Mac a **capability** that the *phone* signs and the relay can check without a database. The phone already holds its own APNs token, so:

1. The phone generates a P-256 key in the Secure Enclave ([CryptoKit `SecureEnclave`](https://developer.apple.com/documentation/cryptokit/secureenclave)).
2. On first registration the phone sends the relay `{apnsToken, phonePublicKey}` together with an **App Attest** assertion ([Establishing your app's integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity), [`DCAppAttestService`](https://developer.apple.com/documentation/devicecheck/dcappattestservice)). The relay answers with `cap = HMAC(relaySecret, apnsToken ‖ macID ‖ expiry)`.
3. The phone hands `cap` to the Mac over the tailnet (`push.register`, which already exists). Every Mac → relay post includes `cap`. The relay recomputes the HMAC, so it needs no storage.

The cost is one HMAC secret in Vercel and about 40 lines of JavaScript. The same design also caps the blast radius if a Mac is compromised: a cap expires and is bound to one token.

### 3.3 Notification Service Extension (NSE): end-to-end encryption and rich content

**What it is.** An app extension that receives any alert push carrying `mutable-content: 1` and may rewrite it before display. It gets about **30 seconds**; then `serviceExtensionTimeWillExpire()` fires, and if the extension never calls the handler, the original content is shown ([Modifying content in newly delivered notifications](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications)). It only runs for pushes that display an alert.

**What Zurafa should use it for:**

1. **End-to-end encryption.** At pairing the Mac and phone agree on a symmetric key (§9.3). The Mac sends `alert: {title: "Zurafa", body: "An agent needs you"}` plus `enc: <ChaCha20-Poly1305 ciphertext of {title, subtitle, body, pane, kind, options}>`. The NSE decrypts using a key it reads from a **shared keychain access group** ([Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)). The relay and APNs then only ever see the generic placeholder. This is how Signal and other E2E messengers handle push. It removes the biggest privacy problem in the current relay: prompts often contain file paths, commands and code.
2. **Attachments.** Add a small agent badge, such as the brand glyph already in `AgentsWidget`, as a `UNNotificationAttachment` so each agent is recognizable at a glance.
3. **Communication-notification styling** (§3.5): the NSE is where the donation and the `content.updating(from:)` call go ([Implementing communication notifications](https://developer.apple.com/documentation/usernotifications/implementing-communication-notifications)).
4. **De-duplication.** The NSE can't suppress a notification without a special entitlement, but the Mac can avoid sending one. Set `apns-collapse-id = pane` so a newer prompt from the same pane replaces the older one.

**Gotchas:**
- The NSE is a separate process with tight memory limits. Don't run models in it, and don't open the Tailscale connection from it. It should only decrypt and decorate.
- It needs the App Group and keychain group entitlements, and has to share the decryption key without `kSecAttrAccessibleWhenUnlocked`. Use `AfterFirstUnlock`, because pushes arrive while the phone is locked.

### 3.4 Actionable notifications

**API surface.**
- `UNNotificationCategory` holds `UNNotificationAction` entries, with options `.authenticationRequired`, `.destructive` and `.foreground` ([`authenticationRequired`](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/authenticationrequired)).
- `UNTextInputNotificationAction` adds an inline reply field ([docs](https://developer.apple.com/documentation/usernotifications/untextinputnotificationaction)).
- Actions run in the app process, launched into the background unless `.foreground` is set.

**Proposed category set for agents:**

| Category | When | Actions |
|---|---|---|
| `permission` (exists) | The agent asks yes/no. | Approve (auth) · Deny (auth, destructive) |
| `permission.always` | The agent offers "Yes, and don't ask again". | Approve · Always allow (auth) · Deny |
| `choice` | The agent shows a numbered menu (Claude Code's 1/2/3). | Up to 4 actions built from the menu text. Categories are static, so register generic `choice.2`, `choice.3` and `choice.4` and put the labels in the body. |
| `question` | The agent is idle and waiting for a prompt. | **Reply** (`UNTextInputNotificationAction`, auth) · Open |
| `done` | A task finished. | Open · Start follow-up (text input) |
| `error` | The agent crashed or errored. | Open · Retry (sends the last command) |

The reply action is the single biggest UX gain. Most agent turns end with a question, and typing *"yes, go with option 2 and add tests"* from the lock screen beats opening the app.

**Gotchas:**
- Action titles are fixed when the category is registered. Dynamic button labels aren't possible, but categories can be re-registered at runtime, and the app could register categories for each pane shape. Keep the set small and stable.
- **The current approve path is fragile** (`MacClient.answerPermission`). The background task window is short and undocumented ([`beginBackgroundTask`](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:))). The phone may also have Tailscale off, connected to a different VPN, or have its VPN on-demand not yet started (§7.1). All of that has to finish within the window. See §3.6.
- The current guard (only send `\r` if the pane is still blocked on a permission) is good. Keep it, and move it to the Mac (§3.6) so it holds no matter how the answer arrives.

### 3.5 Interruption levels, grouping, summaries, Focus

**Interruption levels** ([`UNNotificationInterruptionLevel`](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel)):
- `passive`: list only, no sound, doesn't light the screen.
- `active`: the default.
- `timeSensitive`: breaks through Notification Summary and Focus; the user can turn this off per app ([`timeSensitive`](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive)). It requires the **Time Sensitive Notifications** capability, and the payload sets `"interruption-level": "time-sensitive"`.
- `critical`: bypasses mute. It needs an Apple-granted entitlement ([critical-alerts entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts)) that is reserved for health, safety and security use. **Zurafa won't qualify. Don't apply.**

Mapping for Zurafa:
- blocked or permission → `time-sensitive`. An agent burning wall-clock time while waiting is time-sensitive by Apple's own definition.
- question → `active`.
- done → `passive` by default, with a setting to make it `active`.
- error → `active`.

Ship a per-kind setting that mirrors the Mac's own notification settings.

**Grouping.** `thread-id` groups notifications in Notification Center ([`threadIdentifier`](https://developer.apple.com/documentation/usernotifications/unnotificationcontent/threadidentifier)). The Mac already sends `thread`. Use **one thread per agent pane** (`session/pane`) rather than per session, so a chatty agent doesn't bury a blocked one. Add `summary-arg` so the collapsed stack reads "3 more from Claude Code in zurafa/main".

**Relevance.** `relevance-score` (0–1) orders notifications in the scheduled summary ([`relevanceScore`](https://developer.apple.com/documentation/usernotifications/unnotificationcontent/relevancescore)). Use 1.0 for blocked, 0.6 for questions and 0.2 for done.

**Focus filters.**
- `filter-criteria` ([`filterCriteria`](https://developer.apple.com/documentation/usernotifications/unnotificationcontent/filtercriteria)) together with a `SetFocusFilterIntent` ([docs](https://developer.apple.com/documentation/appintents/setfocusfilterintent)) lets a user say *"In Work Focus, only show Zurafa notifications for workspace `client-x`"* or *"In Sleep, only blocked agents."* The intent exposes parameters such as workspaces and kinds. The app reads `SetFocusFilterIntent.current`, reports it to the Mac, and the Mac stamps `filter-criteria` on each push.
- This costs about a day and is something no competing terminal app offers.

**Communication notifications.**
- These show an avatar and a "sender", and break through the scheduled summary by default. The app needs the Communication Notifications capability, `INSendMessageIntent` in `NSUserActivityTypes`, and an incoming interaction donated in the NSE before calling `content.updating(from:)` ([Implementing communication notifications](https://developer.apple.com/documentation/usernotifications/implementing-communication-notifications)).
- An agent asking you a question is, semantically, a message from a correspondent: sender "Claude Code", conversation id = pane. This gives the agent's glyph as the avatar and "reply" semantics.
- **Review risk: medium.** Apple's framing is direct communication between people. Some non-chat apps use it, but expect a reviewer to ask. Ship time-sensitive first, and try communication styling behind a flag in a TestFlight build before shipping it.

### 3.6 The answer path: decouple approvals from Tailscale

The problem: an Approve tapped on the lock screen currently needs all of these within one background-execution window:
1. the iOS process launched,
2. the phone's Tailscale tunnel up,
3. a TLS handshake with the Mac's tsnet node,
4. the protocol hello, a full `events.subscribe_all` snapshot, and finally the input bytes.

Each step can fail on its own, and step 2 is outside Zurafa's control.

**Design:**
1. The Mac already makes outbound HTTPS calls (the relay). Give it a **long-poll or SSE inbox** on the relay: `GET /api/inbox?mac=<id>`, held open while any agent is blocked, keyed by a per-Mac secret created at pairing.
2. The phone's action handler, the `LiveActivityIntent`, or a Shortcut posts `{pane, promptID, answer, ts}` **signed by the phone's Secure Enclave key** to `/api/answer`. The relay drops it in the Mac's inbox. It can't forge one, because it never holds the private key.
3. The Mac verifies the signature against the phone's registered public key, checks `promptID` against the currently shown prompt (replay and staleness protection), then sends `\r` or ESC exactly as today.
4. **Race both paths.** If the phone already holds a live tailnet socket, send over it as well. The Mac dedupes on `promptID`.

The result: approvals succeed as long as the phone has *any* internet connection, take about one HTTPS round trip, and don't depend on VPN state. Face ID becomes meaningful, because the signing key can be created with `SecAccessControl(.biometryCurrentSet)` ([`biometryCurrentSet`](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset)). The Mac then knows that a fresh biometric check happened on that specific phone. That isn't the same as `.authenticationRequired`, which proves only that the device was unlocked. Use both: unlock for the action, and a biometric-bound key for dangerous categories such as `rm`-like commands and pushes to main (§9.2).

Effort: about 2–3 days, covering the relay endpoint, the Mac poller, iOS signing and promptID plumbing in the daemon. Risk: low to medium. The Vercel function's execution limits rule out long-holds there, so use a short 25-second poll with exponential backoff, which only runs while something is blocked.

---

## 4. Live Activities, Dynamic Island, StandBy, widgets, Controls

### 4.1 Live Activity facts that matter here

From [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) and [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications):

- **Lifetime:** an activity is active for up to **8 hours**. After that the system ends it and removes it from the island, but it can stay on the Lock Screen for up to 4 more hours (12 hours total).
- **Size:** static plus dynamic data has to fit in **4 KB**. Lock Screen views over 160 pt tall may be truncated.
- **No network:** activities have no network access; updates come only through ActivityKit in the app or through push.
- **Budget:** priority-10 pushes count against an hourly budget, and priority-5 pushes don't. `NSSupportsLiveActivitiesFrequentUpdates` raises the budget, and the user can turn it off; read it from `frequentPushesEnabled` ([docs](https://developer.apple.com/documentation/activitykit/activityauthorizationinfo/frequentpushesenabled), [plist key](https://developer.apple.com/documentation/bundleresources/information-property-list/nssupportsliveactivitiesfrequentupdates)).
- **Push-to-start:** 17.2+. The `start` payload needs an `alert`, `attributes-type` and `attributes`. **On iOS 18+, add `"input-push-token": 1`** to get an update token for the new activity, or `input-push-channel` to subscribe it to a broadcast channel. Broadcast pushes can't *start* an activity.
- **Broadcast channels (iOS 18):** one push fans out to every subscriber of a channel. The capability is only enabled on developer.apple.com, not in Xcode.
- **`stale-date`** flips `context.isStale`. **`relevance-score`** picks which of the app's activities gets the island. **`dismissal-date`** has to fall within the 4-hour window.
- **Surfaces:** Lock Screen, Dynamic Island (portrait and, since iOS 27, landscape; use `isDynamicIslandLimitedInWidth`), StandBy (`isActivityFullscreen`, scaled 200%), the Watch Smart Stack and CarPlay (`.supplementalActivityFamilies([.small])`), and the Mac menu bar ([WWDC26-223](https://developer.apple.com/videos/play/wwdc2026/223/)). Buttons don't work in CarPlay.

### 4.2 Gaps in Zurafa's current implementation

1. **The 8-hour cap.** Agents easily run overnight. After 8 hours the system ends the activity on its own. The phone's `activityStateUpdates` watcher only clears the token *if the app gets to run*, and the Mac then keeps sending updates to a dead token, relying on a 410 that Apple doesn't document for this case. **Fix:** the Mac tracks `startedAt` for each phone and, at about 7.5 hours, sends `end` followed by a fresh push-to-start. That's cheap and deterministic.
2. **No `input-push-token: 1`** in the `start` payload (`push.js activityPayload`). Per the docs, iOS 18+ start payloads can request the new update token explicitly. Today the code relies on the app being woken and `activityUpdates` firing. Add the field. It's one line, and the token then flows through `pushTokenUpdates` as before.
3. **No `stale-date`.** If the Mac sleeps or loses its network, the island shows "3 working" indefinitely. Send `stale-date = now + 2 min` on every update. The Mac already pushes at most every 5 s while things change; add a heartbeat every 60 s while anything is working, sent at priority 5 so it doesn't touch the budget. Render "Mac unreachable" when `context.isStale` is set.
4. **No `relevance-score`.** There's only one activity per phone, so this doesn't matter yet. It will if you move to one activity per Mac (below).
5. **Landscape and limited-width compact view (iOS 27).** `compactTrailing` shows a number, which is fine. `compactLeading` uses a 22 pt badge, which fits the 28 pt limited-width circle. Check it with `isDynamicIslandLimitedInWidth`.
6. **StandBy.** The Lock Screen view is reused at 200%. Use `isActivityFullscreen` for a "desk dashboard" layout showing all six agents with status colors. A phone on a MagSafe stand beside the Mac is a natural "agent monitor" setup.
7. **Watch.** Smart Stack forwarding is automatic. Add `.supplementalActivityFamilies([.small])` with a tiny "2 need you" view. That costs nothing, and Approve works from the wrist.

### 4.3 Multi-Mac design

Today `watchActivities` enforces "one activity per phone; a newer one replaces the rest". With several Macs, such as a work and a home machine, that thrashes. Instead, use **one activity per Mac**, with `attributes.mac` already identifying the Mac. Use `relevance-score = 100 × blocked + working`, so the Mac with a blocked agent owns the island. The system limits the number of simultaneous activities, and requests can fail when it's reached, so handle that error.

### 4.4 Broadcast channels: not needed

Channels exist for one-to-many updates (sports scores). Zurafa's data is per-user, so device tokens are right. Skip them.

### 4.5 Widgets

- **Lock Screen accessory widgets** (`accessoryCircular`, `accessoryRectangular`, `accessoryInline`) ([Creating accessory widgets](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications)): "2 blocked · 3 working" when no Live Activity is running, plus the last finished task.
- **Home Screen and interactive widgets** ([Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)): a medium widget listing agents, with Approve/Deny buttons through the same `AnswerPermissionIntent`. Widget buttons run App Intents in the widget extension or the app; WWDC26 adds `allowedExecutionTargets` to choose which ([WWDC26-345](https://developer.apple.com/videos/play/wwdc2026/345/)).
- **WidgetKit push** (iOS 26, [`WidgetPushHandler`](https://developer.apple.com/documentation/widgetkit/widgetpushhandler), [Updating widgets with WidgetKit push notifications](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications)): the Mac can push `content-changed` to reload timelines. These are **budgeted and opportunistic**, so they're good for a "done" tally and useless for real-time status. The relay needs a third push type (`widgets`, topic `<bundle>.push-type.widgets`).
- **Data path:** the widget extension can't reach the Mac. The app writes a snapshot to the App Group container whenever it's connected; the NSE also writes there on every push, which is one more reason to have an NSE; and widget push triggers a reload that reads it. That covers the case where the app is never opened.

### 4.6 Controls (Control Center, Lock Screen, Action button)

`ControlWidget` with `ControlWidgetButton` and `ControlWidgetToggle` runs on iOS 18+ and macOS 26+ ([ControlWidget](https://developer.apple.com/documentation/swiftui/controlwidget), [Creating controls to perform actions across the system](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)). Controls are App Intents, so they come almost free once §5 exists:
- **"Approve oldest prompt"** button. It requires authentication and shows the pane name in the confirmation snippet.
- **"Agents" toggle.** It pauses or resumes all phone notifications, as a do-not-disturb that the Mac respects.
- **"Open blocked agent"**, which deep-links into the terminal.
- **Action button:** any of these can be mapped to the iPhone's Action button. "Press to approve" on the side of the phone is a strong demo.

---

## 5. App Intents, Shortcuts, Siri, Spotlight, Focus

### 5.1 Model

One shared Swift module (app, widget extension and NSE) defines:

- `AgentEntity: AppEntity` (and `IndexedEntity`): id = pane id; properties include name, program, workspace, status and lastMessage ([AppEntity](https://developer.apple.com/documentation/appintents/appentity), [IndexedEntity](https://developer.apple.com/documentation/appintents/indexedentity)). `IndexedEntity` puts agents into Spotlight through Core Spotlight ([Core Spotlight](https://developer.apple.com/documentation/corespotlight)).
- `WorkspaceEntity`, `MacEntity`.
- Intents:
  - `AnswerPromptIntent(agent, answer)`, which already exists in a narrower form
  - `SendToAgentIntent(agent, text)`
  - `GetAgentStatusIntent(agent) -> status`
  - `OpenAgentIntent`
  - `NewAgentIntent(workspace, program, prompt)`: start Claude Code in a new tab with this prompt
  - `PauseNotificationsIntent`
- `AppShortcutsProvider` with phrases such as "Approve in Zurafa" and "What are my agents doing" ([AppShortcutsProvider](https://developer.apple.com/documentation/appintents/appshortcutsprovider)).
- `IntentAuthenticationPolicy.requiresAuthentication` on everything that writes ([docs](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy)).

### 5.2 What each system surface gives you

- **Shortcuts automations:** "When I arrive home, ask Zurafa for status and read it", or "At 6pm, if any agent is blocked, notify me." Power users chain these with Zurafa's own `zurafa` CLI on the Mac.
- **Siri (iOS 27).** Siri reaches app content through App Intents. **Entity schemas** contribute to the Spotlight semantic index, and **intent schemas** allow natural-language invocation without fixed phrases ([WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/), [WWDC26-240 App Schemas](https://developer.apple.com/videos/play/wwdc2026/240), [WWDC26-344 code-along](https://developer.apple.com/videos/play/wwdc2026/344)). That makes *"Hey Siri, tell the Claude agent in zurafa to run the tests too"* plausible: `SendToAgentIntent` with the agent resolved from the index. **Risk:** schema domains are Apple-defined, and the session material at hand didn't show whether a schema fits "send text to an agent" (a messaging schema might). Prototype before promising it.
- **View Annotations (iOS 27)** map on-screen views to entities so the user can say "approve this" while looking at a pane ([WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)). Annotate the terminal screen with its `AgentEntity`.
- **Interactive snippets (`SnippetIntent`, iOS 26):** Siri or Spotlight shows a live mini-card for an agent with its last lines and Approve/Deny, without opening the app ([SnippetIntent](https://developer.apple.com/documentation/appintents/snippetintent)).
- **Spotlight on Mac (macOS 26)** runs App Intents. If the Mac app adopts the same entities, ⌘-Space "approve claude" works on the Mac too, which keeps the two apps consistent.
- **`SyncableEntity` (iOS 27)** declares entity IDs stable across devices, so a Siri conversation can continue between devices ([WWDC26-345](https://developer.apple.com/videos/play/wwdc2026/345/)). Pane ids are already globally stable across the Mac and phone.
- **`RelevantEntities`** (iOS 27) suggests entities for a context. Push the currently blocked agents so they show up proactively.
- **`LongRunningIntent` / `CancellableIntent`** (iOS 27): "Run the test suite and tell me when it's done" as one Shortcut. The intent keeps running past 30 seconds, with progress shown as a Live Activity, while the Mac streams progress ([WWDC26-345](https://developer.apple.com/videos/play/wwdc2026/345/)).
- **`AppIntentsTesting`** (iOS 27) can exercise intents through system pathways in CI ([WWDC26-295](https://developer.apple.com/videos/play/wwdc2026/295)).
- **Focus filter:** `SetFocusFilterIntent` (§3.5).

### 5.3 Execution context gotcha

An intent running in the background still needs a way to reach the Mac. Route **writes** through the signed relay path from §3.6. **Reads** such as status should come from the App Group snapshot the NSE keeps fresh, with an optional live refresh when a tailnet socket is already up. Never have an intent block for seconds on a Tailscale cold start.

---

## 6. Background execution and connection resume

### 6.1 What iOS allows

There is **no supported way to keep an arbitrary TCP socket alive in the background** for an app like this:

| Mechanism | Fits Zurafa? | Why |
|---|---|---|
| `beginBackgroundTask` | Yes, for finishing a send. | A short, undocumented window ([docs](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:))). |
| `BGAppRefreshTask` | Marginal. | Opportunistic and short ([BGAppRefreshTask](https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask), [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)). Use it to refresh the widget snapshot at most. |
| `BGProcessingTask` | No. | Runs at the system's discretion, usually while charging. |
| `BGContinuedProcessingTask` (iOS 26) | **Situational.** | It has to start from a user action in the foreground and report progress, and the system shows a Live Activity with a cancel button ([BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask), [Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)). Valid for "upload this file to the Mac" or "pull this log". **Not** a keep-alive: progress has to be real, and forum reports describe it pausing on lock (developer.apple.com/forums/thread/796138). |
| Background `URLSession` | Yes, for transfers. | Uploads and downloads continue without the app ([Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)). Fine for "send this photo or screenshot to the agent", which goes to the relay or over HTTPS to the Mac's tsnet node. Note: a background session's daemon is outside the app, so tsnet-embedded traffic can't use it (§7.2). |
| PushKit VoIP | **No.** | Each VoIP push has to report a CallKit call; using it for anything else gets the app rejected and pushes cut off. |
| Audio / location background modes | **No.** | A guaranteed rejection if used as a keep-alive. |

So the architecture has to be **"push wakes, foreground streams"**, and it already is. The improvements are to the resume path.

### 6.2 Connection resume design

Current behavior: on activation, if a socket claims to be connected but the Mac hasn't spoken within 2 s, rebuild it. Then a full handshake runs: TLS, upgrade, hello, a full `subscribe_all` snapshot, and re-attaching each open terminal with replay.

Improvements:

1. **Path awareness.** Run an `NWPathMonitor` ([docs](https://developer.apple.com/documentation/network/nwpathmonitor)) for the whole session. When the path changes (Wi-Fi to cellular, or the VPN coming up), reconnect immediately instead of waiting for a send to fail. Use `NWConnection`'s viability and better-path handlers ([NWConnection](https://developer.apple.com/documentation/network/nwconnection)) to migrate early when a better path appears.
2. **Fail fast and say why.** When `MacClient` is `.waiting` and no `utun` path exists, the most common cause is that Tailscale is off. Detect it ("no VPN interface and the host is `*.ts.net`") and show "Turn on Tailscale" with a button that opens the Tailscale app through its URL scheme, instead of a generic timeout.
3. **Resumable sessions.** Have the daemon issue a `resume_token` and a per-subscription event sequence number at subscribe time. On reconnect the phone sends `{resume_token, last_seq}` and the daemon replays a delta rather than a full snapshot; terminals already resume from an output offset (`shown[pane]`). This cuts reconnect time from "full snapshot" to a single round trip.
4. **Pre-warm on push.** When a time-sensitive alert arrives with the app suspended, nothing runs. When the user **taps** the notification, start connecting in `didReceive` before SwiftUI finishes navigating, which the code already roughly does. Also render the **App Group snapshot** right away so the screen isn't empty while the socket comes up.
5. **`NetworkConnection` (iOS 26).** The new async/structured-concurrency API ([NetworkConnection](https://developer.apple.com/documentation/network/networkconnection), [WWDC25-250](https://developer.apple.com/videos/play/wwdc2025/250)) includes built-in framing (TLV) and fits Swift 6 strict concurrency far better than the current callback and `MainActor.assumeIsolated` code. Migrate when the target moves to 26. It's a mostly mechanical port of `MacClient`.
6. **TCP keepalive while foregrounded.** Set `NWProtocolTCP.Options.enableKeepalive` with a roughly 15 s idle interval, so a dead path is noticed in seconds rather than at the next write. Keep the application-level 2 s probe on resume.

---

## 7. Networking

### 7.1 Tailscale app (NetworkExtension) vs. embedded tsnet

**Today** the phone relies on the user's **Tailscale iOS app**, a packet-tunnel NetworkExtension, being on. MagicDNS resolves `*.ts.net` through the tunnel's DNS.

Constraints:
- **iOS runs one VPN at a time.** A user on a corporate VPN, or with a privacy VPN such as Mullvad or iCloud Private Relay-like tools, can't reach the Mac. Tailscale's own FAQ says this ([Can I use Tailscale alongside other VPNs?](https://tailscale.com/kb/1105/other-vpns)), and only one VPN app can have On Demand enabled ([Tailscale: VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand)). Apple's API is [`NEVPNManager`](https://developer.apple.com/documentation/networkextension/nevpnmanager) / [NetworkExtension](https://developer.apple.com/documentation/networkextension).
- **Local network privacy doesn't apply to the VPN path.** TN3179 defines a local network as one on a broadcast-capable interface, "Wi-Fi and Ethernet, but not cellular (WWAN) or VPN" ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)). So no Local Network prompt is needed today. Keep it that way: Bonjour discovery would add a prompt (§7.3).

**Option: embed Tailscale in the app (TailscaleKit / libtailscale).**
- The Mac side already does this: the daemon runs tsnet as "Zurafa's own Tailscale device". libtailscale ships Swift bindings, **TailscaleKit**, for iOS and macOS. They provide a `TailscaleNode` that can listen and dial with an "NWConnection-like" async API, a `URLSessionConfiguration.tailscaleSession` that proxies HTTP through loopback, and a LocalAPI described as "somewhat incomplete". It has to be built from source (`make ios`); there's no published binary ([libtailscale/swift](https://github.com/tailscale/libtailscale/tree/main/swift)). It needs no VPN entitlement, because it's a userspace netstack in-process.
- **Pros:**
  - It works **alongside any other VPN** and needs no Tailscale app at all; a "zero-install" phone is possible with a Tailscale login inside Zurafa.
  - Zurafa controls the node's lifecycle, so it can show precise errors.
  - The node can be tagged or ACL'd as a "zurafa-phone".
- **Cons and risks:**
  - The node only runs while the app runs, so every foreground means a cold start: control-plane contact, DERP or a direct WireGuard handshake. Expect a cost of roughly a second or more per resume. This is an estimate; measure it. Persist the node state directory in the App Group to avoid re-login.
  - Each phone is a tailnet device; the user consents through a browser login URL delivered over the IPN bus.
  - The Go runtime adds tens of MB to the binary.
  - The NSE, widgets and background `URLSession` can't use the node because it lives in the app process. That's fine if writes go through the relay (§3.6).
  - App Review: userspace networking without a VPN profile is ordinary networking code. No special entitlement applies, so the risk is low.
  - Maintenance: as of this writing TailscaleKit has no published version or stability statement.
- **Recommendation:** add a **"Built-in Tailscale" connection mode** as an opt-in fallback ("Can't use the Tailscale app? Sign in here"), and keep the system Tailscale app as the default. Do it after §3.6 lands, since the relay answer path removes most of the urgency.

### 7.2 Network.framework specifics

- Keep `NWConnection` with TLS. In 26+, port to `NetworkConnection` (§6.2).
- Certificate trust: the Mac's tsnet serves a Let's Encrypt certificate for `*.ts.net` (Tailscale HTTPS), so default trust works. **Add pinning to the pairing key, not the certificate:** after TLS, the protocol `hello` should carry a signature by the Mac's pairing key over a phone nonce (§9.3). Then a tailnet compromise, or a re-issued certificate, can't impersonate the Mac.
- Multipath TCP needs an entitlement and server support. It isn't worth it, because WireGuard roaming already handles Wi-Fi to cellular for the Tailscale path.

### 7.3 Bonjour / same-LAN direct connection

If phone and Mac share a LAN, a direct connection skips DERP and works with Tailscale off. Cost:
- the Local Network prompt (`NSLocalNetworkUsageDescription` and `NSBonjourServices: _zurafa._tcp`), which background code can't trigger ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy));
- a TLS identity to pin (§9.3);
- a second listener on the Mac.

**Defer.** Tailscale already goes direct on the same LAN. Revisit only if users complain about Tailscale being required at home.

### 7.4 Continuity: Handoff, Universal Clipboard, iPhone Mirroring

- **Handoff** ([`NSUserActivity`](https://developer.apple.com/documentation/foundation/nsuseractivity)). The Mac app publishes an activity `dev.zurafa.pane` with `{macID, pane}` for the focused pane, and the iOS app lists the type in `NSUserActivityTypes`. Then "Continue on iPhone" appears in the App Switcher, or the dock on iPad, and opens that pane. Reverse it on iOS, so a pane open on the iPhone appears in the Mac's Dock. Requirements: both apps signed by the same team, same Apple Account, Bluetooth and Wi-Fi on. **Gotcha:** the Mac app ships through Developer ID or Sparkle, not the Mac App Store. Handoff works for Developer ID apps from the same team, but verify on a real notarized build. Effort: about 1 day. This is the most "Apple-native" feature on the list, and it fits "pick up where the agent is" perfectly.
- **Universal Clipboard** needs no API: `UIPasteboard` reads the Mac's copy ([UIPasteboard](https://developer.apple.com/documentation/uikit/uipasteboard)). Programmatic reads trigger the paste-permission prompt. Use **`PasteButton` / `UIPasteControl`** in the key bar so paste never prompts ([PasteButton](https://developer.apple.com/documentation/swiftui/pastebutton), [UIPasteControl](https://developer.apple.com/documentation/uikit/uipastecontrol)). Wrap pasted text in bracketed-paste sequences when the remote app enabled mode 2004. SwiftTerm handles this if it's given the text via `paste`.
- **iPhone Mirroring** (macOS 15+) shows the phone app on the Mac. iOS 27 makes iPhone apps resizable there, and SwiftUI apps get it automatically ([WWDC26-269](https://developer.apple.com/videos/play/wwdc2026/269/), [WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)). For Zurafa this is mostly a **duplication hazard**: iPhone notifications are relayed to the Mac while mirroring, so the Mac would get its own banner *and* the phone's. The existing `userAtMac` suppression already covers that, since if you're mirroring you're at the Mac. Make sure the terminal reflows at mirrored sizes, and test with the Xcode 27 resizable previews.

---

## 8. Terminal text input on iPhone and iPad

### 8.1 Software keyboard and the key bar

- SwiftTerm's iOS `TerminalView` implements `UITextInput`/`UIKeyInput` ([UITextInput](https://developer.apple.com/documentation/uikit/uitextinput), [UIKeyInput](https://developer.apple.com/documentation/uikit/uikeyinput)). Zurafa sets `inputAccessoryView = nil` and draws its own glass key bar (`TerminalScreen.swift`), which is the right call with Liquid Glass. The system's accessory bar ([`inputAccessoryView`](https://developer.apple.com/documentation/uikit/uiresponder/inputaccessoryview)) would sit on an opaque strip.
- Set `UITextInputTraits` ([docs](https://developer.apple.com/documentation/uikit/uitextinputtraits)) to `autocorrectionType = .no`, `autocapitalizationType = .none`, `smartQuotesType = .no`, `smartDashesType = .no`, `smartInsertDeleteType = .no`, `spellCheckingType = .no` and `keyboardType = .asciiCapable`. Smart punctuation turning `--` into `—` silently breaks shell commands. Check what SwiftTerm defaults to.
- **Key bar content for agents:** Esc, Ctrl (sticky), Tab, ↑ ↓ ← →, `/`, `|`, `~`, and **1 / 2 / 3** for numbered menus. Agent-aware keys work better here than generic ones: when the pane's status is a permission prompt, show a large **Yes / No** pair that sends exactly what the Mac's banner sends.

### 8.2 Prompt composer: the main iPhone input mode

Typing into a raw PTY on a phone is miserable, and agents take whole prompts. Add a **composer sheet**: a multi-line `TextEditor` with full autocorrect and dictation, history, and `@file` completion fetched from the Mac. It sends the text in one go as a bracketed paste followed by `\r`. That gives:
- **Dictation**, built into `UITextView`, and a natural fit for "describe the task" prompts.
- **On-device transcription** with `SpeechAnalyzer` (iOS 26, [docs](https://developer.apple.com/documentation/speech/speechanalyzer)) for a press-and-hold mic button with live text, which also works on a locked device inside a Live Activity flow.
- **Scribble** with Apple Pencil, free in a standard text view. For the terminal view itself, adopt `UIScribbleInteraction` so Pencil writing in a pane routes to the composer instead of failing ([UIScribbleInteraction](https://developer.apple.com/documentation/uikit/uiscribbleinteraction)).

### 8.3 Hardware keyboard (iPad and Magic Keyboard on iPhone)

- **Raw keys:** override `pressesBegan`/`pressesEnded` and read `UIPress.key` (`UIKey` with `keyCode`, `characters` and `modifierFlags`) ([UIPress](https://developer.apple.com/documentation/uikit/uipress)). That's the only way to get Ctrl-letter combinations, Esc, Option-as-Meta and auto-repeat correctly. Check SwiftTerm's coverage and add Option-as-Meta as a setting, matching the Mac app.
- **Shortcuts that beat the system:** `UIKeyCommand` with `wantsPriorityOverSystemBehavior = true` ([docs](https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior)) is needed so that, for example, ⌘-W closes the *pane* and not the scene, and Tab and arrows go to the terminal rather than focus navigation. Mirror the Mac's bindings: ⌘T new tab, ⌘D split, ⌘[ / ⌘] cycle panes, ⌘K clear, ⌘1–9 workspaces, and ⌘⏎ to open the composer.
- **iPadOS 26 menu bar:** iPad apps now get a Mac-style menu bar; declare it with `UIMainMenuSystem` ([docs](https://developer.apple.com/documentation/uikit/uimainmenusystem), [Menus and shortcuts](https://developer.apple.com/documentation/uikit/menus-and-shortcuts)). Building the menus from the same command table as the Mac app gives near-identical menus on both. In SwiftUI, the equivalents are `.keyboardShortcut` and `.onKeyPress` ([keyboardShortcut](https://developer.apple.com/documentation/swiftui/view/keyboardshortcut(_:modifiers:)), [onKeyPress](https://developer.apple.com/documentation/swiftui/view/onkeypress(_:action:))).

### 8.4 iPad: multiwindow, Stage Manager, pointer

- **Multiple scenes** (`UIApplicationSupportsMultipleScenes`, [docs](https://developer.apple.com/documentation/uikit/uiapplication/supportsmultiplescenes); [UISceneSession](https://developer.apple.com/documentation/uikit/uiscenesession)): one window per pane or workspace, with state restoration carrying `{macID, pane}`. This needs a refactor: `MacClient.shared` and `Terminals.shared` are already process-wide, which is right because there should be one socket, but **sizing ownership** ("this phone is the one sizing it", `onSize`) has to become per-*window*. With two windows on the same pane, the larger one wins, or the mirrored-grid mode applies.
- **iPadOS 26 windowing** (freely resizable windows, the menu bar) makes the iPad a credible "terminal on the couch". Size the terminal from the scene geometry and send `resize` while a live resize is happening, debounced.
- **Pointer:** `UIPointerInteraction` ([docs](https://developer.apple.com/documentation/uikit/uipointerinteraction)) gives an I-beam over text, hover highlighting on tabs, and secondary click for a context menu (copy, paste, split, float). Forward mouse events to TUI apps that enable mouse reporting (1000/1006). SwiftTerm supports mouse reporting; wire trackpad scroll to scrollback or mouse wheel to match the Mac.

---

## 9. Security

### 9.1 Today's trust model

- **Transport:** TLS to a `*.ts.net` certificate, inside WireGuard.
- **Admission:** the Mac admits only peers whose Tailscale identity is the owner's (`listen.rs`).
- **Pushes and answers:** the relay is unauthenticated and sees plaintext, and the lock-screen Approve is gated only by device unlock.

This is reasonable for v1, but it leaves Zurafa's security equal to "anyone who can unlock any device on my tailnet, and anyone who learns my APNs token". For a tool that types `\r` into an agent holding shell permissions, the bar should be higher.

### 9.2 Face ID gating

- **UI gate:** `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` ([LAContext](https://developer.apple.com/documentation/localauthentication/lacontext), [Face ID login guide](https://developer.apple.com/documentation/localauthentication/logging-a-user-into-your-app-with-face-id-or-touch-id)). It needs `NSFaceIDUsageDescription`. This is easy to bypass on a compromised device, but it's fine as UX.
- **Cryptographic gate (recommended):** a Secure Enclave P-256 signing key created with `SecAccessControl` flags `.privateKeyUsage` and `.biometryCurrentSet` ([kSecAttrAccessControl](https://developer.apple.com/documentation/security/ksecattraccesscontrol), [biometryCurrentSet](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset), [CryptoKit SecureEnclave](https://developer.apple.com/documentation/cryptokit/secureenclave)). Each signature requires a fresh Face ID, and enrolling a new face invalidates the key. The Mac verifies the signature.
- **Policy, set on the Mac** in Settings → Phone:
  - "Require Face ID for: approvals | typing into panes | closing panes | all".
  - The Mac tags each prompt with a risk level, so `Bash(rm …)`, `git push` and anything outside the project get high risk. High-risk prompts need a biometric-signed answer: no Approve from a lock-screen banner unless the device has Face ID unlocked, and never from a Watch.
- **Gotcha:** two keys are cleaner than one. Use a biometry-bound key for dangerous actions and a plain `AfterFirstUnlock` key for routine ones, such as answers on low-risk prompts. Requiring Face ID for *everything* trains users to stop reading.

### 9.3 Pairing v2 (QR + key exchange)

The current QR is `zurafa://connect?address=NAME.ts.net`. Proposed:

```
zurafa://pair?v=2&addr=NAME.ts.net&mac=<macID>&pk=<Mac X25519 static pubkey b64url>&otp=<128-bit one-time secret>&exp=<unix>
```

1. Scan with `DataScannerViewController` (exists, [docs](https://developer.apple.com/documentation/visionkit/datascannerviewcontroller)).
2. The phone generates:
   - a Secure Enclave P-256 signing key (SE keys are P-256 only);
   - an ephemeral X25519 key ([Curve25519.KeyAgreement](https://developer.apple.com/documentation/cryptokit/curve25519/keyagreement)).
3. The phone connects over the tailnet as today and sends `pair{phonePK_sign, phonePK_eph, HMAC(otp, transcript)}`.
4. The Mac checks the OTP, which is single-use, expires in 5 minutes, and is shown only in the Mac's Settings sheet. It answers with a signature over the transcript using its static key. Both sides derive a `pushKey` (for NSE encryption, §3.3) and a `sessionKey` with HKDF. HPKE is an alternative ([CryptoKit HPKE](https://developer.apple.com/documentation/cryptokit/hpke)).
5. Storage:
   - The phone keeps `{macID, macPK, pushKey}` in the shared keychain group, with `AfterFirstUnlockThisDeviceOnly`, so the NSE can read it.
   - The Mac keeps `{phoneID, phonePK_sign, pushKey, apnsToken, cap}` in the daemon's store.
6. From then on, every connection's `hello` includes a Mac signature over a phone nonce, which pins the Mac beyond TLS (§7.2). Every write that matters (answers, input to a pane flagged high-risk) is signed by the phone.

Why this matters: pairing with an OTP proves physical presence at the Mac's screen. Tailscale identity alone admits any device the user ever logged in, including an old iPad in a drawer. Tailscale identity stays a second factor.

**Zero-tap pairing via iCloud Keychain.**
- The Mac writes a **synchronizable** keychain item (`kSecAttrSynchronizable = true`, [docs](https://developer.apple.com/documentation/security/ksecattrsynchronizable)) to a shared access group, holding `{addr, macID, macPK}`. The public key isn't secret.
- The phone, on the same Apple Account, finds it at first launch and offers "Connect to Yareli's MacBook Pro?".
- Synced items can't carry device-only accessibility or biometric access control, so **only put public data in them**. The phone still runs the OTP-less handshake, and the Mac shows an "Allow this iPhone?" confirmation on its own screen. That gives one click on each side and no camera.
- **Gotchas:**
  - On macOS the item has to go in the data-protection keychain (`kSecUseDataProtectionKeychain`) for iCloud sync ([Keychain services](https://developer.apple.com/documentation/security/keychain-services)).
  - The Mac app is **Developer ID** distributed; the keychain-access-groups and iCloud entitlements need a Developer ID provisioning profile containing them ([Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services)). Verify this with the notarized build pipeline (`scripts/release-macos.sh`) before committing to it.

### 9.4 App Attest

`DCAppAttestService` proves to *your server* that requests come from a genuine copy of the app on genuine hardware ([DCAppAttestService](https://developer.apple.com/documentation/devicecheck/dcappattestservice), [Establishing your app's integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)). Its job for Zurafa is narrow and useful: **gating relay registration** (§3.2), so a script can't mint push capabilities. Apple lists it for macOS 11+ as well, but `isSupported` is false on simulators, and it isn't supported on every Mac. Always check `isSupported` and degrade to rate limiting. It isn't needed between phone and Mac, where the pairing keys cover that.

---

## 10. Design language: Liquid Glass with parity to the Mac

### 10.1 What Apple ships

- **iOS/macOS 26 Liquid Glass:**
  - `glassEffect(_:in:)` and `GlassEffectContainer` for custom glass shapes ([glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)), [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer), [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)).
  - `.buttonStyle(.glass)` ([docs](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass)).
  - Standard bars and sheets pick up glass automatically when built with the new SDK.
  - `tabBarMinimizeBehavior` ([docs](https://developer.apple.com/documentation/swiftui/view/tabbarminimizebehavior(_:))).
- **iOS/macOS 27:** "refreshed materials, refined typography, updated tab and navigation bars", picked up automatically with Xcode 27 ([WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)). New toolbar controls: `visibilityPriority`, `ToolbarOverflowMenu`, `.topBarPinnedTrailing`, `toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)`, and `Tab(role: .prominent)`. Interactive glass now responds to pointer and click on macOS ([WWDC26-269](https://developer.apple.com/videos/play/wwdc2026/269/)).

### 10.2 Rules for Zurafa

Consistent with the project's "stock controls only" and "iOS mirrors Mac look" rules:

1. **Glass goes on the control layer, never on content.** The terminal grid stays opaque in the Mac theme's background color, which `MacLook` and `Terminals.colors` already do. The key bar, the pane switcher and floating buttons are glass. That is what `TerminalScreen`'s `glass(in:)` and `glassGroup()` do, so keep it.
2. **Prefer stock over custom glass.** Wherever a `.toolbar`, `TabView`, `.sheet` or `Menu` can express a control, use it and let the system draw the glass. Keep custom `glassEffect` for the floating key bar, which has no stock equivalent.
3. **One source of tint.** `ui.appearance.accent` already drives `.tint`. Glass picks it up through `.glassEffect(.regular.tint(accent))` only for *prominent* actions (Approve) and stays untinted elsewhere, matching Apple's guidance to tint sparingly.
4. **Delete the fallbacks** when the deployment target reaches 26: the `#available` branches in `glass(in:)` and `glassGroup()`.
5. **Navigation shape:** use the Rex mobile layout as the reference, per the memory note.
   - iPhone: `NavigationStack` with Sessions → Workspace → Pane. A bottom accessory (`tabViewBottomAccessory`, iOS 26) shows "2 agents need you", visible from every screen.
   - iPad: a `NavigationSplitView` sidebar that mirrors the Mac's sidebar one to one: workspaces, tabs, agent tiles with the same `Program.detect` glyphs.
6. **Icons:** for agent badges, reuse the same brand-glyph assets in the app, widget, Live Activity and notification attachment, so an agent looks the same on all four surfaces.
7. **Screenshots** of the running app must be checked in both light and dark appearances before handing the UI back (project rule).

---

## 11. Other relevant capabilities

### 11.1 Swift 6 concurrency

Both targets build in Swift 5 mode, with `@preconcurrency import UserNotifications` and `MainActor.assumeIsolated` inside `NWConnection` callbacks. Swift 6.2's **default MainActor isolation** for app targets fits this codebase, where almost everything is UI-bound and main-actor already, together with the strict concurrency checking described in [Adopting strict concurrency in Swift 6 apps](https://developer.apple.com/documentation/swift/adoptingswift6). Plan:
1. Turn on complete checking as warnings.
2. Port `MacClient` to `NetworkConnection` (async), which removes the callback hopping.
3. Make the protocol types `Sendable`.
4. Switch the language mode.

The NSE and widget extension should be Swift 6 from day one; they're small.

### 11.2 Settings sync: SwiftData + CloudKit vs. key-value store

- What needs syncing: paired Macs (public data only), notification preferences, key-bar layout and composer history.
- **`NSUbiquitousKeyValueStore`** ([docs](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)) handles small values with a 1 MB total and is shared between the iOS and Mac apps when they use the same container identifier. It's the smallest thing that works, so use it.
- **SwiftData with CloudKit** ([Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices); [SwiftData](https://developer.apple.com/documentation/swiftdata), [CloudKit](https://developer.apple.com/documentation/cloudkit)) is overkill unless you add synced history such as an "agent run log". Even then, the Mac daemon is the source of truth for history, and the phone should just query it.
- **Better still:** have the Mac own notification preferences and push them over `ui.appearance`-style requests, the way appearance already works. Then there's nothing to sync. Use KVS only for the pairing hint and the phone's own UI preferences.

### 11.3 Foundation Models and Apple Intelligence

- With iOS 27, Foundation Models can call the on-device model, Private Cloud Compute for eligible small developers at no cost, or third-party providers through a `LanguageModel` protocol ([WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/), [Foundation Models](https://developer.apple.com/documentation/foundationmodels)).
- **Useful application:** in-app, on demand, "Summarize what this agent did in the last hour" over the pane's scrollback, which the Mac sends on request.
- **Not in the NSE:** memory and the time limit rule it out. Have the *Mac* write notification bodies, since it has the context and the compute.
- Apple Intelligence notification summaries apply to Zurafa's notifications automatically. Concise, structured bodies ("Claude Code · zurafa/main — wants to run `npm test`") summarize well. Avoid raw terminal dumps.

### 11.4 Accessibility

- **VoiceOver:** each Live Activity and widget view needs explicit labels ([ActivityKit accessibility guidance](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)). The terminal needs an accessibility representation of the last N lines and an announcement when the status changes ("Claude Code needs approval").
- **Dynamic Type** already drives the terminal font (`UIContentSizeCategory` observer in `Terminals.swift`). Keep it.

---

## 12. Roadmap for Zurafa iOS

Effort is in focused engineer-days for one developer who knows the codebase. Risk is technical plus App Review.

### Phase 1: reliable and private notifications (about 2 weeks)

| # | Item | Effort | Risk | Notes |
|---|---|---|---|---|
| 1.1 | Interruption levels (time-sensitive for blocked, passive for done), `relevance-score`, a `thread-id` per pane, `apns-collapse-id = pane` | 1 d | Low | Capability plus payload fields in `push.js` and `PhonePush.send`. |
| 1.2 | Live Activity hygiene: `input-push-token: 1`, a `stale-date` heartbeat at priority 5, a 7.5 h restart, a "Mac unreachable" stale view, `isDynamicIslandLimitedInWidth`, `isActivityFullscreen` StandBy layout, Watch `.small` family | 2 d | Low | Mostly `PhonePush.swift`, `push.js` and `AgentsWidget.swift`. |
| 1.3 | Relay auth: App Attest-gated registration and an HMAC capability | 2 d | Low–Med | Closes the documented `shortcut:` in `push.js`. |
| 1.4 | Pairing v2 (QR with key and OTP, Secure Enclave keys, signed `hello`) | 3 d | Med | Daemon protocol change; keep v1 pairing working for a release. |
| 1.5 | NSE: E2E-decrypted bodies plus agent-glyph attachment | 2 d | Low | Needs the App Group and keychain group; depends on 1.4. |
| 1.6 | **Signed answers through the relay inbox**, raced with the tailnet path; `promptID` dedupe on the Mac | 3 d | Med | The biggest reliability gain. Vercel limits mean polling, not long-holds. |

Exit criterion: lock-screen Approve succeeds in under 2 s with Tailscale *off* on the phone, and the relay never sees prompt text.

### Phase 2: answer and steer without opening the app (about 2 weeks)

| # | Item | Effort | Risk | Notes |
|---|---|---|---|---|
| 2.1 | Categories `choice.N`, `question` (text reply), `done`, `error` | 2 d | Low | The Mac classifies prompts, which needs daemon status detail. |
| 2.2 | App Intents model: `AgentEntity`/`IndexedEntity`, Answer/Send/Status/Open/New intents, `AppShortcutsProvider` | 3 d | Low | Shared module for app, widget and NSE. |
| 2.3 | Controls (Approve oldest, Pause notifications, Open blocked) plus Action button | 1 d | Low | Free once 2.2 exists. |
| 2.4 | Lock Screen and Home Screen widgets reading the App Group snapshot, plus WidgetKit push | 2 d | Low | The relay gains the `widgets` push type. |
| 2.5 | Focus filter (`SetFocusFilterIntent` and `filter-criteria`) | 1 d | Low | Something no competitor has. |
| 2.6 | Risk-tiered Face ID (biometry-bound key for high-risk prompts) | 1.5 d | Med | The Mac classifies risk; UX tuning needed. |
| 2.7 | Communication-notification styling, behind a flag | 1.5 d | **Med–High (review)** | TestFlight first; drop it if review objects. |

### Phase 3: a terminal that's good on iPad (about 2–3 weeks)

| # | Item | Effort | Risk | Notes |
|---|---|---|---|---|
| 3.1 | Input traits audit, sticky Ctrl, Option-as-Meta, agent-aware key bar (Yes/No, 1/2/3) | 2 d | Low | |
| 3.2 | Prompt composer with dictation, `SpeechAnalyzer` push-to-talk, `@file` completion, bracketed paste | 3 d | Low | The main iPhone input mode. |
| 3.3 | Hardware keyboard: `pressesBegan` coverage, `UIKeyCommand` priority, Mac-matching bindings, `UIMainMenuSystem` menu bar | 3 d | Med | SwiftTerm patches may be needed upstream. |
| 3.4 | Multiwindow / Stage Manager: scene per pane, sizing owned per window, state restoration | 4 d | Med | Touches the `Terminals` sizing model. |
| 3.5 | Pointer: I-beam, hover, context menus, mouse reporting, trackpad scroll | 2 d | Low | |
| 3.6 | `PasteButton` in the key bar; Scribble routing to the composer | 0.5 d | Low | |

### Phase 4: platform polish and modernization (about 2 weeks, can overlap)

| # | Item | Effort | Risk | Notes |
|---|---|---|---|---|
| 4.1 | Deployment target 26; delete glass fallbacks; adopt `tabViewBottomAccessory` "agents need you" and iOS 27 toolbar APIs | 1 d | Low | Drops iOS 17/18 users; check analytics first. |
| 4.2 | `NetworkConnection` port, `NWPathMonitor`-driven reconnect, keepalive, "Turn on Tailscale" diagnostics | 3 d | Med | Then Swift 6 language mode. |
| 4.3 | Resumable subscriptions (`resume_token`, `last_seq` deltas) | 3 d | Med | Daemon change; large reconnect-latency win. |
| 4.4 | Handoff (pane ↔ pane) between the Mac and iOS apps | 1 d | Low–Med | Verify with the Developer ID-signed Mac build. |
| 4.5 | Multi-Mac: one activity per Mac, relevance-ordered | 1.5 d | Low | |
| 4.6 | iCloud Keychain zero-tap pairing hint | 1.5 d | Med | Depends on Developer ID entitlement support for keychain-access-groups and iCloud. |

### Phase 5: bets (time-boxed spikes)

| # | Item | Effort | Risk | Notes |
|---|---|---|---|---|
| 5.1 | Built-in Tailscale (TailscaleKit) as a fallback connection mode | 1 wk spike | **High** | Unversioned library, Go runtime size, cold-start latency. Value drops after 1.6. |
| 5.2 | Siri via iOS 27 App Schemas / intent schemas ("tell the agent…") | 3 d spike | Med–High | Depends on whether an Apple schema fits; prototype before promising. |
| 5.3 | `SnippetIntent` live agent card in Spotlight/Siri; View Annotations on the terminal | 2 d | Med | iOS 26/27 only. |
| 5.4 | `LongRunningIntent` "run X and tell me when done" Shortcut | 2 d | Med | iOS 27. |
| 5.5 | Native **macOS 27.3 ActivityKit**: evaluate replacing parts of the Mac menu-bar UI | spike once released | Unknown | APIs are listed but there's no guidance yet. |
| 5.6 | Foundation Models "summarize this agent's last hour" | 2 d | Low | In-app only; the Mac provides the scrollback. |

### Things to deliberately not do

- Critical-alert entitlement: it won't be granted.
- PushKit or VoIP, audio, or location as a keep-alive: a rejection, and it gets pushes cut off.
- Broadcast channels: they're for one-to-many fan-out.
- Bonjour / same-LAN direct: it adds a privacy prompt, and Tailscale already goes direct on a LAN.
- SwiftData/CloudKit for settings: KVS or Mac-owned preferences are enough.
- Running ML in the NSE.

---

## Sources

**Apple: User Notifications / APNs**
- [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
- [Handling notification responses from APNs](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)
- [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Modifying content in newly delivered notifications](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications)
- [Implementing communication notifications](https://developer.apple.com/documentation/usernotifications/implementing-communication-notifications)
- [UNNotificationInterruptionLevel](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel) · [.timeSensitive](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive) · [critical-alerts entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts)
- [relevanceScore](https://developer.apple.com/documentation/usernotifications/unnotificationcontent/relevancescore) · [filterCriteria](https://developer.apple.com/documentation/usernotifications/unnotificationcontent/filtercriteria) · [threadIdentifier](https://developer.apple.com/documentation/usernotifications/unnotificationcontent/threadidentifier)
- [UNTextInputNotificationAction](https://developer.apple.com/documentation/usernotifications/untextinputnotificationaction) · [authenticationRequired](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/authenticationrequired)
- [Setting up broadcast push notifications](https://developer.apple.com/documentation/usernotifications/setting-up-broadcast-push-notifications)
- [INFocusStatusCenter](https://developer.apple.com/documentation/intents/infocusstatuscenter)

**Apple: ActivityKit / WidgetKit**
- [ActivityKit](https://developer.apple.com/documentation/activitykit) · [ActivityKit updates](https://developer.apple.com/documentation/updates/activitykit) · [Activity](https://developer.apple.com/documentation/activitykit/activity) · [pushToStartTokenUpdates](https://developer.apple.com/documentation/activitykit/activity/pushtostarttokenupdates)
- [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)
- [Creating custom views for Live Activities](https://developer.apple.com/documentation/activitykit/creating-custom-views-for-live-activities) · [Launching your app from a Live Activity](https://developer.apple.com/documentation/activitykit/launching-your-app-from-a-live-activity)
- [frequentPushesEnabled](https://developer.apple.com/documentation/activitykit/activityauthorizationinfo/frequentpushesenabled) · [NSSupportsLiveActivitiesFrequentUpdates](https://developer.apple.com/documentation/bundleresources/information-property-list/nssupportsliveactivitiesfrequentupdates)
- [Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities) · [Creating accessory widgets](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications)
- [Updating widgets with WidgetKit push notifications](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications) · [WidgetPushHandler](https://developer.apple.com/documentation/widgetkit/widgetpushhandler)
- [ControlWidget](https://developer.apple.com/documentation/swiftui/controlwidget) · [Creating controls to perform actions across the system](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system) · [ControlWidgetButton](https://developer.apple.com/documentation/widgetkit/controlwidgetbutton)

**Apple: App Intents / Spotlight**
- [App Intents](https://developer.apple.com/documentation/appintents/app-intents) · [Getting started with App Intents](https://developer.apple.com/documentation/AppIntents/getting-started-with-the-app-intents-framework)
- [AppEntity](https://developer.apple.com/documentation/appintents/appentity) · [IndexedEntity](https://developer.apple.com/documentation/appintents/indexedentity) · [AppShortcutsProvider](https://developer.apple.com/documentation/appintents/appshortcutsprovider) · [LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent) · [SnippetIntent](https://developer.apple.com/documentation/appintents/snippetintent) · [IntentAuthenticationPolicy](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy) · [SetFocusFilterIntent](https://developer.apple.com/documentation/appintents/setfocusfilterintent) · [AppIntentsExtension](https://developer.apple.com/documentation/appintents/appintentsextension)
- [Core Spotlight](https://developer.apple.com/documentation/corespotlight)

**Apple: background, networking**
- [BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler) · [BGAppRefreshTask](https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask) · [BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask) · [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados) · [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- [beginBackgroundTask(withName:expirationHandler:)](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)) · [Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [NetworkConnection](https://developer.apple.com/documentation/network/networkconnection) · [NWConnection](https://developer.apple.com/documentation/network/nwconnection) · [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor) · [NetworkExtension](https://developer.apple.com/documentation/networkextension) · [NEVPNManager](https://developer.apple.com/documentation/networkextension/nevpnmanager)
- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [NSUserActivity](https://developer.apple.com/documentation/foundation/nsuseractivity) · [UIPasteboard](https://developer.apple.com/documentation/uikit/uipasteboard) · [PasteButton](https://developer.apple.com/documentation/swiftui/pastebutton) · [UIPasteControl](https://developer.apple.com/documentation/uikit/uipastecontrol)

**Apple: input, iPad**
- [UITextInput](https://developer.apple.com/documentation/uikit/uitextinput) · [UIKeyInput](https://developer.apple.com/documentation/uikit/uikeyinput) · [UITextInputTraits](https://developer.apple.com/documentation/uikit/uitextinputtraits) · [inputAccessoryView](https://developer.apple.com/documentation/uikit/uiresponder/inputaccessoryview) · [UITextInteraction](https://developer.apple.com/documentation/uikit/uitextinteraction)
- [UIPress](https://developer.apple.com/documentation/uikit/uipress) · [UIKeyCommand](https://developer.apple.com/documentation/uikit/uikeycommand) · [wantsPriorityOverSystemBehavior](https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior) · [UIMainMenuSystem](https://developer.apple.com/documentation/uikit/uimainmenusystem) · [Menus and shortcuts](https://developer.apple.com/documentation/uikit/menus-and-shortcuts) · [Adding menus and shortcuts to the menu bar](https://developer.apple.com/documentation/uikit/adding-menus-and-shortcuts-to-the-menu-bar-and-user-interface)
- [keyboardShortcut](https://developer.apple.com/documentation/swiftui/view/keyboardshortcut(_:modifiers:)) · [onKeyPress](https://developer.apple.com/documentation/swiftui/view/onkeypress(_:action:))
- [UIScribbleInteraction](https://developer.apple.com/documentation/uikit/uiscribbleinteraction) · [UIPointerInteraction](https://developer.apple.com/documentation/uikit/uipointerinteraction) · [supportsMultipleScenes](https://developer.apple.com/documentation/uikit/uiapplication/supportsmultiplescenes) · [UISceneSession](https://developer.apple.com/documentation/uikit/uiscenesession) · [UIWindowScene](https://developer.apple.com/documentation/uikit/uiwindowscene)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) · [DataScannerViewController](https://developer.apple.com/documentation/visionkit/datascannerviewcontroller)

**Apple: security**
- [Keychain services](https://developer.apple.com/documentation/security/keychain-services) · [Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) · [kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable) · [kSecAttrAccessControl](https://developer.apple.com/documentation/security/ksecattraccesscontrol) · [biometryCurrentSet](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset)
- [LAContext](https://developer.apple.com/documentation/localauthentication/lacontext) · [Logging a user into your app with Face ID or Touch ID](https://developer.apple.com/documentation/localauthentication/logging-a-user-into-your-app-with-face-id-or-touch-id)
- [DCAppAttestService](https://developer.apple.com/documentation/devicecheck/dcappattestservice) · [Establishing your app's integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
- [CryptoKit SecureEnclave](https://developer.apple.com/documentation/cryptokit/secureenclave) · [Curve25519.KeyAgreement](https://developer.apple.com/documentation/cryptokit/curve25519/keyagreement) · [HPKE](https://developer.apple.com/documentation/cryptokit/hpke)

**Apple: design, data, language**
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) · [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) · [glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) · [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer) · [.glass button style](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass) · [tabBarMinimizeBehavior](https://developer.apple.com/documentation/swiftui/view/tabbarminimizebehavior(_:))
- [NSUbiquitousKeyValueStore](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore) · [SwiftData](https://developer.apple.com/documentation/swiftdata) · [Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices) · [CloudKit](https://developer.apple.com/documentation/cloudkit) · [Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services)
- [Adopting strict concurrency in Swift 6 apps](https://developer.apple.com/documentation/swift/adoptingswift6) · [Foundation Models](https://developer.apple.com/documentation/foundationmodels)

**WWDC sessions**
- WWDC26: [iOS guide](https://developer.apple.com/wwdc26/guides/ios/) · [223 Live Activities essentials](https://developer.apple.com/videos/play/wwdc2026/223/) · [345 Discover new capabilities in App Intents](https://developer.apple.com/videos/play/wwdc2026/345/) · [240 App Schemas](https://developer.apple.com/videos/play/wwdc2026/240) · [344 Make your app available to Siri](https://developer.apple.com/videos/play/wwdc2026/344) · [295 AppIntentsTesting](https://developer.apple.com/videos/play/wwdc2026/295) · [269 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/)
- WWDC25: [250 Use structured concurrency with Network framework](https://developer.apple.com/videos/play/wwdc2025/250)
- WWDC24: [10069 Broadcast updates to your Live Activities](https://developer.apple.com/videos/play/wwdc2024/10069/)
- WWDC23: [10185 Update Live Activities with push notifications](https://developer.apple.com/videos/play/wwdc2023/10185)
- WWDC22: [10121 Meet Focus filters](https://developer.apple.com/videos/play/wwdc2022/10121)

**Third party (lower trust, labeled where used)**
- [Tailscale: Can I use Tailscale alongside other VPNs?](https://tailscale.com/kb/1105/other-vpns) · [Tailscale: VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand)
- [tailscale/libtailscale, swift/TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift)
- Apple Developer Forums thread on `BGContinuedProcessingTask` pausing on lock: <https://developer.apple.com/forums/thread/796138>

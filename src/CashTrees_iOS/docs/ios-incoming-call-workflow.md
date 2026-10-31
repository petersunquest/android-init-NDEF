# iOS Incoming Call Workflow (single-call gate)

Consumer shell: `src/CashTrees_iOS/CashTrees_iOS`. PWA stream is **not** modified here.

## Goal

At most **one** CallKit / native voice session at a time on the callee device. Extra inbound calls while ringing or connected are auto-rejected with `voice_call_reject_v1` (`reason: "busy"`). Chat still records that a call arrived (via `callRejected` → declined bubble).

## Happy path (idle → one ringing call)

```
PushKit (VoIP) / ContentView deep link
  → BeamioVoipIncomingBootstrap.reportIncomingCallKit
  → prefetch offer (AES sessionKey) in parallel
  → CallKit.reportIncoming  (fresh UUID; may endZombie only when NOT busy)
  → CallKit UI (opaque "Beamio" → verified @BeamioTag)
  → User Answer → sendAccept + native temp voice channel
     or Decline → sendDecline(reason: "declined") + CallKit end
```

## Busy path (already ringing or in-call)

```
Second (Nth) reportIncomingCallKit
  → isBusyExcluding(callId) == true
  → reportIncomingBusyReject:
       DeepLink / Alert APNs (mustReportForPushKit=false):
         **SKIP** CallKit entirely — keeps first ringing/connected banner
       PushKit (mustReportForPushKit=true):
         reportNewIncomingCall  (Apple requires a report before PushKit completion)
         CXEndCallAction on **only** that new UUID (short delay; never endZombieCalls)
         avoid .declinedElsewhere — SE build 7 showed it collapsing the first banner
  → sendDecline(callId, sessionId, reason: "busy")
  → emitToWeb("callRejected")  → PWA chat bubble (missed / declined)
  → skip tag verify / Answer chrome for the rejected UUID
```

**Build 7 regression:** DeepLink busy QA used report+`.declinedElsewhere` → after-b screenshot was Home idle (first CallKit gone). Build 8+: DeepLink busy skips CallKit; only signaling + chat leave-behind.

**Build 9:** DeepLink busy also skips `cashTreesIncomingVoiceCallPush` + delayed 0.8s/2.0s re-notify (those woke the host and jittered chrome). ContentView skips PWA `reportIncomingSystemCall` inject when busy. After busy-reject, `forceSuspendToKeepLiveCallChrome` re-backgrounds so the first ringing/connected banner returns (`chromeSuspendConsumed` alone was blocking a second suspend).

Busy is true if any of:

- an answered UUID is still mapped
- any non-ended `CXCall` (incoming or outgoing) exists for another callId
- `callIds` still maps another live (non-ended) call

Same `callId` re-delivery while that call is still alive is treated as a re-report, not busy.

## Signals

| Event | Uplink | Web bridge | Chat (PWA, unchanged) |
|---|---|---|---|
| User Decline | `voice_call_reject_v1` `reason: declined` | CallKit path may omit; user action | declined / missed |
| Auto busy | `voice_call_reject_v1` `reason: busy` | **must** `emitToWeb(callRejected)` | same declined path (no SilentPassUI busy copy) |
| Answer | `voice_call_accept_v1` | native accept bridge | connected |

Dialer: any inbound `voice_call_reject_v1` → `endVoiceCall('declined')` (busy looks like declined on dialer).

## Why multi-account dials jittered

`maximumCallsPerCallGroup = 1` alone does not stop multiple `reportNewIncomingCall`s. Old code called `endZombieCalls(except:)` before each new report, which **ended the first ringing call** when a second PushKit arrived → CallKit chrome thrash / screen shake. Fix: busy gate → busy-reject path without `endZombieCalls`.

**Also required:** `maximumCallGroups = 2`. With only one call group, a busy-path `reportNewIncomingCall` (needed for PushKit) **displaces** the live ringing banner — SpringBoard goes idle after the second account dials, then the third dial shows as a fresh first call. The spare group lets busy-reject flash-report + `declinedElsewhere` without touching the live group.

## Key files

| File | Role |
|---|---|
| `BeamioVoipIncomingBootstrap.swift` | `reportIncomingCallKit`, busy gate, `emitToWeb` |
| `BeamioCallKitManager` (same module) | `isBusyExcluding`, `reportIncoming`, `reportIncomingBusyReject` |
| `BeamioNativeVoiceSignaling.swift` | `sendDecline(..., reason:)`, Accept / offer cache |

## Device QA (no real multi-account dial required)

```text
beamio://debug-incoming?callId=busy-a&claimedTag=@rr01
# while ringing:
beamio://debug-incoming?callId=busy-b&claimedTag=@rr02
```

Expect: first CallKit stays; second hits busy gate (`busy-reject` / `busy auto-reject`); no screen thrash. Second `debug-incoming` **must not** `recreateProvider` when busy (see `BeamioDeepLink.handleDebugIncomingIfPresent`).

Real multi-account PushKit dials exercise the same gate (production path never recreates the provider per offer).

## Out of scope (do not change without product OK)

- SilentPassUI `replacesLiveCall` / `detachLocalVoiceCall` (PWA may still tear local media if a second offer is delivered to Web; shell busy gate is the CallKit fix)
- Dedicated “Busy” chat copy (reuse declined / missed)

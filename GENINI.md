# GEMINI.md — Handoff, Binary-Verified Review & CPU Plan

> **Purpose**: Lets Gemini pick up where the previous session left off. Read `CLAUDE.md` first
> for the full dossier (FNF/DASH internals, prior autopsies, user-request history). **This file
> supersedes the earlier source-only review** — several of those findings were overturned once the
> real `FBSharedFramework` binary was analyzed. Where this file and `CLAUDE.md` disagree, trust the
> **binary-verified** facts here and treat `CLAUDE.md §4C` ("current state") as aspirational, not actual.

- **Last updated**: 2026-11-27 (binary-verification + CPU-plan pass)
- **Git branch**: `1440p-stable-19thnov` (main/PR branch is `dev`)
- **Primary files**: `InstagramDash1440p.mm` (1,678 lines), `InstagramDash1440p.h` — read in full.
- **USER'S CURRENT GOAL (the only one that matters right now)**: *the tweak uses too much CPU.*
  They want 1440p / highest-bitrate-1080p enforced **so Instagram's own network requests are that by
  default**, instead of the tweak doing heavy work to convert after the fact. Outcome must stay
  **exactly** as today; only CPU should drop. See §6 for the verdict + plan.

---

## 0. Must-honor constraints (from `CLAUDE.md`)

1. **No touch commands** unless the user explicitly says so: never run `git`, `npm run build`, `npx tsc`, `npx eslint`.
2. **Zero `.py` files in the repo.** Scratch scripts live only in the external scratchpad dir.
3. **ARC pointer safety**: never deref ivars with `->` on weak / `typeof(weakSelf)` pointers; promote to `__strong` first.
4. **Slow & accurate**: cheapest-correct fix first; cite exact class/method/offset; no hallucinated APIs.
5. **UI**: every secondary view needs entry affordance + live interaction + an exit control.

---

## 1. Verification posture (what is now PROVEN vs still INFERRED)

The binary **is** available and **was** analyzed this session:
- **Target binary**: `C:\devroot\ig\IGFormatV2.6.0\Payload\Instagram.app\Frameworks\FBSharedFramework.framework\FBSharedFramework`
  — Mach-O arm64, **49,867,088 bytes** (matches `CLAUDE.md`'s "49.8 MB"). This is the version the tweak was built against. **Analyze only this one.**
- An installed **V2.8.0** copy exists (51,736,320 bytes) but the user said to ignore it. Note for context: its
  selector/class tables are **identical** to V2.6.0 for everything checked — so the mismatches below are **not
  upgrade drift; they were wrong against the tweak's own target binary.**
- **Method (reproducible, no installs)**: a pure-Python `struct` Mach-O section reader parses `__TEXT,__objc_methname`
  (the authoritative selector pool) and the string sections, then tests **exact NUL-delimited token membership**
  (not substring). Validated: parsing V2.8.0 directly reproduced its pre-extracted per-section dump exactly.
- **Still static, not a device run.** "Selector absent from `__objc_methname` ⇒ `SafeSwizzleMethod` no-ops" is a
  firm inference from how `class_getInstanceMethod` works, not a runtime observation.

**Two questions remain UNVERIFIED** (need per-class method-list dump or `capstone` disasm; **not required for the CPU goal**):
1. Does `_selectQualityFromRepresentations:sequenceIndices:withAvailableBandwidth:` return a raw rep or an `FNFDashQualitySelection`?
2. Does `allRepresentationsForTrack:` internally message-send `representationsForTrack:` (the recursion risk)?

---

## 2. BINARY-VERIFIED FACTS (V2.6.0) — the important part

### 2a. The "selectQuality zero-CPU bypass" NEVER BINDS
- Bare selector **`selectQuality` is absent** from `__objc_methname`.
- **2 of the 5 target classes don't exist**: `FNFDashQualitySelector` **MISS**, `FNFDashLiveQualitySelector` **MISS**.
  (Present: `FNFDashABRQualitySelector`, `FNFDashDefaultQualitySelector`, `FNFDashPrefetchQualitySelector`.)
- ⇒ All five `selectQuality` swizzles (`.mm` ~line 1576) **no-op**. Therefore `HandleQualitySelection`,
  `GetOrPopulatePlaylistCache`'s selector fast-path, and the dead `WrapOrUpdateSelectionMetadata` helper
  **effectively never run on-device.** The "15-20% CPU saved by bypassing ABR" claim in `CLAUDE.md §4C` is **fiction** —
  that path isn't wired to anything.

### 2b. The ONE real selection hook that binds
- `_selectQualityFromRepresentations:sequenceIndices:withAvailableBandwidth:` **exists** and is hooked by
  `Hook_ABR_SelectQualitySeqIndices` (on `FNFDashABRQualitySelector`). Sibling variants the tweak does **not** hook:
  `…:fetchSizesInBytes:sequenceIndexes:` and `…:withAvailableBandwidth:`.
- **This hook calls `SelectTargetRepresentation()` fresh & UNCACHED on every call** (`.mm` ~line 1113), unlike the
  playlist getters (which are cache-backed via `GetOrPopulatePlaylistCache`). ABR re-evaluates during playback ⇒
  **this is the most likely real per-playback CPU cost.**

### 2c. Half the detection signals are INERT (MISS on the rep in V2.6.0)
- **MISS**: `videoSize`, `qualityLabel`, `FBQualityLabel`, `encodingTag`, `track`, `selectedRepresentation`, `videoSize`.
- **OK**: `videoWidth`, `videoHeight`, `width`, `bandwidth`, `bitrate`, `representationId`, `isAudio`, `codec`, `currentRepresentationId`.
- ⇒ `GetRepresentationQualityLabel`, `GetRepresentationEncodingTag`, the `-track` audio check, and selection-unwrapping
  **never fire**. Real detection runs on **dimensions (via `videoWidth`/`videoHeight`) + `representationId` substring +
  the bitrate heuristic** only. The rep class is **not** `FNFDashRepresentation` (MISS); the real ones are
  `FNFDashSegmentedRepresentation` / `FNFDashFragmentedRepresentation` / `FNFDashLiveRepresentation` (duck-typing saves it).

### 2d. The VP9 struct byte-poke is SAFE on V2.6.0 (old finding #5 downgraded)
- Recovered layout: `{FNFDecompressionConfig=BBIIIIBIIIdBBBBBBBBBIBBBBBBBBBBBBBiiBBBBBBIIIBBBiBBBBB}`.
- All seven pokes (`0x33,0x34,0x35,0x38,0x58,0x59,0x74`) land on **in-bounds 1-byte `B`(bool) fields** — not padding,
  not straddling multibyte fields, not OOB. ⇒ **Not memory corruption on this build.** *Which* bool each is
  (the `enableVTForVP9` labels) is still unverified — could be wrong/no-op flags, but safely so.

### 2e. Other bindings
- **Bind (exist)**: playlist getters (`representationsForTrack:`, `allRepresentationsForTrack:`, `_representationsForVideoTrack`,
  `defaultRepresentationForTrack:`, `setDefaultRepresentation:track:`), both `initWithConfig:…`, `_shouldAvoidOnABR:isIntentional:`,
  `pruneQualities:`, all 3 MPD-XML parse methods, `FNFDecompressionSessionForVP9X` init + `usesSoftwareDecoder`,
  `IGFNFVideoPlayer` telemetry trio, `IGFNFSelectedQualityProvider` setter + `videoQualitySelected:…`,
  `initWithSelectedRepresentation:trackType:` (so the wrapper class API is real).
- **No-op (MISS)**: `videoSelectedQualityRepresentation` getter swizzle; `videoView` (telemetry on-screen check degrades to
  isPlaying-only); `playlist` accessor (only mattered to the dead selectQuality path).

---

## 3. Net picture: what the tweak ACTUALLY does on V2.6.0

Not dead — but not what `CLAUDE.md` describes. Effective enforcement = **playlist pinning
(`defaultRepresentationForTrack:`/`setDefaultRepresentation:`/getters) + the ABR `_selectQualityFromRepresentations:…`
hook + MPD-XML pruning + VP9 decode forcing**. The advertised `selectQuality` CPU-bypass and ~half the quality
detectors are inert. So the user's "enforce by default" instinct is **already the de-facto design**; there is no
post-hoc converter to remove.

---

## 4. Mistakes & risks — RE-RANKED after verification

- **(was #1) selectQuality raw-rep crash → MOOT.** Those hooks never bind, so they can't crash *or* help. **But the
  same raw-rep-return concern RELOCATES to `Hook_ABR_SelectQualitySeqIndices`**, which *does* bind and returns a raw
  rep. If that method's contract wants an `FNFDashQualitySelection`, this is the live correctness risk. **UNVERIFIED** (see §1).
- **#2 Recursion (hooks both `representationsForTrack:` + `allRepresentationsForTrack:`)** — both exist and are hooked.
  Mitigated by calling saved original IMPs directly, but call-direction is **UNVERIFIED**. Still the top *structural* risk.
- **#4 → ELEVATED: bitrate-only 1440p heuristic** (`bw≥5.5Mbps && codec~vp9`, `.mm` line 344) now **load-bearing**,
  because the `qualityLabel`/`encodingTag` detectors are inert (§2c). High-bitrate 1080p VP9 ⇒ mislabeled 1440p in the
  badge and pooled as 1440p in selection. Tighten to require a dimension signal.
- **#6 `g_repMetadataCache` unbounded** (never evicted, `.mm` 374–408) — slow leak over long sessions. Cap/LRU.
- **#7 Latent self-deadlock**: `CacheRepresentationMetadata` holds `g_cacheMutex` across foreign `objc_msgSend`
  (getters, `.mm` 386–395). Non-recursive mutex ⇒ re-entry deadlocks. Compute metadata **before** locking.
- **#8 Minor**: `ExtractRepresentationFromObject` recursion guard is only `inner != obj` (A→B→A loops to stack
  exhaustion); Mode 2 "1080p cap" falls back to `rep1440p` for 1440p-only reels (`.mm` 640) so it isn't a hard cap.
- **Dead config (cleanup, NO CPU benefit)**: 5 `selectQuality` hooks, 2 missing classes, the `videoSelectedQualityRepresentation`
  getter hook, and `WrapOrUpdateSelectionMetadata`. Removing them stops `CLAUDE.md §4C` lying; it does **not** save CPU.

---

## 5. Where the CPU actually goes (verified reasoning)

1. **ABR hook re-scan (§2b)** — `Hook_ABR_SelectQualitySeqIndices` → uncached `SelectTargetRepresentation` every ABR tick. **Primary suspect.**
2. **`PruneManifestXml`** — full nested-regex pass + string rebuilds, once per manifest. Redundant with object-layer pinning for "chunk 0 = 1440p"; also the fragile autopsy-#3 path.
3. **Per-rep string allocs** in `SelectTargetRepresentation`/`IsRepresentation*` — `lowercaseString`/`containsString`/`-description` for signals that mostly don't exist (§2c).

---

## 6. CPU PLAN — top 3 (outcome must stay identical), ordered by outcome-preservation certainty

**Approach verdict**: the user is **correct** (enforce-at-source is the low-CPU design, and the code already pins
`defaultRepresentationForTrack:`). Their misconception — that the tweak burns CPU "converting 1080p→1440p after the
fact" — is wrong: that converter (selectQuality bypass) doesn't run. The win is to stop *repeating* the selection work
and remove the *redundant* layer, not to add a new "enforce by default" layer.

1. **Memoize the ABR hook (zero outcome risk, biggest win).** Cache the chosen rep keyed on the representations array
   (associated object on the array, or a small `NSMapTable`) and return O(1) on repeat calls. Same rep, computed once.
   *Caveat*: it returns a raw rep today — confirm the return-type contract (§1 Q1) so memoizing doesn't freeze a wrong type.
2. **Dimensions-first, lazy string fallbacks (zero outcome risk).** Reorder `IsRepresentation1440p/1080p` +
   `SelectTargetRepresentation` to decide on integer `videoWidth`/`videoHeight` compares first; build lowercased
   strings / call `-description` only when dimensions are 0. Same selection, far fewer allocations.
3. **Collapse to one source-level layer (small, verifiable risk — biggest structural win).** Drop `PruneManifestXml`;
   rely on object-layer `defaultRepresentationForTrack:` pinning (already achieves "app natively requests 1440p").
   Removes a per-manifest regex + the fragile path. **Verify on-device that 1440p is still forced before keeping this.**

**Execution order**: (0) **Measure first** — Instruments Time Profiler while scrolling Reels; confirm whether the hot
frame is `SelectTargetRepresentation` under the ABR hook (→ #1) or `PruneManifestXml` (→ #3). Don't optimize blind.
(1) Apply #1. (2) Apply #2. (3) Apply #3 only if the profiler justifies it and device testing confirms outcome. (4)
Optionally delete the dead hooks (§4) — cleanup only.

---

## 8. Stable rewrite + re-added CPU instrumentation (2026-11-27, updated)

The user replaced `InstagramDash1440p.mm` with a "more stable" version (~1,399 lines). Notable structural changes vs. the version this dossier first reviewed:
- **XML manifest pruning REMOVED** — `PruneManifestXml` / `PruneManifestXmlOrData` and the `FNFMediaPresentationDescription` parse hooks are gone. This retires old finding **#3 / autopsy #3**. (The only remaining "prune" is `Hook_PruneQualitiesNoOp` on `FNFDashPlayerSizePruner`, a pass-through no-op.)
- **`HandleQualitySelection` now calls `origImp` first, then returns `WrapOrUpdateSelectionMetadata(chosen, targetRep)`** — i.e. it returns the real selection wrapper with its rep swapped, not a raw rep. Addresses old **#1** *for the `selectQuality` path* (which, per §2a, doesn't bind on V2.6.0/V2.8.0 anyway).
- **STILL OPEN**: `Hook_ABR_SelectQualitySeqIndices` (the selection hook that *does* bind) still `return chosen;` a **raw rep** (line ~930), not wrapped. So the relocated-#1 return-type concern remains live on the one path that matters. Return-type still unverified (metadata parse, no capstone).

### Temporary CPU instrumentation (re-added to the stable file)
Measurement scaffolding to get numbers **without a Mac/Instruments**. **Do NOT ship; remove before release.**
- **What's added**: a `[PROF]` block near the top (atomic counters + `ProfTicks`/`ProfFlushIfDue`);
  `SelectTargetRepresentation` split into a timed wrapper + `SelectTargetRepresentation_impl` (one wrapper
  now covers **all 9 call sites** — quality selectors, ABR, the 3 playlist getters, default-rep,
  set-default, quality provider); `[PROF]` counters in the `usesSoftwareDecoder` and
  `VTDecompressionSessionCreate` hooks. **Prune timing was dropped** (no XML path to measure anymore).
- **Where it logs**: one cumulative line (≤ once/2s) appended to `Documents/Instagram1440p.log`. Read the **last** line.
- **How to read** `[PROF] select=… swDecoder(real) yes/no VTcreate=… firstErr=…`:
  - `select` **calls ≫ reels watched** and total ms high → selection is the cost → **Plan #1** (memoize the ABR hook / cache per rep-array).
  - `swDecoder(real) yes ≫ no`, or `firstErr` high → **software VP9 decode** (A18 Pro likely has no VP9 HW block);
    **no selection fix helps** — codec/HW problem (forcing H.264/HEVC caps quality) or accept the cost.
- **On-screen readout (no file pull needed)**: `InstagramDash1440p_GetProfSummary()` (declared in `.h`,
  defined in `.mm`) returns the live summary; `InstagramPerfHUDPill` in `InstagramReverbUI.m` shows it as a
  **3rd tap-mode** (tap the CPU/GPU/Net badge: full → compact → `[PROF]`), refreshing every 2s.
- **Removal**: delete the `[PROF]` block; rename `SelectTargetRepresentation_impl` back and drop its wrapper;
  delete the three `// [PROF]` counter lines; delete `InstagramDash1440p_GetProfSummary` (`.h` decl + `.mm` def)
  and revert the 3 `InstagramReverbUI.m` edits (`displayMode` cycle back to `% 2`, drop the `mode == 2` branch
  and the `lineBreakMode` line). In-code comments mark each spot.
- **Build status**: code-reviewed + static-consistency-checked only; **not compiled** (no iOS SDK on the
  Windows dev box). Uses C++ `std::atomic` (`<atomic>`), not `<stdatomic.h>` (file is ObjC++ `.mm`).

## 9. IMPLEMENTED: Plan #1 — selection memoization restored (2026-11-27)

Measured cause (via the `[PROF]` HUD): `SelectTargetRepresentation` ran **~219k times / ~10.5s CPU**
in one scroll; decode exonerated (`swDec 0/0`, `VT=39 err=0`). Root cause: the stable rewrite dropped
the per-playlist memoization, so every hooked getter + ABR tick re-scanned uncached.

**Fix applied to `InstagramDash1440p.mm` (Plan #1 only, user-approved):**
- New `InstagramDashPlaylistCacheEntry` + `PlaylistCacheFor(owner, origReps, isPrefetch)` — memoizes the
  chosen rep on the playlist (or rep-array) via an associated object, keyed by mode. One scan per
  `(owner, mode)`; thread-safe; freed with the owner (no global unbounded cache).
- Rewired the 6 binding hooks to use it: `representationsForTrack:`, `allRepresentationsForTrack:`,
  `_representationsForVideoTrack`, `defaultRepresentationForTrack:`, `setDefaultRepresentation:track:`,
  and `_selectQualityFromRepresentations:sequenceIndices:…` (ABR — prefers the `_playlist` ivar, falls
  back to array-keying).
- Left un-memoized **intentionally**: `HandleQualitySelection` (selectQuality) and the
  `videoSelectedQualityRepresentation` provider hook — both are non-binding on V2.6.0/V2.8.0, so they
  never fire. `isPrefetch` is unused by the selector, so cache-sharing across it is outcome-safe.
- **Built on CI + VERIFIED on device** (2026-11-27): compiled cleanly via `build.sh`, sideloaded, and
  the `[PROF]` readout confirmed `select` fell 219,466 → ~170. Plan #1 works.

**Verify:** push → CI build → sideload → scroll 2 min → HUD `[PROF]`: `select` calls should fall from
~219k to **tens**, total ms to near-zero; `swDec`/`VT` unchanged; 1440p reels still read "1440p".
Then remove the profiling (§8 removal steps).

## 10c. Battery focus — harmless vs. big (2026-11-27, latest)

User pivoted hard to **battery** and **deprioritized cache** ("leave it, cache is not important"). A
cache size-cap edit was started in `InstagramReverbUI.m` then **fully reverted** (it added a 30-min
background cache-walking timer that works against the battery goal). Codebase = verified CPU fix +
battery logging only.

**Honest framing given to user:** no *harmless* change saves "a lot" — the big battery costs (1440p
decode, screen, radio) are intrinsic to the agenda. Harmless = the tweak's own overhead = modest.

- **Harmless (zero risk), modest:** (1) pause/slow the HUD perf-pill polling — it samples
  CPU+GPU(IOKit)+net every 2s while visible; pause when dimmed/hidden or slow 2s→5s. (2) remove temp
  `[PROF]`/battery logging after measuring. (3) disable perf-pill polling entirely if the badge isn't used.
- **Big but NOT harmless (gate on the 2-day battery log):** stop forcing 1440p on prefetched/skipped
  reels (saves radio+decode, keeps watched-reel 1440p, but tricky + quality-ramp risk); drop VT
  `RealTime=true` (power-hungry pacing, medium smoothness risk).
- **Next:** offered to implement harmless #1 (pause-when-dimmed + 2s→5s) on request; otherwise wait for
  battery-log data before the big-but-risky prefetch change.

**"Badges" toggle button ADDED (2026-11-27):** `InstagramReverbHUDView` action row is now 3-up (thirds):
Reset / Clean Cache / **Badges**. New `-[InstagramReverbHUDManager toggleBadges]` (.h-declared) hides both
pills (dashPill + perfPill) and **stops the perf-pill's 2s polling when hidden → this is harmless battery
win #1, now user-controlled**. State persists via `NSUserDefaults "InstagramReverb_badgesHidden"` and is
re-applied when the pills are created. Static-checked, **not yet compiled** (ships next CI push). Files:
`InstagramReverbUI.m` (property/create/layout/handler/toggleBadges/apply-on-create) + `InstagramReverbUI.h` (decl).
Follow-up: titles shortened to **Reset / Clean / Badges**; HUD panel compacted **180×164 → 165×160**
(`showHUD`, lines ~1832-33) to remove the ~6.5pt dead gap below the button row (content ends y≈157.5).

## 10b. Battery/cooling track + candidate optimizations (added 2026-11-27)

**1080p question (answered):** In **Mode 0 (Max Resolution)**, a reel that *has* a 1440p rendition always
gets 1440p, never 1080p (`chosen = rep1440p ?: rep1080p ?: …`, now locked by the memoization). Exceptions:
(a) a true-1440p rep not *detected* as 1440p (dimensions 0 **and** no "1440" in repId), (b) **Mode 1**
caps at 1080p by design, (c) the reel genuinely has no 1440p rendition.

**Battery/thermal logging — ADDED (temporary, remove after the 2-day field track):**
- New self-contained block in `InstagramDash1440p.mm` (`BatteryLogPath`/`ThermalStateName`/
  `BatteryLogSample`/`StartBatteryTracking`), called from `InstagramDash1440p_Init`.
- Writes `Documents/InstagramBattery.log` on each `NSProcessInfoThermalStateDidChange` + a 5-min heartbeat:
  `… thermal=nominal battery=78% state=unplugged lowPower=NO mode=0 [heartbeat]`.
- Read over 2 days: `thermal=serious/critical` during reel-watching = device cooking; `battery=` drop rate
  = drain; `mode=` correlates quality mode with heat. No dependency on `[PROF]`.
- **Build status:** static-checked only; **not yet compiled** (new this turn). It ships with the next CI
  push alongside the already-verified CPU fix. APIs used are iOS 11+/14+ (target is 14+).

**Battery optimization plan (DATA-GATED by the log above — not yet implemented):**
1. **Throttle HUD polling (SAFE, do first):** `InstagramPerfHUDPill` polls CPU+GPU(IOKit)+net every 2s
   while visible; the GPU IOKit query is heaviest. → 5s + pause when dimmed. Zero agenda/FNF risk.
2. **Reconsider VT `RealTime=true` (medium):** keep `EnableHardwareAcceleratedVideoDecoder` (saves power);
   drop/scope `RealTime` (disables power-efficient pacing; pointless for pre-recorded reels). No res change.
3. **Don't force 1440p on prefetched/skipped reels (biggest lever, hardest):** wasted radio+decode for
   reels scrolled past, BUT architecturally tricky (hooks are per-playlist, no clean active-vs-prefetch
   signal) and must not break the watched-reel 1440p guarantee. Validate the waste in the log first.

## 10. Handoff brain — status, future plans, and how to reason here

### A. You-are-here (2026-11-27) — PLAN #1 VERIFIED ON DEVICE ✅
- **Plan #1 (selection memoization) built on CI, sideloaded, and CONFIRMED WORKING on device.**
- **Result: `select` dropped from 219,466 → ~165–173 (~99.9% fewer scans).** The user had been
  fighting this CPU issue for a long time; the restored memoization resolved the measured cost.
- `[PROF]` instrumentation + HUD readout are **still in** (that's how the result was read). Remaining
  steps before closing out:
  1. Confirm the `select` **ms** also dropped (baseline 10505ms → expected tens of ms). [awaiting figure]
  2. Confirm a 1440p reel still reads "1440p" on the dash pill (outcome preserved).
  3. Pill `CPU%` is noisy/hard to read — use the `select` ms as the clean CPU proxy; phone running
     cooler over a few minutes is the real-world confirmation.
  4. Once confirmed, **remove the profiling** (§8 removal steps) and commit the clean version.
- Baseline (pre-fix, on device): `select=219466 / ~10505ms`, `swDec 0/0`, `VT=39 err=0`.

### B. Decision tree for the pending test (what each outcome means + next move)
1. **`select` → tens, pill `CPU%` visibly lower, 1440p still reads "1440p"** → **SUCCESS.** Strip the
   profiling (§8), commit, done.
2. **`select` → tens BUT `CPU%` unchanged** → selection was *not* the dominant CPU cost (the 10.5s
   wasn't a big share of total). Memoization is still correct — keep it — but the agenda isn't met.
   Instrument and measure the *next* candidate (do NOT guess): FNF's own `orig` getter cost, the
   decode/render path, `UpdateActivePlaybackTelemetryFromPlayer`, or something outside this file.
3. **`select` still ~100k+** → cache isn't hitting. Add a hit/miss counter; check whether `self`
   (the `FNFDashPlaylist`) is a stable instance across getter calls, and whether the ABR hook finds
   the `_playlist` ivar vs. falling back to array-keying on fresh-per-tick arrays.
4. **Crash** → revert Plan #1 and bisect. Likely culprits: `object_getIvar(self,"_playlist")` in the
   ABR hook (guarded by `respondsToSelector:`, but verify), or mode-switch invalidation. Disable the
   ABR-hook change first.
5. **1440p reels now show lower quality** → outcome regressed → revert. Check the cached single-element
   array vs. where FNF expects the full ladder, and that mode-change invalidation recomputed.

### C. Parked optimization ideas — DATA-GATED, do NOT apply speculatively
Only if a *measured* second hot path appears. None are justified by current data:
- **Skip the `orig` getter call on a cache hit** — saves FNF's getter cost, but risky (changes FNF's
  expected call pattern; the getter may have side effects). Needs isolation + a test.
- **Hoist/remove the `InstagramDash1440p_GetMode()` mutex per call** — negligible (~0.02% CPU) and
  touches concurrency; not worth it.
- **If `swDec` ever shows `yes ≫ no`** → software VP9 decode → a codec/HW problem, not a selection fix.
  Options: force H.264/HEVC (caps quality — conflicts with the 1440p agenda) or accept the cost.
- **Plan #2 (lazy `description`)** — now near-worthless: after memoization the selector runs ~once per
  playlist, so the `[rep description]` calls are cold. The user correctly declined it.

### D. Reasoning methodology (the part that makes you smarter — adopt it)
1. **Measure before optimizing.** This whole session's value came from `[PROF]` turning "I think it's
   XML" into "it's 219k selection scans." Never optimize an unmeasured path — the user bans guesswork.
2. **Label FACT / INFERENCE / UNKNOWN.** Source/binary-verified = fact; reasoned-but-unobserved =
   inference (say so); needs-measurement = unknown (don't fill it with a guess). He asks "how confident
   %?" and "is this guesswork?" — answer calibrated, per-claim.
3. **Binary-verify against the real `FBSharedFramework` (V2.6.0).** A pure-Python Mach-O parser (no Mac,
   no capstone) reads `__TEXT,__objc_methname` + string sections and tests exact NUL-token membership —
   that's how we proved `selectQuality` never binds and half the detectors are inert. Use it before
   trusting any hook.
4. **Variable isolation.** One change per build; never stack speculative work onto an unverified change.
   This repo's crash history (`CLAUDE.md §5` autopsies) is stacked changes.
5. **Trust the binary over the docs.** `CLAUDE.md §4C` is aspirational and does not match the code; this
   file holds the verified reality and supersedes it on conflict.

### E. User working style (calibrate to this)
- Accuracy over speed; wants the extra verification step; dislikes guesswork and confident hedges.
- Wants to **verify claims himself** — give trust-free protocols with explicit pass/fail + falsification
  criteria, not "trust me."
- No Mac/Xcode. Builds via **GitHub Actions CI** (`build.sh` on a macOS runner → `latest` release),
  sideloads via LiveContainer/TrollStore, reads results from the HUD or the container log
  (`Documents/Instagram1440p.log`).
- Pushes back hard on over-confidence or manipulation — respond with calibration, not reassurance.
- **Build gap to remember:** `Makefile` omits `InstagramDash1440p.mm`; only `build.sh` (CI) includes it.

### F. Reusable assets created this session
- `[PROF]` instrumentation + `InstagramDash1440p_GetProfSummary()` + HUD tap-mode 2 (live readout, no
  file pull). The measurement protocol (force-quit reset → scroll → compare `select` + `CPU%`).
- The Python Mach-O existence-checker method (§1). Keep this `GEMINI.md` current — it is the living
  source of truth for this work.

## 7. Bottom line

Static analysis against the real **V2.6.0** binary shows the tweak's advertised CPU optimization and ~half its
detectors were **non-functional from day one** (not drift). It still forces quality via playlist pinning + the ABR
method + XML pruning. The user's low-CPU approach is sound and mostly already implemented; the concrete wins are
**memoizing the one bound hot-path hook** and **removing the redundant XML layer** — same visual outcome, less work.
Two correctness questions (ABR return-type, recursion direction) remain unverified and need a method-list/disasm pass,
but neither blocks the CPU goal. No code changed this session.

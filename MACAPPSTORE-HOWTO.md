# Publishing xTranscript on the Mac App Store

A practical, end-to-end recipe for shipping xTranscript v1.0.0 (with
the `$9.99/yr` Pro subscription) on the Mac App Store. Written for
**Eric Nicolas** as the project owner — paths and IDs are the real
ones used by this codebase.

The whole thing is roughly four hours of work the first time; subsequent
updates are ~30 minutes.

---

## What you're working with

| | |
|-|-|
| Bundle ID | `net.eric-nicolas.xtranscript` |
| App name | xTranscript |
| Version | 1.0.0 |
| Subscription Product ID | `net.eric-nicolas.xtranscript.pro.yearly` |
| Subscription Price | Tier 9 ($9.99 USD/yr) |
| Privacy Policy URL | `https://github.com/enicolas72/transcript/blob/main/docs/privacy.md` |
| Support URL | `https://github.com/enicolas72/transcript/issues` |
| EULA | Apple standard (`https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`) |
| GitHub repo | `https://github.com/enicolas72/transcript` |

---

## Section 1 — Apple Developer Program (one-time)

### 1.1 Enrol

1. Go to [developer.apple.com/programs](https://developer.apple.com/programs/).
2. Sign in with your personal Apple ID (the same one you use on your
   Mac is fine).
3. Click **Enroll**. Pay **$99 USD/year**. Approval is usually
   instant for individuals; up to 24 hours occasionally.
4. Use **Individual** enrolment unless you have a registered company
   with a D-U-N-S number — Individual is faster and the developer
   name on the App Store will be `Eric Nicolas`.

### 1.2 Accept the Paid Apps agreement

You won't be able to ship a paid product (or a subscription) until
this is signed.

1. App Store Connect → **Agreements, Tax, and Banking**.
2. Sign the **Paid Apps Agreement**.
3. Fill in:
   - **Banking** — IBAN + SWIFT for your French bank account.
   - **Tax forms** — French resident → fill the W-8BEN form to claim
     the France/US tax treaty rate (otherwise Apple withholds 30 %
     US tax on your earnings).

This usually takes a few business days for Apple to validate.
**Do this first** — without it, paid apps and subscriptions can't be
submitted, period.

---

## Section 2 — Apple Developer Portal: register the App ID

This is a one-line string reservation in Apple's system.

1. [developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers).
2. Click **+** → **App IDs** → **App** → **Continue**.
3. Pick **Explicit** (not Wildcard).
4. Description: `xTranscript`.
5. Bundle ID: `net.eric-nicolas.xtranscript` — type exactly this.
6. Capabilities: **App Sandbox** is implicit from your entitlements
   file, no extra checkbox needed. Leave the rest alone.
7. **Register**.

You only do this once. Subsequent updates use the same App ID.

---

## Section 3 — App Store Connect: create the app record

1. [appstoreconnect.apple.com](https://appstoreconnect.apple.com).
2. **My Apps → +** → **New App**.
3. Fill the form:
   - **Platforms**: macOS (only).
   - **Name**: `xTranscript` — must be globally unique on the App
     Store. If it's taken, try `xTranscript - Audio Transcription`
     (Apple allows differentiator suffixes).
   - **Primary language**: English (U.S.).
   - **Bundle ID**: pick `net.eric-nicolas.xtranscript - xTranscript`
     from the dropdown (it appears after Section 2).
   - **SKU**: `net.eric-nicolas.xtranscript` — internal only,
     reuse the bundle ID, never visible to users.
   - **User Access**: Full Access.
4. Click **Create**.

You're now on the app's main page. The left sidebar has tabs for
**App Information**, **Pricing and Availability**, **App Privacy**,
**Subscriptions**, **macOS App** (the version you're submitting),
etc.

---

## Section 4 — App Information

### 4.1 General

- **Subtitle** (30 chars): "On-device audio transcription"
- **Category**: Productivity (primary). Utilities (secondary, optional).
- **Content Rights**: tick "No, it does not contain, show, or access
  third-party content" (the audio the user provides is theirs; we
  don't host or curate any catalogue).

### 4.2 Localizable Information (English U.S.)

These show up on the App Store listing.

- **Privacy Policy URL**:
  `https://github.com/enicolas72/transcript/blob/main/docs/privacy.md`
- **License Agreement URL**: leave empty — this falls back to the
  Apple standard EULA (link reproduced under §10).

### 4.3 General Information

- **Bundle ID**: already set; locked.
- **Apple ID**: auto-assigned numeric, copy to your notes (you'll
  use it later if you ever script anything against the App Store
  Connect API).

---

## Section 5 — App Privacy (the questionnaire)

Apple makes you tick boxes describing what data you collect. Be
truthful — they sometimes audit submissions.

1. Click **Get Started** under **App Privacy** if it's the first
   time, or **Edit** if there's already an entry.

2. **"Does this app collect data?"** → **Yes** (we send audio to xAI,
   which is "data collection" under Apple's definition).

3. Add data types:
   - **Audio Data** — Other Audio Data
     - Linked to user? **No**
     - Used to track? **No**
     - Purposes: **App Functionality**

4. **Identifiers**:
   - **Purchases** (auto-renewable subscriptions) — Apple handles
     this for you; you don't need to declare it manually since it's
     done via StoreKit which Apple already discloses on their side.
     If the questionnaire asks specifically about purchase history,
     answer **Yes → Linked to user → App Functionality**.

Save. The questionnaire output should match your `Transcript/PrivacyInfo.xcprivacy`
manifest — they're separate but Apple cross-checks.

---

## Section 6 — Set up the subscription product

This is the biggest single step. Get it right and IAP works
everywhere; get it wrong and the upgrade button is dead.

### 6.1 Create the subscription group

1. Sidebar → **Subscriptions**.
2. Click **+** under "Subscription Groups".
3. **Reference name**: `xTranscript Pro` (internal).
4. Save.

A subscription group lets you offer multiple tiers users can switch
between. We only have one subscription, but Apple still requires the
group container.

### 6.2 Create the auto-renewable subscription

1. Inside the group, **+** under "Subscriptions".
2. **Reference name**: `xTranscript Pro Yearly`.
3. **Product ID**: `net.eric-nicolas.xtranscript.pro.yearly`
   — must match the constant in
   `Transcript/SubscriptionManager.swift:19` exactly. Can never be
   changed after creation; if you mistype it, you'll have to create
   a new product.
4. Save.

### 6.3 Configure the subscription

You're now on the subscription's detail page.

**Subscription Duration**: 1 Year.

**Subscription Prices**:
- Click **+** → choose your primary territory (United States).
- **Price Tier**: Tier 9 ($9.99 USD).
- Click **Next** to see the auto-converted prices for every other
  territory in the world. Apple does the FX work; you don't have to
  set 175 individual prices.
- Apply.

**Localizations** (per language; English minimum, French strongly
suggested for you):

- **Subscription Display Name**: `xTranscript Pro`
- **Description** (255 chars):
  > "Unlimited audio length per file. Decoded entirely on-device with
  > the app's embedded FFmpeg. Sent to xAI for transcription using
  > your own xAI API key. Cancel anytime."

**Family Sharing**:
- Tick **Enabled**. Costs you nothing and is a small marketing win.

**App Store Promotion**:
- Skip. Optional. Used only if you want subscription banners inside
  the App Store app itself.

**Review Information**:
- **Screenshot**: Apple wants to see the upgrade UI in your app.
  Take a 1280×800 screenshot of the `UpgradeView` modal sheet — the
  one with "Subscribe — $9.99/yr". Upload here.
- **Review Notes**: see Section 11 below.

**Save**. The subscription enters **"Ready to Submit"** state. It
will be reviewed alongside the next app build you submit — they
travel together; you can't review IAP independently.

---

## Section 7 — Pricing and Availability

The app itself is **free to download** (the subscription is the
paywall).

1. Sidebar → **Pricing and Availability**.
2. **Price Schedule** → Free.
3. **Availability** → All territories (default), unless you have a
   reason to restrict.
4. **Distribution Method** → Mac App Store (only).
5. Save.

---

## Section 8 — App Store Listing (per platform → macOS)

Required fields under the **macOS App** version (the unreleased
version you'll be submitting; v1.0.0).

### 8.1 Marketing Copy

- **Promotional Text** (170 chars, can be updated without resubmit):
  > "Drop any audio or video. xTranscript turns it into clean text
  > and SRT subtitles using your own xAI API key. Works with MKV,
  > WebM, OGG, MP4, MP3, WAV, …"

- **Description** (4 000 chars): write 200–400 words. Hit:
  - What the app does (audio/video → text + SRT, locally decoded,
    cloud-transcribed via xAI)
  - Free vs Pro tier explanation (5-min limit on Free, $9.99/yr Pro
    removes it)
  - **Required disclosure**: BYOK ("you bring your own xAI API key,
    transcription quotas are billed by xAI directly, not by
    xTranscript")
  - Format coverage list

- **Keywords** (100 chars, comma-separated, no spaces around commas):
  > `transcribe,transcription,audio,video,subtitles,srt,xai,grok,speech,text`

- **Support URL**: `https://github.com/enicolas72/transcript/issues`
- **Marketing URL**: leave empty (or `https://eric-nicolas.net`
  if you want).

### 8.2 Screenshots

macOS submissions require **at least one** screenshot at one of
Apple's accepted sizes. Easiest format:

- **1280 × 800** — the smallest accepted size, looks clean on the
  store, easy to produce on a 13" Mac.
- **2560 × 1600** — 13" Retina, sharper.
- **2880 × 1800** — 15" Retina, sharpest. Pick one.

Recommended set (4–6 screenshots):
1. **Hero** — Empty-state drop zone with the sidebar visible. Caption
   overlay: "Drop any file. We'll handle the rest."
2. **Mid-transcription** — File queue showing one file in progress,
   another done, log panel showing live xAI partials. Caption:
   "Live transcription as bytes go up."
3. **TXT/SRT outputs** — Finder window showing the generated `.txt`
   + `.srt` next to the input file.
4. **Pro upgrade** — The `UpgradeView` sheet with the price visible.
   Caption: "Free up to 5 min · Pro for unlimited."
5. **Settings** — Sidebar showing the API key field, Subscription
   section, Acknowledgements link.

Generate them by running the app under the StoreKit configuration
file (so the upgrade sheet shows the test price), grabbing
`Cmd-Shift-4` rectangles, and resizing/cropping in Preview.

### 8.3 App Icon

- Apple pulls this from `Assets.xcassets/AppIcon` automatically when
  you upload the build. Nothing to set in App Store Connect.
- **Verify**: 1024×1024 PNG present (we have it).

### 8.4 Build

- Greyed-out until you upload your first build (Section 12). Come
  back here once that's done and select the build.

### 8.5 Age Rating

1. Click **Edit** under "Age Rating".
2. Answer "None" or "No" to every category. (No violence, no
   gambling, no medical info, no contests — xTranscript is a
   utility.)
3. Apple computes **4+** automatically.

### 8.6 Copyright

`© 2026 Eric Nicolas`

### 8.7 Sign-In Information (for App Review)

If your app required a sign-in, this is where you'd give the reviewer
test credentials. **Skip this — not needed.**

But: the **App Review Notes** field (further down on the same page,
Section 11) is where the BYOK + sandbox key explanation goes.

---

## Section 9 — Code signing & provisioning (Xcode side)

### 9.1 Add your Team to the project

1. Open `Transcript.xcodeproj` in Xcode.
2. Select the project root in the navigator → **xTranscript** target.
3. **Signing & Capabilities** tab.
4. **Team**: pick your Apple Developer Team from the dropdown.
   Xcode will:
   - Auto-generate the **Mac App Distribution** certificate the first
     time you archive (you'll be prompted).
   - Auto-generate the **Mac Installer Distribution** certificate
     similarly.
   - Create a provisioning profile bound to your bundle ID.
5. **Signing Certificate**: leave on "Automatically managed".

### 9.2 Capabilities sanity check

The capabilities pane should show:
- **App Sandbox** — checked
- **Hardened Runtime** — auto-applied for Distribution builds
- **In-App Purchase** — Xcode usually adds this automatically when
  you reference StoreKit; if not, click **+ Capability** and add
  it. (No entitlements file change required — it's just a flag in
  the provisioning profile.)

If "In-App Purchase" doesn't appear, double-check that
`developer.apple.com` shows it enabled on your App ID.

---

## Section 10 — Local StoreKit testing (do this BEFORE uploading)

Critical: don't submit a subscription you haven't actually purchased
locally first. Apple rejects half-broken IAP flows.

### 10.1 Wire the StoreKit config to the scheme

Already done by this commit. The scheme references
`Transcript/Configuration/Products.storekit`. Verify:

1. Product → Scheme → **Edit Scheme…**
2. **Run** → **Options** tab.
3. **StoreKit Configuration**: should be set to `Products.storekit`.
   If empty, click the dropdown and select it.

### 10.2 Test the flow

1. Build & Run.
2. Drop a 6-minute test file (any `.mp3` or `.mkv` longer than 5 min
   works).
3. The file row should show the limit error + sparkles upgrade button.
4. Click the sparkles button → upgrade sheet opens with `$9.99 / year`.
5. Click **Subscribe** → Xcode pops a fake purchase confirmation,
   click **Buy** → sheet flips to "You're on xTranscript Pro".
6. Sidebar updates: green ✓ badge.
7. Re-drop the same 6-minute file → transcribes successfully.

### 10.3 Test edge cases

In Xcode's **Debug** menu → **StoreKit** submenu (only visible
while running with a StoreKit config):

- **Manage Transactions…** — see purchase history, simulate refund.
- **Refund Transaction** → sidebar should flip back to Free.
- **Delete All Transactions** → fresh state.
- **Test Subscription Renewal** → simulate fast renewal cycles
  (compresses years into seconds).
- **Test Ask to Buy** → the `.pending` flow we handle in
  `SubscriptionManager.purchase()`.

You should be able to do all of these without the app crashing or
the sidebar getting stuck.

### 10.4 Test Restore Purchases

1. Click **Delete All Transactions** in the StoreKit debugger.
2. Sidebar → click **Restore Purchases**.
3. Re-purchase if no transaction is found, or restore the latest
   if one exists.

---

## Section 11 — App Review Notes (the make-or-break field)

Reviewers reject opaque BYOK + IAP apps. Make their life as easy as
possible.

Paste this (or a close variant) into **App Information → Review
Information → Notes**:

```
xTranscript is a Bring-Your-Own-Key client for xAI's Speech-to-Text
API. To review this build end-to-end you'll need both an xAI API key
and a sandbox tester account.

xAI API key for review:
  XAI_API_KEY = xai-***************************************
  (this is a throwaway key with a low monthly cap; please don't
  share it externally)

How to test:
  1. Launch xTranscript.
  2. Paste the xAI API key into the sidebar's "xAI API key" field.
  3. Drag any short audio/video file (e.g. a < 5-minute MP3) onto
     the right panel. The transcription will run in a few seconds
     and write a .txt next to the input.
  4. Drag a > 5-minute file. The file row will show a "5-min limit"
     error with a Pro upgrade button.
  5. Click the upgrade button (the sparkles icon next to the file
     row, OR "Upgrade to Pro · $9.99 / year" in the sidebar).
  6. The upgrade sheet appears with the live price. Tap Subscribe
     to test the StoreKit flow with the sandbox tester account.
  7. After purchase, re-drag the > 5-min file — it transcribes
     successfully. Sidebar shows the "✓ xTranscript Pro" badge.
  8. Tap "Restore Purchases" in the sidebar to verify the restore
     flow.

Subscription details:
  - Auto-renewable yearly subscription, $9.99 USD / year.
  - No introductory free trial. The 5-minute Free tier is the trial.
  - Subscription is processed entirely by Apple's StoreKit.
  - xAI usage is billed separately by xAI on the user's own API key
    (it is NOT included in the xTranscript Pro subscription).

Source / acknowledgements:
  - The app embeds a custom LGPL-only audio-decoder build of FFmpeg.
    Source available at:
      https://github.com/enicolas72/transcript/releases
    plus the build recipe at scripts/build-ffmpeg.sh.
  - In-app: Sidebar → "Acknowledgements…" shows the bundled
    LICENSES.txt (Resources/LICENSES.txt) reproducing the LGPL
    notice and pointing reviewers to the source URL.
```

Replace the masked key with a real throwaway. Generate one at
`console.x.ai`, set a low monthly limit, expect to revoke it after
the review concludes.

---

## Section 12 — Build & upload

### 12.1 Bump the version (skip on first submit)

For first submit: `MARKETING_VERSION = 1.0.0`,
`CURRENT_PROJECT_VERSION = 1`. We're already there.

For subsequent submits, bump `CURRENT_PROJECT_VERSION` (build
number) every upload, even if the marketing version stays the same:

```
MARKETING_VERSION = 1.0.1   # only when shipping new user-facing changes
CURRENT_PROJECT_VERSION = 2 # always increment for every build upload
```

### 12.2 Switch the scheme back to "no StoreKit config"

Distribution builds **must not** ship with a `Products.storekit`
config that overrides the App Store. Edit the scheme:

1. Product → Scheme → **Edit Scheme…**
2. **Run → Options → StoreKit Configuration → None**.

Or just toggle this only when you're about to archive — flip it
back to `Products.storekit` for your day-to-day local development.

(Apple actually ignores the StoreKit config in Release archives, but
keeping the config off in the scheme during archive removes any
ambiguity.)

### 12.3 Archive

1. **Product → Destination → Any Mac (Apple Silicon, Intel)**
   (universal target — already set).
2. **Product → Archive**.
3. Wait 30–90 seconds. The Organizer window opens automatically.

If the build fails:
- "missing entitlement" → check `Transcript/Transcript.entitlements`
  has `com.apple.security.app-sandbox = true`.
- "no signing certificate" → re-do Section 9.

### 12.4 Validate

In the Organizer:

1. Select the new archive.
2. **Validate App** → choose **App Store Connect** distribution.
3. Apple does a long lint check (~60 seconds) — catches things like
   missing icons, malformed Info.plist, etc.
4. Fix anything it complains about. Common ones:
   - "Marketing Icon missing" → make sure
     `Assets.xcassets/AppIcon/icon_1024.png` exists.
   - "Privacy manifest missing" → re-check that
     `Transcript/PrivacyInfo.xcprivacy` is in the app bundle's
     Resources phase.
   - "Encryption export documentation" → already declared
     `ITSAppUsesNonExemptEncryption = false` in `Info.plist`,
     should pass.

### 12.5 Distribute

1. Same Organizer screen → **Distribute App**.
2. **App Store Connect** → **Upload**.
3. **Strip Swift symbols**: yes (smaller download, no debug info
   leaked).
4. **Manage Version and Build Number**: yes (Xcode bumps the build
   number for you).
5. Wait 2–10 minutes for the upload + Apple's automatic processing.
6. You'll get an email when the build is ready to be selected.

### 12.6 Select the build in App Store Connect

1. Refresh App Store Connect → your app → macOS App version.
2. The **Build** section now has a **+** — click it, pick the build
   you just uploaded, save.

---

## Section 13 — TestFlight (optional but recommended)

TestFlight on macOS lets you get private testers (up to 100 emails)
on the same build before App Review.

1. App Store Connect → **TestFlight** tab.
2. Add internal testers (yourself, a couple friends).
3. They get an email; install the TestFlight app on their Mac;
   download xTranscript; report any issues.
4. **Worth doing** to catch sandbox-write bugs and the BYOK flow
   before review.

You can submit for App Review in parallel with TestFlight beta —
they don't block each other.

---

## Section 14 — Submit for review

1. Back to App Store Connect → your app → macOS App version 1.0.0.
2. Top-right: **Add for Review** → **Submit to App Review**.
3. Apple ETA varies wildly: 24 hours is common, 5 days happens.
   Median in 2026 is ~1.5 days.
4. You'll get email updates: "In Review", "Pending Developer
   Release" (success), or "Rejected".

---

## Section 15 — Common rejections & remedies

Realistic ones xTranscript might hit:

| Rejection reason | Why it happens | Fix |
|-|-|-|
| **2.1 — "App requires a third-party API key to work"** | BYOK is a yellow flag for App Review. They sometimes argue the app has "no functionality" without the key. | Update the App Description to lead with "Bring Your Own xAI API key" + screenshot of the key field. Reply with the App Review Notes you already wrote (Section 11). Most reviewers accept this on the second pass. |
| **3.1.2(a) — "Subscription terms not clearly displayed"** | The subscription footer in `UpgradeView` is the disclosure. Make sure auto-renewal text + Privacy + EULA links are visible **without scrolling** in the upgrade sheet. | Already implemented; if Apple complains, screenshot the visible footer and reply. |
| **4.2 — "Minimum functionality"** | App appears to do too little. Less likely for transcription, but could happen. | Reply with screenshots showing the full transcription flow. |
| **5.1 — "Privacy"** | Mismatched between your `PrivacyInfo.xcprivacy` and the App Privacy questionnaire. | Reconcile the two. Audio data declarations must match. |
| **2.5.10 — "App contains hidden, undocumented, or non-public APIs"** | Sometimes triggered by FFmpeg if Apple's symbol scanner finds something it doesn't recognise. Unlikely with our LGPL-only build. | Reply with the Acknowledgements text + a link to the FFmpeg source release. The `nm` post-build check we have proves no GPL symbols leaked. |

Reply to rejections in **Resolution Center** (left sidebar in App
Store Connect). Be polite, be specific, attach screenshots. Most
disputes resolve in one round.

---

## Section 16 — After approval

### 16.1 Release

Apple gives you a choice:
- **Manually release this version** — you click a button when you're
  ready. Recommended for a launch — gives you time to coordinate.
- **Automatically release this version** — Apple ships immediately
  on approval.

Set this in App Store Connect → your version → **Version Release**.

### 16.2 Monitor sales

App Store Connect → **Sales and Trends** has a 24-hour-delayed
dashboard. **Reports** → **Financial** has the actual payout
breakdown (Apple takes 30 % first year, 15 % from year 2 of a
subscriber).

### 16.3 Subscription analytics

App Store Connect → **Subscriptions** → click the product. Apple
shows churn, conversion, and retention curves automatically. No
analytics SDK needed.

### 16.4 Updates

When you ship `v1.0.1`:

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in pbxproj.
2. App Store Connect → your app → click **+ macOS App version**
   → enter `1.0.1`.
3. Update **What's New in This Version** (4 000 chars, shown to
   users prominently when they update).
4. Re-archive, re-upload, select the new build, submit for review.
5. Subsequent reviews are usually faster (~1 day) because Apple
   already has your app in their system.

---

## Section 17 — When something is on fire

| Problem | First thing to check |
|-|-|
| Upgrade button does nothing | Scheme's StoreKit configuration. In production builds it MUST be **None**; in dev it must be `Products.storekit`. |
| StoreKit returns "product not found" | Product ID mismatch. Compare `SubscriptionManager.proYearlyProductID` against the App Store Connect product ID character-by-character. |
| Sandbox tester can't sign in | The tester account is bound to a region. Make sure your Mac's App Store is signed *out* of your real Apple ID, then the StoreKit prompt asks for the sandbox tester. |
| Reviewer can't reach api.x.ai | Most likely you didn't include a working API key in App Review Notes, or its quota was exhausted. Re-issue a key with a higher cap and reply via Resolution Center. |
| App Sandbox blocks file writes | We've seen this; fix is in `TranscriptionViewModel.requestWriteAccess`. If a tester reports it, ask them what folder they dropped from and whether they hit "Allow" on the NSOpenPanel prompt. |

---

## Pre-flight checklist

Print this, tick before submitting:

- [ ] Apple Developer Program: paid, agreements signed, banking + tax filled.
- [ ] App ID `net.eric-nicolas.xtranscript` registered.
- [ ] App Store Connect app record created.
- [ ] Subscription product `net.eric-nicolas.xtranscript.pro.yearly` created at Tier 9.
- [ ] App Privacy questionnaire filled (audio data: app functionality, not linked, not tracking).
- [ ] Privacy Policy URL set (GitHub-hosted markdown).
- [ ] Support URL set (GitHub Issues).
- [ ] At least one screenshot uploaded (1280×800 minimum).
- [ ] Description, promo text, keywords filled.
- [ ] App Review Notes contain the throwaway xAI key + step-by-step.
- [ ] Local StoreKit test passed: free → 5-min limit → upgrade → unlimited → restore.
- [ ] `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` set correctly.
- [ ] Scheme's StoreKit configuration is **None** for the archive build.
- [ ] Archive validates clean.
- [ ] Build uploaded; selected in the version's **Build** section.
- [ ] **Submit to App Review**.

Good luck.

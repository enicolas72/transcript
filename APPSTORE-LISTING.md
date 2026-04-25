# App Store Connect listing copy

Copy-paste-ready text for every field in App Store Connect when you
submit xTranscript. Lengths fit Apple's caps; character counts noted
in `<>` next to each section.

If you decide to localize to French, see the placeholder at the
bottom — same fields, same caps, ready for translation.

---

## App Name `<30>`

```
xTranscript
```

(11 chars — well under the 30-char cap. If "xTranscript" is taken on
the App Store, fall back to one of: `xTranscript - Audio to Text`
(29), `xTranscript Transcriber` (23), or `xTranscript for xAI` (19).)

---

## Subtitle `<30>`

```
Audio & video transcription
```

`<27 chars>` — appears under the app name in search results and on
the product page.

Alternative if you want to lead with the technology:

```
Transcribe any audio via xAI
```

`<28 chars>`

---

## Promotional Text `<170>`

```
Drop any audio or video file. xTranscript decodes it locally and streams the audio to xAI's grok-stt to produce clean text and SRT subtitles. 11 languages.
```

`<156 chars>` — this is the only field on the listing you can update
**without resubmitting a new build**. Use it for time-sensitive
nudges (e.g. promo prices, what's new at a glance).

---

## Keywords `<100>`

```
transcribe,transcription,audio,video,subtitles,srt,xai,grok,speech,text,podcast,meeting
```

`<87 chars>` — comma-separated, no spaces around commas. Keywords
boost search ranking but don't appear visibly to users.

Don't include the app name, the developer name, or category names —
Apple already indexes those for free; using them in keywords is a
waste of bytes.

---

## Description `<4000>`

```
xTranscript turns audio and video files into clean text and SRT subtitles. Drag any file onto the window — xTranscript decodes it on your Mac and streams it to xAI's Grok speech-to-text API.


WHAT IT DOES

• Drop any audio or video file: MP3, M4A, MP4, MOV, WAV, FLAC, AAC, AIFF, CAF, ALAC, MKV, WebM, OGG/Opus, AVI, WMV, WMA, and more.
• Generates a .txt transcript and/or a .srt subtitle file next to the input file, or in a folder you choose.
• 11 languages: English, French, German, Spanish, Italian, Portuguese, Dutch, Russian, Chinese, Japanese, Korean.
• Multi-file queue with per-file progress, retry, and overwrite protection.
• Real-time live partial transcripts stream back into the log panel as the audio uploads — you see words appear within seconds.


DECODING HAPPENS ON YOUR MAC

xTranscript embeds an audio-only LGPL build of FFmpeg, so it opens formats Apple's frameworks don't natively support — including MKV, WebM, OGG/Opus, AVI, WMV, and WMA — without you having to convert anything first. The decoded 16 kHz mono PCM is what gets sent to xAI; the original file never leaves your Mac.


YOU BRING YOUR OWN xAI API KEY

xTranscript uses xAI's Speech-to-Text API for the actual transcription. To use the app you'll need an xAI API key — sign up free at console.x.ai. xAI bills your account directly for the audio minutes you transcribe (at the time of writing, $0.20 per audio-hour for streaming). xTranscript never sees your payment details, your Apple account, or your audio.


FREE & PRO

• Free — every feature, capped at 5 minutes of audio per file. Great for voice memos, podcast clips, short interviews.
• xTranscript Pro — $9.99 / year — removes the 5-minute limit. No other restrictions; same encoder, same xAI pipeline, just no length cap.


PRIVACY

• Your audio goes to xAI for transcription. That's the only third party involved.
• No analytics, no tracking, no advertising identifiers, no telemetry.
• No xTranscript accounts, no sign-up — just paste your xAI key into Settings.
• Generated transcripts and subtitles are written locally next to the input (or to a folder you pick) and never leave your Mac.

Full privacy policy: https://github.com/enicolas72/transcript/blob/main/docs/privacy.md


SUBSCRIPTION TERMS

xTranscript Pro is an auto-renewable yearly subscription billed at $9.99 / year (price may vary by region) through your Apple ID. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Your Apple ID will be charged for renewal within 24 hours of the end of the period. Manage or cancel anytime in System Settings → Apple Account → Subscriptions. Any unused portion of a free trial period (if any was offered) is forfeited when you purchase a subscription.


REQUIREMENTS

• macOS 14 (Sonoma) or later
• An xAI API key (free signup at console.x.ai; pay-as-you-go billed by xAI on your account)
• Internet connection (the audio is uploaded to xAI for transcription)


LINKS

• Privacy Policy: https://github.com/enicolas72/transcript/blob/main/docs/privacy.md
• Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
• Source code, issue tracker, source release of the embedded FFmpeg: https://github.com/enicolas72/transcript
```

`<2 850 chars>` — fits comfortably under the 4 000-char cap with room
to grow.

The subscription terms paragraph is **mandatory** for App Review when
you ship an auto-renewable subscription. Don't trim it.

---

## What's New in This Version `<4000>`

For v1.0.0:

```
First release. Drag-and-drop audio and video transcription via xAI's grok-stt API:

• 11 languages, .txt and .srt outputs side by side
• Embedded LGPL FFmpeg decodes anything — MKV, WebM, OGG/Opus, AVI, WMV, on top of every native macOS format
• Live partial transcripts stream back as the audio uploads
• Free up to 5 min per file; xTranscript Pro at $9.99/year removes the limit
```

`<425 chars>` — the "What's New" field shows in the Updates tab in
the App Store and pops up on the user's Mac when an update is
available, so keep it short and feature-led.

For future versions, follow the same pattern (3–5 bullets, lead with
the user-visible change).

---

## Age Rating

Answer **No / None** to every question in the questionnaire. Apple
will compute **4+** automatically.

---

## Category

| | |
|-|-|
| Primary | **Productivity** |
| Secondary (optional) | **Utilities** |

---

## Subscription product copy

Inside the subscription product (Section 6 of MACAPPSTORE-HOWTO.md),
under **Localizations → English (U.S.)**:

### Subscription Display Name `<30>`

```
xTranscript Pro
```

`<15 chars>`

### Subscription Description `<255>`

```
Removes the 5-minute-per-file limit on the Free tier. Transcribe any length of audio or video. Same xAI-powered accuracy. Cancel anytime through System Settings.
```

`<162 chars>`

---

## Review screenshot

Apple wants a screenshot of the upgrade UI uploaded to the
subscription product's Review Information section. Take a 1280×800
crop of the `UpgradeView` modal sheet showing:

- The "xTranscript Pro" title
- The bullet list ("Unlimited file length", etc.)
- The price ($9.99 / year — visible courtesy of `Products.storekit`)
- The Subscribe button
- The auto-renewal footer

That single screenshot satisfies Apple Guideline 3.1.2(a) — proof
that subscription terms are visible before purchase.

---

## French localization (optional placeholder)

If you decide to ship a French listing, here are the same fields
ready for translation. Apple charges nothing for additional locales
and conversion lift on a French listing for a French developer is
real.

### Subtitle `<30>`

```
Transcription audio et vidéo
```

`<28 chars>`

### Promotional Text `<170>`

```
Déposez n'importe quel fichier audio ou vidéo. xTranscript le décode en local puis l'envoie à l'API grok-stt de xAI pour produire un texte propre et des sous-titres SRT. 11 langues.
```

`<186 chars>` — too long, trim to e.g. drop the "11 langues" tail.

### Keywords `<100>`

```
transcription,sous-titres,audio,video,srt,xai,grok,parole,podcast,reunion
```

`<74 chars>` — French keywords. Apple's keyword field is per-locale.

### Description

(translate the English description body, keeping the bullet structure
and the SUBSCRIPTION TERMS paragraph — that one's required word-for-
word equivalent in every locale).

---

## Quick copy-paste checklist

When you're filling in App Store Connect, the order that minimizes
context-switching:

1. **App Information** → category + content rights + privacy URLs
2. **Pricing and Availability** → Free, all territories
3. **Subscriptions** → group + product (use Display Name + Description above)
4. **macOS App version 1.0.0**:
   - Subtitle, Promotional Text, Description, Keywords, What's New
   - Screenshots (4–6)
   - Age rating questionnaire
   - Copyright: `© 2026 Eric Nicolas`
   - Support URL, Marketing URL
   - **App Review Notes** (template in MACAPPSTORE-HOWTO.md §11)
5. **Build** → upload from Xcode, then select here
6. **Submit for Review**

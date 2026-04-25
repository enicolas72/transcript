# xTranscript — Privacy Policy

_Last updated: 2026-04-23_

## Short version

xTranscript turns audio and video files you give it into text. The only
data that leaves your computer is the audio you choose to transcribe,
and the only place it goes is **xAI's Speech-to-Text API** — so that
xAI can produce the transcript. We don't run a server, don't have user
accounts, don't collect analytics, and don't share your data with
anyone else.

## What data xTranscript handles

- **Audio files you pick.** When you drop an audio or video file onto
  xTranscript, the app extracts its audio track on your machine —
  using AVFoundation when Apple supports the container, or an
  embedded LGPL build of FFmpeg as a fallback for formats Apple
  doesn't open (MKV, WebM, OGG/Opus, AVI, WMV). The decoded audio
  is then streamed (as 16 kHz mono PCM) over a secure WebSocket to
  `wss://api.x.ai/v1/stt`, and the transcript is returned. FFmpeg
  itself runs entirely on your device and does not initiate any
  network connections of its own (we built it with all network
  protocols disabled).
- **Your xAI API key.** Stored on your device in the system
  `UserDefaults` database. It is never sent anywhere except to xAI's
  own API, as the `Authorization` header on each request. You can
  remove it from the Settings sidebar at any time.
- **Settings.** Output-folder preference, enabled output formats, and
  chosen language. Stored locally on your device.

## What data xTranscript does NOT handle

- No user accounts, no sign-up, no email address, no password.
- No analytics, no crash reporters, no telemetry of any kind.
- No advertising identifiers, no tracking.
- No contacts, photos, location, microphone (live recording), or any
  other sensor access.
- We do not receive or see your audio, your transcripts, or your API
  key. Everything flows directly between your Mac and xAI.

## Subscriptions

xTranscript offers an optional yearly **Pro** subscription that removes
the 5-minute-per-file limit on the Free tier. The subscription is
handled entirely by **Apple's App Store** through StoreKit. We don't
see your payment details, your Apple ID, or your transaction history
beyond a yes/no entitlement that StoreKit reports back to the app.

Apple's handling of subscription data is governed by their privacy
policy: https://www.apple.com/legal/privacy/.

## Third parties

Exactly one: **xAI**. When you use xTranscript, the audio track of
the files you drop on the app is sent to xAI for transcription. xAI's
handling of that data is governed by their own privacy policy and
API terms:

- xAI Privacy Policy: https://x.ai/legal/privacy-policy
- xAI API Terms: https://x.ai/legal/api-terms

If you are uncomfortable with that data transfer, do not use
xTranscript.

## Storage

- Input audio/video files are read from disk but not copied by
  xTranscript; the temporary working copies used during extraction
  are deleted as soon as the transcription finishes.
- Transcript outputs (`.txt` / `.srt`) are written to the location
  you selected (same folder as the input, or a custom folder you
  picked). They are never uploaded anywhere.

## Your choices

- Use the **xAI API key** field in Settings to replace or clear the
  key at any time. Clearing it disables all network calls from the
  app.
- To delete every trace of xTranscript from your machine: drag the
  app to the Trash and, if you want, remove the app's `UserDefaults`
  domain with
  `defaults delete net.eric-nicolas.xtranscript`.

## Contact

Questions about this policy? Open an issue at
https://github.com/enicolas72/transcript

## Changes

If this policy changes, the "Last updated" date above will change. We
won't push notifications for privacy-policy updates — there are no
notifications from this app.

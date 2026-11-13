# How GeminiFlow works

This document covers the architecture and what we learned about the Gemini APIs while building and hardening GeminiFlow. It's useful if you want to change the app or build something similar, for example an iOS version.

## 1. Product shape

- **Main engine:** Gemini Live Transcribe, model `gemini-3.5-transcribe-live`, streamed over a WebSocket while the user talks. About **0.4 s** from release to text, with 99–100% word recall on our test set.
- **Safety net 1:** the REST backup, model `gemini-3.5-flash-lite`, `generateContent` with the whole recording as inline WAV. It only runs when Live fails. It's often slow (2–9 s) and has frequent 503 "high demand" errors.
- **Safety net 2:** Apple on-device recognition, `SFSpeechRecognizer` (streaming partials during the press, plus a WAV-file pass as a fallback). It's the last resort and is never silently dropped.
- **Output path:** text → clipboard + "Recent Dictations" (last 5, **memory only**; dictated text is never written to disk) → auto-paste. On iOS this will be a keyboard extension or share flow instead, but keep the "never lose a dictation" principle.
- **Interaction:** hold to talk, double-tap for locked (hands-free) mode, tap again to stop, Esc to cancel.

## 2. Gemini Live protocol: what actually works

**Endpoint:** `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`

**Auth:** send the key in the `x-goog-api-key` **header** on the WebSocket upgrade. The server accepts it. Never put the key in the URL. Also scrub keys from every log line.

**Setup message:**
```json
{"setup":{"model":"models/gemini-3.5-transcribe-live",
          "generationConfig":{"responseModalities":["TEXT"]},
          "realtimeInputConfig":{"automaticActivityDetection":{"disabled":true}}}}
```

- **Audio:** `{"realtimeInput":{"audio":{"mimeType":"audio/pcm;rate=16000","data":"<base64>"}}}`, sent as 16 kHz mono int16 PCM in ~100 ms chunks. Resends after a reconnect go out as 1 s chunks.
- **Use manual activity.** Server voice detection missed speech, and tuning `startOfSpeechSensitivity` changed nothing. Send `{"realtimeInput":{"activityStart":{}}}` when speech starts and `{"realtimeInput":{"activityEnd":{}}}` at release. Use `activityEnd`, **not** `audioStreamEnd`.
- **Turn end:** each turn ends with `generationComplete`. We never saw `turnComplete` for this model. After it, the server sends one `voiceActivity ACTIVITY_END` **echo** per `activityEnd`.
- **Empty turn:** an echo that arrives while that turn is still pending means the server closed an **empty** turn. You get no transcript and no `generationComplete`. We use this as the "Live heard nothing" signal.
- **Rule 1: never send `activityStart` while the previous turn is still pending.** The server silently ignores it, folds or drops the audio, and **words get lost**. This was our most expensive bug, fixed on 12 Nov. Hold any new voiced audio, plus ~0.3 s of pre-roll, until the pending turn's `generationComplete`, then reopen.
- **Rule 2: keep activities short.** Release-to-text time grows with how long the open activity is: 16 s → 0.5 s, 32 s → 0.7 s, 124 s → 1.5 s. We split at local pauses (fixed RMS 150 threshold, ~0.4 s gap) into several activities within one session, and stitch the segments together.
- **Coverage bookkeeping:** track which byte of the recording each answered turn covers. Coverage may only advance to the **end byte of the activity that was actually answered**, never to "bytes sent so far". This is what makes reconnects lossless.
- **Session lifetime:** the server closes the socket at about **9 min 50 s** of session age, with close code **1008**. We rotate proactively at the first pause after 8.5 min: open a new socket, resume from the covered byte, nothing is re-sent. A close at 9.5 min or later counts as a planned rotation, not a failure.
- **Mid-press drops:** real drops happen with codes 1011 and 0 ("connection reset by peer"). We reconnect up to 2 times per press, with 0.25 s / 0.75 s backoff, and resend from the last covered byte.
- **Warm-up:** first connect after idle takes ~350 ms, warm ~65 ms. The first mic buffer after idle arrives ~450 ms after press, ~170 ms when warm. On iOS, open the socket at press-down, in parallel with starting the mic.

## 3. REST backup (gemini-3.5-flash-lite)

- **Request:** `generateContent` with `inlineData` audio/wav, `temperature 0`, `thinkingConfig.thinkingBudget 0`, `maxOutputTokens 8192`.
- **Timeout:** an idle timeout of 8 s + 0.25 s per audio second. With a fixed 8 s, 124 s recordings timed out.
- **Retry:** retry once on 429/503, including slow 503s that arrive at about 6 s, within a total deadline. Never retry after a timeout.
- **Size limit:** inline requests are capped at about 20 MB, which is roughly **8 min** of WAV after base64. Longer recordings need chunking. This is open backlog item 31.
- **⚠️ It hallucinates on silence or noise.** It returns fluent invented text: "00:00 Send the quarterly report to Sarah by 5:00 PM today.", "The quick brown fox…", "0:00 --". **Never send a recording to REST unless there is evidence of speech** (see section 4). Also reject outputs that can't be right: text starting with a zero timestamp, or more than 10 + 40 characters per second of speech audio.

## 4. "No speech" detection (accidental taps, silent holds)

Live's final turn closing empty is not enough on its own. We end a press as **No speech**, with nothing pasted, when all of these hold:
1. Live's final turn was empty, with no earlier text.
2. On-device recognition produced no text. Always wait up to 0.6 s for its verdict. Code 1110 means "No speech detected".
3. There's no speech-level audio. Measure frames of 20 ms. The noise floor is the 20th-percentile frame RMS. The speech threshold is 3× the noise floor, clamped to between 250 and 1000. "No speech" means peak RMS below 350, or less than 0.10 s of frames above the threshold.

Things we got wrong first:
- **An absolute RMS-60 floor is too low.** Normal room noise peaks at 130–260 RMS. Real speech peaks at 800+, and our quietest test speech peaks at about 560–840.
- **A purely relative measure fails on short all-speech clips.** A 0.43 s "Hello." has a noise floor at speech level. That's why the threshold is clamped.

## 5. Text polish (applied to all engines)

- Filler removal: um, uh, and so on.
  - "kind of" / "sort of" are removed only when clearly filler: set off by commas, or next to other fillers. They're kept after a/the/what/this ("what kind of car") and as a plain hedge ("I kind of like it").
- Stutters: collapse "the the the", but keep grammatical doubles like "had had" and "that that", and repeated names like "Bora Bora".
  - Repeated phrases and mid-thought restarts collapse too: "happy with my with my new app" becomes "happy with my new app", and "I also want you to give some I also want you to give updates" keeps one copy. Kept as dictated: emphasis with a comma ("I know, I know"), courtesy phrases ("thank you, thank you"), idioms ("again and again and again"), names, number runs, and any repeat that is plain grammar ("we have to do what we have to do"). Nothing is collapsed across a sentence end. When unsure, the words stay.
- Pronoun "i" → "I" only as the pronoun, never in i.e., file names or paths.
- Auto-capitalisation skips iPhone, iOS, URLs and emails, and words after abbreviations (e.g., a.m., U.S.).
- The final "?" or "." is decided by the **last** sentence, not the first.
- Spoken "new line" works as a whole-word command only.

## 6. Reliability details worth copying

- **Overlapping presses:** a re-press while the previous dictation is still finishing must work. Give each press its own snapshot object holding audio, state and results. Pastes go through **one serial queue**, and nothing is pasted while a newer press is recording.
- **Bounded wait:** if Live fails and REST is slow, paste the on-device text after ~3 s. Swap in the better Gemini text only if that's provably safe; we verified it with the Accessibility API on macOS.
- **Mic unavailable:** if the engine fails to start or delivers 0 Hz or no buffers, show a clear notice ("Mic access needed" / "Mic unavailable") instead of failing silently.
- **Watchdogs:** every async stage has one (the WAV recognition fallback, the Live 2.5 s cap after release, the 0.45 s empty-turn grace), so the UI never sticks on "Thinking…".
- **Privacy:**
  - Temp WAV files are mode 0600, deleted after use, and swept if stale.
  - Logs contain **numbers only**, never dictated text or keys.

## 7. Testing approach (worked very well)

- **Test hooks:** the app has e2e-only hooks that feed a WAV file through the real pipeline, e.g. `--e2e-file <wav> <model> [flags]`, and print the result plus "release → text" latency. Most failures can be injected through flags:
  - a forced socket drop at N s
  - a simulated session-lifetime close
  - a fake or slow 503
  - an empty final turn
  - a REST delay
  - a fallback forced to on-device
- **Test audio:** generated with macOS `say` (several voices and rates, noisy/quiet versions, 30 s / 2 min / 5 min / 10 min hands-free clips, synthetic room noise). Cache writes are atomic, because a hung `say` once left a truncated file that later runs reused.
- **Gates:**
  - recall ≥ threshold against the reference text
  - Live used without fallback
  - latency limits (Live ≤ 3 s; median ~0.4 s)
  - no duplicated 4-word phrase at reconnect seams (counted only if it appears twice or more)
  - filler leakage
  - no-speech cases must give `<NO SPEECH>` without a REST call
- **Unit tests:** about 500 of them, run by the app's `--test` flag. Logic is kept in small pure functions (decision tables) so it can be tested without a network or UI.
- **Online vs offline:** the online suite runs against the real servers. It's about 60 checks and takes ~10 min, plus ~16 min once a day for the 5- and 10-minute tests. The offline suite is fast and needs no network.
- **REST flakiness is real:** judge REST-only failures against changes that don't touch REST, and retry once after ~10 min before blaming the code.

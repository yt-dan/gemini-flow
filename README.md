# GeminiFlow

Fast voice dictation for macOS. Hold **Fn**, speak, let go, and your words are typed wherever your cursor is.

It uses Google's **Gemini Live** speech-to-text, streamed while you talk, so text normally appears about **0.4 seconds** after you let go. If Gemini Live has a problem, GeminiFlow quietly falls back to a second Gemini service and then to Apple's on-device recognition, so a dictation is never lost.

- **Hold Fn** to talk, and let go to paste.
- **Double-tap Fn** for hands-free mode, for long dictations. The dot and sound bars in the floating pill turn green. Tap Fn again to finish.
- **Esc** cancels.
- Silence or an accidental tap pastes nothing ("No speech").
- Filler words ("um", "uh", "you know") and stutters are cleaned up automatically. You can change this in `rules.json`.
- Your last 5 dictations are in the menu bar under **Recent Dictations**. They're kept in memory only and never saved to disk.

## Install (about 5 minutes)

> **Using an AI coding agent?** Point it at this repo and say *"Install GeminiFlow for me by following AGENTS.md."*

You need a Mac with macOS 11 or newer and a **Gemini API key**, which is free from [Google AI Studio](https://aistudio.google.com/apikey).

1. Open the **Terminal** app. Press ⌘+Space, type `Terminal`, and press Return.
2. Copy and paste this line, then press Return:
   ```bash
   git clone https://github.com/yt-dan/gemini-flow.git ~/GeminiFlow && cd ~/GeminiFlow && ./install.sh
   ```
   If macOS asks to install the **Command Line Tools**, click **Install**, wait for it to finish, then run `cd ~/GeminiFlow && ./install.sh` again.
3. If a keychain window asks to let **codesign** use a key, enter your Mac password and click **Always Allow**.
4. Finish the one-time setup:
   - Allow **Microphone** and **Speech Recognition** when asked.
   - Go to **System Settings → Privacy & Security → Accessibility** and turn **GeminiFlow** on. GeminiFlow needs this so it can paste for you.
   - Click the menu bar icon, choose **Set Gemini API Key…**, paste your key, and click **Save**.
   - Go to **System Settings → Keyboard → "Press fn key to"** and choose **Do Nothing**. This stops the emoji picker from popping up.

For a step-by-step guide with explanations, see [docs/SETUP.md](docs/SETUP.md).

## Update

```bash
cd ~/GeminiFlow && ./update.sh
```

Updating keeps your API key, permissions and settings.

## Custom vocabulary (names and unusual words)

If GeminiFlow keeps misspelling a name or a product term, add it to your custom words list. The easiest way is **Custom Words** in the menu bar menu: it opens a small window where you add and remove terms, keeps the list outside the project folder, and the list is sent to Google with each dictation, like the audio. The list is a small file that lives **outside** the GeminiFlow folder:

`~/Library/Application Support/GeminiFlow/custom-words.json`

```json
["Siobhan", "Zyphra", "Kristoffer"]
```

- It applies from your next dictation. You don't need to restart.
- Use it for **names and unusual terms only**. A common word in the list replaces words that sound like it: in testing, adding "build" turned a spoken "bill" into "build".
- Up to 100 terms of up to 64 characters each. Longer or extra entries are ignored.
- Your words stay in that file on your Mac and are sent to Gemini Live with each dictation. Because the file is not in the GeminiFlow folder, the names in it are never committed or published with the code. They are never written to the log; only the number of terms is.
- It works with Gemini Live, the main engine. The two backup engines don't use it.
- Advanced: `rules.json` also accepts a `"customVocabulary": [...]` list, which is added after the words from the file. `rules.json` is part of the GeminiFlow folder, so keep private names out of it if you share that folder.

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing gets pasted | Turn GeminiFlow on in **Privacy & Security → Accessibility**. If it's already on, turn it off and on again. |
| The emoji picker opens when I press Fn | **System Settings → Keyboard → "Press fn key to" → Do Nothing**. |
| "Mic access needed" | **Privacy & Security → Microphone →** turn GeminiFlow on. |
| Text quality got worse or it's slow | Check your API key from the menu bar icon. GeminiFlow shows "Gemini Live ready" when the key works. |
| It asks for permissions again after an update | Run `./install.sh` once more. It creates the local signing certificate that keeps permissions stable. |
| Start at login | Run `./install.sh --start-at-login`. |

Logs, which contain numbers and status only and never your words or your key, are in `~/Library/Logs/GeminiFlow.log`.

## Privacy

- Audio is sent only to Google's Gemini API using **your own API key**, and only while you hold Fn or are in hands-free mode.
- Nothing you say is written to disk. Temporary audio files are private to your user account and deleted right after use.
- Your API key is stored in your macOS user preferences and is never written to logs.

## For developers

- `main.m` is the whole app (Objective-C, no Xcode project needed). `build.sh` compiles it with `clang`.
- `./build.sh` builds and installs to `~/Applications/GeminiFlow.app`.
- `~/Applications/GeminiFlow.app/Contents/MacOS/GeminiFlow --test` runs about 500 built-in unit tests.
- `python3 tests/run_tests.py --bin ~/Applications/GeminiFlow.app/Contents/MacOS/GeminiFlow` runs the offline end-to-end suite. It uses macOS `say` to generate test audio.
- [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md) explains the architecture and what we learned about the Gemini Live protocol.
- GeminiFlow is improved continuously, and every change passes the offline and online test suites before it's published here.

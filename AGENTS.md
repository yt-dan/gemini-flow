# Instructions for AI agents: installing GeminiFlow

You're helping a person install GeminiFlow, a macOS menu-bar voice-dictation app, from this repository. Follow these steps in order. Explain what you're doing in plain language, because the person may not be technical.

## Ground rules
- Only run the commands below. Don't edit `main.m`, `build.sh` or `install.sh`.
- **Never print, log or commit the user's API key.** If you set it for them, pass it only through the `GEMINI_API_KEY` environment variable for a single command, as shown in step 3.
- Don't create or modify anything outside `~/GeminiFlow`, `~/Applications/GeminiFlow.app`, `~/Library/Application Support/GeminiFlow`, and (only if asked) `~/Library/LaunchAgents/com.google.internal.geminiflow.plist`.

## Steps

1. **Get the code.** Skip this if the repo is already at `~/GeminiFlow`.
   ```bash
   git clone https://github.com/yt-dan/gemini-flow.git ~/GeminiFlow
   ```

2. **Check the Command Line Tools.**
   ```bash
   xcode-select -p
   ```
   If this fails, run `xcode-select --install`. Tell the user to click **Install** in the window that appears and to tell you when it has finished, then continue.

3. **Install.** Ask the user whether they want to give you their Gemini API key now. The key is free at https://aistudio.google.com/apikey.
   - If they give you the key:
     ```bash
     cd ~/GeminiFlow && GEMINI_API_KEY='<their key>' ./install.sh
     ```
   - Otherwise:
     ```bash
     cd ~/GeminiFlow && ./install.sh
     ```

   Add `--start-at-login` if the user wants GeminiFlow to start automatically.

   Success looks like:
   - `OK: <N> passed, 0 failed` in step 4/6
   - `GeminiFlow is installed and running` at the end

   If a macOS keychain dialog appears ("codesign wants to use key…"), tell the user to type their Mac login password and click **Always Allow**.

4. **Guide the one-time permissions.** Only the user can click these; macOS doesn't allow scripts to grant them.
   - Allow **Microphone** and **Speech Recognition** when prompted.
   - Go to **System Settings → Privacy & Security → Accessibility** and turn on **GeminiFlow**. You can open the page with:
     ```bash
     open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
     ```
   - If no key was given in step 3: menu bar icon → **Set Gemini API Key…** → paste → **Save**.
   - Go to **System Settings → Keyboard → "Press fn key to"** and choose **Do Nothing**.

5. **Verify.** Ask the user to click into any text field, hold **Fn**, say "testing one two three", and let go. The text should appear within about a second. If it doesn't:
   - Check `tail -40 ~/Library/Logs/GeminiFlow.log`. It contains no dictated text.
   - The usual cause is that Accessibility isn't on yet. Turn it off and on again, then quit GeminiFlow from the menu bar icon and run `open ~/Applications/GeminiFlow.app`.

## Updating later
```bash
cd ~/GeminiFlow && ./update.sh
```

## Uninstalling
```bash
pkill -x GeminiFlow; rm -rf ~/Applications/GeminiFlow.app ~/Library/LaunchAgents/com.google.internal.geminiflow.plist
defaults delete com.google.internal.geminiflow
```
This also deletes the saved API key. Optionally, delete `~/GeminiFlow` and the "GeminiFlow Local Signing" certificate in Keychain Access.

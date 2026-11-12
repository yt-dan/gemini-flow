# Step-by-step setup (no technical experience needed)

This takes about 5–15 minutes. Most of that is waiting for Apple's tools to download the first time.

## What you need
- A Mac running macOS 11 (Big Sur) or newer.
- A **Gemini API key**. This is a password-like code that lets GeminiFlow use Google's speech service.
  1. Go to https://aistudio.google.com/apikey and sign in.
  2. Click **Create API key** and copy it.
  3. Keep it private; don't paste it into chats or documents.

## 1. Open Terminal
Press **⌘ + Space**, type **Terminal**, and press **Return**. A window with a text prompt opens. You'll paste commands here.

## 2. Download and install
Paste this line, then press **Return**:
```bash
git clone https://github.com/yt-dan/gemini-flow.git ~/GeminiFlow && cd ~/GeminiFlow && ./install.sh
```
What happens:
- The code is downloaded into a folder called `GeminiFlow` in your home folder.
- The installer checks your Mac. If Apple's **Command Line Tools** are missing, a window asks to install them. Click **Install**, wait until it says it's done, then paste this and press Return:
  ```bash
  cd ~/GeminiFlow && ./install.sh
  ```
- The installer creates a small **local signing certificate**. It stays on your Mac, and it's what lets macOS remember GeminiFlow's permissions after updates.
- If a window says **"codesign wants to use the key…"**, type your Mac login password and click **Always Allow**.
- The app is built, self-tested, installed in your Applications folder, and started. You'll see a microphone icon in the menu bar at the top right of your screen.

## 3. Give permissions (one time)
macOS asks before an app can use the microphone or type for you.
1. **Microphone** and **Speech Recognition**: click **Allow** when asked.
2. **Accessibility**: open **System Settings → Privacy & Security → Accessibility** and turn on **GeminiFlow**. This lets GeminiFlow paste the text at your cursor.

## 4. Add your API key
Click the menu bar icon → **Set Gemini API Key…** → paste your key with **⌘ + V** → **Save**. You should see **Gemini Live ready**.

## 5. Stop the emoji picker
Open **System Settings → Keyboard** and set **"Press fn key to"** (or **"Press 🌐 key to"**) to **Do Nothing**.

## 6. Try it
1. Click into any text box (an email, a document, a chat).
2. Hold **Fn**, say a sentence, and let go. Your words appear within about a second.
3. For a long dictation, **double-tap Fn**. The pill turns green inside, and you can let go and keep talking. Tap **Fn** again when you're done.
4. Press **Esc** to cancel a recording.

## Getting updates
Open Terminal and paste:
```bash
cd ~/GeminiFlow && ./update.sh
```
Updating keeps your key, permissions and settings.

## Something not working?
See the troubleshooting table in the [README](../README.md#troubleshooting), or ask your AI agent to follow [AGENTS.md](../AGENTS.md).

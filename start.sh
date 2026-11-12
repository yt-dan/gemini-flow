#!/bin/bash
# Start GeminiFlow in background
APP_PATH="${HOME}/Applications/GeminiFlow.app/Contents/MacOS/GeminiFlow"

if [ -f "$APP_PATH" ]; then
    nohup "$APP_PATH" > /dev/null 2>&1 &
    echo "GeminiFlow launched! Check your top menu bar for the 🎙️ Flow icon."
else
    echo "GeminiFlow app not found. Run ./build.sh first."
fi

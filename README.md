# Tama Agent

<p align="center">
  <img src="https://raw.githubusercontent.com/KenKaiii/tama-agent/main/assets/icon_1024.png" alt="Tama Agent" width="200">
</p>

<p align="center">
  <strong>Your AI pet that lives in the menu bar.</strong>
</p>

<p align="center">
  <a href="https://github.com/KenKaiii/tama-agent/releases/latest"><img src="https://img.shields.io/github/v/release/KenKaiii/tama-agent?include_prereleases&style=for-the-badge" alt="GitHub release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="MIT License"></a>
  <a href="https://youtube.com/@kenkaidoesai"><img src="https://img.shields.io/badge/YouTube-FF0000?style=for-the-badge&logo=youtube&logoColor=white" alt="YouTube"></a>
  <a href="https://www.skool.com/raid"><img src="https://img.shields.io/badge/Skool-Free%20community-7C3AED?style=for-the-badge" alt="Free Skool community"></a>
</p>

**Tama Agent** is a macOS app that puts an AI assistant in your menu bar. Press ⌥ + Space and a floating panel pops up over whatever you're doing. Ask it questions, tell it to do things on your computer, talk to it with your voice, or set up automations that run on a schedule. Choose from multiple AI models — GPT-5.5, Codex, Kimi K2.6, MiniMax M2.7, MiMo-V2-Pro, and more.

No dock icon. No browser tab. Just a lightweight assistant that's always one hotkey away.

> [!TIP]
> **Want to build your own apps with AI?** A free 7-day build challenge and 20+ step-by-step projects are in my free community: **[skool.com/raid](https://www.skool.com/raid)**

---

## 🧠 Why this exists

Every time you want to use AI, you have to open a browser, find the right tab, and lose focus on what you were doing.

Tama Agent is just *there*. Press ⌥ + Space and it appears over your current app. Ask it something, get your answer, and get back to work. It can run commands, edit files, search the web, manage your schedule, and more — all without leaving what you're doing.

---

## ✨ What it can do

### Talk to it from anywhere
Press ⌥ + Space and a floating panel appears over whatever app you're using. Type your message, get a response with nicely formatted text and code blocks. Close it when you're done. No window switching, no context loss.

### Call Tama
Start a voice call with Tama and have a real conversation. It listens, thinks, and talks back — just like a phone call with an AI that can actually do things. While you're talking, Tama has full access to all its tools: run commands, edit files, search the web, manage your schedule. Ask it to look something up, fix a bug, or set a reminder, all mid-conversation. Built-in speech recognition and text-to-speech powered by Kokoro — everything runs locally.

### Use your voice
Hold ⌥ + Space to speak instead of type. Tama Agent transcribes what you say and responds. It can also read responses back to you with built-in text-to-speech.

### Do things on your computer
It's not just a chatbot. You can ask it to:
- Run terminal commands
- Read, write, and edit files
- Search through your folders and codebases
- Pull information from websites

Ask it to clean up a file, find something in your project, run a build script, or summarize a webpage. It figures out the steps and does them.

### Reminders & automations
Set up reminders that show up as native macOS notifications. Or create routines — things that run automatically on a schedule:
- "Remind me to review PRs in 2 hours"
- "Every morning at 9am, check the weather and give me a summary"
- "Run this script every Friday at 5pm"

### Multiple models across providers
Pick the AI that works best for you:

| Provider | Models |
|----------|--------|
| **OpenAI** | GPT-5.5, GPT-5.5 Pro, GPT-5.4, GPT-5.4 Mini, GPT-5.4 Nano, GPT-5.3 Codex, Codex Mini |
| **Moonshot** | Kimi K2.6 |
| **MiniMax** | M2.7, M2.7 Highspeed |
| **Xiaomi** | MiMo-V2-Pro |

Just paste your API key or log in with OAuth and you're good to go. Switch between models anytime.

### Built for Mac
Native macOS app — no Electron, no web views. Fast, lightweight, and feels like it belongs on your Mac. Lives in the menu bar so it never clutters your dock.

---

## 🚀 Getting started

### Download

| Mac | Link |
|-----|------|
| Apple Silicon (M1/M2/M3/M4) | [Download](https://github.com/KenKaiii/tama-agent/releases/latest) |

### Setup

1. Drag to Applications, launch it
2. It shows up in your menu bar
3. Click it → AI Settings → add your API key or log in
4. Hit ⌥ + Space and start chatting

That's it.

---

## 🛠️ For developers

```bash
git clone https://github.com/KenKaiii/tama-agent.git
cd tama-agent
xcodegen generate
xcodebuild -project Tama.xcodeproj -scheme Tama -configuration Debug build
```

Stack: Swift 6, macOS 15+, AppKit + SwiftUI

---

## 🔒 Privacy

- Everything runs locally on your Mac
- Conversations are sent to your chosen AI provider's API
- Credentials encrypted and stored locally
- No analytics, no telemetry, no tracking

---

## 👥 Community

- [YouTube @kenkaidoesai](https://youtube.com/@kenkaidoesai) — tutorials and demos
- [Free Skool community](https://www.skool.com/raid): a 7-day build challenge and 20+ step-by-step projects

---

## 📄 License

MIT

---

<p align="center">
  <strong>A native macOS AI assistant that's always one hotkey away.</strong>
</p>

<p align="center">
  <a href="https://github.com/KenKaiii/tama-agent/releases/latest"><img src="https://img.shields.io/badge/Download-Latest%20Release-blue?style=for-the-badge" alt="Download"></a>
</p>

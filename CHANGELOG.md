# Changelog

Every release, newest first. The same list is on [yap.primitive8.cc/changelog](https://yap.primitive8.cc/changelog).

## 1.1 · 20 October 2026

Meeting notes, translation, a new Settings design and a lot of small things that make dictation feel right.

### New
- **Meeting notes.** Press ⌥⇧M when a call starts and again when it ends. Yap writes down who said what (You and
  Others, from your mic and your Mac's sound), then a title, summary and action items, all on your Mac. Works with any
  call app; no bot joins. The notes are copied as Markdown and kept in Library → Meetings with the audio.
- **Translate.** End with "…translate to French", or set "Always translate to" in Settings. About 40 languages.
- **Spoken maths.** "What's 40 plus 20" types 60; "15 percent of 200" types 30.
- **Learns from corrections.** Fix a word right after it pastes ("Jon" to "John") and it joins your dictionary.
- **Voice commands.** "Scratch that" drops the last sentence; end with "send it" or "press enter" to send.
- **Auto-zoom.** Recordings zoom in where you click and follow your pointer. One click removes it.
- **Blur.** Draw boxes over emails, API keys or names, for the whole video or part of it.
- **Burned-in captions.** Export a copy with the captions in the picture, for Slack and social.
- **Shortcuts on screen.** Combos like ⌘K appear in recordings for tutorials. Ordinary typing never does.
- **Yap Mic** (experimental). An iPhone app that makes your phone a wireless, encrypted microphone for your Mac.
  Turn it on in Settings → General → Experimental.
- **yap:// links.** Start dictation, a recording or meeting notes from Shortcuts, Raycast, Alfred, Stream Deck or a
  script.
- **Updates.** Yap can check for new versions itself, and releases are notarized by Apple.

### Better
- **Fits in with your text.** Mid-sentence, Yap adds the space and keeps it lowercase. Names keep their capitals.
- **Paste last again** with ⌃⌥V.
- **Can't hear you?** Yap warns you when no sound is coming from the microphone.
- **Snippet fill-ins:** `{date}`, `{time}`, `{day}`, `{year}` and `{clipboard}`.
- **Try it now.** A practice box in onboarding and Settings checks the key, the mic and pasting.
- **Clearer Settings.** Plain labels with a line on what each one does, and pages for Voice Commands and iPhone Mic.
- **New Settings design** (experimental, on by default): icon tabs along the top, like Apple's own apps, in Liquid
  Glass. Turn it off in General → Experimental to get the sidebar back.

## 1.0 · 15 October 2026

The first release.

- **Dictation.** Hold a key, talk, and Yap pastes at your cursor. All on your Mac.
- **AI cleanup.** Removes filler words and false starts, and adapts to the app you are typing in.
- **Command Mode.** Select text and say what to do with it, like "make this friendlier".
- **Screen recording.** Camera bubble, microphone and system audio, click highlights, and no time limit.
- **The Flow bar.** A small pill with a live waveform, plus the animated Yap mark and a Liquid Glass icon.
- **Library.** Transcripts, captions, titles, summaries and chapters for every recording, made on your Mac.

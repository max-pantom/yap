# Security

Yap handles sensitive input: your voice, what you type, and your screen. If you find a vulnerability, please
**don't open a public issue**. Report it privately through GitHub's "Report a vulnerability" button on the
Security tab of this repository. We'll acknowledge it within a few days.

Areas of particular interest:
- anything that could make Yap capture keystrokes, audio or the screen outside a user-initiated session
- data leaving the Mac without the user configuring it
- the paste/selection path (`Sources/Yap/Dictation/TextBridge.swift`)
- the Keychain-stored API key for custom model servers

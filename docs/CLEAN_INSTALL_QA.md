# Clean-install QA

Use a disposable **standard macOS user account** for every release candidate.
This is the closest reproduction of a colleague's fresh laptop on the same
hardware: the account starts with an empty TCC permission database, no
Whisperino preferences, no models, no Launch at Login registration, and no
previous app path or quarantine history.

Do not use `tccutil reset` on the maintainer account as the primary clean test.
It does not clear all first-run state and it disrupts the working installation.

## Create the test account

1. In the maintainer account, open **System Settings → Users & Groups**.
2. Add a **Standard** user named `Whisperino QA`.
3. Fast-user-switch to that account. Do not sign in to iCloud or copy files
   from the maintainer account.
4. Record the macOS version from **About This Mac**. Managed-device profiles,
   macOS build, CPU architecture, and browser can still differ from another
   laptop, so capture those when comparing a report.

Creating or deleting the account needs an administrator password and is the
only part of this procedure that cannot be automated unattended.

## Primary fresh-install path (DMG)

1. Download the release DMG from GitHub using the same browser as the reporter.
2. Open the DMG, drag **Whisperino** onto **Applications**, eject the DMG, and
   launch Whisperino from Applications.
3. Confirm the microphone prompt appears first and Accessibility follows only
   after that decision. Enable `/Applications/Whisperino.app`, then quit and
   reopen Whisperino once if macOS requests it.
4. In TextEdit, start and finish a transcription. Confirm the result appears in
   the selected text field and is not duplicated in the notch.
5. Start another transcription in a browser input, switch to another app while
   speaking, then return to the original field and stop. Confirm no controls in
   the other app are clicked and the final text returns to the original field.
6. Repeat with Parakeet, Nemotron streaming, and one Whisper model.

## Adversarial download path (ZIP or app launched from the DMG)

1. In a fresh QA account, launch `Whisperino.app` directly from Downloads or
   from the mounted DMG instead of dragging it first.
2. Confirm Whisperino shows **Install Whisperino before continuing** and does
   not show microphone or Accessibility prompts from that temporary copy.
3. Choose **Install in Applications**. Confirm it relaunches from
   `/Applications/Whisperino.app` and only then starts onboarding.
4. If an Applications copy already exists, confirm the downloaded copy offers
   **Open Installed Copy** and does not create a second permission identity.

While Whisperino is running, this command must print a path under
`/Applications`, never one containing `AppTranslocation`:

```bash
ps -ww -p "$(pgrep -x Whisperino | head -1)" -o command=
```

Capture these diagnostics with every failed fresh-install report:

```bash
sw_vers
uname -m
xattr -l /Applications/Whisperino.app
codesign -dv --verbose=4 /Applications/Whisperino.app
codesign -dr - /Applications/Whisperino.app
```

## Upgrade path

Keep a second disposable account with the previous public version installed.
Grant its permissions, verify one transcription, update from Whisperino's menu,
follow the Accessibility re-grant prompt for the current ad-hoc release, then
repeat the focus-switch test. Once releases use Apple Developer ID signing and
notarization, replace the expected re-grant with a check that permission is
preserved.

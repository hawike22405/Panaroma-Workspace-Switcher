# Orbit Wheel + Zen Nebula: Sine installation and recovery

## Why it stopped responding
Nebula uses Sine, whose newer versions manage privileged scripts through their own loader. Files previously copied to `chrome/JS` for fx-autoconfig may no longer execute. An inactive `Ctrl+Alt+O` shortcut is consistent with Orbit not being loaded, though logs are needed to confirm.

## Install the Sine-compatible Orbit without uninstalling Nebula
1. Open `about:profiles` in Zen. Back up the **active** profile first.
2. Open **Zen Settings → Sine** and leave **Nebula enabled**.
3. In Sine's General settings, enable **Enable installing JS from unofficial sources** only after reviewing Orbit's source and accepting the risk of privileged browser-chrome scripts.
4. In Sine's custom/unpublished-mod installation field, paste the branch/folder URL:
   `https://github.com/hawike22405/Panaroma-Workspace-Switcher/tree/zen-orbit-wheel/zen-orbit-wheel`
5. Install **Zen Orbit Wheel** and verify that both **its CSS and JS script are enabled**. Restart Zen fully.
6. Test `Ctrl+Alt+O` first; the Ctrl+Tab interception remains experimental.
7. After Orbit loads under Sine, disable the previous **manual** Orbit files if the old fx-autoconfig loader is still active, avoiding two copies of Orbit. Do **not** delete Sine or Nebula's shared files.

Sine supports `owner/repo/tree/branch/folder` paths; if your Sine version cannot install a nested branch, the Sine-ready files are also in the downloadable ZIP, and can be moved into a standalone repository root as an alternative.

## Still no wheel?
- Check the **Sine mod toggle**, **script toggle**, and the unofficial JS permission.
- Check Zen's **Browser Console** (often `Ctrl+Shift+J`) for `[OrbitWheel]` errors.
- Confirm you're in the same profile where Sine and Nebula are installed.
- Check for previous manual Orbit copies on Linux:
  `find ~/.config/zen ~/.zen -type f \\( -name 'OrbitWheel.uc.js' -o -name 'OrbitWheel.uc.css' \\) 2>/dev/null`
- **Do not reinstall fx-autoconfig over Sine's `config.js` or delete the `chrome/utils` directory.**

## Revert
Disable or uninstall **Zen Orbit Wheel** from Sine only. Nebula remains enabled.

## Verification level
Manifest paths and JavaScript syntax are checked; runtime loading in your particular Zen/Sine installation is not yet verified.

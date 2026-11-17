# WeChat 270353 screenshot persistence implementation plan

> Execute in this archive workspace; no `.git`, commits or pushes. User explicitly requested persistent screenshot behavior after the one-time native release was verified.

**Goal:** In the pinned 270353 arm64 client, prevent `pc_forbid_screenshot` from reactivating screenshot exclusion after restart while retaining the completed recall behavior and marker layout.

**Architecture:** Reuse the existing static patch manifest and all-before-write validation. Change only the screenshot-command factory `HandleScreenshot` at `0x3a50138` to return native success (`mov w0,#1; ret`), without posting the privacy activation task. The adjacent `rpa_strike_for_pc` command and unrelated privacy/audio paths retain original instructions.

**Tech Stack:** Existing Swift/ArgumentParser patcher and XCTest; system native APIs for the arm64 instruction probe. No new dependency or persistent polling.

## Evidence and constraints

- arm64 UUID `8CB5F29E-FC1D-3D47-897A-272A4651E916`; target build `270353` only.
- Frozen factory prologue: `FF0302D1F85F04A9`; replacement `20008052C0035FD6`.
- Original route: XML security message `gog_wcs_plugin_config` → `pc_forbid_screenshot` → `HandleScreenshot` → temporary WCProbe privacy state.
- Temporary native release was user-authorized and real-user verified for both macOS and WeChat screenshots without restarting. It did not survive a later process restart.
- User has authorized permanent treatment and previously declined original-app backups. Validate a copy before applying to the installed client; do not overwrite a running app.
- Re-signing may invalidate the current TCC code-identity grant; check the actual process permission and request the user's normal system authorization only if it is missing.
- This survives process restarts, not replacement by a future official build. Do not claim support for other builds or automatic-update persistence.

## Tasks

1. [x] Add patcher integration regressions using the actual checked-in profile, an independent native prologue fixture, idempotent patching and unchanged adjacent bytes. Add rejection for changed original instructions. A test-only Objective-C++ probe reads the same manifest using system Foundation, executes its arm64 entry and requires native success for dummy request pointers. Watch failures before adding the profile entry.
2. [x] Add the one-entry screenshot target to the existing 270353 manifest. Run the full tests and universal Release build; review the exact binary scope independently.
3. [x] Patch and strictly verify the existing validation copy and its exact code changes.
4. [x] Apply the verified build/config to the installed client after it exits. Confirm the native factory acknowledges requests without enabling privacy, verify startup state, signature, runtime/profile, TCC status and real screenshots across restart. Record actual outcomes and limitations in README and this ledger.

## Progress

- RED: both new Swift integration tests failed on the missing manifest target. The native probe independently failed on missing acknowledgement bytes; existing 7 ABI checks remained green.
- GREEN: full `make test` passed 20 XCTest tests, 0 failures, 7 existing ABI checks and 2 screenshot acknowledgement checks. Universal Release `make build` passed.
- Independent review found no blocking issue; confirmed bool return ABI, unique caller, unchanged outer timestamp/device validation and untouched adjacent security command. Report: `/tmp/wechat270352-codex/review-permanent-capture.md`.
- Validation copy patched and `codesign --verify --deep --strict` passed. Compared against frozen original: only the existing three hook ranges and new 8-byte screenshot range differ in arm64 `__text`; Intel `__text` is identical. Report: `/tmp/wechat270352-codex/permanent-capture-binary-scope.json`.
- Ruling: combine live startup/restart testing with final installation rather than run two identically patched app copies against the same account container. Offline validation-copy scope/signing and native execution checks are complete; installed-client live verification remains mandatory.
- User saved drafts, exited and explicitly authorized installation/restart verification. Applied the reviewed configuration to `/Applications/WeChat.app` with the local Release CLI; strict signature verification passed. Installed factory entry verified as `20008052c0035fd6`.
- First normal startup PID95201: loaded factory bytes match, actual native acknowledgement returns 1, temporary privacy bytes are all zero, weshot_disable is zero, runtime is loaded and real NSWindows have sharingType=1. No temporary native-stop call was made after installing this change.
- First startup screen-capture preflight returned false after re-signing. User was asked to reauthorize the updated app, restart it through the normal permission flow, and verify both screenshots and existing recall markers.
- Final user result: `重开后两种截图及撤回标记都正常`. Current process PID15363 differs from first-start PID95201, confirming actual process restart. Read-only postcheck: factory bytes match, native acknowledgement=1, privacy state remains all zero, weshot_disable=0, runtime loaded. No one-time stop interface was used in either new process. Strict installed-app signature verification passed.
- Final debugger preflight still reported false despite the user's successful real WeChat screenshot test. No broad OS recording-permission claim is made; no further permission reset was performed because the requested screenshots work in actual use. The screenshot exclusion state and instruction handler behavior were independently verified.
- Complete for 270353 arm64 process-restart persistence. Official app replacement/update can remove the patch; no support claimed for other builds or update persistence. No commits or pushes.

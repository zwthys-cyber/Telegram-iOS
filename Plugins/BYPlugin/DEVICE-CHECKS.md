# BYPlugin 2.2 installed-app check

CI verifies the real Postbox/state-manager paths and plugin injection in a simulator. It does not verify a signed device installation or the new chat/Quick Look interface. The interactive XcodeBuildMCP tools are not exposed in this session; the root CLAUDE.md “Driving the simulator UI” section hands these checks to the installed-app user.

Expected presentation before checking:
- After received timed content expires, its text or saved media remains at its original chat position with “Kept locally · visible only to you”. It must not appear twice or move to the newest-message position.
- Images remain images; videos/files open the archived local file. A missing file shows an explicit unavailable message, not a successful-save claim.
- Open/close preview and share using system navigation, in light/dark appearance and portrait/landscape; content and controls stay inside safe areas without a covered top row or clipped bottom control.
- These local rows offer local actions only; they do not send reactions, replies, read receipts or restore deleted cloud messages.

Use the matching 2.2 IPA and dylib, injected during signing. Settings → BYPlugin should show version 2.2 active.

1. Enable recalled/edited history and media saving. Receive and fully download an image, MP4 and document in a test chat. Have the sender recall them. Open the recall marker/history; preview and export each file.
2. Separately enable received timed-content retention. Receive and open a timed photo and a view-once video/voice message. Let the timer expire or close the viewer. Check the retained content in the original chat, then reopen the chat after restarting the app.
3. Clear Telegram's ordinary media cache and reopen the retained files. Clearing the dedicated BY history record should remove its retained row and files. A preview already open during clearing should remain readable until dismissed.
4. Turn retention off and test a new timed message: ordinary expiry should resume. Paid content and secret-chat expiry should behave as before.
5. Check an older metadata-only record: missing media must be reported accurately. Test a second account to confirm the first account's history is not shown.

If recording UI transitions, follow root AGENTS.md: capture opening/closing and scrolling, then evaluate labelled frames against the expectations above. A successful compile is not a visual verification.

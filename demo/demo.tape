# DomainSaver demo — a real Codex skill run in about 25 seconds of playback.
#
# Render from the repository root:
#
#   PORKBUN_API_KEY=... PORKBUN_SECRET_KEY=... vhs demo/demo.tape
#
# Output: demo/demo.gif
#
# Requirements:
#   * Codex CLI installed and signed in with a ChatGPT account.
#   * The domain-search skill installed with ./install.sh.
#   * PORKBUN_API_KEY / PORKBUN_SECRET_KEY exported for the live quote.
#   * Public registry and Porkbun endpoints reachable from the recording host.
#
# No response is staged. Codex invokes the installed skill, which runs the
# repository's registry check and authenticated registrar quote. The tape hides
# the model's wait time, not its command or result. Re-render whenever Codex or
# the CLI output changes so the GIF cannot drift from the real workflow.
# `danger-full-access` is limited to this ephemeral task because the recording
# needs live registry and registrar networking. Render only from a checkout you
# trust; the prompt explicitly keeps the repository read-only.

Output demo/demo.gif

Require codex

Set Shell bash
Set FontSize 18
Set Width 1500
Set Height 560
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 32ms
Set PlaybackSpeed 1.0
Set WaitTimeout 90s

# Render from the repository root. Avoiding a hard-coded path keeps the public
# asset portable and prevents the renderer's home directory appearing in it.
Hide
Type "clear" Enter
Show

Sleep 700ms

# --- Act 1: prove Codex is using ChatGPT authentication -----------------
Type "# DomainSaver runs as a Codex skill using your ChatGPT account." Enter
Sleep 900ms
Type "codex login status" Enter
Wait+Screen@10s /Logged in using ChatGPT/
Sleep 1400ms

# --- Act 2: invoke the skill through the Codex CLI ----------------------
Type "" Enter
Type "# Ask Codex to verify the registry result with a real registrar quote." Enter
Sleep 1100ms
Type "codex exec --ignore-user-config --ephemeral -s danger-full-access -c model_reasoning_effort=low '$domain-search Check shed.link with a registry lookup and live registrar quote. Reply in four lines with domain, registry/list renewal, registrar/quoted renewal, and why they differ. Do not modify files.' 2>/dev/null" Enter

# The live quote and model response take roughly 30 seconds. Keep the render
# deterministic and concise by waiting for the result without recording blank
# frames; Show resumes on the actual completed terminal screen.
Sleep 600ms
Hide
Wait+Screen@90s /PREMIUM/
Show
Sleep 3800ms

# --- Act 3: state the safety boundary -----------------------------------
Type "" Enter
Type "# Unregistered is not available. Codex checked instead of guessing." Enter
Sleep 2200ms
Type "# github.com/stephenlclarke/DomainSaver" Enter
Sleep 2800ms

# ---------------------------------------------------------------------------
# Social exports (LinkedIn wants video, not GIF). Regenerate from demo.gif:
#
#   16:9 — ffmpeg -y -i demo/demo.gif -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
#            -vf "scale=1920:-2:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0x1e1e2c,format=yuv420p" \
#            -c:v libx264 -preset slow -crf 20 -r 30 -c:a aac -b:a 96k -shortest \
#            -movflags +faststart demo/demo-16x9.mp4
#
#   1:1  — same, with scale=1080:-2 and pad=1080:1080
#
# The silent AAC track is deliberate: some platforms mishandle a video stream
# with no audio stream at all. format=yuv420p and even dimensions are required
# for H.264 to play everywhere.

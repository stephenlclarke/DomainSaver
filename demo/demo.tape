# DomainSaver demo — the whole pitch in ~25 seconds.
#
# Render:  vhs demo/demo.tape
# Output:  demo/demo.gif
#
# REQUIRES PORKBUN_API_KEY / PORKBUN_SECRET_KEY in the environment. Without
# them quote.sh cannot make a per-name call, and the reveal (the entire point
# of the demo) degrades to a "no credentials" message.
#
# The numbers below are not staged: shed.link really is quoted at $819.27/yr
# against a $7.72 list price. Re-render whenever the CLI output changes so the
# GIF can never drift from reality.

Output demo/demo.gif

Set Shell bash
Set FontSize 18
# quote.sh's table is ~115 columns. Narrower than this and the NOTES column
# wraps, which is exactly the row a viewer needs to read in one glance.
Set Width 1500
# Height is deliberately tight: each act is ~13 lines, and any spare rows
# become dead space that dominates the frame once the GIF is letterboxed
# into a square or 16:9 video for social.
Set Height 480
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set PlaybackSpeed 1.0

# No `cd`: vhs inherits the working directory, so render from the repo root
# (`vhs demo/demo.tape`). Hard-coding a path both breaks for other people and
# prints the renderer's home directory into a public asset, because check.sh
# names the absolute path to quote.sh in its warning.
Hide
Type "clear" Enter
Show

Sleep 800ms

# --- Act 1: what every other tool tells you ------------------------------
Type "# Every domain tool says this name is available." Enter
Sleep 1200ms
Type "./scripts/check.sh shed.link" Enter
Sleep 6s

# --- Act 2: the tool refuses to say 'available' --------------------------
Type "" Enter
Type "# UNREGISTERED. Not AVAILABLE. It will not guess." Enter
Sleep 2s
Type "# $7.72 is the TLD list price, not a quote for this name." Enter
Sleep 2500ms

# --- Act 3: the reveal ---------------------------------------------------
Type "clear" Enter
Sleep 500ms
Type "# So ask the registrar what it actually costs." Enter
Sleep 1200ms
Type "./scripts/quote.sh shed.link" Enter
Sleep 7s

Type "" Enter
Type "# $819.27/yr. 106x the list price." Enter
Sleep 2500ms
Type "# github.com/jhammant/DomainSaver" Enter
Sleep 3s

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

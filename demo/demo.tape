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
Set FontSize 20
Set Width 1240
Set Height 760
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set PlaybackSpeed 1.0

Hide
Type "cd ~/dev/DomainSaver && clear" Enter
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

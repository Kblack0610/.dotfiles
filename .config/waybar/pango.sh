# shellcheck shell=bash disable=SC2034  # the colours are for the scripts that source this
# pango.sh - markup helpers for the waybar load, CI, day, dispatch, agents and health chips (load.sh, ci_runners.sh, day.sh, dispatch.sh, ai_agents.sh, health.sh). The
# Prometheus reader they share with the hub board is .local/lib/prom.sh.

# Bar theme (Jackie Brown) colours, the set fleet_pulse.sh uses: the pale Catppuccin
# amber is invisible on the dark bar. Indexed by status level: 0 ok, 1 warn, 2 red,
# the scale the cc:*_status rules use.
LEVEL_COLOUR=("#a6e34a" "#ffcc2f" "#ef5734")
LEVEL_CLASS=(ok warn critical)
C_GRN="${LEVEL_COLOUR[0]}"
C_YEL="${LEVEL_COLOUR[1]}"
C_RED="${LEVEL_COLOUR[2]}"

# A bar module must not stall the bar on a dead endpoint; the board waits 10s.
PROM_TIMEOUT=5

# Pango markup escape for text that came from outside (run titles, job names). The
# replacements are quoted: bash 5.2's patsub_replacement makes a bare & mean "the match".
pango_esc() {
  local s="$1"
  s="${s//&/"&amp;"}"
  s="${s//</"&lt;"}"
  s="${s//>/"&gt;"}"
  printf '%s' "$s"
}

# paint <colour> <text>
paint() { printf "<span color='%s'>%s</span>" "$1" "$2"; }

# emit <text> <tooltip> <class>: waybar JSON, escaped by jq.
emit() {
  jq -cn --arg t "$1" --arg tt "$2" --arg c "$3" '{text: $t, tooltip: $tt, class: $c}'
}

# pango_ansi: stdin Pango (the tooltips above) to stdout terminal text, for the control menu's
# preview. <b> is bold, <span color|foreground='#rrggbb'> truecolour, <span alpha> dim, <tt>
# nothing (the terminal is monospace); a close restores the tags still open. NO_COLOR strips.
pango_ansi() {
  perl -CSD -0777 -pe '
    my @open;
    s{<(/?)(b|tt|span)\b([^>]*)>}{
      my ($close, $tag, $attr) = ($1, $2, $3);
      if ($close) { pop @open; $ENV{NO_COLOR} ? "" : "\e[0m" . join("", @open) }
      else {
        my $e = "";
        if ($tag eq "b") { $e = "\e[1m" }
        elsif ($tag eq "span" && $attr =~ /(?:color|foreground)=.#([0-9a-fA-F]{6})/) {
          $e = sprintf("\e[38;2;%d;%d;%dm", map { hex } unpack("A2A2A2", $1));
        }
        elsif ($tag eq "span" && $attr =~ /alpha=/) { $e = "\e[2m" }
        push @open, $e;
        $ENV{NO_COLOR} ? "" : $e;
      }
    }ge;
    s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/\x27/g; s/&#39;/\x27/g; s/&amp;/&/g;
  '
}

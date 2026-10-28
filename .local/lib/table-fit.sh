# shellcheck shell=bash
# table-fit.sh (sourced) - fit a tab-led TSV table to a terminal width: the one column
# fitter the terminal boards share (fleet-sessions watch, command-center.sh).
#
# Lines starting with a TAB are table rows (the first is the header); other lines pass
# through. Columns take their content's width and drop from the least important end until
# the rest fit; the flex column takes what is left. Every line is clipped with ~.
#
#   table_fit <width|0> keep="1 3 2" [flex=4] [flexmin=12] [opt="3"] [right="2"] [cap="1:34"]
#
# keep: most important first, the first never drops. opt: hidden while every body cell is
# "-" or "no". right: right-aligned. cap: col:max width.

table_fit() {
  local w="${1:-0}" keep="" flex=0 flexmin=12 opt="" right="" cap="" a
  shift
  for a in "$@"; do
    case "$a" in
      keep=*) keep="${a#keep=}" ;;
      flex=*) flex="${a#flex=}" ;;
      flexmin=*) flexmin="${a#flexmin=}" ;;
      opt=*) opt="${a#opt=}" ;;
      right=*) right="${a#right=}" ;;
      cap=*) cap="${a#cap=}" ;;
      *) echo "table_fit: unknown option $a" >&2; return 2 ;;
    esac
  done
  awk -F'\t' -v W="$w" -v KEEP="$keep" -v FLEX="$flex" -v FLEXMIN="$flexmin" \
      -v OPT="$opt" -v RIGHT="$right" -v CAP="$cap" '
    function clip(s, w) { return (w > 0 && length(s) > w) ? substr(s, 1, w - 1) "~" : s }
    BEGIN {
      GAP = 2
      n_keep = split(KEEP, keep, " ")
      n = split(OPT, c, " "); for (i = 1; i <= n; i++) optional[c[i]] = 1
      n = split(RIGHT, c, " "); for (i = 1; i <= n; i++) rjust[c[i]] = 1
      n = split(CAP, c, " "); for (i = 1; i <= n; i++) { split(c[i], kv, ":"); capw[kv[1]] = kv[2] }
    }
    { line[NR] = $0 }
    /^\t/ {
      is_row[NR] = 1; hdr = !rows++
      if (NF - 1 > ncol) ncol = NF - 1
      for (j = 1; j <= NF - 1; j++) {
        v = $(j + 1); cell[NR, j] = v
        if (length(v) > wid[j]) wid[j] = length(v)
        if (!hdr && j in optional && v != "-" && v != "no") used[j] = 1
      }
    }
    END {
      for (j in capw) if (wid[j] > capw[j]) wid[j] = capw[j]
      total = -GAP
      for (k = 1; k <= n_keep; k++) {
        j = keep[k]
        if (j in optional && !used[j]) continue
        on[j] = 1; total += wid[j] + GAP
      }
      for (k = n_keep; W > 0 && total > W && k > 1; k--)
        if (keep[k] in on) { delete on[keep[k]]; total -= wid[keep[k]] + GAP }
      if (FLEX > 0) on[FLEX] = W == 0 || W - total - GAP >= FLEXMIN
      for (r = 1; r <= NR; r++) {
        if (!is_row[r]) { print clip(line[r], W); continue }
        out = ""
        for (j = 1; j <= ncol; j++) {
          if (!on[j]) continue
          v = clip(cell[r, j], wid[j])
          if (j == FLEX) v = cell[r, j]
          else if (j in rjust) v = sprintf("%" wid[j] "s", v)
          else v = sprintf("%-" wid[j] "s", v)
          out = out (out == "" ? "" : sprintf("%" GAP "s", "")) v
        }
        sub(/ +$/, "", out); print clip(out, W)
      }
    }'
}

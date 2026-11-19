# unit-jobs.awk -v c=<cores> [-v min=<floor, default 2>] <loadavg file> -> the cores free by that load (run-bats.sh admits runs and sizes `--jobs auto` with it).
# Busy is the larger of the 1-minute load ($1) and the processes running now (the n of $4's
# n/total, less this awk); free is c minus busy, rounded, floor min (2 unless given; run-bats.sh asks for 0). No line read prints 2.
NR == 1 {
  split($4, r, "/")
  busy = $1 + 0
  if (r[1] - 1 > busy) busy = r[1] - 1
  m = (min == "" ? 2 : min + 0)
  f = int(c - busy + 0.5)
  print (f < m ? m : f)
}
END { if (NR == 0) print 2 }

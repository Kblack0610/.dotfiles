# unit-jobs.awk -v c=<cores> <loadavg file> -> the bats --jobs for the unit tier (tests/Makefile).
# Busy is the larger of the 1-minute load ($1) and the processes running now (the n of $4's
# n/total, less this awk); free is c minus busy, rounded, floor 2. No line read prints 2.
NR == 1 {
  split($4, r, "/")
  busy = $1 + 0
  if (r[1] - 1 > busy) busy = r[1] - 1
  f = int(c - busy + 0.5)
  print (f < 2 ? 2 : f)
}
END { if (NR == 0) print 2 }

# Blind brief template

Fill the angle-bracket fields and pass the result as the whole prompt to a fresh Agent (`general-purpose` or `claude`, never `fork`). Add nothing else: no summary of the existing plan, no hint at what you think the answer is.

---

<The original ask, in the human's words, with the facts they gave. Not your restatement of it.>

Work from the repo snapshot at `<snapshot path>`. It is the code as it stood before anyone answered this question. Read-only data you may use: <live read-only sources: dashboards, Prometheus, `gh run list`, logs, the cluster with get/describe only>.

Do not read, list or search any of these, even if something points you there: `~/.claude*/plans/`, `~/.agent/`, `~/.notes/`, `<live checkout path>`, and git history of any kind (`git log`, `git show`, `git blame`, `git diff`). Do not edit anything, start anything or post anything.

Return: your recommended approach, the evidence behind each claim (file:line in the snapshot, or the command and its output), what it costs, its risks, and what you could not check.

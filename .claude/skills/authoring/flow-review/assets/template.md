# <Who does what, start to finish>

<project> - <flow> review - <env>

<One paragraph: which account does what, on which surfaces and viewports, against which env and commit, on what date. Say whether anything real happened (sandbox payment, test inbox).>

- **Web** <url>
- **App** <url or build>
- **Commit** <sha>

**<N> fix - <N> polish - <N> verify**

## <Surface, e.g. Web>

<One line: what this surface covers and anything the reader must know to read the steps.>

### 1. <Step name>

<One line: what the user does and what they see.>

- **FIX** <A defect a user would notice. file:line when known.>
- **POLISH** <Works, but looks or reads wrong.>
- **VERIFY** <Cannot be judged in this env; say where and what to check.>
- **OK** <Checked and right. Include these; they tell the reader what was covered.>

![Desktop](shots/01-<step>-desktop.png)
![Phone](shots/02-<step>-phone.png)

## What this is not

<Test data vs real data, surfaces not run (native device, prod), anything a reader could wrongly generalize from.>

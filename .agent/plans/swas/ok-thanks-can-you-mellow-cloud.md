# Plan: ClickUp Fleet Ticket — Minimal Critical Updates

## Context
All fleet management tickets are still "unprocessed requests" with no priorities and missing due dates.
R1 deck is due in 6 days (May 19). Goal: apply the smallest set of updates that makes scheduling visible and accurate.

## Changes

### 1. R1 Deck (`86e1bp68j`) → in progress + high priority
- Status: `unprocessed requests` → `in progress`
- Priority: set to **high** (2)

### 2. R1 Subtask: existing BS deployment (`86e1bpc5j`) → in progress + due date
- Status: `unprocessed requests` → `in progress`
- Due date: **May 16** (must be done before R1 on May 19)

### 3. R1 Subtask: virgin BS deployment (`86e1bpbka`) → in progress + due date
- Status: `unprocessed requests` → `in progress`
- Due date: **May 17**

### 4. Initial Deployment System (`86e1bpgme`) — add missing due date
- Due date: **June 4, 2026** (per notes; ClickUp currently blank)

### 5. High-level Deliverables Breakdown (`86e1bpk74`) — set priority
- Priority: **high** (2)

### 6. R2 Deck (`86e1bp89c`) — set priority
- Priority: **normal** (3) — starts after R1 delivers

## What's intentionally skipped
- No description edits (descriptions are already clear enough)
- No start-date changes
- No changes to R2 subtasks (none exist)
- Pacman POC (`86e1burn3`) excluded from scope per prior decision

## Tools
`clickup_update_task` for each ticket above — 6 calls, can be parallelized where statuses don't conflict.

## Verification
- Re-fetch all 6 tickets and confirm status/priority/due_date fields match expected values.

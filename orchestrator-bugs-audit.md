# Orchestrator Bugs Audit

**Date:** 2026-01-28
**Sessions Audited:**
- `58` (parent orchestrator)
- `66` (parent orchestrator)
- `cms-dmd-backoffice-cms-58_002-e2e-tests-implementation-cms58` (workflow)
- `cms-dmd-backoffice-cms-66_001-implemente2etestspr` (workflow)

---

## Bug Fix Checklist

| # | Bug | Priority | Status |
|---|-----|----------|--------|
| 1 | [x] Workflow directory not found (schedule-checkin.sh) | High | Fixed |
| 2 | [x] Bash multi-line command parsing (PM training) | Low | Fixed |
| 3 | [x] .workflow/agents directory not found | Medium | Fixed |
| 4 | [x] Workflow status not updated on completion | High | Fixed |
| 5 | [x] Model mismatch (name:role:model parsing) | Medium | Fixed |
| 6 | [x] Check-in display text overlap | High | Fixed |
| 7 | [x] Empty check-in display pane | Medium | Fixed |
| 8 | [x] Remove "start loop" option from PM workflow | Medium | Fixed |
| 9 | [x] Model mismatch persists - agents deploy with wrong model | High | Fixed |
| 10 | [x] PM not asking clarifying questions (reported - needs investigation) | Medium | Fixed |
| 11 | [x] PM uses Task tool instead of create-team.sh for agents | High | Fixed |

**Priority Order:** 11, 9, 8, 10 (new bugs)

---

## Bug 1: Workflow Directory Not Found (CMS-66)

**Session:** `cms-dmd-backoffice-cms-66_001-implemente2etestspr:0` (PM pane)

**Error:**
```
Error: Workflow directory not found: .workflow/001-implemente2etestspr
```

**Root Cause:** PM ran `schedule-checkin.sh` from the `e2e/` subdirectory instead of project root. The script looks for `.workflow/` relative to current working directory.

**Impact:** Check-ins fail to schedule when PM is in wrong directory.

**Suggested Fix:**
- Option A: Modify `schedule-checkin.sh` to auto-detect project root (find .workflow directory upward)
- Option B: Add validation/warning when script detects it's not in project root
- Option C: Add PM instruction to always `cd` to project root before scheduling

---

## Bug 2: Bash Multi-line Command Parsing Error (CMS-58)

**Session:** `cms-dmd-backoffice-cms-58_002-e2e-tests-implementation-cms58:0` (PM pane)

**Error:**
```
tail: echo: No such file or directory
tail: : No such file or directory
tail: === qa-validator (window 2) last 20 lines ===: No such file or directory
tail: tmux: No such file or directory
tail: capture-pane: No such file or directory
```

**Root Cause:** PM attempted to run multi-line bash command:
```bash
tmux capture-pane -t "$SESSION:1" -p | tail -30
echo ""
echo "=== qa-validator (window 2) last 20 lines ==="
tmux capture-pane -t "$SESSION:2" -p | tail -20
```

The newlines were not properly escaped, causing `tail` to interpret each subsequent line as a filename argument.

**Impact:** PM status checks fail silently with confusing error output.

**Suggested Fix:**
- PM training/instructions: Use `&&` to chain commands or put in script
- Or: Use semicolons to separate commands in single-line bash

---

## Bug 3: .workflow/agents Directory Not Found (Session 66)

**Session:** `66:0` (parent orchestrator)

**Error:**
```
"/Users/personal/dev/gnarlysoft/cms-dmd-backoffice-CMS-66/.workflow/agents/": No such file or directory (os error 2)
```

**Root Cause:** Attempted to access `.workflow/agents/` before it was created, or incorrect path structure.

**Impact:** Workflow initialization may have failed or be incomplete.

**Suggested Fix:**
- Ensure `init-workflow.sh` creates all required directories
- Add directory existence checks before accessing

---

## Bug 4: Workflow Status Not Updated When All Tasks Complete (CMS-66)

**Session:** `cms-dmd-backoffice-cms-66_001-implemente2etestspr`

**Observed:**
- `status.yml` shows `status: in-progress`
- `tasks.json` shows ALL 12 tasks as `completed`
- No pending check-ins (check-ins stopped)

**Expected:** When all tasks are completed, workflow status should update to `completed`.

**Root Cause:** No automatic mechanism to detect task completion and update workflow status.

**Impact:** Workflows appear incomplete even when finished. PM/orchestrator can't easily identify completed workflows.

**Suggested Fix:**
- Add workflow completion detection in check-in loop
- When all tasks are `completed`, auto-update `status.yml` to `status: completed`
- Or: Add a `complete-workflow.sh` script for PM to call

---

## Bug 5: Model Mismatch - agents.yml Name vs Model Field (CMS-66)

**Session:** `cms-dmd-backoffice-cms-66_001-implemente2etestspr`

**agents.yml content:**
```yaml
- name: qa-implementer:developer:opus
  role: qa-implementer:developer:opus
  model: sonnet    # <-- CONTRADICTS name suffix

- name: qa-validator:qa:opus
  role: qa-validator:qa:opus
  model: sonnet    # <-- CONTRADICTS name suffix
```

**User's Request:** "All agents should use opus model"

**Actual Result:** Agents are running Sonnet 4.5 (visible in status bar)

**Root Cause:** The `name:role:model` format in agent names was not parsed. The explicit `model:` field took precedence, but it defaulted to `sonnet` instead of using the model from the name.

**Impact:** Agents run with wrong model, potentially affecting quality/cost of work.

**Related:** This was the bug we fixed earlier in `create-team.sh` - but the agents.yml was written before the fix was applied.

**Suggested Fix:**
- When parsing agents.yml, extract model from `name:role:model` format
- Or: Ensure PM specifies model correctly when creating agents.yml

---

## Bug 6: Check-in Display Text Overlap/Garbage (CMS-58)

**Session:** `cms-dmd-backoffice-cms-58_002-e2e-tests-implementation-cms58:0.0`

**Observed Output:**
```
[done]    17:06:02  Check team progresssks remaining)
```

**Expected:**
```
[done]    17:06:02  Check team progress
```

**Root Cause:** Previous line content not fully cleared before writing new content.

Hex analysis confirms:
```
progresssks remai  <- "progress" + leftover "sks remaining"
remaining))        <- "remaining)" + leftover ")"
```

When a shorter note (19 chars) replaces a longer one (33 chars), the extra 14 characters remain.

**Impact:** Display looks messy and confusing.

**Technical Issue:** The Python code inside `checkin-display.sh` uses `print()` without clearing to end of line. The `\033[J` (clear to end of screen) only runs AFTER the Python code, so individual lines aren't cleared.

**Additional Finding (17:34):** Display is duplicating content - multiple "frames" stacked on top of each other. The `\033[2J\033[H` (clear screen + home) isn't fully clearing the pane. Text overlap still visible: `Check team progressasks remaining)`.

**Suggested Fix:**
- Add `\\033[K` to each Python print statement: `print(f'...\033[K')`
- Or: Pad each line to fixed width before printing
- Also consider using `tput clear` instead of escape sequences

---

## Bug 7: Empty Check-in Display Pane (CMS-66)

**Session:** `cms-dmd-backoffice-cms-66_001-implemente2etestspr:0.0`

**Observed:** Pane 0 shows completely empty output (only blank lines)

**Expected:** Should show check-in history and status

**Root Cause:** CONFIRMED - `checkin-display.sh` is NOT running in pane 0. The pane just has a `bash` shell.

Investigation showed:
- WORKFLOW_NAME env var is set correctly
- Workflow directory exists
- But pane 0 command is `bash`, not `checkin-display.sh`

The display script was never started or crashed and wasn't restarted.

**Impact:** No visibility into check-in status

**Suggested Fix:**
- Verify `checkin-display.sh` is running: `ps aux | grep checkin-display`
- Check if script errored out
- Restart display script if needed

---

## Bug 11: PM Uses Task Tool Instead of create-team.sh for Agent Creation

**Session:** `cms-dmd-backoffice-cms-66_001-implemente2etestspr`

**Issue:** When user asked PM to spawn developer + code-reviewer agents, PM incorrectly used:
1. First: `Task` tool with "Developer" prompt (sub-agent)
2. Then: `tmux-orchestrator:tmux-meta-agent` sub-agent

**Expected:** PM should directly run `create-team.sh` via Bash:
```bash
$HOME/dev/tools/tmux-orchestrator/bin/create-team.sh /path/to/project developer:developer:opus code-reviewer:code-reviewer:opus
```

**Root Cause:** PM instructions don't explicitly forbid using Task tool for agent creation. PM may confuse "delegate to agents" with "use Task tool sub-agents".

**Impact:** Agents created via Task tool are sub-processes, not tmux windows. They can't receive messages via send-message.sh or use notify-pm.sh.

**Suggested Fix:**
Add to PM constraints: "NEVER use Task tool or sub-agents to create team members. ALWAYS use create-team.sh directly via Bash."

---

## Bug 8: Remove "start loop" Option from PM Workflow

**Reported:** User request

**Issue:** The PM workflow still offers "start" vs "start loop" options. The "start loop" (ralph loop) feature is not needed and should be removed.

**Current Behavior:**
```
╔══════════════════════════════════════════════════╗
║  Type 'start' for manual check-ins              ║
║  Type 'start loop' for ralph loop               ║
╚══════════════════════════════════════════════════╝
```

**Expected:** Only "start" option should be shown.

**Impact:** Confusing UX, unnecessary option.

**Suggested Fix:**
- Remove "start loop" option from PM briefing template
- Remove ralph loop handling from PM workflow step 9
- Test thoroughly after change (E2E + manual)

---

## Bug 9: PM Doesn't Use Model Format When Creating Team

**Session:** `sync_001-createelectrondashboard`

**Issue:** When user approves a team with specific models (e.g., "all opus"), the PM calls `create-team.sh` without the model specification format.

**Observed:**
```bash
# PM approved: developer (opus), qa (opus), code-reviewer (opus)
# PM actually ran:
create-team.sh /Users/personal/dev/sync developer qa code-reviewer
# Instead of:
create-team.sh /Users/personal/dev/sync developer:developer:opus qa:qa:opus code-reviewer:code-reviewer:opus
```

**Result:** Developer and QA got default models (sonnet) instead of requested opus.

**Root Cause:** PM instructions don't tell PM to use `name:role:model` format when user specifies custom models.

**Impact:** Agents deploy with wrong models, affecting quality/cost.

**Suggested Fix:**
- Update PM instructions (step 5 and step 9a) to use `role:role:model` format when models are specified
- Example: If user approves "developer (opus)", PM should run `create-team.sh ... developer:developer:opus`

---

## Bug 10: PM Not Asking Clarifying Questions (Needs Investigation)

**Reported:** User report

**Issue:** User reports PM is not asking questions about features before suggesting agents - it just immediately proposes teams.

**Investigation Status:** Initial testing showed PM DID ask questions when:
- `initial_request` is empty (PM asked about authentication type)
- `initial_request` has vague content (PM still asked clarifying questions)

**Possible Causes:**
- May be intermittent
- May depend on how detailed the `initial_request` is
- May be specific to certain workflow paths

**Status:** Needs more investigation to reproduce consistently.

---

## Known Non-Issues (Not Orchestrator Bugs)

1. **Stop hook errors** - These are hook configuration issues, not orchestrator bugs:
   ```
   Stop hook error: Failed with non-blocking status code: No stderr output
   ```

2. **E2E test failures** - These are the actual work being done (tests failing due to code issues), not orchestrator problems.

3. **"File has not been read yet"** - Claude Code tool usage errors, not orchestrator.

---

## Recommendations

1. **Add project root detection** to `schedule-checkin.sh` - walk up directories to find `.workflow/`
2. **Add PM instructions** about staying in project root or using absolute paths
3. **Improve error messages** to suggest common fixes
4. **Add validation** in scripts to detect common misconfigurations

---

## Audit Status

- [x] Session 58 (parent) - Checked
- [x] Session 66 (parent) - Checked
- [x] CMS-58 workflow PM pane - Checked
- [x] CMS-58 workflow agent panes - Checked
- [x] CMS-66 workflow PM pane - Checked
- [x] CMS-66 workflow agent panes - Checked

**Next audit:** Continue monitoring for new issues

---

## Audit Log

| Time | Finding |
|------|---------|
| 17:25 | Initial audit - found Bugs 1-3 |
| 17:26 | Found Bug 4 - workflow status not updated when tasks complete |
| 17:26 | Communication check - PM ↔ Agent messaging working correctly |
| 17:27 | Test assertion errors in agents (expected - E2E work in progress) |
| 17:27 | Model mismatch detected in CMS-66 - see Bug 5 |
| 17:28 | Display text overlap in CMS-58 check-in pane - see Bug 6 |
| 17:28 | Empty check-in display in CMS-66 pane 0 |
| 17:29 | Check-in timing verified - 5 min intervals working correctly |
| 17:29 | Global registry (~/.tmux-orchestrator/registry.json) not found |
| 17:30 | Bug 6 persists - multiple lines show text overlap (extra chars at end) |
| 17:31 | All workflow files verified present and valid |
| 17:31 | CMS-58 check-ins confirmed working (5 min intervals) |
| 17:31 | Audit summary: 7 bugs found, monitoring continues |
| 17:33 | CMS-66 confirmed: 12/12 tasks done, status still "in-progress" (Bug 4) |
| 17:33 | CMS-58: 1/9 tasks done, agents actively working |
| 17:33 | No new orchestrator errors in last 10 minutes |
| 17:36 | Check-in fired successfully (done: 7, next in 5m) |
| 17:36 | Check-in system confirmed working correctly |
| 17:37 | CMS-58 progress: 2/9 tasks completed (was 1/9) |
| 17:37 | Both agents actively working, no new errors |
| 17:37 | CMS-58 rapid progress: 5/9 done, 1 in progress, 3 pending |
| 17:40 | Created bug-fix workflow session: tmux-orchestrator_001-fixorchestratorbugs |
| 17:41 | CMS-58 check-in #8 fired successfully |
| 17:41 | Bug-fix PM initialized, waiting for user attach |
| 17:43 | Bug-fix session attached, PM now working |
| 17:44 | Bug-fix PM created PRD and 7 tasks, waiting for team approval |
| 17:46 | CMS-58 check-in #9 fired successfully |
| 17:48 | Bug-fix PM proposed: 1 developer (sonnet) for all 7 bugs |
| 17:51 | CMS-58 check-in #10 fired, still 5/9 tasks |
| 17:56 | CMS-58 check-in #11 fired, still 5/9 tasks |
| 23:47 | Sent approval to bug-fix PM: use opus instead of sonnet |
| 23:49 | Bug-fix developer agent created (opus model) |
| 23:50 | CMS-58 ALL 9/9 TASKS COMPLETED! (status still in-progress = Bug #4) |
| 00:05 | Bug-fix developer completed: Bug 6 (display overlap), Bug 1 (directory detection), Bug 4 (completion detection), Bug 3 (agents dir) |
| 00:06 | Bug-fix developer enhanced Task 5: Added validation and debug output to model parsing |
| 00:12 | Bug-fix developer COMPLETED ALL 7 BUGS - notified PM with full summary |
| 00:12 | Developer summary: (1) \033[K clear codes, (2) find_project_root(), (3) status.yml completion, (4) agents path fixes, (5) model validation, (6) display auto-start delay, (7) bash docs |
| 00:15 | PM verified all fixes and marked workflow as completed |
| 00:16 | All changes committed: [main cf4a225] fix: Resolve 7 orchestrator bugs from audit |
| 00:16 | **BUG-FIX WORKFLOW COMPLETE** - All 7 bugs fixed and committed |
| 03:00 | User reported: PM not asking clarifying questions - added as Bug 10 for investigation |
| 03:05 | Tested PM question behavior - PM DID ask questions in tests (when initial_request empty or vague) |
| 03:10 | User reported: Remove "start loop" option - added as Bug 8 |
| 03:12 | User reported: Model mismatch in sync session - agents showing Opus but agents.yml says sonnet |
| 03:15 | Confirmed Bug 9: PM doesn't use name:role:model format when user specifies custom models |
| 03:15 | sync_001-createelectrondashboard: PM ran `create-team.sh ... developer qa code-reviewer` instead of using opus format |
| 03:20 | Sent new bugs 8-10 to PM in tmux-orchestrator_001-fixorchestratorbugs |
| 03:22 | PM updated PRD, added tasks, assigned to developer, restarted check-ins |
| 03:25 | Developer completed Bug 8: Removed 'start loop' from orchestrator.py |
| 03:25 | Developer completed Bug 9: Updated PM template for name:role:model format |
| 03:25 | Developer completed Bug 10: Fixed PM question skipping logic |
| 03:26 | Developer notified PM: All bugs 8-10 FIXED |
| 03:27 | PM marked workflow as completed (10/10 tasks done) |
| 03:28 | Commit created: [32cbb18] fix: Resolve PM workflow bugs 8-10 |
| 03:28 | **ALL 10 ORCHESTRATOR BUGS FIXED AND COMMITTED** |
| 03:35 | User reported Bug 11: PM in CMS-66 session used Task tool instead of create-team.sh |
| 03:36 | Bug 11 added to audit - PM tried Task tool then tmux-meta-agent instead of direct Bash |
| 03:37 | Sent Bug 11 to bug-fix session for immediate fix |
| 03:50 | DELETED agents/ folder - was creating unnecessary Task tool sub-agents |
| 03:50 | Removed tmux-orchestrator:Developer, :PM, :QA, :tmux-meta-agent from Task tool |
| 03:50 | Updated README.md to remove agents/ references |

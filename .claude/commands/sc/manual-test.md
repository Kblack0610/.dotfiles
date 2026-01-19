---
name: manual-test
description: "Manual PR testing using Playwright MCP and project-specific State/Seed APIs"
category: testing
complexity: enhanced
mcp-servers: [playwright]
personas: [qa-specialist]
---

# /sc:manual-test - Manual PR Testing with Playwright MCP

## Triggers
- PR verification when CI passes but manual testing needed
- Feature validation before merge
- Visual/behavioral verification across branches

## Usage
```
/sc:manual-test [pr-number|branch] [--project shack|gheeggle|sentinel] [--scenario specific-test]
```

## Behavioral Flow
1. **Discover**: Identify project type and load project config from `/projects/testing/g2i/{project}/`
2. **Setup**: Reset database with test data via State API
3. **Navigate**: Use Playwright MCP to interact with UI
4. **Verify**: Take snapshots, check elements, validate behavior
5. **Report**: Document pass/fail for each test scenario

## Project Configurations

All G2I apps share the same State API pattern:

### Common State API Pattern
- **Endpoint**: POST/GET/PATCH `/api/state`
- **Auth**: HTTP Basic Auth (default: `openai:voyager`)
- **Query Params**: `?strict=false` for lenient validation
- **Payload**: JSON with table names as keys, record arrays as values

### Shack (Slack clone)
- **Location**: `/home/kblack0610/dev/bnb/g2i/shack`
- **Base URL**: `http://localhost:80` (Docker) or `http://localhost:3000` (dev)
- **Key localStorage**: `searchQuery`, `committedQuery`, `recentSearches`
- **Config**: `/projects/testing/g2i/shack/config.json`

### Gheeggle (Google Sheets clone)
- **Location**: `/home/kblack0610/dev/bnb/g2i/gheeggle`
- **Base URL**: Same pattern as Shack
- **Config**: `/projects/testing/g2i/gheeggle/config.json`

### Sentinel
- **Location**: `/home/kblack0610/dev/bnb/g2i/sentinel`
- **Base URL**: Same pattern
- **Config**: `/projects/testing/g2i/sentinel/config.json`

## Playwright MCP Workflow

### Step 1: Setup Database
```javascript
// Use WebFetch or Bash curl to call State API
POST http://localhost/api/state?strict=false
Authorization: Basic b3BlbmFpOnZveWFnZXI=
Content-Type: application/json

// Payload from /projects/testing/g2i/{project}/seed-data.json
```

### Step 2: Navigate to App
```
mcp__playwright__browser_navigate({ url: "http://localhost" })
```

### Step 3: Set Authentication
```
mcp__playwright__browser_evaluate({
  function: "() => { localStorage.setItem('loggedInUserId', 'user_test'); }"
})
```

### Step 4: Navigate to Test Page
```
mcp__playwright__browser_navigate({ url: "http://localhost/client/{workspace}" })
```

### Step 5: Interact with UI
```
// Click elements
mcp__playwright__browser_click({ element: "Button", ref: "[data-testid='...']" })

// Type text
mcp__playwright__browser_type({ element: "Input", ref: "[data-testid='...']", text: "..." })

// Press keys
mcp__playwright__browser_press_key({ key: "Enter" })
```

### Step 6: Verify State
```
// Take accessibility snapshot
mcp__playwright__browser_snapshot({})

// Check localStorage/sessionStorage
mcp__playwright__browser_evaluate({
  function: "() => localStorage.getItem('key')"
})

// Take screenshot for visual verification
mcp__playwright__browser_take_screenshot({ filename: "test-result.png" })
```

## Common Test Patterns

### Search Testing (Shack)
1. Click `[data-testid="search-bar-button"]`
2. Type search query
3. Press Enter
4. Wait for results with `browser_wait_for`
5. Verify results with `browser_snapshot`

### Form Testing
1. Navigate to form page
2. Use `browser_fill_form` for multiple fields
3. Submit with `browser_press_key({ key: "Enter" })`
4. Verify success state

### Navigation Testing
1. Navigate to starting page
2. Perform action
3. Use `browser_navigate_back`
4. Verify state preservation with `browser_evaluate`

## Tool Coordination
- **Bash**: Git branch checkout, app startup, curl for State API
- **WebFetch**: Alternative for State API calls
- **Playwright MCP**: All browser interactions
- **Read**: Load config and seed data files
- **TodoWrite**: Track test progress

## Examples

### Test a Shack PR
```
/sc:manual-test 1577 --project shack
# Loads shack config, resets database, runs test scenarios for PR #1577
```

### Test Specific Scenario
```
/sc:manual-test --project gheeggle --scenario formula-editing
# Runs only the formula-editing test scenario
```

### Test Current Branch
```
/sc:manual-test --project shack
# Tests current branch using all applicable scenarios
```

## Boundaries

**Will:**
- Reset database state via State API for clean test environment
- Navigate and interact with UI via Playwright MCP
- Verify UI state through snapshots and element inspection
- Check localStorage/sessionStorage for state validation
- Document test results with pass/fail status

**Will Not:**
- Modify application code during testing
- Run automated E2E test suites (use `/sc:test --type e2e` for that)
- Make commits or push changes
- Test in production environments

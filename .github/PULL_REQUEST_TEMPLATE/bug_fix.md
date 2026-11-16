### Summary

Describe the bug fixed in harbor.wz and the user-visible workspace or session behavior
that changed.

### Reproduction

Provide the smallest setup that reproduced the issue.

```lua
-- setup or picker usage that reproduced the bug
```

### Root Cause

Explain why source discovery, session capture, restore, persistence, reload
behavior, or error handling was wrong.

### Fix

Describe the implementation change and why it fixes the problem.

### Regression Test

Describe the regression test added or updated.

### Compatibility Impact

- [ ] Non-breaking
- [ ] Potentially breaking
- [ ] Breaking

If this changes behavior intentionally, explain why the new behavior is correct.

### Checklist

- [ ] The change is scoped to harbor.wz.
- [ ] Public API changes are documented, if applicable.
- [ ] Picker, source, or session behavior is covered by tests, if applicable.
- [ ] Existing saved sessions remain compatible.
- [ ] Required checks pass:
  - [ ] `busted --verbose`
  - [ ] `luacheck plugin spec`
  - [ ] `stylua --check plugin spec`
  - [ ] `selene --display-style=quiet plugin`


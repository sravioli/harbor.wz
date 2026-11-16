### Summary

Describe the harbor.wz documentation change.

### Documentation Changed

List the README, examples, contributing guide, issue templates, pull request
templates, or annotation docs changed by this pull request.

### Reader Impact

Explain who benefits from this documentation change:

- Users managing workspaces and sessions in WezTerm.
- Contributors changing harbor.wz internals.

### Examples Touched

```lua
-- setup, picker, or session example changed by this pull request
```

### Behavior Change

- [ ] Documentation only
- [ ] Documents an existing behavior
- [ ] Documents a new behavior

If this documents a new behavior, link to the implementation pull request or
commit.

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


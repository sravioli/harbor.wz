### Summary

Describe the new harbor.wz feature and the user-facing workspace or session workflow it
enables.

### Motivation

Explain why this belongs in harbor.wz. Focus on the picker, sources, session capture/restore,
workspace naming, or WezTerm integration.

### API Sketch

```lua
-- show intended setup, picker, or session usage
```

### Behavior

Describe how the feature behaves, including default options, picker
results, saved session format, restore behavior, and failure cases.

### Compatibility

- [ ] Non-breaking
- [ ] Potentially breaking
- [ ] Breaking

If this is potentially breaking or breaking, explain the migration path.

### Tests

Describe the tests added or updated for this behavior.

### Documentation

Describe the README, examples, annotation, or template changes made for this
feature.

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


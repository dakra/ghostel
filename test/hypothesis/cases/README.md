# Saved Hypothesis render cases

JSON files in this directory are replayed by `make test-hypothesis-cases` and in CI.
When the full Hypothesis render property test fails, it writes the minimized failing
case here as `render-<hash>.json`; commit useful cases to keep them as regressions.

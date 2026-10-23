# Search

Find posts, communities, and users from the Search tab.

## Sub-features

- `search-posts`: submit a post query.
- `search-scope`: switch Communities and Users.
- `search-clear`: clear results.

## How to get to it (user POV)

Choose Search in the tab bar.

## Driving it with XcodeBuildMCP

Preconditions: Launch with `settings`, tap Search, and require the Search Reddit field. Focus its current ref, use type_text for `swift`, and submit using the keyboard Search action supported by the harness. Require results or an explicit empty result for the submitted query. Switch Communities and Users and check their corresponding result types. Use Clear if shown and require the empty search view. Capture query, scope, and visible results.

## Gotchas

- Results come from FixtureRedditClient, not current Reddit search.
- Inspect scope labels in the current snapshot before acting.
- If fixture data has no match, record that precondition; an empty result does not verify navigation into a matching result.

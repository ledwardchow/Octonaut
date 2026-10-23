# Post details and comments

Read a post and collapse or expand its replies.

## Sub-features

- `comments-open`: open detail from a feed row.
- `comments-collapse`: hide and restore a comment.

## How to get to it (user POV)

Posts > Home > A quiet walk above the coast. A direct detail launch is also available for diagnosis.

## Driving it with XcodeBuildMCP

Preconditions: Launch with `feeds`, open Home, then tap A quiet walk above the coast. Require the post title and the comment by morning_light containing The colours are lovely. That path looks peaceful. Capture the expanded state. Use the `Collapse comment` control exposed in the current snapshot; require its body to disappear and a collapsed row to remain. Use `Expand comment` and require the same text to return. Capture all actions and states.

## Gotchas

- A `detail` launch opens the coast post directly; it does not prove feed-row navigation.
- No nested screenshot comment children or more-comments node is seeded. Report those journeys as unavailable.
- Do not use Reply, votes, saves, or Report to establish real Reddit behavior with no account.

# Feature integration notes

The SwiftUI feature layer uses small presentation models (`PostCardModel`,
`CommentCardModel`, `CommunityCardModel`, `AccountCardModel`) so rows and
previews do not depend on Reddit DTO details. Each model has an initializer for
the corresponding Domain value. The store can be seeded with decoded Domain
values using:

```swift
LedditFeatureStore(
    domainPosts: FixtureData.posts,
    domainComments: FixtureData.comments,
    domainAccounts: FixtureData.accounts
)
```

`AppRootView` should replace its placeholder tab content with
`LedditTabsView(store:)`. The current store is fixture-backed and keeps local UI
actions working; a service-backed store can replace `refreshPosts`,
`refreshInbox`, and mutation methods while the views remain unchanged.

Media integration lives in `DesignSystem/LedditMediaComponents.swift` and is
used by feed rows, post detail, and gallery screens. `PostCardModel(post:)`
preserves image, thumbnail, gallery, video, and separate audio URLs. A Reddit
video with separate DASH audio is assembled into an `AVMutableComposition`
before playback. `PostDetailView` calls `LedditFeatureStore.loadPostDetail`,
which maps `PostThread` comments, `more`, and deleted nodes into the visible
comment tree.

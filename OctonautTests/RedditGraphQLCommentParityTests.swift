import XCTest

@testable import Octonaut

final class RedditGraphQLCommentParityTests: XCTestCase {
    func testWireRichTextStringRendersFormattingAndLinks() throws {
        let document = #"{"document":[{"e":"par","c":[{"e":"link","t":"Read this","u":"https://example.com","f":[[1,0,9]]}]}]}"#
        let content: [String: RedditJSONValue] = ["richtext": .string(document)]
        let result = try XCTUnwrap(RedditGraphQLRichText.decode(content, thingID: "t1_comment"))
        XCTAssertEqual(result.plainText, "[**Read this**](https://example.com)")
    }

    private func decode(_ json: String, visited: [String] = []) throws -> [CommentTreeNode] {
        try RedditGraphQLComments.decode(
            Data(json.utf8), postFullname: "t3_post", parentFullname: "t3_post",
            sort: .best, account: AccountID(), sessionGeneration: "session", visitedCursors: visited
        )
    }

    func testDeletedAncestorKeepsRepliesAndDoesNotBorrowSiblingID() throws {
        let nodes = try decode(#"{"data":{"postInfoById":{"commentForest":{"trees":[{"depth":0,"node":{"__typename":"DeletedComment"}},{"depth":1,"parentId":"t1_dead","node":{"__typename":"Comment","id":"t1_reply","authorInfo":{"name":"reader"},"content":{"markdown":"Reply"}}},{"depth":0,"node":{"__typename":"DeletedComment"}},{"depth":0,"node":{"__typename":"Comment","id":"t1_sibling","content":{"markdown":"Sibling"}}},{"depth":1,"parentId":"t1_sibling","node":{"__typename":"Comment","id":"t1_child","content":{"markdown":"Child"}}}]}}}}"#)
        XCTAssertEqual(nodes.count, 3)
        guard case .comment(let deleted) = nodes[0] else { return XCTFail("Deleted ancestor lost its children") }
        XCTAssertEqual(deleted.fullname, "t1_dead")
        XCTAssertNil(deleted.author)
        XCTAssertEqual(deleted.body?.plainText, "[deleted]")
        XCTAssertEqual(deleted.children.count, 1)
        guard case .comment(let reply) = deleted.children[0] else { return XCTFail("Missing reply") }
        XCTAssertEqual(reply.fullname, "t1_reply")
        XCTAssertEqual(reply.parentFullname, "t1_dead")
        guard case .deleted(let leaf) = nodes[1] else { return XCTFail("Expected deleted leaf") }
        XCTAssertNotEqual(leaf.id, "t1_sibling")
        guard case .comment(let sibling) = nodes[2] else { return XCTFail("Missing sibling") }
        XCTAssertEqual(sibling.children.count, 1)
    }

    func testISODateFlairAndHiddenScore() throws {
        let nodes = try decode(#"{"data":{"postInfoById":{"commentForest":{"trees":[{"depth":0,"node":{"__typename":"Comment","id":"t1_date","createdAt":"2026-10-04T00:26:11.575000+0000","score":42,"isScoreHidden":true,"authorInfo":{"name":"reader"},"authorFlair":{"text":"Author","template":{"id":"flair-id"}},"content":{"markdown":"Body"}}}]}}}}"#)
        guard case .comment(let comment) = try XCTUnwrap(nodes.first) else { return XCTFail("Missing comment") }
        XCTAssertEqual(comment.createdAt.timeIntervalSince1970, 1_791_073_571.575, accuracy: 0.001)
        XCTAssertEqual(comment.authorFlair?.text, "Author")
        XCTAssertEqual(comment.authorFlair?.id, "flair-id")
        XCTAssertNil(comment.score)
    }

    func testMarkdownRemainsSourceOfTruthWhenRichTextAlsoExists() throws {
        let content = try XCTUnwrap(JSONDecoder().decode([String: RedditJSONValue].self, from: Data(#"{"markdown":"**bold** [link](https://example.com)","richtext":{"document":[{"e":"par","c":[{"e":"text","t":"bold"}]}]}}"#.utf8)))
        let result = RedditGraphQLRichText.decode(content, thingID: "t1_text")
        XCTAssertEqual(result?.plainText, "**bold** [link](https://example.com)")
    }

    func testStructuredFallbackKeepsCodepointFormattingAndLinks() throws {
        let content = try JSONDecoder().decode([String: RedditJSONValue].self, from: Data(#"{"richtext":{"document":[{"e":"par","c":[{"e":"text","t":"😀é bold","f":[[1,4,4]]},{"e":"link","t":" site","u":"https://example.com"}]}]}}"#.utf8))
        let result = try XCTUnwrap(RedditGraphQLRichText.decode(content, thingID: "t1_text"))
        XCTAssertTrue(result.plainText.contains("😀é **bold**"))
        XCTAssertTrue(result.plainText.contains("[ site](https://example.com)"))
    }

    func testStructuredBlocksAndMediaProduceMarkdown() throws {
        let content = try JSONDecoder().decode([String: RedditJSONValue].self, from: Data(#"{"richtext":{"document":[{"e":"blockquote","c":[{"e":"par","c":[{"e":"text","t":"Quote"}]}]},{"e":"list","o":true,"c":[{"e":"li","c":[{"e":"par","c":[{"e":"text","t":"First"}]}]}]},{"e":"code","c":[{"t":"let x = 1"}]},{"e":"table","h":[{"c":[{"e":"text","t":"Name"}]},{"c":[{"e":"text","t":"Value"}]}],"c":[[{"c":[{"e":"text","t":"A"}]},{"c":[{"e":"text","t":"B"}]}]]},{"e":"img","id":"media"},{"e":"video","id":"video"}]},"richtextMedia":[{"id":"media","large":{"url":"https://i.redd.it/image.jpg"}}]}"#.utf8))
        let result = try XCTUnwrap(RedditGraphQLRichText.decode(content, thingID: "t1_text"))
        XCTAssertTrue(result.plainText.contains("> Quote"))
        XCTAssertTrue(result.plainText.contains("1. First"))
        XCTAssertTrue(result.plainText.contains("```\nlet x = 1\n```"))
        XCTAssertTrue(result.plainText.contains("| Name | Value |"))
        XCTAssertTrue(result.plainText.contains("![Image](https://i.redd.it/image.jpg)"))
        XCTAssertTrue(result.plainText.contains("[Video](https://reddit.com/link/text/video/video/player)"))
    }

    func testRepeatedCursorDoesNotCreateAnotherMoreNode() throws {
        let response = #"{"data":{"postInfoById":{"commentForest":{"trees":[{"depth":0,"more":{"cursor":"same","count":4}}]}}}}"#
        let first = try decode(response)
        guard case .more(let more) = try XCTUnwrap(first.first), case .page(let token) = more.continuation else {
            return XCTFail("Missing cursor")
        }
        XCTAssertEqual(token.parentFullname, "t3_post")
        XCTAssertEqual(token.visitedCursors, ["same"])
        XCTAssertTrue(try decode(response, visited: token.visitedCursors).isEmpty)
    }
}

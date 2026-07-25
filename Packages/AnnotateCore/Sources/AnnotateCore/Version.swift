/// The one place the version is written down.
///
/// It used to live in three: `MARKETING_VERSION` twice in the Xcode project and
/// a string literal in the MCP server. Three copies of a number nobody looks at
/// drift the moment one of them is bumped, and the version an agent sees in the
/// MCP handshake is exactly the one nobody thinks to update.
///
/// The release workflow refuses to publish when the tag and this value disagree,
/// so a tag cannot quietly ship a differently-numbered build.
public enum AnnotateVersion {
    /// Semantic version, no `v` prefix. The release tag is this with `v` in front.
    ///
    /// Below 1.0 on purpose: the wire protocol and the tool schemas are still
    /// free to change, and a 0.x number says that without a paragraph.
    public static let current = "0.1.0"
}

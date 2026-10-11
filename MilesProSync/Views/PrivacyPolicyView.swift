import SwiftUI

/// Shows PRIVACY.md from the app bundle, so the in-app policy is always the same text as the
/// published one.
struct PrivacyPolicyView: View {
    private let blocks = PolicyDocument.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks.indices, id: \.self) { index in
                    view(for: blocks[index])
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func view(for block: PolicyDocument.Block) -> some View {
        switch block {
        case .title(let text):
            Text(text).font(.title2.bold())
        case .heading(let text):
            Text(text).font(.headline).padding(.top, 8)
        case .subheading(let text):
            Text(text).font(.subheadline.bold()).padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(PolicyDocument.inline(text))
            }
            .font(.callout)
        case .paragraph(let text):
            Text(PolicyDocument.inline(text)).font(.callout)
        }
    }
}

/// Just enough Markdown for the policy: #/##/### headings, "- " bullets, and paragraphs with
/// inline bold and links.
enum PolicyDocument {
    enum Block: Equatable {
        case title(String)
        case heading(String)
        case subheading(String)
        case bullet(String)
        case paragraph(String)
    }

    static func load(bundle: Bundle = .main) -> [Block] {
        guard let url = bundle.url(forResource: "PRIVACY", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [.paragraph("The privacy policy couldn't be loaded.")]
        }
        return parse(text)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("### ") {
                flushParagraph()
                blocks.append(.subheading(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.title(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
}

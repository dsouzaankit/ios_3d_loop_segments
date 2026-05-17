import Foundation

enum WebDAVResponseParser {
    static func parse(data: Data, baseHost: String) throws -> [WebDAVItem] {
        let delegate = ParserDelegate(baseHost: baseHost)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw WebDAVError.parseFailed
        }
        return delegate.items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        let baseHost: String
        var items: [WebDAVItem] = []

        private var inResponse = false
        private var captureElement: String?
        private var textBuffer = ""

        private var currentHref = ""
        private var isCollection = false
        private var contentLength: Int64?

        init(baseHost: String) {
            self.baseHost = baseHost
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = localName(elementName)
            if name == "response" {
                inResponse = true
                currentHref = ""
                isCollection = false
                contentLength = nil
                textBuffer = ""
                captureElement = nil
            }
            if inResponse, name == "collection" {
                isCollection = true
            }
            if inResponse, name == "href" || name == "getcontentlength" {
                captureElement = name
                textBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inResponse, captureElement != nil else { return }
            textBuffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = localName(elementName)
            if captureElement == name {
                let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                switch name {
                case "href":
                    currentHref = value
                case "getcontentlength":
                    contentLength = Int64(value)
                default:
                    break
                }
                captureElement = nil
                textBuffer = ""
            }
            if name == "response" {
                inResponse = false
                flushCurrent()
            }
        }

        private func flushCurrent() {
            guard !currentHref.isEmpty else { return }
            let displayName = WebDAVURLBuilder.displayName(fromHref: currentHref)
            guard !displayName.isEmpty, displayName != "/" else { return }
            items.append(WebDAVItem(
                href: WebDAVURLBuilder.normalizedHrefPath(currentHref),
                name: displayName,
                isDirectory: isCollection,
                contentLength: contentLength
            ))
        }

        private func localName(_ elementName: String) -> String {
            if let idx = elementName.firstIndex(of: ":") {
                return String(elementName[elementName.index(after: idx)...]).lowercased()
            }
            return elementName.lowercased()
        }
    }
}

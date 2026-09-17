import Foundation
import UniformTypeIdentifiers

let catalogue = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let formats = try JSONSerialization.jsonObject(with: catalogue) as! [[String: Any]]
let infoURL = URL(fileURLWithPath: CommandLine.arguments[2])
var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
var declarations = info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []
var known = Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })
var documents: [[String: Any]] = []
for format in formats {
    let name = format["name"] as! String
    let extensions = format["extensions"] as! [String]
    var types: [String] = []
    for ext in extensions {
        let type = UTType(filenameExtension: ext)
        let identifier: String
        if let type, !type.isDynamic, !type.identifier.hasPrefix("dev.press.archive.") { identifier = type.identifier }
        else {
            identifier = "dev.press.archive.\(ext)"
            if known.insert(identifier).inserted {
                declarations.append([
                    "UTTypeIdentifier": identifier,
                    "UTTypeDescription": "\(ext.uppercased()) container",
                    "UTTypeConformsTo": ["public.data"],
                    "UTTypeTagSpecification": ["public.filename-extension": [ext]]
                ])
            }
        }
        types.append(identifier)
    }
    documents.append(["CFBundleTypeName": "\(name) container", "CFBundleTypeRole": "Viewer",
                      "LSHandlerRank": "Alternate", "LSItemContentTypes": Array(Set(types)).sorted()])
}
info["CFBundleDocumentTypes"] = documents
info["UTImportedTypeDeclarations"] = declarations
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)

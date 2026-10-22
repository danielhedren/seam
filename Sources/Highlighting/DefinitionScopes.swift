import Foundation
import SeamCore
import SwiftTreeSitter

/// Which nodes name a definition worth showing in a hunk header, per language. Namespaces are
/// left out: in C# they wrap the whole file and say nothing about where a change is.
enum DefinitionScopes {
    enum Name {
        case field(String)
        case fixed(String)
        /// A variable holding a function, as in `const handle = () => …`.
        case functionValue
    }

    static func rules(for language: SyntaxLanguage) -> [String: Name] {
        switch language {
        case .csharp:
            [
                "class_declaration": .field("name"), "struct_declaration": .field("name"),
                "interface_declaration": .field("name"), "record_declaration": .field("name"),
                "enum_declaration": .field("name"), "method_declaration": .field("name"),
                "constructor_declaration": .field("name"),
                "destructor_declaration": .field("name"),
                "property_declaration": .field("name"), "local_function_statement": .field("name"),
            ]
        case .typescript, .tsx, .javascript:
            [
                "class_declaration": .field("name"), "abstract_class_declaration": .field("name"),
                "interface_declaration": .field("name"), "enum_declaration": .field("name"),
                "function_declaration": .field("name"),
                "generator_function_declaration": .field("name"),
                "method_definition": .field("name"), "variable_declarator": .functionValue,
            ]
        case .php:
            [
                "class_declaration": .field("name"), "interface_declaration": .field("name"),
                "trait_declaration": .field("name"), "enum_declaration": .field("name"),
                "function_definition": .field("name"), "method_declaration": .field("name"),
            ]
        case .rust:
            [
                "function_item": .field("name"), "struct_item": .field("name"),
                "enum_item": .field("name"), "trait_item": .field("name"),
                "mod_item": .field("name"), "impl_item": .field("type"),
            ]
        default: [:]
        }
    }

    /// Definitions in document order, outer before inner.
    static func scopes(in tree: MutableTree, text: String, language: SyntaxLanguage)
        -> [SyntaxScope]
    {
        let rules = rules(for: language)
        guard !rules.isEmpty, let root = tree.rootNode else { return [] }
        let source = text as NSString
        var scopes: [SyntaxScope] = []
        func visit(_ node: Node) {
            if let type = node.nodeType, let rule = rules[type],
                let name = name(of: node, rule, source)
            {
                let range = node.pointRange
                let first = Int(range.lowerBound.row)
                scopes.append(
                    SyntaxScope(
                        lines: first...max(first, Int(range.upperBound.row)), name: name))
            }
            for index in 0..<node.namedChildCount {
                if let child = node.namedChild(at: index) { visit(child) }
            }
        }
        visit(root)
        return scopes
    }

    private static func name(of node: Node, _ rule: Name, _ source: NSString) -> String? {
        let named: Node?
        switch rule {
        case .fixed(let name): return name
        case .field(let field): named = node.child(byFieldName: field)
        case .functionValue:
            guard
                let value = node.child(byFieldName: "value")?.nodeType,
                ["arrow_function", "function_expression", "function"].contains(value)
            else { return nil }
            named = node.child(byFieldName: "name")
        }
        guard let range = named?.range, NSMaxRange(range) <= source.length else { return nil }
        let text = source.substring(with: range)
        let firstLine = text.prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        return firstLine.isEmpty ? nil : firstLine
    }
}

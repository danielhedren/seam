;; Seam's additions to the vendored query, for what it misses (SPEC §8.4). Appended after it, so
;; the vendored captures win where both match the same node.

;; A method's return type is its `returns` field, not `type`.
(method_declaration returns: (identifier) @type)

;; Calls without a receiver, and generic calls.
(invocation_expression function: (identifier) @function)
(invocation_expression function: (generic_name (identifier) @function))
(invocation_expression
  function: (member_access_expression name: (generic_name (identifier) @function)))

;; Namespaces, file-scoped and dotted, and the names `using` brings in.
(file_scoped_namespace_declaration name: (_) @module)
(namespace_declaration name: (qualified_name) @module)
(using_directive (qualified_name) @module)
(using_directive (identifier) @module)

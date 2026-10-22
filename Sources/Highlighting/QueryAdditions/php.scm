;; Seam's additions to the vendored query, for what it misses (SPEC §8.4). Put before it, so
;; these captures win where both match the same node.

;; The class in `Client::class` and `Client::NAME`; the query has it only for calls.
(class_constant_access_expression
  .
  [
    (name) @type
    (qualified_name (name) @type)
    (relative_name (name) @type)
  ])
(scoped_property_access_expression
  scope: [
    (name) @type
    (qualified_name (name) @type)
    (relative_name (name) @type)
  ])

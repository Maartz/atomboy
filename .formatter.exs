# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "games/*.exs"],
  # The Potion surface is written without parentheses — it is the language's
  # storefront, and the formatter must respect it instead of rewriting it as
  # function calls.
  locals_without_parens: [defactor: 2, variables: 1, every_frame: 1]
]

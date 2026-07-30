# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "jeux/*.exs"],
  # La surface de Potion s'écrit sans parenthèses — c'est la vitrine du
  # langage, et le formateur doit la respecter au lieu de la réécrire en
  # appels de fonctions.
  locals_without_parens: [defactor: 2, variables: 1, every_frame: 1]
]

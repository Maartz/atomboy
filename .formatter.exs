# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "jeux/*.exs"],
  # La surface de Potion s'écrit sans parenthèses — c'est la vitrine du
  # langage, et le formateur doit la respecter au lieu de la réécrire en
  # appels de fonctions.
  locals_without_parens: [defacteur: 2, variables: 1, chaque_frame: 1, si: 2]
]

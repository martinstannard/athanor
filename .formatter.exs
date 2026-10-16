# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # Kept in step with .credo.exs's MaxLineLength so the formatter never rewraps code the linter
  # would have accepted (and vice-versa).
  line_length: 120
]

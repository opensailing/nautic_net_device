# Used by "mix format"
[
  import_deps: [:protobuf, :tesla],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "rootfs_overlay/etc/iex.exs"
  ],
  line_length: 120
]

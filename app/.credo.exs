# credo configuration for the PromptOn server.
# - Design.AliasUsage disabled: in resource changes/validations/policies, writing the full module
#   name (`PromptOn.Checks.X`, `Ash.Error.Changes.InvalidAttribute`) is the CLAUDE.md convention
#   (what a policy block refers to should be readable right where it stands).
# - Refactor.Nesting 3: Ash changes/validations naturally carry one extra level of `with`/`case`.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/", "priv/repo/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/priv/static/", ~r"/priv/repo/migrations/"]
      },
      strict: true,
      checks: %{
        extra: [
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]}
        ],
        disabled: [
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}

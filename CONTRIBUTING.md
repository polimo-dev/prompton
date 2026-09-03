# Contributing to PromptOn

Thanks for helping. Bug reports, questions, and pull requests go through
[GitHub issues and PRs](https://github.com/polimo-dev/prompton).

## Developer Certificate of Origin

Every commit must be signed off. By signing off you certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org/) — that you wrote the change
or otherwise have the right to submit it under the license of this repository.

```sh
git commit -s -m "describe the change"
```

This appends a `Signed-off-by: Your Name <you@example.com>` line using your git `user.name` and
`user.email`. Pull requests with unsigned commits cannot be merged; `git commit --amend -s` or
`git rebase --signoff` fixes existing commits.

## Licensing of contributions

- Contributions to this repository are licensed under its license, the
  **Functional Source License, Version 1.1, Apache 2.0 Future License** ([LICENSE](LICENSE)).
- Contributions under `sdk/elixir` are licensed under the **Apache License 2.0**
  ([sdk/elixir/LICENSE](sdk/elixir/LICENSE)).

New files do not need license headers.

## Before opening a pull request

Read `app/CLAUDE.md` (domain and Ash conventions) and `app/AGENTS.md` (Phoenix/Elixir rules),
then make sure the same checks CI runs pass locally:

```sh
cd app && mix precommit      # compile --warnings-as-errors, format, credo --strict, ash.codegen --check, test
cd ../sdk/elixir && mix test
```

Migrations are generated with `mix ash.codegen <name>` and must be expand/contract safe
(deploys are rolling: the old and the new server run against the same schema). Keep pull requests focused; describe the user-visible
change and the reason in the description.

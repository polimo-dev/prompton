# ---- build ----
FROM elixir:1.20 AS build

ENV MIX_ENV=prod LANG=C.UTF-8

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# The build context is the repository root; only app/ is copied. The Elixir SDK is a git dependency
# (prompton_sdk, pinned to a commit in mix.exs) fetched by mix deps.get.
COPY app/mix.exs app/mix.lock ./
COPY app/config config
RUN mix deps.get --only prod && mix deps.compile

COPY app/assets assets
COPY app/lib lib
COPY app/priv priv
# mix compile generates the colocated hooks (phoenix-colocated/*), so it has to run before the
# assets build
RUN mix compile && mix assets.setup && mix assets.deploy && mix release

# ---- runtime ----
# Must be the same Debian release as the builder (elixir:1.20) — ERTS is tied to the glibc version
FROM debian:trixie-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates openssl libncurses6 \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 MIX_ENV=prod PHX_SERVER=true PORT=4000

WORKDIR /app
COPY --from=build /app/_build/prod/rel/prompton ./

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=3s --start-period=20s CMD ["/app/bin/prompton", "rpc", "PromptOn.ReleaseTasks.health!()"]

CMD ["/app/bin/prompton", "start"]

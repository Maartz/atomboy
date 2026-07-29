# atomboy — build en conteneur : aucune dépendance à installer chez soi.
#
#     docker build --output type=local,dest=burrito_out .
#
# dépose l'exécutable Linux autonome dans burrito_out/. Pour choisir la
# cible (voir mix.exs, releases/burrito) :
#
#     docker build --build-arg BURRITO_TARGET=linux_x64 --output type=local,dest=burrito_out .
#
# La version du binaire porte le SHA du commit : passé en argument de build
# (le contexte n'embarque pas .git) —
#
#     docker build --build-arg ATOMBOY_SHA=$(git rev-parse --short HEAD) ...

FROM elixir:1.18-otp-26 AS build

# xz : l'archiveur de Burrito ; zig 0.16.0 : son compilateur d'enveloppe.
RUN apt-get update \
  && apt-get install -y --no-install-recommends xz-utils curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.16.0
RUN set -eux; \
  arch="$(uname -m)"; \
  curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
    -o /tmp/zig.tar.xz; \
  mkdir -p /opt/zig; \
  tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
  rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

# Les dépendances d'abord — la couche se met en cache tant que mix.exs ne
# bouge pas.
COPY mix.exs mix.lock ./
ARG ATOMBOY_SHA
ENV ATOMBOY_SHA=${ATOMBOY_SHA}
RUN mix deps.get

COPY lib lib
COPY rel rel

# Une seule cible par défaut : le binaire Linux (Burrito lit BURRITO_TARGET).
ARG BURRITO_TARGET=linux_x64
ENV BURRITO_TARGET=${BURRITO_TARGET}
RUN mix release --overwrite

# L'étage final ne contient QUE les binaires : `--output` les dépose chez toi.
FROM scratch AS artefacts
COPY --from=build /app/burrito_out/ /

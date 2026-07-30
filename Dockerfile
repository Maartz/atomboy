# atomboy — containerised build: nothing to install on your own machine.
#
#     docker build --output type=local,dest=burrito_out .
#
# drops the self-contained Linux executable into burrito_out/. To pick the
# target (see mix.exs, releases/burrito):
#
#     docker build --build-arg BURRITO_TARGET=linux_x64 --output type=local,dest=burrito_out .
#
# The binary's version carries the commit SHA: passed as a build argument
# (the context does not carry .git) —
#
#     docker build --build-arg ATOMBOY_SHA=$(git rev-parse --short HEAD) ...

FROM elixir:1.18-otp-26 AS build

# xz: Burrito's archiver; zig 0.16.0: its wrapper compiler.
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

# Dependencies first — the layer stays cached as long as mix.exs does not
# move.
COPY mix.exs mix.lock ./
ARG ATOMBOY_SHA
ENV ATOMBOY_SHA=${ATOMBOY_SHA}
RUN mix deps.get

COPY lib lib
COPY rel rel

# One target by default: the Linux binary (Burrito reads BURRITO_TARGET).
ARG BURRITO_TARGET=linux_x64
ENV BURRITO_TARGET=${BURRITO_TARGET}
RUN mix release --overwrite

# The final stage holds ONLY the binaries: `--output` drops them on your disk.
FROM scratch AS artefacts
COPY --from=build /app/burrito_out/ /

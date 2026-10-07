# A mix release of an app with a defk kernel, built in a stock Debian Elixir
# image. The build context is the defk repo root:
#
#   podman build -f examples/release_debian/Dockerfile -t defk-release-debian .
#   podman run --rm defk-release-debian
#
# See README.md for what had to be added, what it costs, and why the runtime
# stage copies a path out of _build.
ARG BUILDER_IMAGE=hexpm/elixir:1.20.2-erlang-29.0.3-debian-trixie-20260713-slim
ARG RUNNER_IMAGE=debian:trixie-20260713-slim

FROM ${BUILDER_IMAGE} AS build

# defk runs the C compiler at compile time (Defk.Build: `cc`, or $CC).
# Pass --build-arg BUILD_PKGS= to see the failure without it.
ARG BUILD_PKGS=build-essential
RUN if [ -n "$BUILD_PKGS" ]; then \
      apt-get update && apt-get install -y --no-install-recommends $BUILD_PKGS \
      && rm -rf /var/lib/apt/lists/*; \
    fi

ENV MIX_ENV=prod
# The app uses defk as a path dep ("../.."), so keep the repo layout.
WORKDIR /src/defk
COPY mix.exs ./
COPY lib ./lib
COPY priv ./priv
COPY examples/release_debian/mix.exs ./examples/release_debian/
COPY examples/release_debian/lib ./examples/release_debian/lib

WORKDIR /src/defk/examples/release_debian
RUN mix release

FROM ${RUNNER_IMAGE} AS run
# No C compiler here: these are the release's ERTS runtime libraries, the
# same as for any Elixir release (libsctp1 only silences an OTP socket warning).
RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 libncurses6 libsctp1 openssl locales ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
COPY --from=build /src/defk/examples/release_debian/_build/prod/rel/release_debian ./

# Workaround: the kernel's .so is not in the release. Defk.Build writes it to
# _build/<env>/defk/ and the module loads it from that absolute build path, so
# it must exist at the same path at runtime. Set COPY_SO=0 to see the failure.
ARG COPY_SO=1
COPY --from=build /src/defk/examples/release_debian/_build/prod/defk /tmp/defk-so
RUN if [ "$COPY_SO" = 1 ]; then \
      mkdir -p /src/defk/examples/release_debian/_build/prod \
      && mv /tmp/defk-so /src/defk/examples/release_debian/_build/prod/defk; \
    else rm -rf /tmp/defk-so; fi

CMD ["bin/release_debian", "eval", "IO.inspect(ReleaseDebian.check())"]

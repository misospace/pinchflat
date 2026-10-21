# This image is the shared toolchain used by:
#   - docker/dev.Dockerfile           (local dev + CI test runner)
#   - docker/selfhosted.Dockerfile    (release builder stage; ffmpeg is COPYd into the runner)
#
# Pinning:
#   - ffmpeg:  pinned URL below. selfhosted's runner copies this binary, so the version
#              here is what production ships. See issue #347 (newer ffmpeg builds trigger
#              "illegal instruction" on some users' hardware).
#   - deno:    pinned version + committed SHA-256 of the release zips below. Renovate
#              manages the version via the comment; whoever lands a version bump must
#              refresh the matching digest from the release's deno-<arch>.zip.sha256sum
#              assets. A stale digest fails the build loudly.
#   - apprise: pinned in docker/ci-base.requirements.txt so Renovate's pip_requirements
#              manager can bump it.
#   - yt-dlp:  pinned to the exact release below plus committed SHA-256 per binary,
#              managed by Renovate (version). selfhosted's runner copies this binary into
#              production, so this is the single source of truth for the shipped version.
#              Refresh the digests from the release's SHA2-256SUMS asset when bumping.
#   - oh-my-zsh: floats to master. Affects dev shell ergonomics only; low stakes.
#
# Drift caveat: ci-base ships ffmpeg and yt-dlp into selfhosted's runner, so bumping
# either pin here changes the binaries users get. Consumers should pin to :sha-<...>,
# not :latest, so any base bump goes through a PR.
# These three combine into the hexpm/elixir tag (see DEV_IMAGE below). hexpm only
# publishes specific combos, so Renovate tracks each against the real hexpm/elixir
# tag list (customManagers in renovate.json) and groups the bumps into one PR — it
# never proposes a value from a combo that isn't published. Debian stays on trixie-slim.
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=28.5.0.4
ARG DEBIAN_VERSION=trixie-20260713-slim
# renovate: datasource=github-releases depName=denoland/deno
ARG DENO_VERSION=v2.9.0
# SHA-256 of the Deno release zips fetched below, per Linux architecture. Refresh
# both together with DENO_VERSION (digests published as deno-<arch>.zip.sha256sum
# alongside each release).
ARG DENO_SHA256_X86_64=96c9c73fc05ea57603bc28d8071d41e861bd40bcf2a9f849dd5969ed1a2c8498
ARG DENO_SHA256_AARCH64=a0f266eb189af2f27db0c6dcf9eb2f68ba2e8bbff1442c969ace398463f8b2bf
# renovate: datasource=github-releases depName=yt-dlp/yt-dlp
ARG YT_DLP_VERSION=2026.08.19
# SHA-256 of the yt-dlp release binaries fetched below, per architecture. Refresh
# both together with YT_DLP_VERSION (digests published in the release's
# SHA2-256SUMS asset).
ARG YT_DLP_SHA256_AMD64=58162f9bfdc27458ea47bfcb311cf47028f17d8154a8bf7d689861d46399230a
ARG YT_DLP_SHA256_ARM64=b16e4dab368a816cd05d477d698a605a6ae87ccee1c8ffd38fa21d7254141fcc
# renovate: datasource=node-version depName=node
ARG NODE_MAJOR=24
# NOT renovate-tracked: ffmpeg is pinned for issue #347 (illegal instruction on some CPUs).
# Newer builds must be smoke-tested manually before bumping. FFMPEG_BUILD is paired with
# FFMPEG_RELEASE — both come from the same yt-dlp/FFmpeg-Builds release page.
ARG FFMPEG_RELEASE=autobuild-2026-07-30-16-10
ARG FFMPEG_BUILD=N-125858-g86940d45af

ARG DEV_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"

FROM ${DEV_IMAGE}

# Re-declare ARGs needed inside the build stage. ARGs declared before FROM
# are only in scope for the FROM line itself.
ARG TARGETPLATFORM
ARG DENO_VERSION
ARG DENO_SHA256_X86_64
ARG DENO_SHA256_AARCH64
ARG YT_DLP_VERSION
ARG YT_DLP_SHA256_AMD64
ARG YT_DLP_SHA256_ARM64
ARG NODE_MAJOR
ARG FFMPEG_RELEASE
ARG FFMPEG_BUILD

COPY docker/ci-base.requirements.txt /tmp/ci-base.requirements.txt

RUN echo "Building for ${TARGETPLATFORM:?}" && \
# Install debian packages
  apt-get update -qq && \
  apt-get install -y inotify-tools curl git openssh-client jq \
    python3 python3-setuptools python3-wheel python3-dev pipx \
    python3-mutagen locales procps build-essential graphviz zsh unzip && \
# Install ffmpeg — pinned build, see issue #347. selfhosted's runner copies these binaries
# from this image, so the version here is what production ships.
  export FFMPEG_BASE_URL="https://github.com/yt-dlp/FFmpeg-Builds/releases/download/${FFMPEG_RELEASE}/ffmpeg-${FFMPEG_BUILD}" && \
  export FFMPEG_DOWNLOAD=$(case ${TARGETPLATFORM:-linux/amd64} in \
    "linux/amd64")   echo "${FFMPEG_BASE_URL}-linux64-gpl.tar.xz"   ;; \
    "linux/arm64")   echo "${FFMPEG_BASE_URL}-linuxarm64-gpl.tar.xz" ;; \
    *)               echo ""        ;; esac) && \
    curl -L ${FFMPEG_DOWNLOAD} --output /tmp/ffmpeg.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz --strip-components=2 --no-anchored -C /usr/bin/ ffmpeg ffprobe && \
# Install nodejs, Yarn, Deno, yt-dlp, and Apprise
  curl -sL https://deb.nodesource.com/setup_${NODE_MAJOR}.x -o nodesource_setup.sh && \
  bash nodesource_setup.sh && \
  apt-get install -y nodejs && \
  apt-get clean && \
  rm -f /var/lib/apt/lists/*_* && \
  npm install -g yarn && \
  # Install baseline Elixir packages
  mix local.hex --force && \
  mix local.rebar --force && \
  # Install Deno - required for YouTube downloads (See yt-dlp#14404). Fetched as
  # the versioned GitHub release zip and verified against the committed SHA-256
  # above; no remote install script is piped to a shell. Staged under /tmp so
  # the exec bit is set before the binary lands in /usr/local/bin.
  export DENO_ARCH=$(case ${TARGETPLATFORM:-linux/amd64} in \
  "linux/arm64")   echo "aarch64" ;; \
  *)               echo "x86_64"  ;; esac) && \
  export DENO_SHA256=$(case ${TARGETPLATFORM:-linux/amd64} in \
  "linux/arm64")   echo "${DENO_SHA256_AARCH64}" ;; \
  *)               echo "${DENO_SHA256_X86_64}"  ;; esac) && \
  curl -fsSL "https://github.com/denoland/deno/releases/download/${DENO_VERSION}/deno-${DENO_ARCH}-unknown-linux-gnu.zip" -o /tmp/deno.zip && \
  { echo "${DENO_SHA256}  /tmp/deno.zip" | sha256sum -c - || \
    { echo "ERROR: digest mismatch for the Deno zip - if DENO_VERSION was bumped, refresh both DENO_SHA256_* digests in this file from the release deno zip's .sha256sum asset" >&2; exit 1; }; } && \
  unzip -q /tmp/deno.zip -d /tmp/deno-staging && \
  chmod 755 /tmp/deno-staging/deno && \
  mv /tmp/deno-staging/deno /usr/local/bin/deno && \
  rm -rf /tmp/deno.zip /tmp/deno-staging && \
  # Download the exact yt-dlp release managed above, verified against the
  # committed SHA-256 above before it is made executable.
  export YT_DLP_BASE_URL="https://github.com/yt-dlp/yt-dlp/releases/download/${YT_DLP_VERSION}" && \
  export YT_DLP_DOWNLOAD=$(case ${TARGETPLATFORM:-linux/amd64} in \
  "linux/amd64")   echo "${YT_DLP_BASE_URL}/yt-dlp_linux"          ;; \
  "linux/arm64")   echo "${YT_DLP_BASE_URL}/yt-dlp_linux_aarch64" ;; \
  *)               echo "${YT_DLP_BASE_URL}/yt-dlp_linux"          ;; esac) && \
  export YT_DLP_SHA256=$(case ${TARGETPLATFORM:-linux/amd64} in \
  "linux/arm64")   echo "${YT_DLP_SHA256_ARM64}" ;; \
  *)               echo "${YT_DLP_SHA256_AMD64}" ;; esac) && \
  curl -fsSL ${YT_DLP_DOWNLOAD} -o /usr/local/bin/yt-dlp && \
  { echo "${YT_DLP_SHA256}  /usr/local/bin/yt-dlp" | sha256sum -c - || \
    { echo "ERROR: digest mismatch for the yt-dlp binary - if YT_DLP_VERSION was bumped, refresh both YT_DLP_SHA256_* digests in this file from the release SHA2-256SUMS asset" >&2; exit 1; }; } && \
  chmod a+rx /usr/local/bin/yt-dlp && \
  # Install Apprise (version pinned in docker/ci-base.requirements.txt, managed by Renovate)
  export PIPX_HOME=/opt/pipx && \
  export PIPX_BIN_DIR=/usr/local/bin && \
  pipx install "$(cat /tmp/ci-base.requirements.txt)" && \
  rm /tmp/ci-base.requirements.txt && \
  # Set up ZSH tools
  chsh -s $(which zsh) && \
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

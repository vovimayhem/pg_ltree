# Stage 1: Runtime =============================================================
# The minimal package dependencies required to run the app in the release image:
ARG RUBY_VERSION=2.7.7
ARG IMAGE_VARIANT=slim-bullseye

# Use an official Ruby image as base:
FROM ruby:${RUBY_VERSION}-${IMAGE_VARIANT} AS runtime

# We'll set MALLOC_ARENA_MAX for optimization purposes & prevent memory bloat
# https://www.speedshop.co/2017/12/04/malloc-doubles-ruby-memory.html
ENV MALLOC_ARENA_MAX="2"

# We'll install curl for later dependency package installation steps
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libpq5 \
    openssl \
    tzdata \
 && rm -rf /var/lib/apt/lists/*

# Update the RubyGems system software, which will update bundler, to avoid the
# "uninitialized constant Gem::Source (NameError)" error when running bundler
# commands:
RUN gem update --system && gem cleanup

# Stage 2: development-base ====================================================
# This stage will contain the minimal dependencies for the rest of the images
# used to build the project:

# Use the "runtime" stage as base:
FROM runtime AS development-base

# Install the app build system dependency packages - we won't remove the apt
# lists from this point onward:

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libpq-dev \
    sudo

# Receive the developer user's UID and USER:
ARG DEVELOPER_UID=1000
ARG DEVELOPER_USERNAME=you

# Replicate the developer user in the development image:
RUN addgroup --gid ${DEVELOPER_UID} ${DEVELOPER_USERNAME} \
 ;  useradd -r -m -u ${DEVELOPER_UID} --gid ${DEVELOPER_UID} \
    --shell /bin/bash -c "Developer User,,," ${DEVELOPER_USERNAME}

# Add the developer user to the sudoers list:
RUN echo "${DEVELOPER_USERNAME} ALL=(ALL) NOPASSWD:ALL" | tee "/etc/sudoers.d/${DEVELOPER_USERNAME}"

# Ensure that the home directory, the app path and bundler directories are owned
# by the developer user:
# (A workaround to a side effect of setting WORKDIR before creating the user)
RUN userhome=$(eval echo ~${DEVELOPER_USERNAME}) \
 && chown -R ${DEVELOPER_USERNAME}:${DEVELOPER_USERNAME} $userhome \
 && mkdir -p /workspaces/pg_ltree \
 && chown -R ${DEVELOPER_USERNAME}:${DEVELOPER_USERNAME} /workspaces/pg_ltree \
 && chown -R ${DEVELOPER_USERNAME}:${DEVELOPER_USERNAME} /usr/local/bundle/*

# Add the app's "bin/" directory to PATH:
ENV PATH=/workspaces/pg_ltree/bin:$PATH

# Set the app path as the working directory:
WORKDIR /workspaces/pg_ltree

# Change to the developer user:
USER ${DEVELOPER_USERNAME}

# Configure bundler to retry downloads 3 times:
RUN bundle config set --local retry 3

# Configure bundler to use 2 threads to download, build and install:
RUN bundle config set --local jobs 2

# Stage 3: Testing =============================================================
# In this stage we'll complete an image with the minimal dependencies required
# to run the tests in a continuous integration environment.
FROM development-base AS testing

# Copy the project's gemspec & Gemfile files:
COPY --chown=${DEVELOPER_USERNAME} pg_ltree.gemspec Gemfile* /workspaces/pg_ltree/
COPY --chown=${DEVELOPER_USERNAME} lib/pg_ltree/version.rb /workspaces/pg_ltree/lib/pg_ltree/

# Configure bundler to exclude the gems from the "development" group when
# installing, so we get the leanest Docker image possible to run tests:
RUN bundle config set --local without development

# Install the project gems, excluding the "development" group:
RUN bundle install

# Stage 4: Development =========================================================
# In this stage we'll add the packages, libraries and tools required in our
# day-to-day development process.

# Use the "development-base" stage as base:
FROM development-base AS development

# Change to root user to install the development packages:
USER root

# Install sudo, along with any other tool required at development phase:
RUN apt-get install -y --no-install-recommends \
  # Adding bash autocompletion as git without autocomplete is a pain...
  bash-completion \
  # gpg & gpgconf is used to get Git Commit GPG Signatures working inside the
  # VSCode devcontainer:
  gpg \
  # wait until a port is available:
  netcat \
  # postgres client:
  postgresql-client \
  # /proc file system utilities: (watch, ps):
  procps \
  # Vim will be used to edit files when inside the container (git, etc):
  vim

# Persist the bash history between runs
# - See https://code.visualstudio.com/docs/remote/containers-advanced#_persist-bash-history-between-runs
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/command-history/.bash_history" \
 && mkdir /command-history \
 && touch /command-history/.bash_history \
 && chown -R ${DEVELOPER_USERNAME} /command-history \
 && echo $SNIPPET >> "/home/${DEVELOPER_USERNAME}/.bashrc"

# Create the extensions directories:
RUN mkdir -p \
  /home/${DEVELOPER_USERNAME}/.vscode-server/extensions \
  /home/${DEVELOPER_USERNAME}/.vscode-server-insiders/extensions \
 && chown -R ${DEVELOPER_USERNAME} \
  /home/${DEVELOPER_USERNAME}/.vscode-server \
  /home/${DEVELOPER_USERNAME}/.vscode-server-insiders

# Change back to the developer user:
USER ${DEVELOPER_USERNAME}

# Install rubocop & solargraph:
RUN gem install rubocop solargraph

# Copy the gems installed in the "testing" stage:
COPY --from=testing /usr/local/bundle /usr/local/bundle
COPY --from=testing /workspaces/pg_ltree/ /workspaces/pg_ltree/

# Configure bundler to not exclude any gem group, so we now get all the gems
# specified in the Gemfile:
RUN bundle config unset --local without

# Install the full gem list:
RUN bundle install


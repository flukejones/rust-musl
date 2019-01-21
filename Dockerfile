FROM ubuntu:latest

ARG TOOLCHAIN=stable

# Install minimum dev environment for our purposes
RUN apt-get update && \
    apt-get install -y \
    build-essential \
    cmake \
    curl \
    file \
    git \
    musl-dev \
    musl-tools \
    libpq-dev \
    libsqlite-dev \
    libssl-dev \
    pkgconf \
    sudo \
    zip \
    xutils-dev \
    python \
    && apt-get clean

RUN useradd rust -u 1000 --user-group --create-home --shell /bin/bash --groups sudo

# install fixuid
RUN USER=rust && \
    GROUP=rust && \
    curl -SsL https://github.com/boxboat/fixuid/releases/download/v0.1/fixuid-0.1-linux-amd64.tar.gz | tar -C /usr/local/bin -xzf - && \
    chown root:root /usr/local/bin/fixuid && \
    chmod 4755 /usr/local/bin/fixuid && \
    mkdir -p /etc/fixuid && \
    printf "user: $USER\ngroup: $GROUP\n" > /etc/fixuid/config.yml
ENTRYPOINT ["fixuid"]

# Allow sudo without a password.
ADD sudoers /etc/sudoers.d/nopasswd

# Static linking for C++ code
RUN sudo ln -s "/usr/bin/g++" "/usr/bin/musl-g++"

# Run all further code as user `rust`, and create our working directories
# as the appropriate user.
USER rust
RUN mkdir -p /home/rust/libs /home/rust/src
ENV PATH=/home/rust/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Build a static library version of OpenSSL using musl-libc.  This is
# needed by the popular Rust `hyper` crate.
RUN echo "Building OpenSSL" && \
    cd /tmp && \
    OPENSSL_VERSION=1.0.2o && \
    curl -LO "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" && \
    tar xvzf "openssl-$OPENSSL_VERSION.tar.gz" && cd "openssl-$OPENSSL_VERSION" && \
    env CC=musl-gcc ./Configure no-shared no-zlib -fPIC --prefix=/usr/local/musl linux-x86_64 && \
    env C_INCLUDE_PATH=/usr/local/musl/include/ make depend && \
    make && sudo make install && \
    \
    echo "Building zlib" && \
    cd /tmp && \
    ZLIB_VERSION=1.2.11 && \
    curl -LO "http://zlib.net/zlib-$ZLIB_VERSION.tar.gz" && \
    tar xzf "zlib-$ZLIB_VERSION.tar.gz" && cd "zlib-$ZLIB_VERSION" && \
    CC=musl-gcc ./configure --static --prefix=/usr/local/musl && \
    make && sudo make install && \
    \
    echo "Building libpq" && \
    cd /tmp && \
    POSTGRESQL_VERSION=9.6.8 && \
    curl -LO "https://ftp.postgresql.org/pub/source/v$POSTGRESQL_VERSION/postgresql-$POSTGRESQL_VERSION.tar.gz" && \
    tar xzf "postgresql-$POSTGRESQL_VERSION.tar.gz" && cd "postgresql-$POSTGRESQL_VERSION" && \
    CC=musl-gcc CPPFLAGS=-I/usr/local/musl/include LDFLAGS=-L/usr/local/musl/lib ./configure --with-openssl --without-readline --prefix=/usr/local/musl && \
    cd src/interfaces/libpq && make all-static-lib && sudo make install-lib-static && \
    cd ../../bin/pg_config && make && sudo make install && \
    \
    rm -r /tmp/*

ENV OPENSSL_DIR=/usr/local/musl/ \
    OPENSSL_INCLUDE_DIR=/usr/local/musl/include/ \
    DEP_OPENSSL_INCLUDE=/usr/local/musl/include/ \
    OPENSSL_LIB_DIR=/usr/local/musl/lib/ \
    OPENSSL_STATIC=1 \
    PQ_LIB_STATIC_X86_64_UNKNOWN_LINUX_MUSL=1 \
    PG_CONFIG_X86_64_UNKNOWN_LINUX_GNU=/usr/bin/pg_config \
    PKG_CONFIG_ALLOW_CROSS=true \
    PKG_CONFIG_ALL_STATIC=true \
    LIBZ_SYS_STATIC=1 \
    TARGET=musl

RUN curl https://sh.rustup.rs -sSf | \
    sh -s -- -y --default-toolchain $TOOLCHAIN && \
    rustup target add x86_64-unknown-linux-musl
RUN rustup component add clippy
RUN rustup component add rustfmt
ADD cargo-config.toml /home/rust/.cargo/config

# Expect our source code to live in /home/rust/src.  We'll run the build as
# user `rust`, which will be uid 1000, gid 1000 outside the container.
WORKDIR /home/rust/src


FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG HOST_UID=1000
ARG HOST_GID=1000
ARG HOST_USER=codex

ENV TZ=Etc/UTC
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    bash \
    bc \
    bison \
    build-essential \
    ca-certificates \
    chrpath \
    cpio \
    curl \
    debianutils \
    device-tree-compiler \
    diffstat \
    dnsutils \
    file \
    flex \
    gcc-multilib \
    gawk \
    git \
    iproute2 \
    iputils-ping \
    less \
    libegl1-mesa \
    libelf-dev \
    libtool \
    libncurses5 \
    libncurses5-dev \
    libncursesw5-dev \
    libssl-dev \
    libtinfo5 \
    locales \
    lsb-release \
    python3 \
    python3-git \
    python3-jinja2 \
    python3-pexpect \
    python3-pip \
    rsync \
    screen \
    socat \
    sudo \
    texinfo \
    tmux \
    tftpd-hpa \
    u-boot-tools \
    unzip \
    vim-tiny \
    wget \
    xterm \
    xz-utils \
    zip \
    zlib1g-dev \
    zstd \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
    && ln -sf /bin/bash /bin/sh

RUN groupadd --gid "${HOST_GID}" "${HOST_USER}" \
    && useradd --uid "${HOST_UID}" --gid "${HOST_GID}" --create-home --shell /bin/bash "${HOST_USER}" \
    && echo "${HOST_USER} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/"${HOST_USER}" \
    && chmod 0440 /etc/sudoers.d/"${HOST_USER}"

USER ${HOST_USER}
WORKDIR /workspace
CMD ["/bin/bash", "-l"]

# Lightweight utility pod for benchmarking and debugging
FROM ubuntu:24.04
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /app
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.12 python3.12-dev python3-pip python3-venv \
        htop iotop strace lsof \
        iproute2 iputils-ping dnsutils curl iperf3 \
        hey wrk apache2-utils \
        jq ripgrep fzf bat fd-find less \
        git vim \
        tmux zsh \
        nodejs npm \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install uv
ADD https://astral.sh/uv/install.sh /uv-installer.sh
RUN sh /uv-installer.sh && rm /uv-installer.sh
ENV PATH="/root/.local/bin/:$PATH"

# Create venv and set as default
RUN uv venv -p 3.12
ENV VIRTUAL_ENV=/app/.venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# Install rust-just
RUN uv pip install rust-just

# Install dotfiles
RUN git clone --depth=1 --filter=blob:none https://github.com/tlrmchlsmth/dotfiles .dotfiles \
    && cd .dotfiles \
    && PIP_BREAK_SYSTEM_PACKAGES=1 bash install.sh \
    && rm -rf .git

# vllm for benchmarking
RUN uv pip install vllm

# guidellm
RUN git clone --depth=1 --filter=blob:none \
      -b max_completion_tokens \
      https://github.com/tlrmchlsmth/guidellm guidellm \
    && cd guidellm \
    && uv pip install .

# lm_eval
RUN uv venv .lm_eval -p 3.12
RUN uv pip install --python "/app/.lm_eval/bin/python" "lm_eval[api]" transformers
RUN echo "alias lm_eval=/app/.lm_eval/bin/lm_eval" >> .dotfiles/zshrc

# Make first time neovim startup seamless
RUN nvim --headless "+autocmd User LazyDone quitall" "+Lazy! sync" "+MasonUpdate" +qa || true

# Cleanup
RUN apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# Turn off auto-updates & prompts for oh-my-zsh
RUN echo "DISABLE_AUTO_UPDATE=true" >> $HOME/.zshrc.local && \
    echo "DISABLE_UPDATE_PROMPT=true" >> $HOME/.zshrc.local

CMD ["sleep", "infinity"]

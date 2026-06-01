#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[mac-setup] %s\n' "$*"
}

warn() {
  printf '[mac-setup] WARN: %s\n' "$*" >&2
}

fail() {
  printf '[mac-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

DELETE_OMZ=1
UPGRADE=1
BREW_UPDATE=1
INSTALL_HOMEBREW=0
INSTALL_FONT=1

GHOSTTY_DARK_THEME="${GHOSTTY_DARK_THEME:-Desert}"
GHOSTTY_CONFIG_PATH="${GHOSTTY_CONFIG_PATH:-}"
GHOSTTY_FONT_SIZE="${GHOSTTY_FONT_SIZE:-13}"

usage() {
  cat <<'USAGE'
用法：
  setup-zsh-homebrew.sh [选项]

选项：
  --no-delete-omz       备份 ~/.oh-my-zsh 后保留它，不删除。
  --no-upgrade          只安装缺失的软件；已安装的软件不升级。
  --no-brew-update      安装/升级前不执行 brew update。
  --install-homebrew    如果找不到 Homebrew，则自动安装 Homebrew。
  --no-font             不安装/检测 MesloLGS NF 字体。
  -h, --help            显示这段帮助。

环境变量：
  GHOSTTY_CONFIG_PATH   强制指定要写入的 Ghostty 配置文件路径。
  GHOSTTY_DARK_THEME    Ghostty 主题。默认：Desert
  GHOSTTY_FONT_SIZE     Ghostty 字体大小。默认：13
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-delete-omz) DELETE_OMZ=0 ;;
    --no-upgrade) UPGRADE=0 ;;
    --no-brew-update) BREW_UPDATE=0 ;;
    --install-homebrew) INSTALL_HOMEBREW=1 ;;
    --no-font) INSTALL_FONT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知选项：$1" ;;
  esac
  shift
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少必要命令：$1"
}

find_brew() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
  elif [[ -x /opt/homebrew/bin/brew ]]; then
    printf '/opt/homebrew/bin/brew\n'
  elif [[ -x /usr/local/bin/brew ]]; then
    printf '/usr/local/bin/brew\n'
  else
    return 1
  fi
}

install_homebrew() {
  require_cmd curl
  log "未找到 Homebrew；因为指定了 --install-homebrew，开始自动安装 Homebrew"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

ensure_brew_shellenv_in_zprofile() {
  local brew_cmd="$1"
  local brew_prefix
  local zprofile="$HOME/.zprofile"
  local shellenv_line
  local tmp

  brew_prefix="$($brew_cmd --prefix)"
  shellenv_line="eval \"\$($brew_prefix/bin/brew shellenv)\""

  if [[ -f "$zprofile" ]]; then
    cp -p "$zprofile" "$BACKUP_DIR/.zprofile.before-homebrew-shellenv"
    log "已备份 ~/.zprofile"

    tmp="$(mktemp "${TMPDIR:-/tmp}/zprofile.cleanup.XXXXXX")"

    # 规范化 Homebrew 初始化：删除旧脚本错误写入的空块、重复的 Homebrew 标题、
    # 以及已有的 brew shellenv 行，最后统一追加一份当前机器正确的 shellenv。
    awk '
      $0 == "# Homebrew" { next }
      $0 == "eval \"\"" { next }
      $0 ~ /^eval "\\$\([^)]*\/bin\/brew shellenv\)"$/ { next }
      { print }
    ' "$zprofile" > "$tmp"

    mv "$tmp" "$zprofile"
  fi

  {
    printf '\n# Homebrew\n'
    printf '%s\n' "$shellenv_line"
  } >> "$zprofile"

  log "已将正确的 Homebrew shellenv 写入 ~/.zprofile"
}

formula_outdated() {
  local pkg="$1"
  local output

  if output="$(brew outdated --formula --quiet "$pkg" 2>/dev/null)"; then
    grep -Fxq "$pkg" <<<"$output"
    return
  fi

  # 兼容较旧 Homebrew：如果不支持 `brew outdated --formula --quiet <pkg>`，
  # 回退到完整 outdated 列表，再精确匹配包名。
  output="$(brew outdated --formula 2>/dev/null || true)"
  awk '{print $1}' <<<"$output" | grep -Fxq "$pkg"
}

cask_outdated() {
  local pkg="$1"
  local output

  if output="$(brew outdated --cask --quiet "$pkg" 2>/dev/null)"; then
    grep -Fxq "$pkg" <<<"$output"
    return
  fi

  # 兼容较旧 Homebrew：如果不支持 `brew outdated --cask --quiet <pkg>`，
  # 回退到完整 outdated 列表，再精确匹配 cask 名。
  output="$(brew outdated --cask 2>/dev/null || true)"
  awk '{print $1}' <<<"$output" | grep -Fxq "$pkg"
}
ensure_zsh_patina_tap_if_needed() {
  if brew list --formula zsh-patina >/dev/null 2>&1; then
    log "zsh-patina 已安装，跳过 tap 检查：michel-kraemer/zsh-patina"
  else
    ensure_tap "michel-kraemer/zsh-patina"
  fi
}

install_or_upgrade_formula() {
  local pkg="$1"

  if brew list --formula "$pkg" >/dev/null 2>&1; then
    if [[ "$UPGRADE" -eq 1 ]]; then
      if formula_outdated "$pkg"; then
        log "升级 formula：$pkg"
        brew upgrade "$pkg"
      else
        log "formula 已安装且没有可升级版本，跳过安装/升级：$pkg"
      fi
    else
      log "formula 已安装，因 --no-upgrade 跳过升级检查：$pkg"
    fi
  else
    log "安装 formula：$pkg"
    brew install "$pkg"
  fi
}

install_or_upgrade_cask() {
  local pkg="$1"

  if brew list --cask "$pkg" >/dev/null 2>&1; then
    if [[ "$UPGRADE" -eq 1 ]]; then
      if cask_outdated "$pkg"; then
        log "升级 cask：$pkg"
        brew upgrade --cask "$pkg"
      else
        log "cask 已安装且没有可升级版本，跳过安装/升级：$pkg"
      fi
    else
      log "cask 已安装，因 --no-upgrade 跳过升级检查：$pkg"
    fi
  else
    log "安装 cask：$pkg"
    brew install --cask "$pkg"
  fi
}

ensure_tap() {
  local tap="$1"
  if brew tap | grep -qx "$tap"; then
    log "tap 已存在：$tap"
  else
    log "添加 tap：$tap"
    brew tap "$tap"
  fi
}

font_meslo_installed() {
  local dir
  local font

  for dir in "$HOME/Library/Fonts" /Library/Fonts; do
    [[ -d "$dir" && -r "$dir" ]] || continue
    font="$(find "$dir" \
      -maxdepth 1 \
      \( -iname '*MesloLGS*' -o -iname '*Meslo LG S*' \) \
      -print -quit 2>/dev/null || true)"
    [[ -n "$font" ]] && return 0
  done

  return 1
}

install_meslo_font_if_needed() {
  local cask="font-meslo-for-powerlevel10k"

  if brew list --cask "$cask" >/dev/null 2>&1; then
    if [[ "$UPGRADE" -eq 1 ]]; then
      if cask_outdated "$cask"; then
        log "升级 P10K 推荐字体 cask：$cask"
        brew upgrade --cask "$cask"
      else
        log "P10K 推荐字体 cask 已安装且没有可升级版本，跳过安装/升级：$cask"
      fi
    else
      log "P10K 推荐字体 cask 已安装，因 --no-upgrade 跳过升级检查：$cask"
    fi
  elif font_meslo_installed; then
    log "已检测到 MesloLGS NF 字体，跳过 Homebrew 字体 cask 安装；如需改由 Homebrew 管理，可手动安装：brew install --cask $cask"
  else
    log "安装 P10K 推荐字体：$cask"
    brew install --cask "$cask"
  fi
}

ghostty_app_exists() {
  [[ -d /Applications/Ghostty.app || -d "$HOME/Applications/Ghostty.app" ]]
}

install_ghostty_if_needed() {
  local cask="ghostty"

  if brew list --cask "$cask" >/dev/null 2>&1; then
    if [[ "$UPGRADE" -eq 1 ]]; then
      if cask_outdated "$cask"; then
        log "升级 Ghostty cask"
        brew upgrade --cask "$cask"
      else
        log "Ghostty cask 已安装且没有可升级版本，跳过安装/升级"
      fi
    else
      log "Ghostty cask 已安装，因 --no-upgrade 跳过升级检查"
    fi
  elif ghostty_app_exists; then
    warn "检测到 Ghostty.app 已存在但不是 Homebrew 管理；将使用 brew --force 接管/覆盖安装，以统一由 Homebrew 管理。"
    brew install --cask --force "$cask"
  else
    log "安装 Ghostty"
    brew install --cask "$cask"
  fi
}

choose_ghostty_config_path() {
  if [[ -n "$GHOSTTY_CONFIG_PATH" ]]; then
    printf '%s\n' "$GHOSTTY_CONFIG_PATH"
    return
  fi

  local macos_dir="$HOME/Library/Application Support/com.mitchellh.ghostty"
  local xdg_dir="$HOME/.config/ghostty"
  local candidates=(
    "$macos_dir/config.ghostty"
    "$macos_dir/config"
    "$xdg_dir/config.ghostty"
    "$xdg_dir/config"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  printf '%s\n' "$macos_dir/config.ghostty"
}

backup_file_if_exists() {
  local file="$1"
  local label="$2"

  if [[ -f "$file" ]]; then
    cp -p "$file" "$BACKUP_DIR/$label"
    log "已备份 $file"
  fi
}

write_ghostty_config() {
  local config_path="$1"
  local config_dir
  config_dir="$(dirname "$config_path")"
  mkdir -p "$config_dir"

  backup_file_if_exists "$config_path" "ghostty.config.before-setup"

  cat > "$config_path" <<GHOSTTY
# 字体
font-family = "MesloLGS NF"
font-size = ${GHOSTTY_FONT_SIZE}
font-thicken = true
adjust-cell-height = 2

# 主题
theme = ${GHOSTTY_DARK_THEME}
cursor-color = #ffffff
selection-background = #807462
selection-foreground = #f5e6c6
palette = 0=#6d6551
palette = 8=#9a9a9a
palette = 6=#f3c86a
# 轻量对比度兜底。不要设太高，否则会改动 P10K prompt 的文字颜色。
minimum-contrast = 1.2

# 窗口
background-opacity = 0.96
background-blur = 10
macos-titlebar-style = transparent
window-padding-x = 10
window-padding-y = 8
window-theme = auto

# 光标
cursor-style = bar
cursor-style-blink = true
cursor-opacity = 0.85

# 鼠标
mouse-hide-while-typing = true
copy-on-select = clipboard

# 下拉终端
quick-terminal-position = top
quick-terminal-screen = mouse
quick-terminal-autohide = true
quick-terminal-animation-duration = 0.15
keybind = global:opt+backquote=toggle_quick_terminal

# 安全
clipboard-paste-protection = true
clipboard-paste-bracketed-safe = true

# Shell 集成
shell-integration = detect

# 分屏使用 Ghostty 默认快捷键：
# Cmd + D：向右新建分屏
# Cmd + Shift + D：向下新建分屏
# Cmd + Option + 方向键：切换分屏
# Cmd + W：关闭当前分屏 / surface

# 配置
keybind = super+shift+,=reload_config
keybind = super+,=open_config

# 性能
scrollback-limit = 25000000
GHOSTTY

  log "已写入 Ghostty 配置：$config_path"
}

write_micro_bindings() {
  local bindings_path="$HOME/.config/micro/bindings.json"
  local bindings_dir
  bindings_dir="$(dirname "$bindings_path")"
  mkdir -p "$bindings_dir"

  backup_file_if_exists "$bindings_path" "micro.bindings.json.before-setup"

  cat > "$bindings_path" <<'JSON'
{
  "Ctrl-left": "StartOfTextToggle",
  "Ctrl-right": "EndOfLine",
  "Ctrl-Up": "CursorStart",
  "Ctrl-Down": "CursorEnd"
}
JSON

  log "已写入 micro 快捷键配置：$bindings_path"
}

configure_git_diff_tools() {
  if ! command -v git >/dev/null 2>&1; then
    warn "未找到 git，跳过 git-delta / difftastic 的 git 配置"
    return
  fi

  backup_file_if_exists "$HOME/.gitconfig" ".gitconfig.before-setup"
  touch "$HOME/.gitignore_global"

  git config --global core.excludesfile "$HOME/.gitignore_global"
  git config --global core.pager delta
  git config --global interactive.diffFilter 'delta --color-only'

  git config --global delta.navigate true
  git config --global delta.side-by-side true
  git config --global delta.line-numbers true
  git config --global delta.syntax-theme DarkNeon
  git config --global delta.line-numbers-left-style '#ddcf81'
  git config --global delta.line-numbers-right-style '#4edcaa'
  git config --global delta.line-numbers-minus-style '#eb4c4c'
  git config --global delta.line-numbers-plus-style '#95eb79'
  git config --global delta.line-numbers-zero-style '#e9efd0'
  git config --global delta.minus-style 'syntax "#473030"'
  git config --global delta.plus-style 'syntax "#25313a"'
  git config --global delta.zero-style syntax

  git config --global merge.conflictStyle zdiff3
  git config --global difftool.difftastic.cmd 'difft "$LOCAL" "$REMOTE"'
  git config --global alias.df '!GIT_EXTERNAL_DIFF=difft git diff'
  git config --global alias.dfs '!GIT_EXTERNAL_DIFF=difft git diff --staged'
  git config --global alias.dfh '!GIT_EXTERNAL_DIFF=difft git diff HEAD'

  log "已写入 git-delta / difftastic 的 git 配置"
}

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.mac-setup-backups/$STAMP"
ZSHRC="$HOME/.zshrc"
P10K="$HOME/.p10k.zsh"
OMZ_DIR="$HOME/.oh-my-zsh"
NEW_ZSHRC_TMP="$(mktemp "${TMPDIR:-/tmp}/zshrc.homebrew.XXXXXX")"
GHOSTTY_CONFIG_WRITTEN=""

mkdir -p "$BACKUP_DIR"

cleanup_tmp() {
  rm -f "$NEW_ZSHRC_TMP"
}
trap cleanup_tmp EXIT

log "备份目录：$BACKUP_DIR"

BREW_CMD="$(find_brew || true)"
if [[ -z "$BREW_CMD" ]]; then
  if [[ "$INSTALL_HOMEBREW" -eq 1 ]]; then
    install_homebrew
    BREW_CMD="$(find_brew || true)"
  fi
fi
[[ -n "$BREW_CMD" ]] || fail "未找到 Homebrew。请先安装 Homebrew，或使用 --install-homebrew 重新运行。"

eval "$("$BREW_CMD" shellenv)"
BREW_CMD="$(command -v brew)"

require_cmd zsh
require_cmd tar
require_cmd mktemp
require_cmd grep
require_cmd find
require_cmd awk

backup_file_if_exists "$ZSHRC" ".zshrc.before-setup"
if [[ ! -f "$ZSHRC" ]]; then
  log "未找到现有 ~/.zshrc，将初始化一个新文件"
fi

backup_file_if_exists "$P10K" ".p10k.zsh.before-setup"

if [[ -e "$OMZ_DIR" ]]; then
  tar -czf "$BACKUP_DIR/oh-my-zsh.tar.gz" -C "$HOME" ".oh-my-zsh"
  log "已备份 ~/.oh-my-zsh"
else
  log "未找到 ~/.oh-my-zsh，跳过迁移删除步骤"
fi

ensure_brew_shellenv_in_zprofile "$BREW_CMD"

if [[ "$BREW_UPDATE" -eq 1 ]]; then
  log "更新 Homebrew 元数据"
  brew update
else
  log "因为指定了 --no-brew-update，跳过 brew update"
fi

ensure_zsh_patina_tap_if_needed

BASE_FORMULAS=(
  powerlevel10k
  zsh-autosuggestions
  zsh-autocomplete
  zsh-patina
)

MODERN_FORMULAS=(
  fzf
  zoxide
  eza
  bat
  yazi
  micro
  difftastic
  git-delta
  lazygit
  mole
)

for pkg in "${BASE_FORMULAS[@]}"; do
  install_or_upgrade_formula "$pkg"
done

for pkg in "${MODERN_FORMULAS[@]}"; do
  install_or_upgrade_formula "$pkg"
done

if [[ "$INSTALL_FONT" -eq 1 ]]; then
  install_meslo_font_if_needed
else
  log "因为指定了 --no-font，跳过字体安装/检测"
  warn "仍会写入 Ghostty 配置中的 MesloLGS NF 字体；如果本机没有该字体，Ghostty 可能回退到默认字体。"
fi

install_ghostty_if_needed

write_micro_bindings
configure_git_diff_tools

cat > "$NEW_ZSHRC_TMP" <<'ZSHRC'
# Powerlevel10k instant prompt。保持在文件顶部附近。
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Homebrew 路径。兼容 Apple Silicon 和 Intel Mac。
if [[ -z "${HOMEBREW_PREFIX:-}" ]]; then
  if command -v brew >/dev/null 2>&1; then
    HOMEBREW_PREFIX="$(brew --prefix)"
  elif [[ -x /opt/homebrew/bin/brew ]]; then
    HOMEBREW_PREFIX="/opt/homebrew"
  elif [[ -x /usr/local/bin/brew ]]; then
    HOMEBREW_PREFIX="/usr/local"
  fi
fi

_add_path_if_missing() {
  local dir="$1"
  [[ -d "$dir" ]] || return
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) export PATH="$dir:$PATH" ;;
  esac
}

_add_fpath_if_missing() {
  local dir="$1"
  [[ -d "$dir" ]] || return
  local existing
  for existing in "${fpath[@]}"; do
    [[ "$existing" == "$dir" ]] && return
  done
  fpath=("$dir" "${fpath[@]}")
}

if [[ -n "${HOMEBREW_PREFIX:-}" ]]; then
  _add_path_if_missing "$HOMEBREW_PREFIX/sbin"
  _add_path_if_missing "$HOMEBREW_PREFIX/bin"
  _add_fpath_if_missing "$HOMEBREW_PREFIX/share/zsh/site-functions"
  export HOMEBREW_PREFIX PATH
fi

ZSHRC

cat >> "$NEW_ZSHRC_TMP" <<'ZSHRC'
# fzf 先加载，避免它覆盖 zsh-autocomplete 的补全 widget。
if command -v fzf >/dev/null 2>&1; then
  source <(fzf --zsh)
fi

ZSHRC

cat >> "$NEW_ZSHRC_TMP" <<'ZSHRC'
# zsh-autocomplete 官方推荐：放在靠前位置，并替代手动 compinit。
# 这里显式配置为输入后自动显示补全列表，而不是必须按 Tab 才触发。
if [[ -n "${HOMEBREW_PREFIX:-}" && -r "$HOMEBREW_PREFIX/share/zsh-autocomplete/zsh-autocomplete.plugin.zsh" ]]; then
  zstyle ':autocomplete:*' delay 0.05
  zstyle ':autocomplete:*' timeout 2.0
  zstyle ':autocomplete:*' min-input 1
  zstyle -e ':autocomplete:*:*' list-lines 'reply=( 16 )'
  source "$HOMEBREW_PREFIX/share/zsh-autocomplete/zsh-autocomplete.plugin.zsh"
fi

# 历史记录
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt share_history
setopt hist_ignore_all_dups
setopt hist_ignore_space
setopt hist_reduce_blanks

# 输入目录名时自动 cd 进去。
setopt auto_cd

# 允许交互式 shell 识别 # 注释，方便直接粘贴带注释的命令块。
setopt interactive_comments

export EDITOR='micro'

_add_path_if_missing "$HOME/.lmstudio/bin"
_add_path_if_missing "$HOME/.opencode/bin"
_add_path_if_missing "$HOME/.miniforge3/bin"
_add_path_if_missing "$HOME/.local/bin"

# Mamba / Miniforge
if [[ -x "$HOME/.miniforge3/bin/mamba" ]]; then
  export MAMBA_EXE="$HOME/.miniforge3/bin/mamba"
  export MAMBA_ROOT_PREFIX="$HOME/.miniforge3"
  __mamba_setup="$($MAMBA_EXE shell hook --shell zsh --root-prefix "$MAMBA_ROOT_PREFIX" 2>/dev/null)"
  if [[ $? -eq 0 ]]; then
    eval "$__mamba_setup"
  else
    alias mamba="$MAMBA_EXE"
  fi
  unset __mamba_setup
fi

alias orunv='ollama run --verbose'
alias mc='micro'
alias oc='opencode'
alias lg='lazygit'
alias pic='cd ~/.pi-scratch && pi'
alias picc='cd ~/.pi-scratch && pi -c'

ZSHRC

cat >> "$NEW_ZSHRC_TMP" <<'ZSHRC'
# zoxide
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi

# eza：直接替换 ls。
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --icons --group-directories-first'
  alias ll='eza -la --icons --group-directories-first --git'
  alias la='eza -a --icons --group-directories-first'
  alias lt='eza --tree --icons --level=2 --group-directories-first'
fi

# bat
if command -v bat >/dev/null 2>&1; then
  alias batp='bat --paging=never --style=plain'
fi

# yazi
if command -v yazi >/dev/null 2>&1; then
  y() {
    local tmp cwd
    tmp="$(mktemp -t yazi-cwd.XXXXXX)" || return
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(command cat -- "$tmp" 2>/dev/null)" && [[ -n "$cwd" && "$cwd" != "$PWD" ]]; then
      builtin cd -- "$cwd"
    fi
    rm -f -- "$tmp"
  }
fi

ZSHRC

cat >> "$NEW_ZSHRC_TMP" <<'ZSHRC'
ulimit -n 4096

# zsh-autosuggestions
if [[ -n "${HOMEBREW_PREFIX:-}" && -r "$HOMEBREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
  source "$HOMEBREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi

# Powerlevel10k
if [[ -n "${HOMEBREW_PREFIX:-}" && -r "$HOMEBREW_PREFIX/share/powerlevel10k/powerlevel10k.zsh-theme" ]]; then
  source "$HOMEBREW_PREFIX/share/powerlevel10k/powerlevel10k.zsh-theme"
fi
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# zsh-patina 必须放在最后激活。
if command -v zsh-patina >/dev/null 2>&1; then
  eval "$(zsh-patina activate)"
elif [[ -n "${HOMEBREW_PREFIX:-}" && -x "$HOMEBREW_PREFIX/bin/zsh-patina" ]]; then
  eval "$("$HOMEBREW_PREFIX/bin/zsh-patina" activate)"
fi
ZSHRC

if ! zsh -n "$NEW_ZSHRC_TMP"; then
  fail "生成的 ~/.zshrc 存在语法错误，未写入正式文件。"
fi

install -m 0644 "$NEW_ZSHRC_TMP" "$ZSHRC"
log "已写入 ~/.zshrc"

GHOSTTY_CONFIG_WRITTEN="$(choose_ghostty_config_path)"
write_ghostty_config "$GHOSTTY_CONFIG_WRITTEN"

if [[ "$DELETE_OMZ" -eq 1 && -e "$OMZ_DIR" ]]; then
  rm -rf "$OMZ_DIR"
  log "已在备份后删除 ~/.oh-my-zsh"
elif [[ -e "$OMZ_DIR" ]]; then
  log "因为指定了 --no-delete-omz，保留 ~/.oh-my-zsh"
fi

cat <<SUMMARY

完成。

摘要：
  备份目录：        $BACKUP_DIR
  Zsh 配置：       $ZSHRC
  Ghostty 配置：   ${GHOSTTY_CONFIG_WRITTEN:-未写入}
  Ghostty 字体：   ${GHOSTTY_FONT_SIZE}
  Oh My Zsh：      $(if [[ "$DELETE_OMZ" -eq 1 ]]; then printf '如果存在则已删除'; else printf '已保留'; fi)
  基础工具：        ${BASE_FORMULAS[*]}
  现代 CLI：       ${MODERN_FORMULAS[*]}

下一步：
  1. 重启当前 shell：
       exec zsh

  2. 重启 Ghostty，或者在 Ghostty 里重新加载配置：
       Cmd + Shift + ,

  3. 如果 Powerlevel10k 图标显示异常，执行：
       p10k configure

  4. 如果下拉终端全局快捷键不生效，请给 Ghostty 开启辅助功能权限：
       系统设置 > 隐私与安全性 > 辅助功能 > Ghostty

常用命令：
  fzf：        Ctrl+R 搜索历史命令，Ctrl+T 搜索文件
  zoxide：     z <目录关键词>
  eza：        ls、ll、la、lt
  bat：        batp <文件>
  yazi：       y
  micro：      mc <文件>
  lazygit：    lg
  git-delta：  git diff / git show 时自动使用 delta
  difftastic： git df、git dfs、git dfh
  mole：       mole --help
  auto_cd：    直接输入目录名即可进入目录，例如：Downloads

Ghostty 分屏快捷键：
  Cmd + D：                  向右新建分屏
  Cmd + Shift + D：          向下新建分屏
  Cmd + Option + 方向键：    在分屏之间切换
  Cmd + W：                  关闭当前分屏 / surface

验证：
  ghostty +show-config | grep -E '^(font-family|font-size|theme|minimum-contrast|background-opacity|background-blur|quick-terminal|keybind = .*quick_terminal)'
  echo \$PATH

恢复：
  恢复 zshrc：
    cp '$BACKUP_DIR/.zshrc.before-setup' ~/.zshrc

  如果备份过 p10k 配置，可以恢复：
    cp '$BACKUP_DIR/.p10k.zsh.before-setup' ~/.p10k.zsh

  如果备份过 zprofile，可以恢复：
    cp '$BACKUP_DIR/.zprofile.before-homebrew-shellenv' ~/.zprofile

  如果备份过 gitconfig，可以恢复：
    cp '$BACKUP_DIR/.gitconfig.before-setup' ~/.gitconfig

  如果备份过 micro 快捷键配置，可以恢复：
    cp '$BACKUP_DIR/micro.bindings.json.before-setup' ~/.config/micro/bindings.json

  如果备份过 Ghostty 配置，可以恢复：
    cp '$BACKUP_DIR/ghostty.config.before-setup' '${GHOSTTY_CONFIG_WRITTEN:-/path/to/ghostty/config}'

  如果备份过 Oh My Zsh，可以恢复：
    tar -xzf '$BACKUP_DIR/oh-my-zsh.tar.gz' -C ~

SUMMARY
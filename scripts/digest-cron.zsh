#!/usr/bin/env zsh
# zsh-ai 每日知识库 cron 启动器(可提交到仓库,**不含任何密钥**)。
#
# cron 不加载 .zshrc,所以这里:
#   1. 从仓库外的 env 文件读取 provider / API key 等敏感配置
#   2. 只 source 插件本身(不碰 .zshrc)
#   3. 生成当天知识库
#
# 用法:
#   crontab:  0 18 * * * /usr/bin/zsh /path/to/zsh-ai/scripts/digest-cron.zsh >> ~/.zsh-ai/logs/digest.cron.log 2>&1
#   手动测试: zsh scripts/digest-cron.zsh
#
# 敏感配置放在仓库外的 env 文件(默认 ~/.config/zsh-ai/env,chmod 600),
# 可用 ZSH_AI_ENV_FILE 覆盖路径。该文件里 export ZSH_AI_LOG_DIR / ZSH_AI_PROVIDER /
# OPENAI_API_KEY 等。

emulate -L zsh

# 1. 载入仓库外的敏感配置(存在才载入)
env_file="${ZSH_AI_ENV_FILE:-$HOME/.config/zsh-ai/env}"
if [[ -r "$env_file" ]]; then
    source "$env_file"
fi

# 2. 载入插件:相对本脚本定位(scripts/ 的上一级就是仓库根)
plugin="${0:A:h:h}/zsh-ai.plugin.zsh"
if [[ ! -r "$plugin" ]]; then
    print -r -- "digest-cron: 找不到插件 $plugin" >&2
    exit 1
fi
source "$plugin"

# 3. 生成当天知识库(可传日期参数透传给 zsh-ai-digest)
zsh-ai-digest "$@"

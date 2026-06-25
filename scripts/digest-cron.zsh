#!/usr/bin/env zsh
# zsh-ai 每日知识库 cron 启动器(可提交到仓库,**不含任何密钥**)。
#
# cron 不加载 .zshrc,所以这里:
#   1. 从仓库外的 env 文件读取 provider / API key 等敏感配置
#   2. 生成当天知识库
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


# 2. 生成当天知识库(可传日期参数透传给 zsh-ai-digest)
zsh-ai-digest "$@"

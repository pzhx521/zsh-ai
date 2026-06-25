#!/usr/bin/env zsh

# Daily knowledge-base digest for zsh-ai.
#
# zsh-ai-digest [YYYY-MM-DD] reads that day's request log
# ($ZSH_AI_LOG_DIR/YYYY-MM-DD.jsonl), aggregates the commands, asks the model
# (same ZSH_AI_PROVIDER, but without the small per-command token cap) to write a
# markdown knowledge base, and saves it to $ZSH_AI_LOG_DIR/YYYY-MM-DD.md.
#
# Intended to run nightly via cron:  0 18 * * * zsh-ai-digest

# Aggregate a JSONL log into a compact, model-friendly TSV summary.
# Usage: _zsh_ai_digest_aggregate <jsonl-file> <date>
# Parsing is done in perl (a required dependency) so jq stays optional.
_zsh_ai_digest_aggregate() {
    emulate -L zsh
    local file="$1" date_str="$2"
    DIGEST_DATE="$date_str" perl -ne '
        chomp;
        next unless /\{/;
        my %f;
        while (/"(\w+)":"((?:[^"\\]|\\.)*)"/g) { $f{$1} = $2; }
        my $ok = (/"ok":true/) ? 1 : 0;
        $total++;
        if ($ok) { $succ++; } else { $fail++; }
        my $cmd = $f{command} // "";
        if ($ok && length $cmd) {
            $cnt{$cmd}++;
            $risk{$cmd} = $f{risk} // "";
            $q{$cmd} //= ($f{query} // "");
        }
        if (!$ok) {
            my $e = $f{error} // "";
            $e =~ s/\\[ntr]/ /g; $e = substr($e, 0, 160);
            push @fails, (($f{query} // "") . "\t" . $e);
        }
        END {
            print "DATE\t$ENV{DIGEST_DATE}\n";
            $succ ||= 0; $fail ||= 0; $total ||= 0;
            my $ncmds = scalar keys %cnt;
            print "TOTALS\trequests=$total\tsuccess=$succ\tfailed=$fail\tcommands=$ncmds\n";
            print "COMMANDS (count, risk, command, sample_query):\n";
            for my $c (sort { $cnt{$b} <=> $cnt{$a} } keys %cnt) {
                my ($cc, $qq) = ($c, $q{$c});
                for ($cc, $qq) { s/\\n/ /g; s/\\t/ /g; s/\\"/"/g; s/\\\\/\\/g; }
                print "$cnt{$c}\t$risk{$c}\t$cc\t$qq\n";
            }
            if (@fails) {
                print "FAILURES (query, error):\n";
                print "$_\n" for @fails;
            }
        }
    ' "$file"
}

# The system prompt that turns the aggregated summary into the knowledge base.
_zsh_ai_digest_system_prompt() {
    local date_str="$1"
    cat <<EOF
你是一个命令行知识库整理助手。下面会给你某一天用户通过 AI 生成的命令的聚合统计(TSV 格式)。请据此输出一份**中文 markdown 知识库文档**,严格遵循以下结构:

# 今日命令知识库 · ${date_str}

> 一行元信息:数据来源、统计口径(00:00–18:00)。

## 📊 当日概览
一个 markdown 表格:总请求、成功、失败、去重命令数、最常用命令、风险分布。

## 🔥 高频命令(按当日使用次数降序)
- **必须按 TSV 中 count 从高到低排序**,count 高的排最前。
- 每条命令一个小节,标题含:序号、命令用途简述、使用次数、风险等级(🟢安全/🟡中危/⚠️高危)。
- 命令本体放进 \`\`\`bash 代码块。
- 然后两栏说明:**用途**(这条命令解决什么问题)、**关键参数**(逐个解释关键 flag/参数的含义)。

- 若某条命令是**安装命令**(apt/apt-get/yum/dnf/pacman/brew/npm/pip/pip3/gem/cargo/go 等的 install),除了解释命令本身,还要**额外说明所安装的软件/SDK 是做什么的(用途、典型场景)**。

## 🧩 扩展命令 Demo(真实可用,按需取用)
- 围绕当天出现的命令,给出相关、实用的扩展命令。
- **所有命令必须是真实存在的工具/用法,严禁编造不存在的命令或参数。**
- 对版本有要求的工具,显式标注最低版本,如「需 iproute2 ≥ 4.0」「需 fd ≥ 8.0」「GNU find ≥ 4.3.3」。
- 命令放进 \`\`\`bash 代码块,并配一句简短说明。

## ⚠️ 当日高危/失败记录
- 列出高危命令(及次数)与失败请求(及原因摘要)。若无则写「无」。

要求:
1. 只输出 markdown 正文,不要用 \`\`\` 把整篇文档包起来,不要任何额外说明或前言。
2. 用途和参数解释要准确、简洁,不要照抄 sample_query。
3. 不确定的命令宁可不写,绝不臆造。
4. **整篇文档不超过 400 行**,内容精炼、不啰嗦;命令多时,扩展 Demo 部分按需精简,优先保证高频命令讲清楚。
EOF
}

# Generate the daily knowledge-base digest.
# Usage: zsh-ai-digest [YYYY-MM-DD]   (defaults to today, local date)
zsh-ai-digest() {
    emulate -L zsh

    if ! _zsh_ai_log_enabled; then
        echo "zsh-ai-digest: 未设置 ZSH_AI_LOG_DIR,没有日志可汇总。" >&2
        return 1
    fi

    local date_str="${1:-$(date +%Y-%m-%d)}"
    # Validate the date so it can't traverse paths when used in file names.
    if [[ ! "$date_str" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]]; then
        echo "zsh-ai-digest: 日期格式无效(应为 YYYY-MM-DD):$date_str" >&2
        return 1
    fi
    local infile="$ZSH_AI_LOG_DIR/$date_str.jsonl"
    if [[ ! -f "$infile" ]]; then
        echo "zsh-ai-digest: 找不到日志文件 $infile" >&2
        return 1
    fi

    local agg
    agg="$(_zsh_ai_digest_aggregate "$infile" "$date_str")"
    if [[ -z "$agg" ]] || [[ "$agg" != *COMMANDS* ]]; then
        echo "zsh-ai-digest: $date_str 没有可汇总的记录。" >&2
        return 1
    fi

    # Skip entirely when there are no successfully-generated commands that day
    # (even if there were failed requests): don't call the model, don't write a
    # file. Exits 0 so a nightly cron run stays quiet.
    local ncmds
    ncmds="$(printf '%s' "$agg" | sed -n 's/.*commands=\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [[ -z "$ncmds" || "$ncmds" -eq 0 ]]; then
        echo "zsh-ai-digest: $date_str 没有成功生成的命令记录,跳过。" >&2
        return 0
    fi

    # Knowledge-base docs live under memory/ to keep them separate from the raw
    # .jsonl logs. Created 700 (subshell umask, so it doesn't leak).
    local memdir="$ZSH_AI_LOG_DIR/memory"
    [[ -d "$memdir" ]] || ( umask 077; mkdir -p "$memdir" ) 2>/dev/null
    local outfile="$memdir/$date_str.md"

    # Reuse the provider request path, overriding (via zsh dynamic scope):
    #   - the system prompt -> digest instructions
    #   - raw content       -> keep markdown newlines (don't collapse to one line)
    #   - max tokens        -> a far larger budget for the long document
    local ZSH_AI_SYSTEM_PROMPT
    ZSH_AI_SYSTEM_PROMPT="$(_zsh_ai_digest_system_prompt "$date_str")"
    local ZSH_AI_RAW_CONTENT=1
    local ZSH_AI_MAX_TOKENS="${ZSH_AI_DIGEST_MAX_TOKENS:-16384}"

    echo "zsh-ai-digest: 正在用 ${ZSH_AI_PROVIDER}/$(_zsh_ai_current_model) 汇总 ${date_str} ..." >&2

    local doc rc
    doc="$(_zsh_ai_query "$agg")"
    rc=$?

    if (( rc != 0 )) || [[ -z "$doc" ]] || [[ "$doc" == "Error:"* ]] || [[ "$doc" == "API Error:"* ]]; then
        echo "zsh-ai-digest: 生成失败。" >&2
        [[ -n "$doc" ]] && print -r -- "$doc" >&2
        return 1
    fi

    # Strip control/ANSI escapes the model may have emitted before persisting,
    # then prepend a fixed disclaimer (our own text, not model-controlled) so a
    # prompt-injected "demo" command is never presented as vetted.
    doc="$(_zsh_ai_sanitize_doc "$doc")"
    doc="> ⚠️ 本文档由 AI 自动生成,命令仅供参考,执行前请人工确认安全性。"$'\n\n'"$doc"

    if ! print -r -- "$doc" > "$outfile" 2>/dev/null; then
        echo "zsh-ai-digest: 无法写入 $outfile" >&2
        return 1
    fi

    echo "zsh-ai-digest: 已生成 $outfile"
}

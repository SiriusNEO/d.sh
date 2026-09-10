#!/usr/bin/env bash
# d.sh: Bash 4.3+ and curl, no Python, jq, Node or package installation.
# Usage: edit the configuration below, then run: bash d.sh 'Set up this project'
# Commands run with your permissions. Linux/macOS/WSL; text files only.
# Independent implementation inspired by deepseek-ai/deepseek-harness minimal.

# ---- User configuration -----------------------------------------------------
# Environment variables with the same names override these defaults.

# Connection
BASE_URL=${BASE_URL:-https://api.deepseek.com}
MODEL_NAME=${MODEL_NAME:-deepseek-v4-flash}
# Required. Never commit a real key.
DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY:-''}

# Runtime
DSH_CWD=${DSH_CWD:-'.'}
DSH_SESSION_FILE=${DSH_SESSION_FILE-'session.jsonl'}   # empty = disabled
DSH_MAX_TOKENS=${DSH_MAX_TOKENS:-32768}
DSH_MAX_STEPS=${DSH_MAX_STEPS:-100}
DSH_COMMAND_TIMEOUT=${DSH_COMMAND_TIMEOUT:-300}
DSH_API_TIMEOUT=${DSH_API_TIMEOUT:-600}
DSH_SHOW_THINKING=${DSH_SHOW_THINKING:-0}              # 0 / 1
DSH_STREAM=${DSH_STREAM:-1}                            # 0 / 1
DSH_REASONING_EFFORT=${DSH_REASONING_EFFORT:-'max'}    # none / low / high / max

# Verbatim upstream sdk-minimal persona (MIT):
# deepseek-ai/deepseek-harness/packages/bundle/sdk-minimal/cordis.patch.yml
DSH_SYSTEM_PROMPT=${DSH_SYSTEM_PROMPT:-'You are a helpful software engineer assistant.'}

# Context compaction
DSH_CONTEXT_WINDOW=${DSH_CONTEXT_WINDOW:-1000000}
DSH_AUTO_COMPACT=${DSH_AUTO_COMPACT:-1}                # 0 / 1
DSH_COMPACT_THRESHOLD=${DSH_COMPACT_THRESHOLD:-''}     # empty = 80% of context
DSH_COMPACT_RETAIN=${DSH_COMPACT_RETAIN:-''}           # empty = 16% of context
DSH_COMPACT_MAX_TOKENS=${DSH_COMPACT_MAX_TOKENS:-8192}
DSH_COMPACT_RETRIES=${DSH_COMPACT_RETRIES:-1}
DSH_MAX_OVERFLOW_RETRIES=${DSH_MAX_OVERFLOW_RETRIES:-1}

# ---- End user configuration -------------------------------------------------

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf 'd.sh requires Bash 4.3+.\n' >&2
    exit 1
fi

# `errexit` and `nounset` are intentionally disabled: tool failures are model
# input, and the JSON/SSE state machines use sparse arrays. Failures that cross
# a function boundary are checked explicitly instead.

readonly DSH_OUTPUT_LIMIT=16000
readonly DSH_CLIP_EDGE=7900
readonly DSH_JSON_MAX_DEPTH=64
readonly DSH_SHELL_READ_SIZE=4096
readonly DSH_STREAM_MAX_TOOL_INDEX=255
# Verbatim upstream compaction marker (MIT):
# deepseek-ai/deepseek-harness/packages/compaction/compaction-tool-result-pruner/src/config.ts
readonly DSH_PRUNE_THRESHOLD=8192
readonly DSH_PRUNE_HEAD=4096
readonly DSH_PRUNE_TAIL=1024
readonly DSH_PRUNE_MARKER=$'\n\n[... tool result middle pruned ...]\n\n'
DSH_PID=''
DSH_IN=''
DSH_OUT=''
DSH_ACTIVE_CURL_PID=''
DSH_TOOL_RUNNING=0
DSH_INTERRUPTED=0

# Large and structured return values use namespaced globals to avoid command
# substitutions, which would copy data and discard state changes in subshells.
declare -A DSH_VALUE DSH_TYPE DSH_RAW
declare -a DSH_MESSAGES DSH_ROLES
declare -a DSH_CALL_IDS DSH_CALL_NAMES DSH_CALL_ARGUMENTS
declare -a DSH_EDITOR_LINES
declare -a DSH_STREAM_TOOL_SEEN DSH_STREAM_TOOL_IDS
declare -a DSH_STREAM_TOOL_NAMES DSH_STREAM_TOOL_ARGUMENTS

# The checkpoint preamble and instruction below are copied verbatim (MIT) from:
# deepseek-ai/deepseek-harness/packages/compaction/compaction-basic/src/summarizer.ts
DSH_CHECKPOINT_PREAMBLE='This is an automatically generated checkpoint condensing an earlier span of the conversation to free up context. Treat the captured context as established background and build on it without restating it. Continue the task directly from the messages that follow, without acknowledging this checkpoint.'
# Status text adapted from the upstream Web UI (MIT):
# deepseek-ai/deepseek-harness/packages/client/ui-chat/src/client/locale.ts
DSH_STATUS_RUNNING='[Deep diving ...]'
DSH_STATUS_COMPACTING='[Compacting context ...]'
IFS= read -r -d '' DSH_COMPACTION_INSTRUCTION <<'TEXT' || :
You are now acting as a compaction engine for this AI coding assistant. Condense the conversation ABOVE into a structured checkpoint that lets another model resume the work with no loss of essential context.

Output EXACTLY the Markdown structure below: keep every section, in order. Use terse bullets, not prose paragraphs. Write "(none)" for an empty section — never drop a section.

## Primary Request and Intent
- [the user's original and evolving goals; quote verbatim where the exact wording matters]

## Key Technical Concepts
- [technologies, frameworks, patterns, and conventions in play]

## Files and Code
- [exact path: why it matters, key changes or snippets]

## Errors and Fixes
- [error: how it was resolved, plus any related user feedback]

## Pending Jobs
- [explicitly requested work not yet completed]

## Current Work
- [precisely what was in progress at this checkpoint]

## Next Step
- [the single next action, directly in line with the most recent request, or "(none)"]

## Critical Context
- [decisions and their rationale, constraints, user preferences, open questions, data needed to continue]

Rules:
- Write concise English engineering prose. Preserve exact file paths, commands, error strings, identifiers, numeric values, function signatures, and syntax fragments.
- Capture user feedback and explicit instructions faithfully, especially corrections.
- Do NOT mention this summarization request or that the context was compacted.
- Output only the checkpoint text: do not call any tool or take any other action.
- If the conversation already contains a <compacted-summary> block, it is a PRIOR checkpoint. Do not copy it forward verbatim: preserve still-true facts, drop stale ones, and merge newer information into a single consolidated summary under the same structure.
TEXT
readonly DSH_CHECKPOINT_PREAMBLE DSH_COMPACTION_INSTRUCTION
readonly DSH_STATUS_RUNNING DSH_STATUS_COMPACTING

# ---- Diagnostics and setup --------------------------------------------------

dsh_log() { printf '%s\n' "$*" >&2; }
dsh_error() { DSH_RESULT="Tool error: $*"; return 1; }

dsh_is_positive_integer() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]]; }
dsh_is_nonnegative_integer() { [[ $1 =~ ^[0-9]{1,9}$ ]]; }
dsh_is_boolean() { [[ $1 == 0 || $1 == 1 ]]; }

dsh_prompt_read() {
    local prompt=$1 secret=${2:-0}
    if ((secret)); then
        IFS= read -r -s -p "$prompt" DSH_PROMPT_VALUE || return 1
        printf '\n' >&2
    else
        IFS= read -r -p "$prompt" DSH_PROMPT_VALUE || return 1
    fi
}

dsh_configure_connection() {
    local answer current_url=$BASE_URL current_model=$MODEL_NAME value
    [[ ${DSH_INTERACTIVE_SETUP:-0} == 1 || -z $DEEPSEEK_API_KEY ]] || return 0
    [[ -t 0 ]] || {
        dsh_log 'Interactive setup requires terminal stdin.'
        return 1
    }
    dsh_prompt_read 'Configure BASE_URL / MODEL_NAME / DEEPSEEK_API_KEY? [Y/n] ' || return 1
    answer=${DSH_PROMPT_VALUE,,}
    while :; do
        case $answer in
            ''|y|yes) break ;;
            n|no)
                if [[ -z $DEEPSEEK_API_KEY ]]; then
                    dsh_log 'DEEPSEEK_API_KEY is required when interactive setup is skipped.'
                    return 1
                fi
                return 0
                ;;
            *)
                dsh_prompt_read 'Please answer Y or N [Y/n] ' || return 1
                answer=${DSH_PROMPT_VALUE,,}
                ;;
        esac
    done
    dsh_prompt_read "BASE_URL [$current_url]: " || return 1
    value=$DSH_PROMPT_VALUE
    [[ -z $value ]] || current_url=$value
    dsh_prompt_read "MODEL_NAME [$current_model]: " || return 1
    value=$DSH_PROMPT_VALUE
    [[ -z $value ]] || current_model=$value
    if [[ -n $DEEPSEEK_API_KEY ]]; then
        dsh_prompt_read 'DEEPSEEK_API_KEY [press Enter to keep current]: ' 1 || return 1
        value=$DSH_PROMPT_VALUE
        [[ -z $value ]] || DEEPSEEK_API_KEY=$value
    else
        while [[ -z $DEEPSEEK_API_KEY ]]; do
            dsh_prompt_read 'DEEPSEEK_API_KEY [required]: ' 1 || return 1
            DEEPSEEK_API_KEY=$DSH_PROMPT_VALUE
        done
    fi
    BASE_URL=$current_url
    MODEL_NAME=$current_model
    DSH_SETUP_CHANGED=1
}

dsh_persist_connection() {
    local source=${BASH_SOURCE[0]} target=$PWD/d.sh tmp=$PWD/.d.sh.tmp.$$
    local line quoted old_umask found_url=0 found_model=0 found_key=0
    [[ ${DSH_SETUP_CHANGED:-0} == 1 ]] || return 0
    case $source in
        /*) ;;
        *) source=$PWD/${source#./} ;;
    esac
    if [[ ! -f $source ]]; then
        if [[ -f $target && -r $target ]]; then
            source=$target
        else
            dsh_log 'Configuration is active for this run only.'
            return 0
        fi
    fi
    [[ -f $source && -r $source ]] || {
        dsh_log 'Cannot save configuration: run a downloaded copy of d.sh instead of piping it into bash.'
        return 1
    }
    if [[ ( -e $target || -L $target ) && $target != "$source" ]]; then
        dsh_log "Cannot save configuration: $target already exists."
        return 1
    fi
    old_umask=$(umask)
    umask 077
    if ! {
        while IFS= read -r line || [[ -n $line ]]; do
            case $line in
                BASE_URL=*)
                    printf -v quoted '%q' "$BASE_URL"
                    printf "BASE_URL=\${BASE_URL:-%s}\n" "$quoted"
                    found_url=1 ;;
                MODEL_NAME=*)
                    printf -v quoted '%q' "$MODEL_NAME"
                    printf "MODEL_NAME=\${MODEL_NAME:-%s}\n" "$quoted"
                    found_model=1 ;;
                DEEPSEEK_API_KEY=*)
                    printf -v quoted '%q' "$DEEPSEEK_API_KEY"
                    printf "DEEPSEEK_API_KEY=\${DEEPSEEK_API_KEY:-%s}\n" "$quoted"
                    found_key=1 ;;
                *) printf '%s\n' "$line" ;;
            esac
        done < "$source"
    } > "$tmp"; then
        umask "$old_umask"
        rm -f -- "$tmp"
        dsh_log "Cannot write configured script: $target"
        return 1
    fi
    umask "$old_umask"
    if ((found_url != 1 || found_model != 1 || found_key != 1)); then
        rm -f -- "$tmp"
        dsh_log 'Cannot save configuration: expected configuration lines were not found.'
        return 1
    fi
    chmod 600 "$tmp" || {
        rm -f -- "$tmp"
        dsh_log "Cannot secure configured script: $target"
        return 1
    }
    mv -f -- "$tmp" "$target" || {
        rm -f -- "$tmp"
        dsh_log "Cannot replace configured script: $target"
        return 1
    }
    dsh_log "Saved configured script to $target (mode 600)."
}

dsh_validate_runtime_config() {
    local name
    case $DSH_REASONING_EFFORT in
        none|low|high|max) ;;
        *)
            dsh_log 'DSH_REASONING_EFFORT must be none, low, high or max.'
            return 1
            ;;
    esac

    for name in \
        DSH_MAX_TOKENS \
        DSH_MAX_STEPS \
        DSH_COMMAND_TIMEOUT \
        DSH_API_TIMEOUT \
        DSH_CONTEXT_WINDOW; do
        dsh_is_positive_integer "${!name}" || {
            dsh_log "$name must be a positive integer."
            return 1
        }
    done
    dsh_is_boolean "$DSH_SHOW_THINKING" || {
        dsh_log 'DSH_SHOW_THINKING must be 0 or 1.'
        return 1
    }
    dsh_is_boolean "$DSH_STREAM" || {
        dsh_log 'DSH_STREAM must be 0 or 1.'
        return 1
    }
    dsh_is_boolean "$DSH_AUTO_COMPACT" || {
        dsh_log 'DSH_AUTO_COMPACT must be 0 or 1.'
        return 1
    }
}

dsh_validate_compaction_config() {
    local name
    dsh_is_positive_integer "$DSH_COMPACT_MAX_TOKENS" || {
        dsh_log 'DSH_COMPACT_MAX_TOKENS must be a positive integer.'
        return 1
    }
    for name in DSH_COMPACT_RETRIES DSH_MAX_OVERFLOW_RETRIES; do
        dsh_is_nonnegative_integer "${!name}" || {
            dsh_log "$name must be a non-negative integer."
            return 1
        }
    done
    [[ -n $DSH_COMPACT_THRESHOLD ]] || DSH_COMPACT_THRESHOLD=$((DSH_CONTEXT_WINDOW * 80 / 100))
    [[ -n $DSH_COMPACT_RETAIN ]] || DSH_COMPACT_RETAIN=$((DSH_CONTEXT_WINDOW * 16 / 100))
    dsh_is_positive_integer "$DSH_COMPACT_THRESHOLD" || {
        dsh_log 'DSH_COMPACT_THRESHOLD must be empty or a positive integer.'
        return 1
    }
    dsh_is_nonnegative_integer "$DSH_COMPACT_RETAIN" || {
        dsh_log 'DSH_COMPACT_RETAIN must be empty or a non-negative integer.'
        return 1
    }
    ((DSH_COMPACT_THRESHOLD < DSH_CONTEXT_WINDOW)) || {
        dsh_log 'DSH_COMPACT_THRESHOLD must be smaller than DSH_CONTEXT_WINDOW.'
        return 1
    }
    ((DSH_COMPACT_RETAIN < DSH_COMPACT_THRESHOLD)) || {
        dsh_log 'DSH_COMPACT_RETAIN must be smaller than DSH_COMPACT_THRESHOLD.'
        return 1
    }
}

dsh_validate_connection_config() {
    [[ -n $MODEL_NAME ]] || {
        dsh_log 'MODEL_NAME must not be empty.'
        return 1
    }
    [[ -n $DEEPSEEK_API_KEY ]] || {
        dsh_log 'DEEPSEEK_API_KEY must not be empty.'
        return 1
    }
    [[ $DEEPSEEK_API_KEY != *[$'\r\n'\"\\]* ]] || {
        dsh_log 'DEEPSEEK_API_KEY contains invalid characters.'
        return 1
    }
    case $BASE_URL in
        http://*|https://*) ;;
        *)
            dsh_log 'BASE_URL must start with http:// or https://.'
            return 1
            ;;
    esac
    command -v curl >/dev/null || {
        dsh_log 'curl is required because Bash builtins cannot establish HTTPS connections.'
        return 1
    }
}

dsh_validate_config() {
    dsh_validate_runtime_config || return 1
    dsh_validate_compaction_config || return 1
    dsh_validate_connection_config
}

# ---- Text and JSON encoding -------------------------------------------------

dsh_clip() {
    DSH_RESULT=$1
    if (( ${#DSH_RESULT} > DSH_OUTPUT_LIMIT )); then
        DSH_RESULT=${DSH_RESULT:0:DSH_CLIP_EDGE}$'\n<response clipped; showing beginning and end>\n'${DSH_RESULT: -DSH_CLIP_EDGE}
    fi
}

# JSON strings are escaped/decoded using Bash builtins, including UTF-16
# surrogate pairs. NUL cannot be represented by Bash and is rejected explicitly.
dsh_quote() {
    local text=$1 i char escape
    text=${text//\\/\\\\}
    text=${text//\"/\\\"}
    for ((i=1; i<32; i++)); do
        printf -v escape '\\%03o' "$i"
        printf -v char '%b' "$escape"
        printf -v escape '\\u%04x' "$i"
        text=${text//"$char"/"$escape"}
    done
    DSH_QUOTED=\"$text\"
}

# ---- Conversation and persistence ------------------------------------------

dsh_history_rebuild() {
    local message separator=''
    DSH_HISTORY=''
    for message in "${DSH_MESSAGES[@]}"; do
        DSH_HISTORY+=$separator$message
        separator=,
    done
}

dsh_history_reset() {
    dsh_quote "$DSH_SYSTEM_PROMPT"
    DSH_MESSAGES=("{\"role\":\"system\",\"content\":$DSH_QUOTED}")
    DSH_ROLES=(system)
    dsh_history_rebuild
}

dsh_history_append() {
    DSH_MESSAGES+=("$1")
    DSH_ROLES+=("$2")
    DSH_HISTORY+=",$1"
}

dsh_history_join() {
    local start=$1 end=$2 i separator=
    DSH_JOINED=
    for ((i=start; i<=end; i++)); do
        DSH_JOINED+=$separator${DSH_MESSAGES[i]}
        separator=,
    done
}

# Session file format: one "<role>\t<message JSON>" line per message, system excluded.
# Rewritten atomically, so an interrupted run never leaves a half-written history.
dsh_session_save() {
    [[ -n $DSH_SESSION_FILE && ${DSH_SESSION_READY:-0} == 1 ]] || return 0
    local i tmp=$DSH_SESSION_FILE.tmp.$$ old_umask write_status=0
    old_umask=$(umask)
    umask 077
    {
        for ((i=1; i<${#DSH_MESSAGES[@]}; i++)); do
            printf '%s\t%s\n' "${DSH_ROLES[i]}" "${DSH_MESSAGES[i]}"
        done
    } > "$tmp" || write_status=$?
    umask "$old_umask"
    if ((write_status != 0)); then
        rm -f -- "$tmp"
        dsh_log "Cannot write session file: $DSH_SESSION_FILE"
        return 1
    fi
    chmod 600 "$tmp" || {
        rm -f -- "$tmp"
        dsh_log "Cannot secure session file: $DSH_SESSION_FILE"
        return 1
    }
    mv -f -- "$tmp" "$DSH_SESSION_FILE" || {
        rm -f -- "$tmp"
        dsh_log "Cannot replace session file: $DSH_SESSION_FILE"
        return 1
    }
}

dsh_session_load() {
    DSH_SESSION_LOADED=0
    [[ -n $DSH_SESSION_FILE && -f $DSH_SESSION_FILE ]] || return 0
    local role message skipped=0
    while IFS=$'\t' read -r role message || [[ -n $role ]]; do
        message=${message%$'\r'}
        case $role in
            system) continue ;;
            user|assistant|tool) ;;
            *) ((skipped+=1)); continue ;;
        esac
        if [[ -z $message ]] || ! dsh_parse "$message" ||
            [[ ${DSH_TYPE[root]} != object || ${DSH_TYPE[root/role]} != string || ${DSH_VALUE[root/role]} != "$role" ]]; then
            ((skipped+=1))
            continue
        fi
        DSH_MESSAGES+=("$message")
        DSH_ROLES+=("$role")
        ((DSH_SESSION_LOADED+=1))
    done < "$DSH_SESSION_FILE"
    dsh_history_rebuild
    ((skipped)) && dsh_log "Ignored $skipped malformed line(s) in $DSH_SESSION_FILE."
    return 0
}

# ---- JSON parser ------------------------------------------------------------

dsh_utf8() {
    local n=$1 octets='' byte escaped
    local -a bytes
    (( n > 0 && n <= 0x10ffff && (n < 0xd800 || n > 0xdfff) )) || return 1
    if ((n < 128)); then
        bytes=("$n")
    elif ((n < 2048)); then
        bytes=("$((192 | n >> 6))" "$((128 | n & 63))")
    elif ((n < 65536)); then
        bytes=("$((224 | n >> 12))" "$((128 | n >> 6 & 63))" "$((128 | n & 63))")
    else
        bytes=("$((240 | n >> 18))" "$((128 | n >> 12 & 63))" "$((128 | n >> 6 & 63))" "$((128 | n & 63))")
    fi
    for byte in "${bytes[@]}"; do
        printf -v escaped '\\%03o' "$byte"
        octets+=$escaped
    done
    printf -v DSH_CHAR '%b' "$octets"
}

dsh_json_string() {
    local value='' part escape hex low n
    [[ ${DSH_INPUT:0:1} == '"' ]] || return 1
    DSH_INPUT=${DSH_INPUT:1}
    while [[ -n $DSH_INPUT ]]; do
        part=${DSH_INPUT%%[\"\\]*}
        [[ $part != *[$'\001'-$'\037']* ]] || return 1
        value+=$part
        DSH_INPUT=${DSH_INPUT:${#part}}
        case ${DSH_INPUT:0:1} in
            '"')
                DSH_INPUT=${DSH_INPUT:1}
                DSH_STRING=$value
                return 0
                ;;
            \\)
                escape=${DSH_INPUT:1:1}
                DSH_INPUT=${DSH_INPUT:2}
                case $escape in
                    '"'|\\|'/') value+=$escape ;;
                    b) value+=$'\b' ;;
                    f) value+=$'\f' ;;
                    n) value+=$'\n' ;;
                    r) value+=$'\r' ;;
                    t) value+=$'\t' ;;
                    u)
                        hex=${DSH_INPUT:0:4}
                        [[ $hex =~ ^[0-9a-fA-F]{4}$ ]] || return 1
                        DSH_INPUT=${DSH_INPUT:4}
                        n=$((16#$hex))
                        if ((n >= 0xd800 && n <= 0xdbff)); then
                            [[ ${DSH_INPUT:0:2} == '\u' ]] || return 1
                            low=${DSH_INPUT:2:4}
                            [[ $low =~ ^[0-9a-fA-F]{4}$ ]] || return 1
                            ((16#$low >= 0xdc00 && 16#$low <= 0xdfff)) || return 1
                            n=$((0x10000 + (n - 0xd800) * 1024 + 16#$low - 0xdc00))
                            DSH_INPUT=${DSH_INPUT:6}
                        fi
                        dsh_utf8 "$n" || return 1
                        value+=$DSH_CHAR
                        ;;
                    *) return 1 ;;
                esac
                ;;
            *) return 1 ;;
        esac
    done
    return 1
}

dsh_json_space() { DSH_INPUT=${DSH_INPUT#"${DSH_INPUT%%[!$' \t\r\n']*}"}; }

dsh_json_value() {
    local path=$1 depth=$2 original key index=0 close token
    ((depth <= DSH_JSON_MAX_DEPTH)) || return 1
    dsh_json_space
    original=$DSH_INPUT
    case ${DSH_INPUT:0:1} in
        '"')
            dsh_json_string || return 1
            DSH_VALUE[$path]=$DSH_STRING
            DSH_TYPE[$path]=string
            ;;
        '{'|'[')
            if [[ ${DSH_INPUT:0:1} == '{' ]]; then
                close='}'
                DSH_TYPE[$path]=object
            else
                close=']'
                DSH_TYPE[$path]=array
            fi
            DSH_INPUT=${DSH_INPUT:1}
            dsh_json_space
            if [[ ${DSH_INPUT:0:1} != "$close" ]]; then
                while :; do
                    if [[ $close == '}' ]]; then
                        dsh_json_string || return 1
                        key=$DSH_STRING
                        dsh_json_space
                        [[ ${DSH_INPUT:0:1} == ':' ]] || return 1
                        DSH_INPUT=${DSH_INPUT:1}
                    else
                        key=$index
                        ((index+=1))
                    fi
                    dsh_json_value "$path/$key" "$((depth+1))" || return 1
                    dsh_json_space
                    [[ ${DSH_INPUT:0:1} == ',' ]] || break
                    DSH_INPUT=${DSH_INPUT:1}; dsh_json_space
                done
            fi
            [[ ${DSH_INPUT:0:1} == "$close" ]] || return 1
            DSH_INPUT=${DSH_INPUT:1}
            ;;
        *)
            if [[ $DSH_INPUT =~ ^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?) ]]; then
                token=${BASH_REMATCH[0]}
                DSH_INPUT=${DSH_INPUT:${#token}}
                DSH_VALUE[$path]=$token
                DSH_TYPE[$path]=$token
                [[ $token == true || $token == false || $token == null ]] || DSH_TYPE[$path]=number
            else
                return 1
            fi
            ;;
    esac
    DSH_RAW[$path]=${original:0:${#original}-${#DSH_INPUT}}
}

dsh_parse() {
    DSH_VALUE=()
    DSH_TYPE=()
    DSH_RAW=()
    DSH_INPUT=$1
    dsh_json_value root 0 || return 1
    dsh_json_space
    [[ -z $DSH_INPUT ]]
}

# ---- Persistent shell -------------------------------------------------------

dsh_shell_close() {
    if [[ -n $DSH_PID ]]; then
        # Job control gives this owned coprocess its own process group.
        kill -KILL -- "-$DSH_PID" 2>/dev/null || :
        wait "$DSH_PID" 2>/dev/null || :
    fi
    [[ -z $DSH_IN ]] || exec {DSH_IN}>&-
    [[ -z $DSH_OUT ]] || exec {DSH_OUT}<&-
    DSH_PID=''
    DSH_IN=''
    DSH_OUT=''
}

dsh_cancel_active_curl() {
    [[ -n $DSH_ACTIVE_CURL_PID ]] || return 0
    # SIGKILL, not SIGINT: background children may have SIGINT ignored.
    kill -KILL -- "$DSH_ACTIVE_CURL_PID" 2>/dev/null || :
}

dsh_interrupt() {
    DSH_INTERRUPTED=1
    dsh_cancel_active_curl
    if ((DSH_TOOL_RUNNING)); then
        dsh_shell_close
    fi
    printf '\n' >&2
}

dsh_shell_start() {
    set -m
    coproc DSH_SHELL {
        unset BASH_ENV
        exec bash --noprofile --norc -c '
            while IFS= read -r -d "" __mini_tag && IFS= read -r -d "" __mini_command; do
                eval -- "$__mini_command" </dev/null
                __mini_status=$?
                builtin printf "\036%s:%s\037" "$__mini_tag" "$__mini_status"
            done
        ' 2>&1
    }
    DSH_PID=$DSH_SHELL_PID
    exec {DSH_IN}>&"${DSH_SHELL[1]}" {DSH_OUT}<&"${DSH_SHELL[0]}"
}

dsh_bash() {
    local command=$1 token marker output='' chunk status rest started=$SECONDS
    local reset=$'\n[shell reset; next call starts in the initial directory/environment]'
    [[ -n $command ]] || {
        dsh_error 'command must not be empty'
        return 1
    }
    if ((DSH_INTERRUPTED)); then
        DSH_RESULT='[interrupted by user; command not started]'
        return 0
    fi
    if [[ -n $DSH_PID ]] && ! kill -0 "$DSH_PID" 2>/dev/null; then
        dsh_shell_close
    fi
    [[ -n $DSH_PID ]] || dsh_shell_start
    if ((DSH_INTERRUPTED)); then
        dsh_shell_close
        DSH_RESULT='[interrupted by user; command not started]'
        return 0
    fi
    printf -v token '%04x%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM"
    marker=$'\036'$token:
    if ! printf '%s\0%s\0' "$token" "$command" >&"$DSH_IN"; then
        dsh_shell_close
        dsh_error "shell input closed$reset"
        return 1
    fi
    while ((SECONDS - started < DSH_COMMAND_TIMEOUT)); do
        chunk=
        if IFS= read -r -t 0.1 -N "$DSH_SHELL_READ_SIZE" chunk <&"$DSH_OUT"; then
            status=0
        else
            status=$?
        fi
        output+=$chunk
        if [[ $output == *"$marker"* ]]; then
            rest=${output##*"$marker"}
            if [[ $rest == *$'\037'* ]]; then
                rest=${rest%%$'\037'*}
                if [[ $rest =~ ^[0-9]+$ ]]; then
                    dsh_clip "${output%%"$marker"*}"
                    DSH_RESULT+=$'\n'"[exit code: $rest]"
                    return 0
                fi
            fi
        fi
        if (( ${#output} > DSH_OUTPUT_LIMIT * 2 )); then
            output=${output:0:DSH_OUTPUT_LIMIT}$'\n<response clipped>\n'${output: -DSH_OUTPUT_LIMIT}
        fi
        if ((status == 1)) || ! kill -0 "$DSH_PID" 2>/dev/null; then
            dsh_shell_close
            dsh_clip "$output"
            if ((DSH_INTERRUPTED)); then
                DSH_RESULT+=$'\n[interrupted by user]'"$reset"
            else
                DSH_RESULT+=$'\n[shell exited]'"$reset"
            fi
            return 0
        fi
    done
    dsh_shell_close
    dsh_clip "$output"
    DSH_RESULT+=$'\n[command timed out]'"$reset"
}

# ---- File editor ------------------------------------------------------------

# Tool arguments are parsed into DSH_VALUE/DSH_TYPE. All editor operations use
# builtins; commands requested by the model may of course use installed tools.
dsh_editor_read_file() {
    local path=$1
    [[ -f $path && -r $path ]] || {
        dsh_error 'path must be an existing readable regular file'
        return 1
    }
    DSH_EDITOR_TEXT=''
    if IFS= read -r -d '' DSH_EDITOR_TEXT < "$path"; then
        dsh_error 'NUL/binary files are unsupported'
        return 1
    fi
}

dsh_editor_split_lines() {
    local rest=$DSH_EDITOR_TEXT
    DSH_EDITOR_LINES=()
    while [[ $rest == *$'\n'* ]]; do
        DSH_EDITOR_LINES+=("${rest%%$'\n'*}")
        rest=${rest#*$'\n'}
    done
    DSH_EDITOR_LINES+=("$rest")
}

dsh_editor_list_directory() {
    local path=$1 child grandchild
    [[ -z ${DSH_TYPE[root/view_range]} || ${DSH_TYPE[root/view_range]} == null ]] || {
        dsh_error 'view_range is only valid for files'
        return 1
    }
    DSH_RESULT="$path/"
    for child in "$path"/*; do
        [[ -e $child || -L $child ]] || continue
        [[ ${child##*/} != node_modules && ${child##*/} != __pycache__ ]] || continue
        DSH_RESULT+=$'\n'"$child"
        if [[ -d $child && ! -L $child ]]; then
            for grandchild in "$child"/*; do
                [[ -e $grandchild || -L $grandchild ]] || continue
                [[ ${grandchild##*/} != node_modules && ${grandchild##*/} != __pycache__ ]] || continue
                DSH_RESULT+=$'\n'"$grandchild"
                ((${#DSH_RESULT} <= DSH_OUTPUT_LIMIT)) || break
            done
        fi
        if ((${#DSH_RESULT} > DSH_OUTPUT_LIMIT)); then
            dsh_clip "$DSH_RESULT"
            return 0
        fi
    done
}

dsh_editor_create() {
    local path=$1
    [[ ${DSH_TYPE[root/file_text]} == string ]] || {
        dsh_error 'file_text must be a string'
        return 1
    }
    [[ ! -e $path && ! -L $path ]] || {
        dsh_error 'create cannot overwrite an existing path'
        return 1
    }
    if (set -o noclobber; printf '%s' "${DSH_VALUE[root/file_text]}" > "$path"); then
        DSH_RESULT="Created $path"
    else
        dsh_error "cannot create $path"
    fi
}

dsh_editor_view_file() {
    local start=1 end=${#DSH_EDITOR_LINES[@]} row i
    if [[ -n ${DSH_TYPE[root/view_range]} && ${DSH_TYPE[root/view_range]} != null ]]; then
        start=${DSH_VALUE[root/view_range/0]}
        end=${DSH_VALUE[root/view_range/1]}
        if [[ ${DSH_TYPE[root/view_range]} != array ||
            ${DSH_TYPE[root/view_range/0]} != number ||
            ${DSH_TYPE[root/view_range/1]} != number ||
            ! $start =~ ^[1-9][0-9]{0,8}$ ||
            ! $end =~ ^(-1|[1-9][0-9]{0,8})$ ||
            -n ${DSH_TYPE[root/view_range/2]} ]]; then
            dsh_error 'view_range must be [start, end], with end=-1 for EOF'
            return 1
        fi
    fi
    ((end != -1)) || end=${#DSH_EDITOR_LINES[@]}
    ((start <= end && end <= ${#DSH_EDITOR_LINES[@]})) || {
        dsh_error 'view_range is outside the file'
        return 1
    }
    DSH_RESULT=''
    for ((i=start; i<=end; i++)); do
        printf -v row '%6d  %s\n' "$i" "${DSH_EDITOR_LINES[i-1]}"
        DSH_RESULT+=$row
        if ((${#DSH_RESULT} > DSH_OUTPUT_LIMIT)); then
            dsh_clip "$DSH_RESULT"
            return 0
        fi
    done
}

dsh_editor_replace() {
    local path=$1 old=${DSH_VALUE[root/old_str]} new rest output
    [[ ${DSH_TYPE[root/old_str]} == string && -n $old ]] || {
        dsh_error 'old_str must be a non-empty string'
        return 1
    }
    [[ -z ${DSH_TYPE[root/new_str]} || ${DSH_TYPE[root/new_str]} == string ]] || {
        dsh_error 'new_str must be a string or omitted, not null'
        return 1
    }
    new=${DSH_VALUE[root/new_str]}
    [[ $DSH_EDITOR_TEXT == *"$old"* ]] || { dsh_error 'old_str did not match'; return 1; }
    rest=${DSH_EDITOR_TEXT#*"$old"}
    [[ $rest != *"$old"* ]] || {
        dsh_error 'old_str matched multiple times; include more context'
        return 1
    }
    output=${DSH_EDITOR_TEXT%%"$old"*}$new$rest
    if printf '%s' "$output" > "$path"; then
        DSH_RESULT="Edited $path"
    else
        dsh_error "cannot write $path"
    fi
}

dsh_editor_insert() {
    local path=$1 line=${DSH_VALUE[root/insert_line]} new=${DSH_VALUE[root/new_str]} output
    if [[ ${DSH_TYPE[root/new_str]} != string ||
        ${DSH_TYPE[root/insert_line]} != number ||
        ! $line =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
        dsh_error 'insert requires integer insert_line and string new_str'
        return 1
    fi
    ((line <= ${#DSH_EDITOR_LINES[@]})) || {
        dsh_error 'insert_line is outside the file'
        return 1
    }
    DSH_EDITOR_LINES=("${DSH_EDITOR_LINES[@]:0:line}" "$new" "${DSH_EDITOR_LINES[@]:line}")
    printf -v output '%s\n' "${DSH_EDITOR_LINES[@]}"
    output=${output%$'\n'}
    if printf '%s' "$output" > "$path"; then
        DSH_RESULT="Edited $path"
    else
        dsh_error "cannot write $path"
    fi
}

dsh_editor() {
    local command=${DSH_VALUE[root/command]} path=${DSH_VALUE[root/path]}
    [[ $path == /* ]] || { dsh_error 'path must be absolute'; return 1; }

    case $command in
        create) dsh_editor_create "$path" ;;
        view)
            if [[ -d $path ]]; then
                dsh_editor_list_directory "$path"
            else
                dsh_editor_read_file "$path" || return 1
                dsh_editor_split_lines
                dsh_editor_view_file
            fi
            ;;
        str_replace)
            dsh_editor_read_file "$path" || return 1
            dsh_editor_replace "$path"
            ;;
        insert)
            dsh_editor_read_file "$path" || return 1
            dsh_editor_split_lines
            dsh_editor_insert "$path"
            ;;
        *) dsh_error "unknown editor command: $command" ;;
    esac
}

# ---- Tool schemas -----------------------------------------------------------

dsh_tools() {
    # read -d '' preserves literal newlines in this embedded JSON schema.
    # Descriptions are adapted from the upstream sdk-minimal persistent Bash and
    # str_replace_editor schemas; wording reflects this script's different runtime.
    # Source (MIT): deepseek-ai/deepseek-harness/packages/bundle/sdk-minimal/cordis.patch.yml
    # Source (MIT): deepseek-ai/deepseek-harness/packages/fs/tool-str-replace-editor/src/index.ts
    IFS= read -r -d '' DSH_TOOLS <<'JSON' || :
[
 {"type":"function","function":{
  "name":"bash",
  "description":"Run a command in a persistent Bash shell. Current directory, environment variables, functions and sourced virtual environments persist across calls and user turns. Network access and permissions are those of the host. No TTY; command stdin is /dev/null. Use noninteractive installer flags. Start long-lived processes in the background with output redirected to log files. Timeout resets the shell and its environment. Avoid very large output.",
  "parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
 }},
 {"type":"function","function":{
  "name":"str_replace_editor",
  "description":"View, create or edit text files using absolute paths. view shows numbered lines or lists a directory two levels deep, excluding hidden entries, node_modules and __pycache__. create never overwrites an existing path. str_replace requires old_str to match exactly once, including whitespace; omit new_str to delete (null is invalid). insert adds new_str AFTER insert_line, where 0 means before the first line. Unused nullable parameters are ignored. Output is clipped at 16000 characters. NUL/binary files are unsupported.",
  "parameters":{"type":"object","properties":{
   "command":{"type":"string","enum":["view","create","str_replace","insert"]},
   "path":{"type":"string","description":"Absolute path"},
   "file_text":{"type":["string","null"]},
   "old_str":{"type":["string","null"]},
   "new_str":{"type":["string","null"]},
   "insert_line":{"type":["integer","null"]},
   "view_range":{"type":["array","null"],"items":{"type":"integer"},"description":"Inclusive [start,end], 1-based; end=-1 means EOF"}
  },"required":["command","path"]}
 }}
]
JSON
}

# ---- Context management and API transport ----------------------------------

dsh_estimate_json_tokens() {
    DSH_TOKEN_ESTIMATE=$(((${#1} + 3) / 4 + 4))
}

dsh_history_estimate() {
    local message total i
    dsh_estimate_json_tokens "$DSH_TOOLS"
    total=$DSH_TOKEN_ESTIMATE
    for ((i=0; i<${#DSH_MESSAGES[@]}; i++)); do
        message=${DSH_MESSAGES[i]}
        dsh_estimate_json_tokens "$message"
        ((total+=DSH_TOKEN_ESTIMATE))
    done
    DSH_HISTORY_TOKENS=$total
}

dsh_prune_tool_results() {
    local i content id pruned quoted_id quoted_content
    DSH_PRUNE_COUNT=0
    for ((i=1; i<${#DSH_MESSAGES[@]}; i++)); do
        [[ ${DSH_ROLES[i]} == tool ]] || continue
        if ! dsh_parse "${DSH_MESSAGES[i]}" || [[ ${DSH_TYPE[root/content]} != string ]]; then
            dsh_log '[compact] Cannot parse a stored tool result; skipping pruning.'
            continue
        fi
        content=${DSH_VALUE[root/content]}
        ((${#content} > DSH_PRUNE_THRESHOLD)) || continue
        id=${DSH_VALUE[root/tool_call_id]}
        pruned=${content:0:DSH_PRUNE_HEAD}$DSH_PRUNE_MARKER${content: -DSH_PRUNE_TAIL}
        dsh_quote "$id"
        quoted_id=$DSH_QUOTED
        dsh_quote "$pruned"
        quoted_content=$DSH_QUOTED
        DSH_MESSAGES[i]="{\"role\":\"tool\",\"tool_call_id\":$quoted_id,\"content\":$quoted_content}"
        ((DSH_PRUNE_COUNT+=1))
    done
    if ((DSH_PRUNE_COUNT)); then
        dsh_history_rebuild
        dsh_log "[compact] Pruned $DSH_PRUNE_COUNT oversized tool result(s)."
    fi
}

dsh_api_request() {
    local payload=$1 body_file status_file response status
    DSH_RESPONSE='' DSH_HTTP_STATUS='' DSH_CURL_STATUS=0
    body_file=$(mktemp "${TMPDIR:-/tmp}/dsh-body.XXXXXX") || {
        dsh_log 'Cannot create a temporary file for the API response.'
        return 1
    }
    status_file=$(mktemp "${TMPDIR:-/tmp}/dsh-status.XXXXXX") || {
        dsh_log 'Cannot create a temporary file for the API status.'
        rm -f -- "$body_file"
        return 1
    }
    # Feed headers through curl's stdin config so the key is not a process argument.
    # Process substitution avoids a temporary request-body file. The response goes
    # to temp files so a trapped SIGINT can kill curl by PID and reap it.
    command curl --disable --silent --show-error --connect-timeout 30 --max-time "$DSH_API_TIMEOUT" \
        --request POST --header 'Content-Type: application/json' \
        --data-binary @<(printf '%s' "$payload") --output "$body_file" --write-out '%{http_code}' \
        --config - "$BASE_URL" >"$status_file" <<< "header = \"Authorization: Bearer $DEEPSEEK_API_KEY\"" &
    DSH_ACTIVE_CURL_PID=$!
    ((DSH_INTERRUPTED)) && dsh_cancel_active_curl
    wait "$DSH_ACTIVE_CURL_PID"
    DSH_CURL_STATUS=$?
    if ((DSH_INTERRUPTED)); then
        wait "$DSH_ACTIVE_CURL_PID" 2>/dev/null || :
        DSH_ACTIVE_CURL_PID=''
        rm -f -- "$body_file" "$status_file"
        dsh_log '[interrupted] Request cancelled.'
        return 130
    fi
    DSH_ACTIVE_CURL_PID=''
    response=$(<"$body_file")
    status=$(<"$status_file")
    rm -f -- "$body_file" "$status_file"
    ((DSH_CURL_STATUS == 0)) || return 1
    DSH_HTTP_STATUS=$status
    DSH_RESPONSE=$response
}

dsh_build_payload() {
    local messages=$1 streaming=$2 max_tokens=$3
    local thinking=enabled effort='' model
    [[ $DSH_REASONING_EFFORT != none ]] || thinking=disabled
    [[ $DSH_REASONING_EFFORT == none ]] || effort=",\"reasoning_effort\":\"$DSH_REASONING_EFFORT\""
    dsh_quote "$MODEL_NAME"
    model=$DSH_QUOTED
    DSH_PAYLOAD="{\"model\":$model,\"messages\":[$messages],\"tools\":$DSH_TOOLS,\"stream\":$streaming,\"max_tokens\":$max_tokens,\"thinking\":{\"type\":\"$thinking\"}$effort}"
}

dsh_report_http_error() {
    local label=$1 status=$2 body=$3
    body=${body//"$DEEPSEEK_API_KEY"/[redacted]}
    if dsh_is_context_overflow "$body"; then
        dsh_log "$label HTTP ${status:-unknown} reported a context-window overflow."
        return 3
    fi
    dsh_log "$label HTTP ${status:-unknown}: ${body:0:2000}"
    return 1
}

dsh_is_context_overflow() {
    local detail=${1,,}
    [[ $detail == *context_length_exceeded* || $detail == *context_window_exceeded* ||
       $detail == *context-window-overflowed* || $detail == *'maximum context length'* ||
       $detail == *'maximum context window'* || $detail == *'max context length'* ||
       $detail == *'max context window'* || $detail == *'input is too long for this model'* ||
       $detail == *'request too large for model context'* ||
       $detail == *'input exceeds the model context'* ||
       $detail == *'prompt exceeds the model context'* ||
       $detail == *'messages exceed the model context'* ]]
}

dsh_summary_request() {
    local selected=$1 messages response status instruction compact code
    dsh_quote "$DSH_COMPACTION_INSTRUCTION"
    instruction=$DSH_QUOTED
    messages="${DSH_MESSAGES[0]},$selected,{\"role\":\"user\",\"content\":$instruction}"
    dsh_build_payload "$messages" false "$DSH_COMPACT_MAX_TOKENS"
    dsh_log "$DSH_STATUS_COMPACTING"
    dsh_api_request "$DSH_PAYLOAD"
    code=$?
    if ((code != 0)); then
        ((code == 130)) && return 130
        dsh_log "Compaction request failed (curl exit code $DSH_CURL_STATUS)."
        return 1
    fi
    response=$DSH_RESPONSE
    status=$DSH_HTTP_STATUS
    if [[ $status != 200 ]]; then
        response=${response//"$DEEPSEEK_API_KEY"/[redacted]}
        dsh_log "Compaction API HTTP $status: ${response:0:2000}"
        return 1
    fi
    dsh_parse "$response" || {
        dsh_log 'Compaction API returned invalid or unsupported JSON.'
        return 1
    }
    status=${DSH_VALUE[root/choices/0/finish_reason]}
    [[ $status == stop ]] || {
        dsh_log "Compaction did not finish cleanly (finish_reason=$status)."
        return 1
    }
    [[ ${DSH_TYPE[root/choices/0/message]} == object &&
       ${DSH_VALUE[root/choices/0/message/role]} == assistant &&
       ${DSH_TYPE[root/choices/0/message/content]} == string &&
       ( -z ${DSH_TYPE[root/choices/0/message/tool_calls/0]} || ${DSH_TYPE[root/choices/0/message/tool_calls/0]} == null ) ]] || {
        dsh_log 'Compaction response is missing a text-only assistant summary.'
        return 1
    }
    DSH_SUMMARY=${DSH_VALUE[root/choices/0/message/content]}
    compact=${DSH_SUMMARY//[[:space:]]/}
    [[ -n $compact ]] || {
        dsh_log 'Compaction produced an empty summary.'
        return 1
    }
}

dsh_select_compaction() {
    local retain=$1 count=${#DSH_MESSAGES[@]} keep accumulated=0 i
    ((count > 2)) || return 1
    keep=$count
    for ((i=count-1; i>=1; i--)); do
        dsh_estimate_json_tokens "${DSH_MESSAGES[i]}"
        ((accumulated+=DSH_TOKEN_ESTIMATE))
        keep=$i
        ((accumulated >= retain)) && break
    done
    while ((keep > 1)) && [[ ${DSH_ROLES[keep]} == tool ]]; do
        ((keep-=1))
    done
    ((keep > 1)) || return 1
    DSH_COMPACT_KEEP=$keep
    DSH_COMPACT_COUNT=$((keep - 1))
    DSH_SHADOWED_TOKENS=0
    for ((i=1; i<keep; i++)); do
        dsh_estimate_json_tokens "${DSH_MESSAGES[i]}"
        ((DSH_SHADOWED_TOKENS+=DSH_TOKEN_ESTIMATE))
    done
}

dsh_compact_once() {
    local mode=$1 retain=$DSH_COMPACT_RETAIN selected checkpoint checkpoint_message
    local checkpoint_tokens count i status
    local -a messages roles
    [[ $mode == pressure ]] || retain=0
    dsh_select_compaction "$retain" || return 1
    dsh_history_join 1 "$((DSH_COMPACT_KEEP - 1))"
    selected=$DSH_JOINED
    dsh_summary_request "$selected"
    status=$?
    ((status == 130)) && return 130
    ((status == 0)) || return 2
    checkpoint=$DSH_CHECKPOINT_PREAMBLE$'\n\n<compacted-summary>\n'$DSH_SUMMARY$'\n</compacted-summary>'
    dsh_quote "$checkpoint"
    checkpoint_message="{\"role\":\"user\",\"content\":$DSH_QUOTED}"
    dsh_estimate_json_tokens "$checkpoint_message"
    checkpoint_tokens=$DSH_TOKEN_ESTIMATE
    if ((checkpoint_tokens >= DSH_SHADOWED_TOKENS)); then
        dsh_log "[compact] Summary is not smaller than its source (~$checkpoint_tokens >= ~$DSH_SHADOWED_TOKENS tokens); history unchanged."
        return 2
    fi
    count=${#DSH_MESSAGES[@]}
    messages=("${DSH_MESSAGES[0]}" "$checkpoint_message")
    roles=(system user)
    for ((i=DSH_COMPACT_KEEP; i<count; i++)); do
        messages+=("${DSH_MESSAGES[i]}")
        roles+=("${DSH_ROLES[i]}")
    done
    DSH_MESSAGES=("${messages[@]}")
    DSH_ROLES=("${roles[@]}")
    dsh_history_rebuild
    dsh_log "[compact] Compacted $DSH_COMPACT_COUNT history item(s) (~$DSH_SHADOWED_TOKENS -> ~$checkpoint_tokens tokens)."
    if [[ $mode == manual ]]; then
        dsh_session_save || return 2
    fi
    return 0
}

dsh_compact_if_needed() {
    local attempt status
    ((DSH_AUTO_COMPACT)) || return 0
    dsh_history_estimate
    ((DSH_HISTORY_TOKENS >= DSH_COMPACT_THRESHOLD)) || return 0
    dsh_log "[compact] Estimated context ~$DSH_HISTORY_TOKENS tokens reached threshold $DSH_COMPACT_THRESHOLD."
    dsh_prune_tool_results
    dsh_history_estimate
    ((DSH_HISTORY_TOKENS >= DSH_COMPACT_THRESHOLD)) || return 0
    for ((attempt=0; attempt<=DSH_COMPACT_RETRIES; attempt++)); do
        dsh_compact_once pressure
        status=$?
        if ((status == 130)); then
            return 130
        fi
        if ((status != 0)); then
            dsh_log '[compact] Automatic compaction could not reduce the history further; continuing with the current history.'
            return 0
        fi
        dsh_history_estimate
        ((DSH_HISTORY_TOKENS < DSH_COMPACT_THRESHOLD)) && return 0
    done
    dsh_log "[compact] Context remains above threshold (~$DSH_HISTORY_TOKENS tokens)."
}

dsh_compact_after_overflow() {
    local status pruned
    dsh_prune_tool_results
    pruned=$DSH_PRUNE_COUNT
    dsh_compact_once overflow
    status=$?
    ((status == 130)) && return 130
    ((status == 0 || pruned > 0))
}

# ---- Streaming completion --------------------------------------------------

dsh_stream_reset() {
    DSH_STREAM_ROLE=assistant
    DSH_STREAM_CONTENT=''
    DSH_STREAM_REASONING=''
    DSH_STREAM_FINISH=''
    DSH_STREAM_ERROR=''
    DSH_STREAM_ERROR_BODY=''
    DSH_STREAM_CONTENT_SEEN=0
    DSH_STREAM_REASONING_SEEN=0
    DSH_STREAM_MAX_TOOL=-1
    DSH_STREAM_TOOL_SEEN=()
    DSH_STREAM_TOOL_IDS=()
    DSH_STREAM_TOOL_NAMES=()
    DSH_STREAM_TOOL_ARGUMENTS=()
}

dsh_stream_consume_tool_call() {
    local path=$1 index id
    index=${DSH_VALUE[$path/index]}
    if [[ ${DSH_TYPE[$path/index]} != number || ! $index =~ ^[0-9]+$ || $index -gt DSH_STREAM_MAX_TOOL_INDEX ]]; then
        DSH_STREAM_ERROR='API returned an invalid streaming tool-call index.'
        return 1
    fi

    DSH_STREAM_TOOL_SEEN[index]=1
    ((index > DSH_STREAM_MAX_TOOL)) && DSH_STREAM_MAX_TOOL=$index

    if [[ ${DSH_TYPE[$path/id]} == string ]]; then
        id=${DSH_VALUE[$path/id]}
        if [[ -n ${DSH_STREAM_TOOL_IDS[index]} && ${DSH_STREAM_TOOL_IDS[index]} != "$id" ]]; then
            DSH_STREAM_ERROR='API changed a streaming tool-call id.'
            return 1
        fi
        DSH_STREAM_TOOL_IDS[index]=$id
    fi
    if [[ ${DSH_TYPE[$path/type]} == string && ${DSH_VALUE[$path/type]} != function ]]; then
        DSH_STREAM_ERROR='API returned an unsupported streaming tool-call type.'
        return 1
    fi
    if [[ ${DSH_TYPE[$path/function/name]} == string ]]; then
        DSH_STREAM_TOOL_NAMES[index]+=${DSH_VALUE[$path/function/name]}
    fi
    if [[ ${DSH_TYPE[$path/function/arguments]} == string ]]; then
        DSH_STREAM_TOOL_ARGUMENTS[index]+=${DSH_VALUE[$path/function/arguments]}
    fi
}

dsh_stream_consume_event() {
    local data=$1 path piece i
    if ! dsh_parse "$data"; then
        DSH_STREAM_ERROR='API returned an invalid or unsupported SSE JSON chunk.'
        return 1
    fi
    if [[ ${DSH_TYPE[root/error]} == object ]]; then
        DSH_STREAM_ERROR_BODY+="${DSH_STREAM_ERROR_BODY:+$'\n'}$data"
        return 0
    fi
    [[ ${DSH_TYPE[root/choices/0]} == object ]] || return 0

    if [[ ${DSH_TYPE[root/choices/0/delta/role]} == string ]]; then
        DSH_STREAM_ROLE=${DSH_VALUE[root/choices/0/delta/role]}
    fi
    if [[ ${DSH_TYPE[root/choices/0/delta/reasoning_content]} == string ]]; then
        piece=${DSH_VALUE[root/choices/0/delta/reasoning_content]}
        DSH_STREAM_REASONING+=$piece
        DSH_STREAM_REASONING_SEEN=1
        ((DSH_SHOW_THINKING)) && printf '%s' "$piece" >&2
    fi
    if [[ ${DSH_TYPE[root/choices/0/delta/content]} == string ]]; then
        piece=${DSH_VALUE[root/choices/0/delta/content]}
        DSH_STREAM_CONTENT+=$piece
        DSH_STREAM_CONTENT_SEEN=1
        printf '%s' "$piece"
    fi
    for ((i=0; ; i++)); do
        path=root/choices/0/delta/tool_calls/$i
        [[ -n ${DSH_TYPE[$path]} ]] || break
        dsh_stream_consume_tool_call "$path" || return 1
    done
    if [[ ${DSH_TYPE[root/choices/0/finish_reason]} == string ]]; then
        DSH_STREAM_FINISH=${DSH_VALUE[root/choices/0/finish_reason]}
    fi
}

dsh_stream_build_response() {
    local assistant content_json quoted_finish quoted_id quoted_name quoted_arguments
    local tool_calls='' separator='' i

    [[ $DSH_STREAM_ROLE == assistant ]] || {
        dsh_log "API stream returned an unexpected role: $DSH_STREAM_ROLE"
        return 1
    }
    [[ $DSH_STREAM_FINISH == stop || $DSH_STREAM_FINISH == tool_calls ]] || {
        dsh_log "Incomplete API stream (finish_reason=$DSH_STREAM_FINISH). If length, increase DSH_MAX_TOKENS."
        return 1
    }

    if ((DSH_STREAM_CONTENT_SEEN)); then
        dsh_quote "$DSH_STREAM_CONTENT"
        content_json=$DSH_QUOTED
    else
        content_json=null
    fi
    assistant="{\"role\":\"assistant\",\"content\":$content_json"

    if ((DSH_STREAM_REASONING_SEEN)); then
        dsh_quote "$DSH_STREAM_REASONING"
        assistant+=",\"reasoning_content\":$DSH_QUOTED"
    fi
    if ((DSH_STREAM_MAX_TOOL >= 0)); then
        for ((i=0; i<=DSH_STREAM_MAX_TOOL; i++)); do
            [[ ${DSH_STREAM_TOOL_SEEN[i]} == 1 && -n ${DSH_STREAM_TOOL_IDS[i]} && -n ${DSH_STREAM_TOOL_NAMES[i]} ]] || {
                dsh_log 'API returned an incomplete streaming tool call.'
                return 1
            }
            dsh_quote "${DSH_STREAM_TOOL_IDS[i]}"
            quoted_id=$DSH_QUOTED
            dsh_quote "${DSH_STREAM_TOOL_NAMES[i]}"
            quoted_name=$DSH_QUOTED
            dsh_quote "${DSH_STREAM_TOOL_ARGUMENTS[i]}"
            quoted_arguments=$DSH_QUOTED
            tool_calls+=$separator"{\"id\":$quoted_id,\"type\":\"function\",\"function\":{\"name\":$quoted_name,\"arguments\":$quoted_arguments}}"
            separator=,
        done
        assistant+=",\"tool_calls\":[$tool_calls]"
    fi
    assistant+='}'

    dsh_quote "$DSH_STREAM_FINISH"
    quoted_finish=$DSH_QUOTED
    DSH_RESPONSE="{\"choices\":[{\"finish_reason\":$quoted_finish,\"message\":$assistant}]}"
    dsh_parse "$DSH_RESPONSE" || {
        dsh_log 'Failed to assemble the streamed assistant message.'
        return 1
    }
    dsh_history_append "$assistant" assistant
}

dsh_complete_stream() {
    local stream_fd curl_pid curl_status line data http_status=''
    dsh_stream_reset
    dsh_build_payload "$DSH_HISTORY" true "$DSH_MAX_TOKENS"
    dsh_log "$DSH_STATUS_RUNNING"

    exec {stream_fd}< <(
        command curl --disable --silent --show-error --no-buffer --connect-timeout 30 --max-time "$DSH_API_TIMEOUT" \
            --request POST --header 'Content-Type: application/json' --header 'Accept: text/event-stream' \
            --data-binary @<(printf '%s' "$DSH_PAYLOAD") --write-out $'\n\036dsh-http:%{http_code}\037\n' \
            --config - "$BASE_URL" <<< "header = \"Authorization: Bearer $DEEPSEEK_API_KEY\""
    )
    curl_pid=$!
    DSH_ACTIVE_CURL_PID=$curl_pid
    ((DSH_INTERRUPTED)) && dsh_cancel_active_curl

    while IFS= read -r line <&"$stream_fd"; do
        line=${line%$'\r'}
        if [[ $line == $'\036dsh-http:'*$'\037' ]]; then
            http_status=${line#$'\036dsh-http:'}
            http_status=${http_status%$'\037'}
            continue
        fi
        case $line in
            data:*)
                data=${line#data:}
                data=${data# }
                [[ -z $data || $data == '[DONE]' ]] || dsh_stream_consume_event "$data" || :
                ;;
            ''|event:*|id:*|retry:*|:*) ;;
            *) DSH_STREAM_ERROR_BODY+="${DSH_STREAM_ERROR_BODY:+$'\n'}$line" ;;
        esac
    done
    exec {stream_fd}<&-
    wait "$curl_pid"
    curl_status=$?
    if ((DSH_INTERRUPTED)); then
        wait "$curl_pid" 2>/dev/null || :
    fi
    DSH_ACTIVE_CURL_PID=''

    ((DSH_STREAM_CONTENT_SEEN)) && printf '\n'
    ((DSH_SHOW_THINKING && DSH_STREAM_REASONING_SEEN)) && printf '\n' >&2
    if ((DSH_INTERRUPTED)); then
        dsh_log '[interrupted] Request cancelled.'
        return 130
    fi
    if ((curl_status != 0)); then
        dsh_log "curl stream failed (exit code $curl_status); no tools executed for this request."
        return 1
    fi
    if [[ $http_status != 200 ]]; then
        dsh_report_http_error 'API' "$http_status" "$DSH_STREAM_ERROR_BODY"
        return $?
    fi
    if [[ -n $DSH_STREAM_ERROR_BODY && -z $DSH_STREAM_FINISH ]]; then
        dsh_report_http_error 'API stream' "$http_status" "$DSH_STREAM_ERROR_BODY"
        return $?
    fi
    [[ -z $DSH_STREAM_ERROR ]] || {
        dsh_log "$DSH_STREAM_ERROR"
        return 1
    }
    dsh_stream_build_response
}

dsh_complete() {
    local response status
    if ((DSH_STREAM)); then
        dsh_complete_stream
        return $?
    fi
    dsh_build_payload "$DSH_HISTORY" false "$DSH_MAX_TOKENS"
    dsh_log "$DSH_STATUS_RUNNING"
    dsh_api_request "$DSH_PAYLOAD"
    status=$?
    if ((status != 0)); then
        ((status == 130)) && return 130
        dsh_log "curl request failed (exit code $DSH_CURL_STATUS); no tools executed for this request."
        return 1
    fi
    response=$DSH_RESPONSE
    status=$DSH_HTTP_STATUS
    if [[ $status != 200 ]]; then
        dsh_report_http_error 'API' "$status" "$response"
        return $?
    fi
    dsh_parse "$response" || {
        dsh_log 'API returned invalid or unsupported JSON (Bash cannot represent NUL characters).'
        return 1
    }
    status=${DSH_VALUE[root/choices/0/finish_reason]}
    [[ $status == stop || $status == tool_calls ]] || {
        dsh_log "Incomplete API response (finish_reason=$status); no tools executed for this request. If length, increase DSH_MAX_TOKENS."
        return 1
    }
    [[ ${DSH_TYPE[root/choices/0/message]} == object && ${DSH_VALUE[root/choices/0/message/role]} == assistant ]] || {
        dsh_log 'API response is missing an assistant message.'
        return 1
    }
    # Preserve the original assistant JSON, including ALL reasoning_content.
    dsh_history_append "${DSH_RAW[root/choices/0/message]}" assistant
    [[ -z ${DSH_VALUE[root/choices/0/message/content]} || ${DSH_TYPE[root/choices/0/message/content]} == null ]] || \
        printf '%s\n' "${DSH_VALUE[root/choices/0/message/content]}"
    if ((DSH_SHOW_THINKING)) && [[ ${DSH_TYPE[root/choices/0/message/reasoning_content]} == string ]]; then
        dsh_log "${DSH_VALUE[root/choices/0/message/reasoning_content]}"
    fi
}

# ---- Agent loop -------------------------------------------------------------

dsh_complete_with_recovery() {
    local status retries=0
    while :; do
        dsh_complete
        status=$?
        ((status == 0)) && return 0
        ((status == 130)) && return 130
        ((status == 3)) || return 1

        if ((!DSH_AUTO_COMPACT)); then
            dsh_log '[compact] Overflow recovery is disabled by DSH_AUTO_COMPACT=0.'
            return 1
        fi
        if ((retries >= DSH_MAX_OVERFLOW_RETRIES)); then
            dsh_log '[compact] Context-overflow retry limit reached.'
            return 1
        fi

        ((retries+=1))
        dsh_log "[compact] Attempting context-overflow recovery ($retries/$DSH_MAX_OVERFLOW_RETRIES)."
        dsh_compact_after_overflow
        status=$?
        ((status == 130)) && return 130
        if ((status != 0)); then
            dsh_log '[compact] No safe history reduction was available for overflow recovery.'
            return 1
        fi
    done
}

dsh_collect_tool_calls() {
    local i path id name
    DSH_CALL_IDS=()
    DSH_CALL_NAMES=()
    DSH_CALL_ARGUMENTS=()

    for ((i=0; ; i++)); do
        path=root/choices/0/message/tool_calls/$i
        [[ -n ${DSH_TYPE[$path]} ]] || break
        id=${DSH_VALUE[$path/id]}
        name=${DSH_VALUE[$path/function/name]}
        if [[ -z $id || -z $name || ${DSH_TYPE[$path/function/arguments]} != string ]]; then
            dsh_log 'API returned an incomplete tool call.'
            return 1
        fi
        DSH_CALL_IDS+=("$id")
        DSH_CALL_NAMES+=("$name")
        DSH_CALL_ARGUMENTS+=("${DSH_VALUE[$path/function/arguments]}")
    done
}

dsh_dispatch_tool() {
    local name=$1 arguments=$2
    dsh_log "[$name] ${arguments:0:2000}"

    if ! dsh_parse "$arguments" || [[ ${DSH_TYPE[root]} != object ]]; then
        DSH_RESULT='Tool error: arguments must be a valid JSON object (no NUL)'
    elif [[ $name == bash && ${DSH_TYPE[root/command]} == string ]]; then
        DSH_TOOL_RUNNING=1
        dsh_bash "${DSH_VALUE[root/command]}" || :
        DSH_TOOL_RUNNING=0
    elif [[ $name == str_replace_editor &&
        ${DSH_TYPE[root/command]} == string &&
        ${DSH_TYPE[root/path]} == string ]]; then
        dsh_editor || :
    else
        DSH_RESULT="Tool error: unknown tool or missing string command/path: $name"
    fi
    dsh_clip "$DSH_RESULT"
    dsh_log "$DSH_RESULT"
}

dsh_append_tool_result() {
    local id=$1 result=$2 quoted_id
    dsh_quote "$id"
    quoted_id=$DSH_QUOTED
    dsh_quote "$result"
    dsh_history_append "{\"role\":\"tool\",\"tool_call_id\":$quoted_id,\"content\":$DSH_QUOTED}" tool
}

dsh_turn() {
    local prompt=$1 step i
    DSH_INTERRUPTED=0
    dsh_quote "$prompt"
    dsh_history_append "{\"role\":\"user\",\"content\":$DSH_QUOTED}" user
    for ((step=0; step<DSH_MAX_STEPS; step++)); do
        dsh_compact_if_needed || return $?
        dsh_complete_with_recovery || return $?
        dsh_collect_tool_calls || return 1

        if ((${#DSH_CALL_IDS[@]} == 0)); then
            if [[ ${DSH_VALUE[root/choices/0/finish_reason]} == stop ]]; then
                dsh_session_save || return 1
                return 0
            fi
            dsh_log 'API indicated tool calls but returned none.'
            return 1
        fi

        for ((i=0; i<${#DSH_CALL_IDS[@]}; i++)); do
            dsh_dispatch_tool "${DSH_CALL_NAMES[i]}" "${DSH_CALL_ARGUMENTS[i]}"
            dsh_append_tool_result "${DSH_CALL_IDS[i]}" "$DSH_RESULT"
            if ((DSH_INTERRUPTED)); then
                dsh_log '[interrupted] Tool execution cancelled.'
                return 130
            fi
        done
    done
    dsh_log "Reached DSH_MAX_STEPS=$DSH_MAX_STEPS; the task may be unfinished."
    return 1
}

# ---- Command-line interface -------------------------------------------------

dsh_help() {
    printf '%s\n' \
        'd.sh - Single-file Bash + curl agent for DeepSeek-compatible APIs' \
        'Usage: bash d.sh [task]' \
        '  Omit the task for interactive mode; use - or pipe input to read stdin.' \
        '  -h, --help             Show this help' \
        '  --                     Treat all remaining arguments as task text' \
        'Edit the configuration block at the top of d.sh.' \
        'Interactive commands: /compact, /clear, /exit; Ctrl+C cancels the running request.'
}

dsh_run_manual_compaction() {
    local status
    DSH_INTERRUPTED=0
    dsh_compact_once manual
    status=$?
    case $status in
        0) ;;
        1) dsh_log 'No compactable history yet.' ;;
        2) dsh_log 'Compaction failed; conversation history is unchanged.' ;;
        *) return "$status" ;;
    esac
}

dsh_run_interactive() {
    local prompt status
    dsh_log 'Enter a task. /compact summarizes old history; /clear resets conversation and shell; Ctrl+C cancels the current request; /exit or Ctrl-D exits.'
    while :; do
        if IFS= read -r -e -p 'You> ' prompt; then
            :
        else
            status=$?
            if ((status == 130)); then
                DSH_INTERRUPTED=0
                continue
            fi
            printf '\n' >&2
            return 0
        fi
        case $prompt in
            /exit|/quit) return 0 ;;
            /compact) dsh_run_manual_compaction; status=$? ;;
            /clear)
                dsh_shell_close
                dsh_history_reset
                dsh_session_save; status=$?
                ;;
            '') continue ;;
            *) dsh_turn "$prompt"; status=$? ;;
        esac
        case $status in
            0) ;;
            130) DSH_INTERRUPTED=0 ;;
            *) return "$status" ;;
        esac
    done
}

dsh_main() {
    local prompt='' cwd=$DSH_CWD option interactive=0
    while (($#)); do
        option=$1
        shift
        case $option in
            -h|--help)
                dsh_help
                return 0
                ;;
            --)
                prompt+="${prompt:+ }$*"
                break
                ;;
            -) prompt+="${prompt:+ }-" ;;
            -*)
                dsh_log "Unknown option: $option (edit the configuration block in d.sh)"
                return 2
                ;;
            *) prompt+="${prompt:+ }$option" ;;
        esac
    done

    DSH_SETUP_CHANGED=0
    dsh_configure_connection || return 2
    dsh_validate_config || return 2
    dsh_persist_connection || return 2
    BASE_URL=${BASE_URL%/}
    [[ $BASE_URL == */chat/completions ]] || BASE_URL+=/chat/completions
    cd -- "$cwd" || {
        dsh_log "Cannot enter working directory: $cwd"
        return 2
    }

    trap dsh_shell_close EXIT
    trap dsh_interrupt INT
    trap 'exit 143' TERM
    dsh_tools
    dsh_history_reset
    dsh_session_load
    DSH_SESSION_READY=1

    [[ -n $prompt || ! -t 0 ]] || interactive=1
    if [[ $prompt == - ]] || { [[ -z $prompt ]] && ((!interactive)); }; then
        IFS= read -r -d '' prompt || :
    fi

    dsh_log "d.sh | $MODEL_NAME | $PWD"
    if ((DSH_SESSION_LOADED)); then
        dsh_log "Resumed $DSH_SESSION_LOADED message(s) from $DSH_SESSION_FILE."
    fi

    if ((interactive)); then
        dsh_run_interactive
        return $?
    fi
    [[ -n $prompt ]] || {
        dsh_log 'Task text is empty.'
        return 2
    }
    dsh_turn "$prompt"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    dsh_main "$@"
    exit $?
fi

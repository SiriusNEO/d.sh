# d.sh

A minimal coding agent for DeepSeek-compatible APIs, all in **one Bash file: `d.sh`**. It requires only Bash 4.3+ and curl. On minimal servers without a full dependency stack, it can bootstrap a more capable harness (Codex, Claude Code, DeepSeek Harness) or handle simple environment setup — serving as a **bootloader agent**.

## Quick Start

Run once without saving the script or configuration:

```bash
DEEPSEEK_API_KEY='your-api-key' bash <(curl -fsSL https://raw.githubusercontent.com/SiriusNEO/d.sh/main/d.sh)
```

Save a configured copy and keep using it:

```bash
curl -fsSL https://raw.githubusercontent.com/SiriusNEO/d.sh/main/d.sh -o d.sh
bash d.sh
```

The first command downloads the script as `d.sh` in the current directory; any existing copy is overwritten. The second runs it and starts an interactive setup for `BASE_URL`, `MODEL_NAME`, and `DEEPSEEK_API_KEY`, then drops you into the interactive prompt. The chosen values are written back into `d.sh` with mode `600`, so later runs only need `bash d.sh`.

## Configuration

The three connection settings are:

| Variable | Purpose |
| --- | --- |
| `DEEPSEEK_API_KEY` | API key; required |
| `BASE_URL` | DeepSeek-compatible API endpoint |
| `MODEL_NAME` | Model sent with each request |

`BASE_URL` defaults to `https://api.deepseek.com` and `MODEL_NAME` to `deepseek-v4-flash`. `DEEPSEEK_API_KEY` is always required. During interactive setup, press Enter to keep the displayed default; API-key input is hidden. When setup runs from a saved copy, the selected values are written back to `d.sh` and the file mode is changed to `600`.

Other harness settings (`DSH_*`) are documented in the configuration block at the top of `d.sh`. Environment variables override values stored in the script and become the defaults shown during interactive setup.

## Sessions

The conversation is saved to `session.jsonl` in the working directory and resumed automatically on the next run. Each line contains the role, a tab, and the message JSON. `/clear` empties the file. Set `DSH_SESSION_FILE` to another path, or to an empty value to disable persistence.

Only complete turns are written, so an interrupted run never resumes on a half-finished tool exchange.

## Tools

| Tool | Description |
| --- | --- |
| `bash` | Persistent shell — cwd, environment, functions and virtualenvs survive across calls and turns |
| `str_replace_editor` | `view` / `create` / `str_replace` / `insert` on text files |

## Interactive commands

- `/compact` — summarize older history
- `/clear` — reset the conversation and persistent shell
- `/exit` — quit
- `Ctrl+C` — cancel the in-flight model request or running command and return to the prompt; a running command also resets the persistent shell
- `Ctrl+D` — quit (same as `/exit`)

## DeepSeek Harness alignment

Behavior tracks the [`sdk-minimal`](https://github.com/deepseek-ai/deepseek-harness/tree/dsh-v0.1.5-alpha.1/packages/bundle/sdk-minimal) profile of **deepseek-harness `dsh-v0.1.5-alpha.1` (`0.1.5-alpha.1`)** — the last release whose `sdk-minimal` bundle shipped the **two-tool** profile. That bundle is unchanged since `v0.1.3-alpha.2`; `dsh-v0.1.5-alpha.2` and later drop `str_replace_editor` and advertise only a persistent shell.

What that means here:

- One persistent Bash shell (300-second timeout) plus `str_replace_editor`; the editor's upstream `maxOutputChars: 16000` matches this script's `DSH_OUTPUT_LIMIT` and tool description.
- Persona defaults to `You are a helpful software engineer assistant.`, with no Harness identity or runtime context.
- Uncompressed JSONL sessions (here: `session.jsonl` in the working directory), a 1,000,000-token fallback context window, and `danger-full-access` (no sandbox).
- Automatic compaction, tool-result pruning and the `[Deep diving ...]` / `[Compacting context ...]` status text are adapted from the full harness of the same series (`compaction-basic`, `compaction-tool-result-pruner`, `ui-chat` locale), because `sdk-minimal` itself excludes compaction.

The wire protocol is the OpenAI-compatible **Chat Completions** API: `POST {BASE_URL}/chat/completions` with Bearer auth and `messages` / `tools` / `stream` / `max_tokens`, plus DeepSeek's `thinking` and `reasoning_effort` extensions. This is the same protocol as upstream `@deepseek-ai/dsh-llm-deepseek`; it is neither the legacy text Completions API (`/completions`) nor the OpenAI **Responses** API (`/responses`, `input` / `instructions`).

## Security

Commands run with your permissions and without a sandbox. Interactive setup stores the API key in the local `d.sh`; never commit or share that configured copy. Session files contain the full conversation and should also remain outside version control.

## Acknowledgements

An independent implementation inspired by [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) (MIT); the persona, tool schemas and minimal-profile behavior are adapted from the two-tool `sdk-minimal` bundle at `dsh-v0.1.5-alpha.1`, and compaction/status behavior from that release's full-harness packages.

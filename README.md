# Qwen3.8 27B — containerized llama-server

[![image](https://github.com/onixldlc/qwen38-server/actions/workflows/build.yml/badge.svg)](https://github.com/onixldlc/qwen38-server/actions/workflows/build.yml)

Qwen3.8 27B served by **stock upstream llama.cpp** — no fork, no patched ggml types. The
weights are [Unsloth Dynamic](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) GGUFs
(`UD-*`), ordinary K-quants that an official release tarball loads as-is. The image is the
upstream release binaries plus an entrypoint that fetches the weights and starts the server.

| Piece | Value |
|---|---|
| Base model | Qwen3.8 27B (`qwen35` arch, hybrid attention + SSM, 262144 native context), Apache 2.0 |
| Weights | [`unsloth/Qwen3.8-27B-GGUF`](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) |
| llama.cpp release | [`b11461`](https://github.com/ggml-org/llama.cpp/releases/tag/b11461), asset `bin-ubuntu-cuda-12.8-x64` (gpu) / `bin-ubuntu-x64` (cpu) |
| Image | [`ghcr.io/onixldlc/qwen38-server`](https://github.com/onixldlc/qwen38-server/pkgs/container/qwen38-server) |
| API | OpenAI-compatible on `:8080` (`/v1/chat/completions`), web UI at `/` |

Links: [weights on HuggingFace](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) ·
[llama.cpp](https://github.com/ggml-org/llama.cpp) ·
[llama-server docs](https://github.com/ggml-org/llama.cpp/tree/master/tools/server) ·
[GHCR package](https://github.com/onixldlc/qwen38-server/pkgs/container/qwen38-server) ·
[build workflow](.github/workflows/build.yml)

## Layout

```
docker/        Dockerfile + entrypoint.sh + verify.sh + mcp-web.sh — shared by both stacks
gpu/           compose.yaml + compose-dev.yaml + .env  — CUDA
cpu/           compose.yaml + compose-dev.yaml + .env  — CPU-only, for a VPS
VERSION        the release number; changing it is what triggers a publish
.github/       workflow that builds both variants and pushes them to GHCR
```

`compose.yaml` pulls the published image — `:gpu` or `:cpu` — so a plain `up` downloads a
build instead of making one:

```bash
cd gpu && podman compose up -d     # CUDA card
cd cpu && podman compose up -d     # VPS
```

`compose-dev.yaml` is the override that builds from this checkout instead. Use it whenever
you are changing anything under `docker/`, since a published tag cannot contain edits you
have not released yet:

```bash
cd gpu && podman compose -f compose.yaml -f compose-dev.yaml up -d --build
```

It replaces nothing but the image source: ports, volume, devices and `env_file` still come
from `compose.yaml`, and the local tag (`localhost/qwen38-server:dev-gpu`) is distinct so a
dev build never shadows the pulled one. The Dockerfile takes `BASE_IMAGE` and
`LLAMA_FLAVOR` build args, which is how one file yields the CUDA image (`nvidia/cuda` base,
172 MB release asset) and the CPU image (`ubuntu:24.04`, 17.7 MB asset); the cpu dev
override sets them, gpu uses the defaults.

Both declare a volume named `qwen38-models`, but compose prefixes it with the folder name,
so on one host they are `gpu_qwen38-models` and `cpu_qwen38-models` — separate 18.5 GB copies.
That only matters if you run both on the same machine.

## Prebuilt images

Skip the build and pull from GHCR. One image name, the variant is the tag:

| Tag | What it is |
|---|---|
| `ghcr.io/onixldlc/qwen38-server:gpu` | newest CUDA build — rolling |
| `ghcr.io/onixldlc/qwen38-server:cpu` | newest CPU-only build — rolling |
| `ghcr.io/onixldlc/qwen38-server:v0.1.0-gpu` | that release's CUDA build — pinned |
| `ghcr.io/onixldlc/qwen38-server:v0.1.0-cpu` | that release's CPU-only build — pinned |

```bash
podman run -d --name qwen38 \
  --device nvidia.com/gpu=0 --security-opt label=disable \
  -v qwen38-models:/models -p 8080:8080 \
  -e MODEL_FILE=Qwen3.8-27B-UD-Q4_K_XL.gguf -e CTX_SIZE=131072 \
  ghcr.io/onixldlc/qwen38-server:gpu
```

## Agent tools

`EXTRA_ARGS` in both `.env.example` files turns on llama.cpp's own built-in tools:

```
--tools read_file,write_file,edit_file,file_glob_search,grep_search,get_info
```

`exec_shell_command` is available upstream and deliberately left out here — it runs in the
container with the server's privileges.

**Where they operate:** a relative path is resolved against the server's working directory,
which this image sets to `/workspace`
([`server-tools.cpp:303-316`](https://github.com/ggml-org/llama.cpp/blob/b11461/tools/server/server-tools.cpp#L303-L316)).
There is no CLI flag for a tool root — the only override is the `x-tool-cwd` header on a
`POST /tools/...` call
([`server-tools.cpp:2089`](https://github.com/ggml-org/llama.cpp/blob/b11461/tools/server/server-tools.cpp#L2089)),
which the model itself cannot set. Both `compose.yaml` files carry a commented-out
workspace mount; uncomment it to give the tools a project:

```yaml
    volumes:
      - qwen38-models:/models
      - ./workspace:/workspace:z
```

Note that an **absolute** path is passed through unchanged
([`server-tools.cpp:162`](https://github.com/ggml-org/llama.cpp/blob/b11461/tools/server/server-tools.cpp#L162)) —
`/workspace` is a default, not a jail. The tools can reach anything the container can.

## Web tools

The model can also search and read the web. `llama-server` speaks MCP over stdio, so this is
one script in the image rather than a service: `docker/mcp-web.sh` is an MCP server exposing
`web_search` and `web_fetch`, built out of `curl` and `jq` and nothing else. Set
`MCP_ENABLE=1` in the stack's `.env`:

```bash
MCP_ENABLE=1
SEARXNG_URL=              # empty = DuckDuckGo lite, no key, no account
SEARCH_RESULTS=8
FETCH_MAX_CHARS=20000
```

The entrypoint renders `/etc/qwen38/mcp.json.template` into a temp dir at start and passes
`--mcp-servers-config` to `llama-server`. The tools then appear as `web_search` /
`web_fetch` in `GET /tools`, in the built-in Web UI and to any OpenAI client that sends a
`tools` array — llama.cpp prefixes MCP tools with the server name, so they show up under the
server named `web`.

`web_search` returns a numbered list of titles and URLs; `web_fetch` returns a page's
visible text with script, style and tags stripped, truncated at `FETCH_MAX_CHARS`. Point
`SEARXNG_URL` at your own SearXNG to keep queries on your network — it needs `json` in its
`search.formats`.

Worth knowing before you turn it on:

- the MCP server is a child process of `llama-server` **with the same privileges**. This one
  only shells out to `curl`, but the mechanism is as trusted as what you declare
- enabling tools of either kind makes llama.cpp default `--cors-origins` to localhost, which
  changes who can reach `:8080` from a browser
- tool-call formatting is the first thing to degrade as the quant gets smaller. `UD-Q2_K_XL`
  is the floor for agentic use; below that, prose still reads fine while the calls stop parsing

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) builds both variants in a
matrix off the one Dockerfile and pushes them to GHCR.

**The `VERSION` file is the trigger.** The workflow runs only on a push to `main` that
changes that file — any other commit costs zero Actions minutes. So a release is one edit,
made from anywhere: the GitHub web editor, github.dev, a phone. No git tag, no local clone,
no credentialed machine.

```
VERSION: 0.1.0 -> 0.2.0        commit to main
  => ghcr.io/onixldlc/qwen38-server:v0.2.0-gpu   (pinned)
     ghcr.io/onixldlc/qwen38-server:v0.2.0-cpu   (pinned)
     ghcr.io/onixldlc/qwen38-server:gpu          (moved to this build)
     ghcr.io/onixldlc/qwen38-server:cpu          (moved to this build)
```

The file holds the bare number (`0.2.0`); the workflow adds the `v`. Pushing the same
VERSION twice republishes over those tags, so bump it to keep a pinned build.

No registry secrets to set up — it logs in with the built-in `GITHUB_TOKEN`. Actions tab →
*Build and Push* → **Run workflow** forces a run without touching the file, with an optional
`version` override and a `publish` checkbox you can clear to build and smoke test only.

## Auto-scaling to the card

`AUTO_SCALE=1` (the default) reads total VRAM with `nvidia-smi` at start and picks the quant,
the context and the KV cache type to match, so one template works on any card:

| VRAM | `MODEL_FILE` | KV | Context | Used | Free |
|---|---|---|---|---|---|
| 12 GB | `UD-Q2_K_XL` | q8_0 | 28672 | 11214 MiB | 1074 MiB |
| 16 GB | `UD-Q3_K_XL` | q8_0 | 57344 | 15329 MiB | 1055 MiB |
| 24 GB | `UD-Q4_K_XL` | q8_0 | 131072 | 21986 MiB | 2590 MiB |
| 32 GB | `UD-Q5_K_XL` | f16 | 98304 | 26942 MiB | 5826 MiB |
| 48 GB | `UD-Q5_K_XL` | f16 | 131072 | 28990 MiB | 20162 MiB |
| 64 GB+ | `UD-Q6_K_XL` | f16 | 262144 (native cap) | 41399 MiB | rest |

Figures are with `ENABLE_VISION=1`; the mmproj is 888 MiB. The rows above 24 GB come from a
fixed table, the 12/16/64+ rows size the context from what is left after weights, mmproj and
`FIT_MARGIN_MIB` (1024 MiB, the same default llama.cpp uses for `--fit-target`).

The KV arithmetic comes from the GGUF header rather than a guess: `block_count = 65` with
`full_attention_interval = 4` leaves 16 full-attention layers, and with `head_count_kv = 4`
and `key_length = value_length = 256` that is 16 x 4 x 512 = 32768 elements per token —
**64 MiB per 1024 tokens at f16, 34 MiB at q8_0**. The other 49 blocks are SSM layers whose
state does not grow with context, which is why a 27B holds 128K on one 24 GB card.

The logic lives in `docker/autoscale.sh`, not buried in the entrypoint, so you can ask it
what it would do without starting anything:

```bash
$ autoscale.sh                      # decide from nvidia-smi
$ VRAM_MIB=49140 autoscale.sh       # decide for a card you do not have
```

It prints `KEY=VALUE` lines on stdout and its reasoning on stderr. Tier thresholds sit below
the nominal card size on purpose — a "24 GB" card reports 24564 MiB (A5000, 3090), 23034 (L4)
or 22731 (A10), so comparing `vram/1024` against 24 would drop every one of them a tier. A
fixed row is also clamped to what actually fits: an A10 gets the 24 GB tier but 118784 context
rather than 131072.

`AUTO_SCALE=0` pins `MODEL_FILE` and `CTX_SIZE` from the environment. `VRAM_MIB=N` overrides
the detection. On multi-GPU hosts the totals are summed, since llama.cpp splits layers across
every visible device.

### Letting llama.cpp size the context instead

`CTX_SIZE=auto` drops `--ctx-size` from the command line entirely. llama.cpp then sizes the KV
pool itself — `fit_params` is **on by default** (`common/common.h:481`) and reserves
`--fit-target` MiB (1024 by default, `common.h:486`). It measures the compute buffers rather
than estimating them, so it is more accurate than any table here; the catch is that it only
adjusts arguments that are not passed, which is why the entrypoint has to leave the flag off
for it to do anything.

## Pick the quant

| VRAM | `MODEL_FILE` | Size | Context (q8_0 KV) |
|---|---|---|---|
| 12 GB | `Qwen3.8-27B-UD-Q2_K_XL.gguf` | 9.8 GB | ~64K |
| 16 GB | `Qwen3.8-27B-UD-Q3_K_XL.gguf` | 13.2 GB | ~96K |
| 24 GB | `Qwen3.8-27B-UD-Q4_K_XL.gguf` | 17.6 GB | 128K |
| 32 GB | `Qwen3.8-27B-UD-Q5_K_XL.gguf` | 20.9 GB | 128K, or f16 KV |

Add 0.93 GB for the vision tower (`ENABLE_VISION=1`), and budget the KV cache on top.

The KV cost is low for a 27B because only every fourth layer is full attention
(`qwen35.block_count = 65`, `qwen35.full_attention_interval = 4` → 16 attention layers; the
other 49 are SSM layers with a constant-size state, ~0.15 GB in total). With 4 KV heads and
`key_length = value_length = 256`, q8_0 at ~1.0625 bytes/element comes to

```
16 layers x 4 heads x (256 + 256) x 1.0625 B  =  ~34.8 KB per token

 32768 -> 1.14 GB      98304 -> 3.42 GB
 65536 -> 2.28 GB     131072 -> 4.56 GB
```

Never go below `q8_0` for the KV cache on this model.

The [ISTA-DASLab GSQ-RCO GGUFs](https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF)
(8.4–11.8 GB) work too — set `MODEL_REPO=ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF`, pick a
`MODEL_FILE` from that repo and `MMPROJ_FILE=mmproj-Qwen3.8-27B-BF16.gguf`. They are a good
pick at 12–16 GB.

## Run

```bash
cp .env.example .env     # pick MODEL_FILE + CTX_SIZE for your card
podman compose up -d
podman logs -f qwen38    # first start downloads 18.5 GB into the qwen38-models volume
curl localhost:8080/v1/models
```

Plain podman, same shape as the invokeai run:

```bash
podman run --rm --name qwen38 \
  --device nvidia.com/gpu=0 --security-opt label=disable \
  -v qwen38-models:/models -p 8080:8080 \
  -e MODEL_FILE=Qwen3.8-27B-UD-Q4_K_XL.gguf -e CTX_SIZE=131072 \
  ghcr.io/onixldlc/qwen38-server:gpu
```

Building it yourself instead: `podman build -t qwen38-server:dev -f docker/Dockerfile .`

`nvidia.com/gpu=0` is the NVIDIA card and nothing else — `/etc/cdi/nvidia.yaml` lists only that
card, so the AMD RX 9060 XT is never handed to the container. `nvidia-ctk cdi list` prints the
valid names. Your older `--runtime=nvidia --gpus '"device=0"'` form still works on the same image.

## CPU-only stack

For a VPS with no GPU. Same weights, same server, `-ngl 0`.

```bash
cd cpu
podman compose up -d --build
```

What is tuned differently in `cpu/.env`:

| Knob | Value | Why |
|---|---|---|
| `N_GPU_LAYERS` | `0` | everything on host cores |
| `CPU_LIMIT` | `3.0` | 50% of a 6 vCPU box |
| `THREADS` / `THREADS_BATCH` | `3` | matched to the quota |
| `ENABLE_VISION` | `0` | the vision tower is slow without a GPU |
| `CTX_SIZE` | `32768` | prompt processing, not RAM, is the limit here |
| `MEM_LIMIT` | `24g` | 17.6 GB weights + ~1.1 GB KV + overhead |
| KV cache | `q8_0` | halves cache RAM for negligible quality cost |

### Capping CPU usage

`cpus:` is a CFS quota, not a core count. The kernel gives the container that much CPU *time*
per scheduling period and freezes it for the rest, so `CPU_LIMIT=3.0` on a 6 vCPU box is a hard
50% ceiling on total usage — it can never pin the whole machine, no matter how many threads
llama.cpp spawns. Scale it to the box: 4 vCPU → `2.0`, 8 vCPU → `4.0`.

Keep `THREADS` equal to `CPU_LIMIT`. Running 6 threads under a 3.0 quota is not faster than
running 3 — the same total CPU time gets split across twice as many threads, each of which is
frozen half the time, which wastes cache locality and adds latency.

`cpu_shares: 512` is a different dial: it only decides who wins when the host is contended,
leaving the hard cap untouched. `mem_limit` bounds RAM. Swap in `cpuset: "0-2"` for hard core
pinning if you want the inference confined to specific cores rather than given a time share.

Sizing: 17.6 GB weights + roughly 1.1 GB of q8_0 KV at 32768 + overhead — a 24 GB box is the
realistic floor, and `UD-Q2_K_XL` brings that down to about 16 GB. Be honest about the speed:
this is a **dense** 27B, so decode lands in the low single digits of tokens/second on a VPS.
It is bound by memory bandwidth rather than clock speed, so a box with faster RAM beats one
with more cores. Measure yours before committing:

```bash
podman exec qwen38-cpu llama-bench -m /models/Qwen3.8-27B-UD-Q4_K_XL.gguf -ngl 0 -t 3
```

## This machine (hybrid AMD + NVIDIA)

GPU 0 is an AMD RX 9060 XT driving the display; GPU 1 is the RTX 3060 (`0000:0d:00.0`,
`card1` / `renderD129`). The NVIDIA container toolkit only ever enumerates NVIDIA cards, so
inside the container the 3060 is device 0 and the AMD card is invisible — nothing to exclude.
Confirmed 12288 MiB and driver 615.71.09.

**The shipped `gpu/.env.example` targets a 24 GB card, not this one.** `UD-Q4_K_XL` is
17.6 GB and will not fit in 12 GB. On the 3060:

```bash
MODEL_FILE=Qwen3.8-27B-UD-Q2_K_XL.gguf   # 9.8 GB
ENABLE_VISION=0                          # the 0.93 GB tower does not fit alongside the KV cache
CTX_SIZE=65536                           # 2.28 GB of q8_0 KV; drop to 32768 if it OOMs
```

That is ~9.2 GiB of weights + ~2.1 GiB of KV + compute buffers against 12 GiB — it fits, but
with little room. The 24 GB defaults are for the A5000-class card.

With a hybrid-graphics manager in play, keep the 3060 out of runtime D3 power-off while the
container holds it — a suspended card shows up as a CUDA init failure at startup, not as a
clean error.

## Getting the weights in

The entrypoint pulls each file with plain resumable `curl` straight from the HF CDN —
no `hf` CLI, no Python, no Xet. A stalled transfer resumes from the byte it reached
(`curl -C -` against a `.part` file) and retries up to `DOWNLOAD_ATTEMPTS` times; a transfer
that drops under 1 KB/s for 60 s is cut and resumed rather than left hanging.

**Or download them yourself** and drop them in. **A file that is already in the volume is
never downloaded again** — the entrypoint only checks that it is present, non-empty and
readable. The `GGUF` magic bytes are checked too, but a mismatch is a warning, not a reason
to spend 18 GB of bandwidth again; delete the file if you want it refetched. A file the
container's uid cannot read is a hard error naming the fix (ownership, or `:Z` on the volume
mount if SELinux is relabelling it) rather than a silent re-download.

```bash
curl -L -C - -O https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q4_K_XL.gguf
curl -L -C - -O https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/mmproj-BF16.gguf

podman run --rm -v qwen38-models:/models -v "$PWD":/host:z \
  docker.io/library/busybox sh -c 'cp /host/*.gguf /models/'
```

Resume a half-finished host download by re-running the same `curl -C -` line.

## Weights volume

Weights live in the named volume `qwen38-models`, so `compose down` / `up` never re-downloads.
It holds the `.gguf` files and nothing else — `verify.sh` fails if anything else turns up in
there.

```bash
podman volume inspect qwen38-models --format '{{.Mountpoint}}'
podman run --rm -v qwen38-models:/m docker.io/library/busybox ls -lA /m
podman volume rm qwen38-models    # only if you want the 18.5 GB back
```

## Verify

```bash
podman exec -it qwen38 verify.sh
```

Checks GPU passthrough, that the binary runs, that the build is new enough for the `--tools`
in `EXTRA_ARGS`, weights on disk, a weights-only volume, and `/health`.

## Sampling

```
--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.05
--tools read_file,write_file,edit_file,file_glob_search,grep_search,get_info
--cache-type-k q8_0 --cache-type-v q8_0
```

Set via `EXTRA_ARGS`. Reasoning effort defaults to `xhigh`, which overthinks and loops on
this model — add `--chat-template-kwargs '{"reasoning_effort":"medium"}'` for normal use.

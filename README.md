# SidePulse Dot — Omarchy bar plugin

A small Omarchy bar widget to **drive and test a [SidePulse Dot](https://sidepulse.io)**
(the tiny two-LED USB device) straight from the status bar. No drivers, no
daemon — the Dot mounts as a small FAT volume and you control its LEDs by
writing an LED-DSL program to its `LEDS.LED` file. This plugin does exactly
that from a native panel.

## What it does

- A bar icon that dims when no Dot is connected and lights up when one is
  mounted (left-click opens the panel, middle-click refreshes, right-click
  turns the LEDs off).
- A panel split into two screens, chosen with the tab chips at the top:
  - **Reactions** (primary) — the agent-reactions section, so the most
    important controls are what you see first.
  - **Manual** — the demo/test controls (Control, Colors, Brightness,
    Animations) and the Custom-program field, kept out of the main view.
- The **Reactions** screen has:
  - **Agent reactions** — see below.
- The **Manual** screen has:
  - **Control** — when more than one Dot is plugged in, a row of chips
    (**Dot 1**, **Dot 2**, …, **Both**) picks which Dot the colors, presets,
    brightness and custom program below apply to. "Both" drives every Dot at
    once. The chip row is hidden when only a single Dot is connected.
  - **Colors** — a row of swatches. Left-click a swatch for a solid color;
    right-click to breathe (pulse) that color.
  - **Brightness** — a slider (8–255) that re-applies the current color/preset.
  - **Animations** — one-click presets (breathing cyan, alternating red/blue,
    rainbow roll, police blink, green heartbeat).
  - **Custom program** — a text field to type any `LEDS.LED` program
    (use `\n` for newlines) and apply it live. See the DSL reference below.
  - **Agent reactions** — make the Dots react to your CLI coding agents'
    state (`agy`, `grok`, `junie`, `opencode`). Toggle it **On**, then for
    each state (**Working**, **Waiting for input**, **Done**, **Error**,
    **Idle**) pick a **color** and, independently, an **animation** —
    **Solid**, **Breathe**, **Blink**, **Fast** or **Heartbeat** — so the
    same color can be shown with any pattern. Each state also has its own
    **brightness** slider (8–255), set independently of the color and
    animation. The ∅ swatch blanks a state (the animation and brightness
    are remembered and return when you pick a color again).
    A live line shows which agent is doing what; **Test** previews a state;
    **Install agent hooks** wires the agents to report. With several Dots a
    **Mode** selector picks how they share the statuses:
    - **Merged** — every reacting Dot shows the single merged status; below
      it, choose whether reactions follow your **Selected Dot**, drive **All
      Dots**, or a specific Dot.
    - **Latest per Dot** — the Dots form a rolling window of the most recent
      statuses (no agent is pinned to a Dot): a new status from an agent that
      is **not** already shown lights the Dot that has been showing the
      **oldest** status. A new status from an agent that **is** already on a
      Dot overrides *that same Dot* (its old status is now stale), and when an
      agent goes idle its Dot returns to the **Idle** program — so the Dots
      never show an out-of-date status, only the latest live one per agent.
      Any Dot with no live agent status (including at startup, before any
      agent has reacted) is driven to the **Idle** program too, so a Dot is
      never left holding a leftover manual program when nothing is running —
      set **Idle** to ∅ (off) to have such Dots go dark.
  - **Device info** — serial, firmware, controller state, and mount path.
    With several Dots connected it lists one line per Dot (serial + firmware).

## How it works

All device access goes through [`bin/sidepulse-dot`](bin/sidepulse-dot), a
self-contained bash helper that:

- enumerates **every** mounted SidePulse volume (looks for `PulseDot`/
  `SidePulse*` volumes, or any mount exposing `LEDS.LED` + `STATUS.TXT`),
  returning them in a stable order sorted by serial,
- reads each `STATUS.TXT` for firmware/serial/state,
- decodes `\n` escapes and writes the program to `LEDS.LED`,
- prints a single JSON object so the QML panel can react.

It supports targeting a specific Dot (or several) with repeatable `--device`
flags:

```sh
sidepulse-dot list                              # JSON array of all Dots
sidepulse-dot status --device /run/media/$USER/PulseDot
sidepulse-dot write "#00ff00" --device /run/media/$USER/PulseDot1
sidepulse-dot off                               # no --device = all Dots
```

`Service.qml` polls `list`, keeps the device list plus a selected target
("all" or a mount path), and issues per-device writes; `Panel.qml` is the UI.
Nothing depends on the upstream `sidepulse` Python CLI.

## Agent reactions

Agent state flows through a second helper,
[`bin/sidepulse-agent`](bin/sidepulse-agent):

```sh
sidepulse-agent report <agent> <state>   # push a state (called by hooks)
sidepulse-agent effective                # merged state across all agents
sidepulse-agent config-get | config-set  # the reactions config (JSON)
sidepulse-agent install-hooks            # wire the agents to report
```

- **States** are normalised to `working | waiting | done | error | idle`.
- The **effective** state is the highest-priority live state across all
  agents (`error` > `waiting` > `working` > `done` > `idle`), so the Dots
  react to whichever agent you're using — and each agent is tracked
  individually (visible via `effective`/the panel's live line). A report
  older than 5 min (`SIDEPULSE_AGENT_STALE`) decays to idle.
- **How each agent reports** (all wired by `install-hooks`):
  - **opencode** — a generated plugin at
    `~/.config/opencode/plugin/sidepulse-dot.js` (chat/tool → working,
    permission ask → waiting, `session.idle` → done, `session.error` → error).
  - **grok** — no command hook is relied on; grok's state is read live
    from the newest `~/.grok/sessions/*/*/events.jsonl` (its `turn_ended`
    outcome → done/error, an open `permission_requested` or a
    `permission_prompt` phase → waiting, `streaming_*`/`tool_execution`/
    `waiting_for_model` phases → working), so nothing needs installing and a
    running grok is detected immediately. `install-hooks` still appends
    `[[hooks.*]]` to `~/.grok/config.toml` (after a timestamped backup) as a
    best-effort push, but grok's config hooks do not reliably fire, which is
    why the live event-log read is the primary signal.
  - **junie** — no command hook; its state is read live from the newest
    `~/.junie/sessions/*/events.jsonl` (`IN_PROGRESS`/`INPUT_REQUIRED`/
    `COMPLETED`), so nothing is installed.
  - **agy** (Google Antigravity CLI) — two complementary signals:
    - **hooks** — `install-hooks` writes `~/.gemini/config/hooks.json`
      (the global customization root) with safe, non-gating lifecycle
      hooks: `PreInvocation`/`PostToolUse` → working, `Stop` → done (or
      error when the stop carries an error). Each hook only echoes `{}`,
      so agy's agent loop is never altered. An existing `hooks.json` is
      merged (our entry is keyed `sidepulse-dot`) after a timestamped
      backup.
    - **live file-watch** — agy keeps an activity trail under
      `~/.gemini/antigravity-cli` (`cli.log`, `history.jsonl`,
      `conversations/*.db`); recent writes are read as **working** even
      before any hook fires, so a running agy is detected immediately
      (window `SIDEPULSE_AGY_WINDOW`, default 25s). A fresh pushed hook
      state takes precedence over the file-watch guess.
    - You can still push manually: `sidepulse-agent report agy <state>`.
- The reactions config is stored at
  `~/.config/sidepulse-dot/reactions.json`; per-agent states live under
  `~/.local/state/sidepulse-dot/agents/`. Reactions are **off by default**.
  Each state keeps a `styles` entry (`{ "hex", "anim", "brightness" }`) —
  the color, animation and brightness chosen in the panel — alongside the
  compiled `programs` string the Dots run; configs saved before `styles`
  (or before `brightness`) existed are migrated by
  inferring the color/animation from the program. A `mode` key
  (`merged` | `rolling`) selects how multiple Dots share statuses; in
  `rolling` mode the per-Dot rolling window is runtime-only (rebuilt from
  the agents' live states on load), so nothing extra is persisted.
- The panel's **manual-control** selections are persisted in the same
  `reactions.json` under a `ui` block (`{ "target", "hex", "mode",
  "brightness" }`) — the Dot **Control** selector plus the last color,
  animation (solid/pulse) and brightness you picked — so the panel comes
  back exactly as you left it after a plugin reload or a full shell restart.
  Missing keys fall back to sensible defaults (target `all`, cyan, 255).

## Install / enable

The plugin lives at `~/.config/omarchy/plugins/reinier.sidepulse-dot/`. Add it
to the bar by putting an entry in `~/.config/omarchy/shell.json` under
`bar.layout.right` (or any section):

```json
{ "id": "reinier.sidepulse-dot" }
```

`shell.json` hot-reloads on save. If a code change doesn't show up, force a
reload with `omarchy-shell shell rescanPlugins`.

## LED program reference

The `LEDS.LED` DSL (colors, timing, easing, `pulse`, `roll`, `repeat`,
brightness, per-LED indexing) is documented upstream in `LEDS_FORMAT.md`. The
Dot has **2 LEDs**, so only indexes `0` and `1` light up. Examples:

```text
#00ff00                        # solid green
off
#00c8ff 1.6s pulse
repeat                         # breathing cyan
0:#ff0000 1:#0040ff            # LED0 red, LED1 blue
```

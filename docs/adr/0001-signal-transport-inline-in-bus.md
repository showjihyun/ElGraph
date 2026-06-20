# Signal transport stays inline in Signal.Bus, not a SignalTransport behaviour

**Status:** accepted

`ElGraph.Signal.Bus` chooses its transport with a runtime check (`Pg.started?(bus)`)
inside `subscribe/1`, `subscribe/2`, and `publish/1` — `:local` uses a `Registry`,
`:pg` uses distributed Erlang `:pg`. The bus **is** the transport; there is no
`SignalTransport` behaviour with adapters. This was decided during implementation
(SPEC §13, review R6): the originally-specced `SignalTransport` behaviour was
deliberately collapsed into the bus.

## Considered options

- **A `SignalTransport` behaviour with `Local` and `Pg` adapters.** Would remove the
  runtime `if/else` and let each transport be unit-tested in isolation (the
  architecture-review reflex — "two transports = a real seam, express it as adapters").
- **Inline dispatch in the bus (chosen).** Two fixed, in-repo transports dispatched by
  a small runtime check at three call sites.

## Why

There are exactly **two** transports, both maintained in this repo, with no requested
user-pluggability. A behaviour would add an indirection layer for no caller benefit —
callers already see a single `Bus` interface regardless of transport, which is the
point. SPEC §13 made this trade-off explicitly.

## Consequences

- The `:pg` transport cannot be exercised in pure isolation (a `:pg` test needs a
  running `:pg` bus); the bus tests cover both transports end-to-end instead.
- **Do not re-suggest** extracting a `SignalTransport` behaviour on the strength of the
  inline `Pg.started?` branch alone. Revisit only if a **third** transport appears or
  user-defined transports become a requirement — then the seam earns its keep.

# Canvas snapshot: Web3 Browser product model

| Field | Value |
|---|---|
| **Date** | 2026-08-23 |
| **Status** | Design + Phase 0 scaffold |
| **Source of truth** | `src/web3-browser/` (README, RULES, whitepaper, MVP) |
| **Related canvases** | Cursor canvases `web3-browser-cross-platform`, `web3-browser-shell-pwa` (IDE-managed; not duplicated as runnable `.canvas.tsx` in-repo) |

## Frozen conclusions

1. Product = **native shell + local PWA**, not Electron.
2. Main logic in **TypeScript** (SI, web3Host, L2 on-demand); native owns sockets + host bind.
3. **IndexedDB** stores published website files (local-first).
4. **Embedded OTA** via `update.json` + zip.
5. Capability **④** remains open.

## Assumptions

- Beamio CashTrees-style bridge lineage can be extended with socket APIs.
- Linux `conet-l0d` remains the server-grade reference; phones implement protocol portability.

## Open items

- Lock product capability ④.
- Choose first native platform for Phase 1 (iOS vs Android vs desktop Tauri).

## Implementation checklist

- [x] `src/web3-browser` package + stubs
- [x] Docs + EN/ZH whitepaper + MVP phases
- [x] GitBook applications stub `web3-browser.md`
- [ ] Phase 1 native socket bridge
- [ ] Deploy GitBook when product requires public sync
